# 02 — Toolchain, build system, and the freestanding environment

> The single most common way OS projects die is a broken build that silently
> produces a binary that can't possibly work. Get this right once.

---

## 1. Theory: what "freestanding" means

C has two conformance modes, defined in the standard:

- **Hosted**: `main()` is the entry point, the full standard library exists, and
  there's a runtime that sets up the stack, heap, and `argv` before you run.
- **Freestanding**: only these headers are guaranteed: `<float.h>`, `<iso646.h>`,
  `<limits.h>, <stdalign.h>, <stdarg.h>, <stdbool.h>, <stddef.h>, <stdint.h>,
  <stdnoreturn.h>`. Entry point is implementation-defined. **No libc.**

Your kernel is freestanding. There is no `malloc`, no `printf`, no `memcpy` —
except that GCC/Clang will *still emit calls* to `memcpy`, `memset`, `memmove`,
and `memcmp` for struct assignments and array initializations, even with
`-ffreestanding`. **You must implement those four functions yourself.** This
catches everyone.

Similarly, on 32-bit targets the compiler emits calls to libgcc helpers
(`__udivdi3` etc.) for 64-bit arithmetic. On x86-64, 64-bit division is native,
but 128-bit isn't. Link against `libgcc` (`-lgcc`) or avoid the operations.

---

## 2. Cross-compiler: build one or use Clang

### Option A — Clang (recommended for getting started)

Clang is a native cross-compiler. No toolchain build required:

```bash
clang --target=x86_64-unknown-none -ffreestanding -nostdlib ...
```

You still want a cross **linker** — use LLD (`ld.lld`) which is also
cross-capable, or the GNU `ld` from a binutils build.

Pros: one command, fast, excellent diagnostics, has `-fsanitize=undefined` that
works freestanding, and integrates with `clang-tidy`/`clang-format`.

### Option B — Build a GCC cross-compiler (`x86_64-elf-gcc`)

The classic approach. Why bother? Because your *host* compiler targets your host
OS: it assumes a libc, a dynamic loader, a red zone, and specific stack
protector semantics. Using it with enough flags mostly works — until it doesn't,
in a way that takes three days to diagnose.

```bash
# Rough sketch; check current versions.
export PREFIX="$HOME/opt/cross" TARGET=x86_64-elf PATH="$PREFIX/bin:$PATH"

# binutils
tar xf binutils-2.4x.tar.xz && mkdir build-binutils && cd build-binutils
../binutils-2.4x/configure --target=$TARGET --prefix="$PREFIX" \
    --with-sysroot --disable-nls --disable-werror
make -j$(nproc) && make install && cd ..

# gcc (C only, no libc needed)
tar xf gcc-14.x.tar.xz && mkdir build-gcc && cd build-gcc
../gcc-14.x/configure --target=$TARGET --prefix="$PREFIX" \
    --disable-nls --enable-languages=c --without-headers
make -j$(nproc) all-gcc all-target-libgcc
make install-gcc install-target-libgcc
```

Verify: `x86_64-elf-gcc -v` should print `Target: x86_64-elf`.

**Recommendation:** start with Clang to get moving; add a GCC cross-toolchain
later and build with both in CI. Two compilers find twice the bugs, and
differing UB handling exposes latent problems.

### The rest of the tools

```bash
# Debian/Ubuntu
sudo apt install nasm clang lld qemu-system-x86 gdb xorriso mtools \
                 grub-pc-bin grub-common make python3
# Arch
sudo pacman -S nasm clang lld qemu-full gdb xorriso mtools grub make python
# macOS (use nix or homebrew + a cross toolchain; QEMU works natively)
brew install nasm llvm qemu xorriso mtools
```

---

## 3. The compiler flags, explained

```makefile
CFLAGS := \
  -std=gnu17 -ffreestanding -nostdlib -nostdinc \
  -mcmodel=kernel -mno-red-zone \
  -mno-mmx -mno-sse -mno-sse2 -mno-80387 \
  -fno-stack-protector -fno-omit-frame-pointer \
  -fno-pic -fno-pie -fno-common \
  -fno-strict-aliasing \
  -Wall -Wextra -Werror \
  -Wshadow -Wvla -Wundef -Wcast-align -Wwrite-strings \
  -Wmissing-prototypes -Wstrict-prototypes -Wredundant-decls \
  -Wnested-externs -Winline -Wno-long-long -Wconversion \
  -O2 -g3 -gdwarf-4 \
  -Iinclude
```

Why each matters:

| Flag | Reason |
|---|---|
| `-ffreestanding` | Don't assume libc semantics for builtins. Critically, don't turn a loop into a `memcpy` call *and* don't assume `main` is special. |
| `-nostdlib -nostdinc` | Don't link host libc; don't include host headers. `-nostdinc` is the one people forget, and it causes bizarre failures when `<stdint.h>` pulls in glibc's `<features.h>`. (You still need the *compiler's* own headers: add `-isystem $(clang -print-resource-dir)/include`.) |
| `-mcmodel=kernel` | Tells the compiler all symbols live in the top 2 GiB (`0xFFFFFFFF80000000+`), so it can use sign-extended 32-bit relocations. Using `-mcmodel=large` works but generates much worse code. |
| `-mno-red-zone` | **Mandatory.** Interrupts push onto the current stack; the red zone would be clobbered. Silent, intermittent, catastrophic corruption otherwise. |
| `-mno-sse` etc. | Kernel must not touch FPU/vector state without saving it. Compiler would otherwise use XMM for struct copies. |
| `-fno-stack-protector` | The canary needs `%gs:0x28` and `__stack_chk_fail`. You can *enable* it later once you set up per-CPU GS — it's a genuinely good idea then. |
| `-fno-pic -fno-pie` | Unless you're doing KASLR with a relocatable kernel, avoid PIC complexity and GOT indirection. |
| `-fno-common` | Tentative definitions become errors instead of silently merging. Default in GCC 10+. |
| `-fno-strict-aliasing` | You will cast between types constantly (page table entries, message buffers). Strict aliasing UB will bite. Linux does this too. |
| `-fno-omit-frame-pointer` | You want stack traces. The performance cost is negligible; the debugging value is enormous. |
| `-g3 -gdwarf-4` | Full debug info including macros. GDB and QEMU work best with DWARF 4. |
| `-Werror` | Non-negotiable. Warnings in kernel code are bugs. |

Assembler and linker:

```makefile
ASFLAGS := -f elf64 -g -F dwarf
LDFLAGS := -n -T arch/x86_64/link.ld -nostdlib -z max-page-size=0x1000
```

`-n` (`--nmagic`) stops the linker from page-aligning sections in ways that
conflict with your script. `-z max-page-size=0x1000` prevents huge alignment
padding that bloats the binary.

---

## 4. The linker script

This is where the higher-half layout is decided. `arch/x86_64/link.ld`:

```ld
ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)

KERNEL_VMA  = 0xFFFFFFFF80000000;   /* -2 GiB: matches -mcmodel=kernel */
KERNEL_LMA  = 0x0000000000100000;   /* 1 MiB physical, where GRUB puts us */

SECTIONS
{
    . = KERNEL_LMA;
    __image_phys_start = .;                /* physical: covers .boot too */

    /* --- boot: runs with paging OFF, must be identity-addressable --- */
    .boot : ALIGN(4K)
    {
        KEEP(*(.multiboot_header))
        *(.boot.text)
        *(.boot.data)
        *(.boot.bss)
    }

    /* --- kernel proper: linked high, loaded low --- */
    . = ALIGN(4K);
    __kernel_start = .;                    /* PHYSICAL — see the warning below */
    _kernel_phys_start = .;
    . += KERNEL_VMA;                       /* switch to virtual addressing */

    .text : AT(ADDR(.text) - KERNEL_VMA) ALIGN(4K)
    {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    }

    .rodata : AT(ADDR(.rodata) - KERNEL_VMA) ALIGN(4K)
    {
        __rodata_start = .;
        *(.rodata .rodata.*)
        /* init/exit function tables — a nice pattern, see §7 */
        . = ALIGN(8);
        __initcall_start = .;  KEEP(*(.initcall.*))  __initcall_end = .;
        . = ALIGN(8);
        __ktest_start = .;     KEEP(*(.ktest))       __ktest_end = .;
        __rodata_end = .;
    }

    .data : AT(ADDR(.data) - KERNEL_VMA) ALIGN(4K)
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    }

    .bss : AT(ADDR(.bss) - KERNEL_VMA) ALIGN(4K)
    {
        __bss_start = .;
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
        __bss_end = .;
    }

    __kernel_end = .;                      /* VIRTUAL — see the warning below */
    _kernel_phys_end = . - KERNEL_VMA;
    __image_phys_end = . - KERNEL_VMA;

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.note.*) }
}
```

**Key idea:** `AT(ADDR(x) - KERNEL_VMA)` sets the **load address** (LMA, where the
bootloader puts the bytes) separately from the **virtual address** (VMA, where
the linker thinks the symbols live). The `.boot` section has VMA == LMA because
it executes before paging is on. Everything else has VMA in the higher half.

> **`__kernel_start` and `__kernel_end` are in different address spaces,
> despite the matching names.** `__kernel_start` is assigned *before*
> `. += KERNEL_VMA`, so it is physical; `__kernel_end` is assigned after,
> so it is virtual. Any arithmetic that treats them as a pair is wrong,
> and the one guide 05 §2 used to write literally —
> `V2P_KERNEL(__kernel_start)` — subtracts `KERNEL_VMA` from a physical
> address and underflows. The reserve range then has an end below its
> start and **silently reserves nothing**, so the allocator hands out the
> kernel image and the failure appears much later, somewhere else.
>
> Two rules follow, and the second is the one that generalises:
>
> 1. Do arithmetic only on the explicit pairs — `_kernel_phys_start` /
>    `_kernel_phys_end`, or `__image_phys_start` / `__image_phys_end`,
>    which also cover `.boot` (it sits *below* `__kernel_start`, so a
>    range starting there misses it).
> 2. **Put the address space in the name.** A symbol called
>    `__kernel_start` invites exactly this bug; one called
>    `_kernel_phys_start` cannot. Corrected 2026-08-15, found by
>    implementation.

Symbols like `__bss_start` are declared in C as `extern char __bss_start[];` —
**note the array type**, so that the symbol's *address* is the value. Writing
`extern char __bss_start;` and using `&__bss_start` also works; using
`extern uintptr_t __bss_start;` and reading it does not — it reads memory at
that address. This is a classic mistake.

---

## 5. Build system

A Makefile is fine and keeps dependencies visible. Here's a complete, working
skeleton:

```makefile
# ---- Toolchain ----------------------------------------------------------
CC      := clang --target=x86_64-unknown-none-elf
LD      := ld.lld
AS      := nasm
OBJCOPY := llvm-objcopy
QEMU    := qemu-system-x86_64

BUILD   := build
TARGET  := $(BUILD)/nyx.elf
ISO     := $(BUILD)/nyx.iso

CFLAGS  := -std=gnu17 -ffreestanding -nostdlib -mcmodel=kernel -mno-red-zone \
           -mno-mmx -mno-sse -mno-sse2 -mno-80387 -fno-stack-protector \
           -fno-omit-frame-pointer -fno-pic -fno-pie -fno-common \
           -fno-strict-aliasing -Wall -Wextra -Werror -Wshadow -Wvla \
           -Wmissing-prototypes -O2 -g3 -Iinclude
ASFLAGS := -f elf64 -g -F dwarf
LDFLAGS := -n -T arch/x86_64/link.ld -nostdlib -z max-page-size=0x1000

# ---- Sources ------------------------------------------------------------
CSRC := $(shell find kernel arch/x86_64 -name '*.c')
ASRC := $(shell find arch/x86_64 -name '*.asm')
OBJ  := $(CSRC:%.c=$(BUILD)/%.o) $(ASRC:%.asm=$(BUILD)/%.o)
DEP  := $(OBJ:.o=.d)

# ---- Rules --------------------------------------------------------------
.PHONY: all run debug clean iso test
all: $(TARGET)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/%.o: %.asm
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) $< -o $@

$(TARGET): $(OBJ) arch/x86_64/link.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJ)
	@# Sanity checks that catch 90% of "it triple faults" bugs:
	@llvm-readelf -h $@ | grep -q 'ELF64' || (echo "not 64-bit!"; exit 1)
	@llvm-nm $@ | grep -q ' T _start' || (echo "no _start!"; exit 1)

iso: $(ISO)
$(ISO): $(TARGET)
	@mkdir -p $(BUILD)/iso/boot/grub
	cp $(TARGET) $(BUILD)/iso/boot/nyx.elf
	printf 'set timeout=0\nset default=0\nmenuentry "Nyx" {\n  multiboot2 /boot/nyx.elf\n  module2 /boot/initrd.img initrd\n  boot\n}\n' \
	    > $(BUILD)/iso/boot/grub/grub.cfg
	tools/mkinitrd.py user/ $(BUILD)/iso/boot/initrd.img
	grub-mkrescue -o $@ $(BUILD)/iso 2>/dev/null

QEMUFLAGS := -m 512M -serial stdio -no-reboot -no-shutdown \
             -d guest_errors,int -D $(BUILD)/qemu.log \
             -device isa-debug-exit,iobase=0xf4,iosize=0x04

run: $(ISO)
	$(QEMU) -cdrom $(ISO) $(QEMUFLAGS)

debug: $(ISO)
	$(QEMU) -cdrom $(ISO) $(QEMUFLAGS) -s -S &
	gdb -q $(TARGET) -ex 'target remote :1234' -ex 'break kmain'

clean:
	rm -rf $(BUILD)

-include $(DEP)
```

Note the `-MMD -MP` dependency generation — without it, changing a header won't
rebuild, and you will debug a stale binary. This wastes more OS-dev hours than
any other single mistake.

### When to move to Meson/CMake/Ninja

When you have: multiple architectures, a userspace with its own toolchain flags,
generated IDL stubs, and a test matrix. Around Chapter 10. Meson handles
cross-files elegantly. Until then, Make keeps everything legible.

---

## 6. The minimal freestanding runtime you must provide

`kernel/klib/string.c`:

```c
#include <stddef.h>

void *memcpy(void *restrict d, const void *restrict s, size_t n) {
    unsigned char *dp = d; const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n) {
    unsigned char *dp = d;
    while (n--) *dp++ = (unsigned char)c;
    return d;
}

void *memmove(void *d, const void *s, size_t n) {
    unsigned char *dp = d; const unsigned char *sp = s;
    if (dp < sp) { while (n--) *dp++ = *sp++; }
    else { dp += n; sp += n; while (n--) *--dp = *--sp; }
    return d;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (; n--; x++, y++) if (*x != *y) return *x - *y;
    return 0;
}
```

Later, replace these with `rep movsb`-based versions (fast on CPUs with ERMSB,
CPUID 7:0 EBX bit 9) and measure. Don't optimize now.

You also need, at minimum:

- `panic(fmt, ...)` — print, dump registers and a backtrace, then halt.
- `assert(x)` / `static_assert` — use them liberally; `-DNDEBUG` for release.
- `kprintf` — Chapter 03.
- Stubs for anything the compiler references: `__stack_chk_fail`,
  `__cxa_pure_virtual` (if you ever link C++), `memcpy` variants.

---

## 7. Two patterns worth adopting now

### Initcall tables

Instead of one giant `kmain` that calls forty init functions in a hand-maintained
order, use linker-collected sections:

```c
// include/nyx/init.h
typedef void (*initcall_t)(void);
#define INITCALL(level, fn) \
    static initcall_t __initcall_##fn \
    __attribute__((used, section(".initcall." #level))) = fn

// usage
static void pmm_init(void) { ... }
INITCALL(2, pmm_init);
```

The linker script sorts `.initcall.*` by name, so levels run in order. `kmain`
becomes:

```c
extern initcall_t __initcall_start[], __initcall_end[];
for (initcall_t *f = __initcall_start; f < __initcall_end; f++) (*f)();
```

This scales, and it makes subsystem dependencies explicit (the level number is
the dependency declaration).

### In-kernel test registration

Same trick, different section — build a self-test suite that runs at boot under
a `-Dktest` build:

```c
#define KTEST(name) \
    static void name(void); \
    static const struct ktest __ktest_##name \
        __attribute__((used, section(".ktest"))) = { #name, name }; \
    static void name(void)

KTEST(pmm_alloc_free_roundtrip) {
    paddr_t p = pmm_alloc();
    KASSERT(p != 0);
    pmm_free(p);
}
```

Chapter 18 turns this into a CI harness that exits QEMU with a status code.

---

## 8. Directory conventions

- `include/abi/` holds headers shared between kernel and userspace. **Nothing in
  here may include a kernel-internal header.** Enforce this with a grep in CI.
  This directory *is* your ABI; treat changes to it as versioned events.
- `arch/` holds everything that mentions x86 specifics. The rule: `kernel/`
  must compile for a hypothetical second architecture without modification. You
  won't achieve this perfectly, but tracking violations tells you where your
  abstractions leak.
- `docs/` gets a design doc per subsystem, written **before** the code, with an
  explicit "Invariants" section. Chapter 13's research directions depend on
  having these.

---

## 9. Verification: prove your build works before you trust it

Before writing kernel logic, confirm:

```bash
llvm-readelf -h build/nyx.elf         # ELF64, x86-64, entry point sane
llvm-readelf -l build/nyx.elf         # LMA ≈ 0x100000, VMA ≈ 0xFFFFFFFF80...
llvm-nm -n build/nyx.elf | head       # symbols at expected addresses
llvm-objdump -d build/nyx.elf | less  # the boot code disassembles as 32-bit?
grub-file --is-x86-multiboot2 build/nyx.elf && echo OK
```

That last one is essential: if GRUB doesn't find your Multiboot2 header in the
first 32 KiB, aligned to 8 bytes, it will simply refuse to boot with an unhelpful
message.

---

## 10. Exercises

1. Compile a trivial `.c` file with and without `-mno-red-zone` and diff the
   disassembly of a leaf function. Find the red-zone use.
2. Write a C file that assigns one 64-byte struct to another. Compile with
   `-ffreestanding` and confirm the compiler still emits a `memcpy` call.
3. Deliberately introduce a stale-header bug (edit a header without `-MMD`) and
   observe how confusing the resulting failure is. Then fix it.
4. Add a CI job (GitHub Actions or a `Makefile` target) that builds with both
   Clang and GCC cross and fails on any warning.

---

Next: [03 — Boot: from firmware to a 64-bit higher-half C function](03-boot-and-long-mode.md)
