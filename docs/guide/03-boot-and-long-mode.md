# 03 — Boot: from firmware to a 64-bit higher-half C function

> Goal of this chapter: `make run` prints `Nyx booting on x86_64` over serial,
> from a C function executing at `0xFFFFFFFF801xxxxx` in 64-bit long mode, with
> a proper stack, cleared `.bss`, and the bootloader's memory map in hand.

---

## 1. Theory: the boot problem

Boot is a **bootstrapping** problem in the literal sense: the machine starts in a
state where almost nothing your code needs exists, and each step must construct
the preconditions for the next.

The chain:

```
Power on
  → CPU starts in real mode at 0xFFFFFFF0 (BIOS) or firmware runs (UEFI)
  → Firmware initializes RAM, enumerates a bit of hardware, finds a boot device
  → Firmware loads a bootloader
  → Bootloader loads YOUR kernel, in a defined format, and hands over control
    in a defined CPU state, with a defined information structure
  → Your kernel takes over
```

The interesting design question is: **where in that chain do you start?**

| Start point | What you must write | What you learn | Verdict |
|---|---|---|---|
| Real mode, 512-byte MBR | Everything: disk reading via BIOS interrupts, A20, protected mode, loading your own ELF | 1980s PC arcana | Fun once. Not a good use of your months. |
| Multiboot2 (GRUB/Limine) | 32→64 transition, page tables, GDT | Real, transferable: mode switching, paging enablement | **Recommended for learning.** |
| Limine protocol | Nothing — you get 64-bit, higher-half, paging on, framebuffer up | Nothing about boot; everything about your kernel | **Recommended for iterating.** |
| Raw UEFI (with GNU-EFI / POSIX-UEFI) | A UEFI app that gets the memory map, exits boot services, sets up paging, jumps to kernel | Modern firmware reality | Do this in Chapter 13 as an exercise. |

**Recommendation:** implement Multiboot2 by hand (this chapter). Then add a
Limine path behind an `#ifdef` so you can iterate quickly on later chapters and
still boot on real UEFI hardware. Isolate both behind a common
`struct bootinfo` — that abstraction is worth having anyway.

---

## 2. The Multiboot2 specification, in practice

Multiboot2 defines:

**A header** the bootloader searches for in the first 32 KiB of your ELF,
8-byte aligned:

```
magic     = 0xE85250D6
arch      = 0 (i386 protected mode)
length    = size of header
checksum  = -(magic + arch + length)   [mod 2^32]
... optional tags ...
end tag   (type=0, flags=0, size=8)
```

**A machine state on entry:**

- 32-bit protected mode, paging **off**, interrupts **off**
- `EAX = 0x36D76289` (the multiboot2 magic — always check it!)
- `EBX = physical address of the boot information structure`
- `CS` = a 32-bit code segment, `DS/ES/FS/GS/SS` = 32-bit data segments
  (their exact GDT is unspecified and will disappear — build your own)
- `ESP` is **undefined**. You have no stack. Your first job is to make one.
- A20 gate is enabled

**A boot information structure** at `[EBX]`: a `total_size`/`reserved` header
followed by a chain of 8-byte-aligned tags:

```
type=1  boot command line
type=2  bootloader name
type=3  module (an extra file loaded into memory: our initrd!)
type=4  basic memory info (legacy)
type=6  memory map (E820-derived) ← the important one
type=8  framebuffer info
type=9  ELF section headers (symbols! useful for backtraces)
type=14 ACPI RSDP v1
type=15 ACPI RSDP v2 ← how you find ACPI tables
type=21 image load base physical address
type=0  end
```

---

## 3. Implementation: `arch/x86_64/boot.asm`

This is the complete boot stub. Read the comments; every line is load-bearing.

```nasm
; arch/x86_64/boot.asm — Multiboot2 header + 32-bit → long mode transition
;
; Entry state: 32-bit protected mode, paging off, no stack, EAX=magic, EBX=mbi
; Exit state:  64-bit long mode, higher-half, stack set, calls kmain(mbi_phys)

%define KERNEL_VMA 0xFFFFFFFF80000000
%define V2P(x)     ((x) - KERNEL_VMA)

; ---------------------------------------------------------------- header ----
section .multiboot_header
align 8
mb_header_start:
    dd 0xE85250D6                       ; magic
    dd 0                                ; architecture: i386 protected mode
    dd mb_header_end - mb_header_start  ; header length
    dd 0x100000000 - (0xE85250D6 + 0 + (mb_header_end - mb_header_start))

    ; --- information request tag: ask for the memory map and modules -------
    align 8
    dw 1                                ; type: information request
    dw 0                                ; flags (0 = required)
    dd 8 + 4*4                          ; size
    dd 6                                ; memory map
    dd 3                                ; modules
    dd 8                                ; framebuffer
    dd 15                               ; ACPI 2.0 RSDP

    ; --- end tag -----------------------------------------------------------
    align 8
    dw 0
    dw 0
    dd 8
mb_header_end:

; ------------------------------------------------------- 32-bit boot code ---
section .boot.text progbits alloc exec nowrite
bits 32
extern __bss_start
extern __bss_end

global _start
_start:
    cli
    cld
    mov esi, eax                        ; the .bss wipe below clobbers EAX

    ; Zero .bss HERE, with paging still off and before we have a stack. NOT
    ; after the long-mode jump: the boot page tables live in .bss (see the data
    ; section below), so a wipe performed once CR3 points at them destroys the
    ; live mappings, and the only thing between you and a triple fault is a
    ; stale TLB entry. §3.1 explains why that sometimes appears to work.
    mov edi, V2P(__bss_start)
    mov ecx, V2P(__bss_end)
    sub ecx, edi
    xor eax, eax
    rep stosb

    mov esp, V2P(boot_stack_top)        ; a stack, at last (physical address)
    push 0                              ; align + terminate any backtrace
    push 0
    mov ebp, esp

    ; Stash the multiboot values before anything can clobber them.
    mov [V2P(mb_magic)], esi
    mov [V2P(mb_info_ptr)], ebx

    cmp esi, 0x36D76289
    jne .no_multiboot

    call check_cpuid
    call check_long_mode
    call setup_page_tables
    call enable_paging_and_long_mode

    ; We are now in a 32-bit compatibility segment with long mode ACTIVE.
    ; Load a 64-bit GDT and far-jump to flush CS with a 64-bit code selector.
    ;
    ; .pointer32, not .pointer: a 32-bit LGDT takes a 16-bit limit and a 32-bit
    ; base, so a higher-half base is silently truncated to its low half. See
    ; §3.1 #1 — this is the single most confusing failure in the chapter.
    lgdt [V2P(gdt64.pointer32)]
    jmp gdt64.kcode:V2P(long_mode_entry)

.no_multiboot:
    mov al, '0'
    jmp boot_error

; ---- CPU feature checks ----------------------------------------------------
; CPUID is available iff we can flip EFLAGS.ID (bit 21).
check_cpuid:
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 1 << 21
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd                               ; restore
    cmp eax, ecx
    je .fail
    ret
.fail:
    mov al, '1'
    jmp boot_error

check_long_mode:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001                 ; is the extended leaf available?
    jb .fail
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29                   ; LM bit
    jz .fail
    ret
.fail:
    mov al, '2'
    jmp boot_error

; ---- Page tables -----------------------------------------------------------
; We build the minimum needed to survive the jump:
;   * identity map    0x00000000..0x40000000   (1 GiB, 2 MiB pages)
;     -- required because RIP is still low when we enable paging
;   * higher-half map 0xFFFFFFFF80000000+      (same 1 GiB)
;     -- where the kernel is linked
;   * direct map      0xFFFF800000000000+      (first 4 GiB, 1 GiB pages)
;     -- so C code can touch arbitrary physical memory immediately
;
; PML4 index for 0xFFFFFFFF80000000 = (addr >> 39) & 0x1FF = 511
; PDPT index                        = (addr >> 30) & 0x1FF = 510
; PML4 index for 0xFFFF800000000000 = 256
setup_page_tables:
    ; PML4[0]   -> pdpt_low   (identity)
    mov eax, V2P(pdpt_low)
    or  eax, 0b11                       ; present | writable
    mov [V2P(pml4) + 0*8], eax

    ; PML4[511] -> pdpt_high  (kernel higher half)
    mov eax, V2P(pdpt_high)
    or  eax, 0b11
    mov [V2P(pml4) + 511*8], eax

    ; PML4[256] -> pdpt_dmap  (direct physical map)
    mov eax, V2P(pdpt_dmap)
    or  eax, 0b11
    mov [V2P(pml4) + 256*8], eax

    ; pdpt_low[0]    -> pd  (covers 0..1GiB)
    mov eax, V2P(pd_low)
    or  eax, 0b11
    mov [V2P(pdpt_low) + 0*8], eax

    ; pdpt_high[510] -> same pd  (covers -2GiB..-1GiB)
    mov [V2P(pdpt_high) + 510*8], eax

    ; pd_low[i] = i * 2MiB, present | writable | huge
    xor ecx, ecx
.map_pd:
    mov eax, 0x200000
    mul ecx                             ; edx:eax = ecx * 2MiB
    or  eax, 0b10000011                 ; present | writable | PS(huge)
    mov [V2P(pd_low) + ecx*8], eax
    mov dword [V2P(pd_low) + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 512
    jne .map_pd

    ; Direct map: 4 x 1GiB pages at pdpt_dmap[0..3].
    ; NOTE: 1GiB pages require CPUID.80000001:EDX[26]. We check it and fall
    ; back to reusing pd_low for the first GiB if unsupported.
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 26
    jz .no_gbpages

    xor ecx, ecx
.map_dmap:
    mov eax, 0x40000000
    mul ecx                             ; edx:eax = ecx * 1GiB
    or  eax, 0b10000011                 ; present | writable | PS
    mov [V2P(pdpt_dmap) + ecx*8], eax
    mov [V2P(pdpt_dmap) + ecx*8 + 4], edx
    inc ecx
    cmp ecx, 4
    jne .map_dmap
    ret

.no_gbpages:
    mov eax, V2P(pd_low)
    or  eax, 0b11
    mov [V2P(pdpt_dmap) + 0*8], eax
    ret

; ---- Turn on PAE, NX, long mode, paging ------------------------------------
enable_paging_and_long_mode:
    ; CR4.PAE (bit 5) — mandatory for long mode
    ; CR4.PGE (bit 7) — global pages
    mov eax, cr4
    or  eax, (1 << 5) | (1 << 7)
    mov cr4, eax

    ; CR3 = physical address of PML4
    mov eax, V2P(pml4)
    mov cr3, eax

    ; EFER.LME (bit 8) + EFER.NXE (bit 11) + EFER.SCE (bit 0, for syscall)
    mov ecx, 0xC0000080
    rdmsr
    or  eax, (1 << 8) | (1 << 11) | (1 << 0)
    wrmsr

    ; CR0.PG (bit 31) | CR0.WP (bit 16)
    mov eax, cr0
    or  eax, (1 << 31) | (1 << 16)
    mov cr0, eax
    ret                                 ; long mode is now ACTIVE (EFER.LMA=1)

; ---- Early error reporting: write to VGA text buffer + serial ---------------
; AL holds an ASCII error code. Paging may or may not be on; we are still low.
boot_error:
    mov dword [0xB8000], 0x4F524F45     ; "ER" white-on-red
    mov dword [0xB8004], 0x4F3A4F52     ; "R:"
    mov byte  [0xB8008], al
    mov byte  [0xB8009], 0x4F
.hang:
    cli
    hlt
    jmp .hang

; ------------------------------------------------------- 64-bit entry -------
section .text
bits 64
extern kmain

long_mode_entry:
    ; Reload data segment registers with null — in long mode their bases are
    ; forced to 0 and only the null selector is guaranteed sane.
    mov ax, 0
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; Jump to the higher-half copy of our own code. Until now RIP was low.
    mov rax, .higher_half
    jmp rax
.higher_half:
    ; Reload the GDT with its higher-half base, now that a 64-bit LGDT can carry
    ; one. Without this the GDT sits at a linear address the next block is about
    ; to unmap. The descriptors don't change, so the cached CS stays valid.
    lgdt [gdt64.pointer]

    ; Real, higher-half stack.
    mov rsp, boot_stack_top
    xor rbp, rbp

    ; .bss was zeroed by the 32-bit stub, before CR3 pointed into it. (The
    ; bootloader zeroes it per spec, but do not trust that: module loaders and
    ; the Limine path differ.)

    ; Drop the identity mapping now that we're running high. This catches any
    ; accidental use of low addresses immediately, instead of in month three.
    mov rax, pml4
    mov qword [rax], 0
    mov rax, cr3
    mov cr3, rax                        ; flush TLB

    ; kmain(uint32_t magic, uint64_t mbi_phys)
    mov edi, [mb_magic]
    mov esi, [mb_info_ptr]              ; zero-extends to rsi — correct, it's
                                        ; a 32-bit physical address
    call kmain

.halt:
    cli
    hlt
    jmp .halt

; ------------------------------------------------------------ data ----------
section .rodata
align 16
gdt64:
    dq 0                                            ; null descriptor
.kcode: equ $ - gdt64
    dq (1<<41)|(1<<43)|(1<<44)|(1<<47)|(1<<53)      ; RW|exec|code|present|L
.kdata: equ $ - gdt64
    dq (1<<41)|(1<<44)|(1<<47)                      ; RW|data|present
.end:

; For the 32-bit LGDT: 16-bit limit + 32-bit base, so the base must be the
; physical (identity-mapped) address.
.pointer32:
    dw gdt64.end - gdt64 - 1
    dd V2P(gdt64)

; For the 64-bit LGDT once we are running high: 16-bit limit + 64-bit base.
.pointer:
    dw gdt64.end - gdt64 - 1
    dq gdt64

; `alignb`, not `align`: in a nobits section NASM's `align` tries to emit
; padding *bytes* and warns, which is fatal if you build at zero warnings.
section .bss
alignb 4096
global pml4
pml4:      resb 4096
pdpt_low:  resb 4096
pdpt_high: resb 4096
pdpt_dmap: resb 4096
pd_low:    resb 4096

alignb 16
mb_magic:    resd 1
mb_info_ptr: resd 1

alignb 16
boot_stack_bottom:
    resb 16384                          ; 16 KiB boot stack
boot_stack_top:
```

### 3.1 Things that will bite you here

1. **The 32-bit `lgdt` cannot be given a higher-half base.** This one is worth
   slowing down for, because the operand and its contents are translated
   differently and it is tempting to conflate them.

   We execute `lgdt` *after* `enable_paging_and_long_mode`, so paging is on and
   both mappings are live. The *operand address* `V2P(gdt64.pointer32)` resolves
   through the identity map — fine. But the *contents* are not an address the
   CPU resolves through anything: they are loaded straight into GDTR, and **the
   32-bit form of `LGDT` loads a 16-bit limit and a 32-bit base.** Hand it a
   pointer holding `dq 0xffffffff80105e40` and the base silently becomes
   `0x80105e40` — the low half, pointing at nothing. The instruction succeeds.
   The *next* far jump faults fetching its code descriptor, and with no IDT that
   is a triple fault, so what you observe is a reset with no output at all.

   In `qemu.log` it looks like this, and the tell is `GDT=` in the dump:

   ```
   v=0e e=0000 i=0 cpl=0 IP=0010:000000000010007e CR2=0000000080105e48
   GDT=     0000000080105e40 00000017
   check_exception old: 0xe new 0xd
   ```

   `CR2` is eight bytes past the truncated GDT base: the descriptor fetch.

   So the stub needs a pointer whose base is *physical* (`.pointer32`). Once you
   are running in 64-bit code, reload GDTR from `.pointer` — the 64-bit form
   does take a 64-bit base — so that the GDT keeps working after you unmap the
   identity range. Both pointers describe the same table; only the base differs.

2. **Zero `.bss` before `CR3` points into it.** The boot page tables are `.bss`
   objects. If you zero `.bss` after enabling paging, `rep stosb` is erasing the
   page tables that are translating the very stores it is performing. Whether
   you survive depends on whether the region happens to still be covered by a
   TLB entry loaded before the wipe — with 2 MiB pages it usually is, so this
   bug boots fine on your machine for a month and then triple-faults on a
   different QEMU version. Exercise 1 is exactly this failure.

   The same wipe also clears `mb_magic`/`mb_info_ptr` before `kmain` reads them,
   so `kmain` sees magic `0` and panics on every boot — a much friendlier
   symptom that will lead you to the real problem, if you are lucky enough to
   have it fire first.

   Do it in the 32-bit stub, before `setup_page_tables`, where the only live
   state is two registers.

3. **`.bss` symbols in the 32-bit stub.** `pml4` etc. are linked in the
   higher-half `.bss`. That's why every 32-bit access uses `V2P()`. If you forget
   one, you write to an unmapped address and triple-fault.

4. **32-bit `mov [addr], eax` writes only 4 bytes.** Page table entries are 8.
   Always write the upper half explicitly (see `.map_pd`).

5. **The identity map must cover wherever the bootloader put you.** GRUB puts
   you at 1 MiB, so 1 GiB is plenty. If you later load a big initrd, make sure
   the direct map covers it before you touch it.

---

## 4. The first thing to do in C: a serial console

VGA text mode is a trap: it doesn't exist on modern hardware, doesn't work over
CI, and can't be logged. Use the 16550 UART on COM1 (port 0x3F8). QEMU's
`-serial stdio` pipes it to your terminal.

`arch/x86_64/serial.c`:

```c
#include <nyx/io.h>
#include <stdint.h>

#define COM1 0x3F8

void serial_init(void) {
    outb(COM1 + 1, 0x00);   /* disable interrupts */
    outb(COM1 + 3, 0x80);   /* DLAB on */
    outb(COM1 + 0, 0x01);   /* divisor lo: 115200 baud */
    outb(COM1 + 1, 0x00);   /* divisor hi */
    outb(COM1 + 3, 0x03);   /* 8N1, DLAB off */
    outb(COM1 + 2, 0xC7);   /* FIFO on, clear, 14-byte threshold */
    outb(COM1 + 4, 0x0B);   /* DTR, RTS, OUT2 (OUT2 gates IRQs) */
}

void serial_putc(char c) {
    if (c == '\n') serial_putc('\r');
    while (!(inb(COM1 + 5) & 0x20)) { }   /* wait for THR empty */
    outb(COM1, (uint8_t)c);
}
```

`include/nyx/io.h`:

```c
static inline void outb(uint16_t port, uint8_t v) {
    __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(port) : "memory");
}
static inline uint8_t inb(uint16_t port) {
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port) : "memory");
    return v;
}
static inline void io_wait(void) { outb(0x80, 0); }
```

Then a `kprintf`. Write your own `vsnprintf` — it's 150 lines, you need `%s %c
%d %u %x %p %zu` and a width/pad modifier, and having it be *yours* means you can
add `%pP` for "format a physical address" or `%pC` for "format a capability".
Don't pull in a 3000-line printf.

**Log levels and a ring buffer**: from day one, route all output through

```c
void klog(int level, const char *subsys, const char *fmt, ...);
#define KINFO(...)  klog(LOG_INFO,  KLOG_SUBSYS, __VA_ARGS__)
#define KWARN(...)  klog(LOG_WARN,  KLOG_SUBSYS, __VA_ARGS__)
#define KDBG(...)   klog(LOG_DEBUG, KLOG_SUBSYS, __VA_ARGS__)
```

and keep the last N KiB in a static ring buffer that `panic()` dumps. When the
system dies during an interrupt storm, the serial FIFO drops characters; the ring
buffer doesn't.

---

## 5. Parsing the Multiboot2 information structure

`kernel/boot/multiboot2.c`:

```c
#include <nyx/bootinfo.h>
#include <nyx/klog.h>

struct mb2_tag { uint32_t type, size; };

struct mb2_mmap_entry {
    uint64_t addr, len;
    uint32_t type, zero;
};

#define MB2_TAG_CMDLINE   1
#define MB2_TAG_MODULE    3
#define MB2_TAG_MMAP      6
#define MB2_TAG_FB        8
#define MB2_TAG_RSDP2    15
#define MB2_MEM_AVAILABLE 1

struct bootinfo g_boot;   /* our architecture-neutral summary */

void multiboot2_parse(uintptr_t mbi_phys) {
    const uint8_t *p = P2V(mbi_phys);
    uint32_t total = *(const uint32_t *)p;
    const struct mb2_tag *tag = (const void *)(p + 8);

    while ((const uint8_t *)tag < p + total && tag->type != 0) {
        switch (tag->type) {
        case MB2_TAG_CMDLINE:
            g_boot.cmdline = (const char *)(tag + 1);
            break;

        case MB2_TAG_MMAP: {
            uint32_t entsz = ((const uint32_t *)(tag + 1))[0];
            const uint8_t *e = (const uint8_t *)(tag + 1) + 8;
            const uint8_t *end = (const uint8_t *)tag + tag->size;
            for (; e < end; e += entsz) {
                const struct mb2_mmap_entry *m = (const void *)e;
                KDBG("mmap: %016lx-%016lx type=%u",
                     m->addr, m->addr + m->len, m->type);
                if (m->type == MB2_MEM_AVAILABLE &&
                    g_boot.nregions < BOOT_MAX_REGIONS) {
                    g_boot.regions[g_boot.nregions++] =
                        (struct bootregion){ m->addr, m->len };
                }
            }
            break;
        }

        case MB2_TAG_MODULE: {
            struct { struct mb2_tag t; uint32_t start, end; char str[]; }
                const *m = (const void *)tag;
            KINFO("module '%s' at %08x-%08x", m->str, m->start, m->end);
            if (g_boot.nmodules < BOOT_MAX_MODULES)
                g_boot.modules[g_boot.nmodules++] =
                    (struct bootmodule){ m->start, m->end, m->str };
            break;
        }

        case MB2_TAG_RSDP2:
            g_boot.acpi_rsdp = (uintptr_t)(tag + 1);
            break;
        }
        /* tags are 8-byte aligned */
        tag = (const void *)(((uintptr_t)tag + tag->size + 7) & ~7UL);
    }
}
```

**Important:** the boot info structure sits in physical memory that you must
*not* overwrite with your allocator. Record its extent
(`mbi_phys .. mbi_phys + total`) and mark it reserved in Chapter 05, or copy
everything you need into `.bss` before allocating. Copying is simpler and safer.

---

## 6. `kmain`

```c
void kmain(uint32_t magic, uint64_t mbi_phys) {
    serial_init();
    klog_init();
    KINFO("Nyx booting on x86_64");

    if (magic != 0x36D76289)
        panic("bad multiboot magic %08x", magic);

    cpu_detect_features();
    multiboot2_parse(mbi_phys);

    gdt_init();        /* real GDT + TSS  (Ch.04) */
    idt_init();        /* exceptions      (Ch.04) */
    pmm_init();        /* frame allocator (Ch.05) */
    vmm_init();        /* real page tables(Ch.06) */
    ...
    KINFO("boot complete, %zu KiB free", pmm_free_bytes() / 1024);
    for (;;) __asm__ volatile("hlt");
}
```

---

## 7. The Limine alternative (highly recommended as a second path)

[Limine](https://github.com/limine-bootloader/limine) is a modern
BIOS+UEFI bootloader with a boot protocol that hands you:

- 64-bit long mode, interrupts off
- Kernel already loaded at a higher-half virtual address you choose
- A **higher-half direct map** of all physical memory already set up (at
  `hhdm_offset`)
- Memory map, modules, framebuffer, RSDP, SMP APs already started and parked,
  kernel physical/virtual base for KASLR

You request things by placing volatile request structures in your binary:

```c
#include <limine.h>

__attribute__((used, section(".limine_requests")))
static volatile LIMINE_BASE_REVISION(2);

__attribute__((used, section(".limine_requests")))
static volatile struct limine_memmap_request memmap_req = {
    .id = LIMINE_MEMMAP_REQUEST, .revision = 0
};

__attribute__((used, section(".limine_requests")))
static volatile struct limine_hhdm_request hhdm_req = {
    .id = LIMINE_HHDM_REQUEST, .revision = 0
};

void kmain_limine(void) {
    uint64_t hhdm = hhdm_req.response->offset;
    struct limine_memmap_response *mm = memmap_req.response;
    ...
}
```

Structure your code so that **both** paths fill the same `struct bootinfo` and
then call the same `kmain_common(&g_boot)`. That gives you:

- Fast iteration (Limine, UEFI, real hardware, framebuffer)
- The educational path (Multiboot2, hand-built page tables)
- A concrete example of hardware/firmware abstraction, which is a design skill

```c
/* include/nyx/bootinfo.h — the abstraction both paths produce */
struct bootregion { uint64_t base, len; };
struct bootmodule { uint64_t start, end; const char *name; };

struct bootinfo {
    const char        *cmdline;
    uint64_t           hhdm_offset;      /* direct map base */
    uint64_t           kernel_phys, kernel_virt;
    unsigned           nregions;
    struct bootregion  regions[BOOT_MAX_REGIONS];
    unsigned           nmodules;
    struct bootmodule  modules[BOOT_MAX_MODULES];
    uintptr_t          acpi_rsdp;
    struct { uint64_t addr; uint32_t w, h, pitch, bpp; } fb;
};
```

---

## 8. Verification: how to debug a kernel that prints nothing

This is the skill. In order of cost:

**1. QEMU's own diagnostics.**

```bash
qemu-system-x86_64 -cdrom nyx.iso -serial stdio -no-reboot -no-shutdown \
    -d int,cpu_reset,guest_errors -D qemu.log
```

`-d int` logs every interrupt/exception with the full register state. A triple
fault shows as a `cpu_reset`. Reading backwards from the reset in `qemu.log`
tells you exactly which exception cascaded.

**2. The QEMU monitor.** `Ctrl-A C` (with `-serial stdio`, use `-monitor
telnet:...` instead) gives you:

```
info registers     — full CPU state including CR0/CR3/CR4/EFER
info mem           — the virtual memory mappings, decoded
info tlb           — virtual→physical for everything currently mapped
x/20i $eip         — disassemble at the instruction pointer
xp/8gx 0x1000      — examine *physical* memory
```

`info mem` right after `mov cr0` is the single most useful thing when your page
tables are wrong.

**3. GDB.**

```bash
qemu-system-x86_64 ... -s -S      # gdbstub on :1234, halted at reset
gdb build/nyx.elf
  (gdb) target remote :1234
  (gdb) break *0x100000            # the physical entry point
  (gdb) continue
  (gdb) si                         # single-step the transition
  (gdb) info registers
```

**Critical gotcha:** GDB starts in 16-bit/32-bit mode and gets confused when the
CPU switches to 64-bit. Use `set architecture i386:x86-64` after the switch, and
consider two separate debug sessions (one for the stub, one with `break kmain`).

**4. The `0xB8000` poke.** Before serial works, `mov byte [0xB8000], 'A'` in the
32-bit stub is a print statement. Crude, always works.

**5. Add `-d int` to your permanent QEMU flags for the first month.**

### Checklist for a triple fault at the long-mode jump

- Is `CR4.PAE` set *before* `CR0.PG`?
- Is `EFER.LME` set *before* `CR0.PG`?
- Is `CR3` a *physical* address, 4 KiB aligned?
- Do the page table entries have bit 0 (Present) set at **every** level?
- Is the identity map covering your current EIP?
- Is your GDT pointer's *limit* `size - 1`?
- Is the *base* in that pointer a 32-bit physical address? A 32-bit `LGDT`
  truncates, so a higher-half base loads garbage silently (§3.1 #1). Compare
  `GDT=` in the `-d int` dump against `llvm-nm | grep gdt64`.
- Did you zero `.bss` while `CR3` already pointed into it (§3.1 #2)?
- Is the code descriptor's `L` bit (53) set and `D` bit (54) **clear**?
- Did you far-jump (not near-jump) to flush CS?

---

## 9. Milestone check

You are done with this chapter when:

- [ ] `make run` prints a banner over serial
- [ ] The banner is printed from a function whose address is `0xFFFFFFFF80...`
      (verify with `%p` on a function pointer)
- [ ] `info registers` in QEMU shows `EFER.LMA=1`, `CR0.PG=1`, `CR4.PAE=1`
- [ ] The kernel dumps the memory map with plausible regions
- [ ] The identity mapping is gone and the kernel still runs
- [ ] `.bss` is zeroed (test with a static uninitialized array)
- [ ] It also boots under `qemu -bios OVMF.fd` via a Limine path (stretch)

---

## 10. Exercises

1. Deliberately remove the `.bss` clearing and observe what breaks. Then explain
   why it *sometimes* works.
2. Modify the boot stub to map only 512 MiB instead of 1 GiB and find the exact
   point where the kernel starts failing when you load a large module.
3. Add Multiboot2 tag type 9 (ELF section headers) parsing and use the symbol
   table to implement `backtrace()` that prints function names. This will pay
   for itself within a week.
4. Write the UEFI path: a small GNU-EFI application that loads your ELF, gets the
   memory map, calls `ExitBootServices`, and jumps to `kmain`. Compare the
   complexity to Multiboot2.

---

Next: [04 — Interrupts, exceptions, and time](04-interrupts-and-exceptions.md)
