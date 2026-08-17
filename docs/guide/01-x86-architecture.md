# 01 — The x86-64 machine: what the hardware actually gives you

> You cannot design a kernel around hardware you don't understand. This chapter
> is the mechanism inventory. Skim it now, return to it constantly.

---

## 1. Why x86-64 (and why the 32-bit stub anyway)

**Choose x86-64.** Reasons:

- It's what QEMU runs fastest (with KVM, near-native).
- The ABI is clean: 16 general registers, RIP-relative addressing, a real
  calling convention (System V AMD64), and — crucially — **segmentation is
  essentially gone**. In long mode, CS/DS/ES/SS bases are forced to 0. You get to
  skip the entire segmentation mess that dominates 32-bit tutorials and teaches
  you nothing transferable.
- `syscall`/`sysret` is dramatically simpler and faster than `int 0x80`/`sysenter`.
- Paging is a clean 4-level (or 5-level) radix tree, the same shape as ARM64 and
  RISC-V Sv48. What you learn transfers.
- Every modern security feature (NX, SMEP, SMAP, PCID, UMIP, CET) exists here.

**But you'll still write 32-bit code.** The firmware (via a Multiboot2
bootloader) hands you control in 32-bit protected mode. Your first ~150 lines of
assembly build page tables and switch to long mode. This is genuinely valuable:
it's the one place you see the machine in a state where paging is off and you can
watch it being turned on.

*(If you use Limine or a UEFI stub instead, you're dropped straight into long
mode. Chapter 03 shows both. I recommend doing Multiboot2 once, by hand, then
never again.)*

---

## 2. Operating modes

```
Real mode (16-bit)        ← power-on state. 1MB, segment:offset, no protection.
   ↓ set CR0.PE
Protected mode (32-bit)   ← segmentation + optional paging. Rings 0–3.
   ↓ set CR4.PAE, EFER.LME, load CR3, set CR0.PG
Long mode
   ├─ 64-bit mode         ← what we run in. Flat, 64-bit, paging mandatory.
   └─ compatibility mode  ← run 32-bit code under a 64-bit kernel. Ignore for now.
System Management Mode    ← firmware's private mode. Invisible; source of latency spikes.
```

Two hard rules for long mode:

1. **Paging is mandatory.** You cannot be in long mode with paging off. So your
   32-bit stub must build valid page tables *before* the switch.
2. **You must enable PAE.** Long mode page tables are 64-bit entries.

---

## 3. Privilege: rings, CPL, and what's actually enforced

Four rings (0 = most privileged). Only 0 and 3 are used in practice. **CPL**
(current privilege level) = the low two bits of CS.

Ring 0 can execute privileged instructions (`mov cr*`, `lgdt`, `lidt`, `hlt`,
`invlpg`, `wrmsr`, `in`/`out` subject to IOPL). Ring 3 cannot.

Protection is enforced at three places:

- **Instruction level:** privileged instructions fault (#GP) at CPL > 0.
- **Page level:** the U/S bit in page table entries. A user access to a
  supervisor page is a #PF.
- **Segment level:** DPL checks on descriptors. Mostly vestigial in long mode,
  but still governs which descriptor `syscall`/`sysret` and interrupts select.

### Transitions to ring 0

| Mechanism | Cost | Use |
|---|---|---|
| `int n` / IDT gate | ~hundreds of cycles | Interrupts, exceptions, legacy syscalls |
| `syscall` / `sysret` | ~50–100 cycles | **Our syscall path.** Uses MSRs, no memory access for the descriptor. |
| `sysenter` / `sysexit` | similar | Intel-only in 32-bit; ignore |
| Task gates / TSS switching | slow, removed in long mode | Don't |

`syscall` does *not* switch stacks for you. It puts RIP into RCX and RFLAGS into
R11, loads RIP from `IA32_LSTAR`, masks RFLAGS with `IA32_FMASK`, and loads
CS/SS from `IA32_STAR`. **You** must switch to a kernel stack — which is what
`swapgs` + a per-CPU structure is for (Chapter 10).

---

## 4. Registers

### General purpose (64-bit)

```
RAX RBX RCX RDX RSI RDI RBP RSP R8 R9 R10 R11 R12 R13 R14 R15
```

Sub-registers: `EAX` (32, **zero-extends on write**), `AX` (16, preserves upper),
`AL`/`AH` (8). The zero-extension rule on 32-bit writes is a frequent bug source.

**System V AMD64 calling convention** (memorize this — your C and asm must agree):

- Integer args: `RDI, RSI, RDX, RCX, R8, R9`, then stack.
- Return: `RAX` (and `RDX` for 128-bit).
- **Callee-saved:** `RBX, RBP, R12–R15`, `RSP`. Everything else is caller-saved.
- Stack must be 16-byte aligned *at the `call` instruction*, so on entry to a
  function `RSP % 16 == 8`.
- There is a 128-byte **red zone** below RSP that leaf functions may use. **You
  must disable it in kernel code** (`-mno-red-zone`) because interrupts push onto
  the same stack and would clobber it.

### Control registers

| Reg | Key bits |
|---|---|
| **CR0** | `PE`(0) protected mode, `WP`(16) write-protect *even in ring 0* — **set this**, `PG`(31) paging |
| **CR2** | Faulting linear address on #PF. Read it *first* in your handler. |
| **CR3** | Physical address of PML4 + PCID bits |
| **CR4** | `PAE`(5), `PGE`(7) global pages, `PCIDE`(17), `OSFXSR`(9), `OSXSAVE`(18), `SMEP`(20), `SMAP`(21), `UMIP`(11), `LA57`(12) |
| **CR8** | Task Priority Register (interrupt priority threshold), 64-bit only |
| **EFER** (MSR 0xC0000080) | `SCE`(0) enable `syscall`, `LME`(8) long mode enable, `LMA`(10) long mode active (read-only), `NXE`(11) enable NX bit |

`CR0.WP` deserves emphasis: without it, ring 0 can write to read-only pages. With
it, the kernel gets copy-on-write semantics enforced against itself, which
catches real bugs.

### RFLAGS bits you care about

`CF`(0) `ZF`(6) `SF`(7) `IF`(9 — interrupt enable) `DF`(10 — string direction,
**must be clear on entry to C code**; use `cld`) `IOPL`(12–13) `AC`(18 — used with
SMAP) `ID`(21 — CPUID support).

### Model-Specific Registers (MSRs)

Read/written with `rdmsr`/`wrmsr` (EDX:EAX pair, index in ECX). Ones you'll use:

```
0xC0000080 IA32_EFER
0xC0000081 IA32_STAR    kernel/user CS,SS selectors for syscall/sysret
0xC0000082 IA32_LSTAR   syscall entry RIP
0xC0000084 IA32_FMASK   RFLAGS bits cleared on syscall (clear IF and DF here!)
0xC0000100 IA32_FS_BASE user TLS
0xC0000101 IA32_GS_BASE per-CPU pointer (kernel)
0xC0000102 IA32_KERNEL_GS_BASE  the "other" GS base, swapped by `swapgs`
0x0000001B IA32_APIC_BASE
0x000006E0 IA32_TSC_DEADLINE
```

---

## 5. Segmentation (the part that survives)

In long mode, segmentation is *almost* dead but not quite. You still need a GDT
because:

- `syscall`/`sysret` and interrupt gates select descriptors by index.
- The TSS (task state segment) is a GDT entry, and you need the TSS for its
  `RSP0` field (the kernel stack loaded on a ring 3→0 interrupt) and the IST.
- FS and GS **still have bases** (set via MSRs), used for TLS and per-CPU data.

A minimal long-mode GDT:

```
0x00  null
0x08  kernel code   (L=1, D=0, DPL=0, type=code)
0x10  kernel data   (DPL=0, type=data)
0x18  user data     (DPL=3)     ← order matters for sysret! see Ch.10
0x20  user code     (L=1, DPL=3)
0x28  TSS (16 bytes, two GDT slots in long mode)
```

`sysret` computes user CS from `STAR[63:48] + 16` and SS from `STAR[63:48] + 8`,
so the user descriptors must be laid out as *data then code*. This trips
everyone up once.

---

## 6. Paging: the 4-level radix tree

A 48-bit virtual address (with `CR4.LA57` clear) decomposes as:

```
63           48 47      39 38      30 29      21 20      12 11         0
[ sign extend ][ PML4 idx][ PDPT idx][  PD idx ][  PT idx ][ page offset ]
     16 bits      9 bits     9 bits    9 bits     9 bits      12 bits
```

Bits 63:48 **must be a sign extension of bit 47** — a "canonical" address. Any
non-canonical address is a #GP, not a #PF. This splits the address space into
two halves with a huge hole:

```
0x0000_0000_0000_0000 – 0x0000_7FFF_FFFF_FFFF   lower half  (userspace)
        ... non-canonical hole ...
0xFFFF_8000_0000_0000 – 0xFFFF_FFFF_FFFF_FFFF   upper half  (kernel)
```

Each level is a 4 KiB table of 512 × 8-byte entries. Entry format:

| Bit | Name | Meaning |
|---|---|---|
| 0 | P | Present |
| 1 | R/W | Writable |
| 2 | U/S | User-accessible |
| 3 | PWT | Write-through |
| 4 | PCD | Cache disable |
| 5 | A | Accessed (set by CPU) |
| 6 | D | Dirty (set by CPU, leaf only) |
| 7 | PS | Page size — at PDPT: 1 GiB page; at PD: 2 MiB page |
| 8 | G | Global (not flushed on CR3 write if CR4.PGE) |
| 11:9 | — | **Available to software.** Use these. |
| 51:12 | — | Physical address of next table / page frame |
| 62:52 | — | Available to software |
| 63 | NX | No-execute (requires EFER.NXE) |

Permissions are the **AND** across all levels: if any level lacks U/S, the page
is not user-accessible. NX is the **OR**: if any level sets NX, it's non-exec.

### Huge pages

2 MiB pages (PS at PD level) and 1 GiB pages (PS at PDPT level) reduce TLB
pressure and let you map the whole physical memory with a handful of entries.
We'll use 2 MiB pages for the boot identity map and 1 GiB pages for the
"direct map" of physical memory into the higher half.

### The direct map (a pattern you must adopt)

The kernel constantly needs to read/write physical memory it doesn't have mapped
(page tables, DMA buffers, another process's frames). The standard solution:
map **all** physical memory at a fixed higher-half offset.

```c
#define PHYS_MAP_BASE 0xFFFF800000000000UL
#define P2V(p) ((void*)((uintptr_t)(p) + PHYS_MAP_BASE))
#define V2P(v) ((uintptr_t)(v) - PHYS_MAP_BASE)
```

Now converting between physical and virtual is arithmetic, not a page-table walk.
(Linux calls this `page_offset`; the alternative, "recursive page tables", is
cuter but harder to reason about and doesn't work well with SMP.)

### The TLB

Translations are cached. **The CPU will not notice you changed a page table.**
Rules:

- After changing an entry that was previously present: `invlpg [addr]`.
- After changing many entries: reload CR3 (flushes all non-global).
- Changing a not-present entry to present usually needs no flush on x86 (the
  CPU doesn't cache negative entries — but *do not* rely on this on other
  architectures, and there are errata; being conservative costs little).
- With **PCID** (CR4.PCIDE), CR3 writes can preserve other address spaces' TLB
  entries. `invpcid` gives fine-grained control. This is a major microkernel
  performance lever — see Chapter 06.
- On SMP, other cores have their own TLBs. You must send an IPI to make them
  invalidate: **TLB shootdown** (Chapter 12).

---

## 7. Interrupts and exceptions

### The IDT

256 entries, each 16 bytes in long mode, pointed to by `IDTR` (loaded with
`lidt`). Vectors:

```
0   #DE  divide error
1   #DB  debug
2   NMI  non-maskable
3   #BP  breakpoint (int3)
6   #UD  invalid opcode
8   #DF  double fault           (error code, always 0) — needs IST
13  #GP  general protection     (error code)
14  #PF  page fault             (error code; CR2 = address)
18  #MC  machine check          — needs IST
0x20+    your choice: PIC/IOAPIC/MSI/IPIs
```

Vectors 0–31 are reserved for exceptions. Some push a 5-byte... no — some push an
**error code** onto the stack, some don't. Your assembly stubs must normalize
this (push a dummy 0 for the ones that don't) so the C handler sees a uniform
frame.

### What the CPU pushes on interrupt entry (long mode)

Always 5 quadwords, *always* including SS:RSP even for same-privilege
interrupts (this is a long-mode simplification over 32-bit):

```
    SS
    RSP
    RFLAGS
    CS
    RIP
  [ error code ]   ← only for some vectors
  ← RSP points here on entry to your handler
```

Stack is aligned to 16 bytes by the CPU before the push.

### Interrupt Stack Table (IST)

The TSS holds 7 `IST` pointers. An IDT gate can specify IST index 1–7, meaning
"switch to this known-good stack unconditionally". Essential for:

- **#DF (double fault)** — the fault you get when handling a fault failed,
  typically stack overflow. If you don't use an IST here, you get a triple fault
  and the machine resets, giving you zero information.
- **NMI** — can arrive during the tiny window where your stack pointer is
  untrusted.
- **#MC**, and **#PF** if you want to survive kernel stack guard-page hits.

Set these up early. The first time your kernel stack overflows, an IST-backed
#DF handler that prints a register dump saves you a day.

### Interrupt controllers

```
8259 PIC     Legacy. Two chips, 15 lines, must be remapped away from vectors 0–31
             (they default to 0x08, colliding with #DF). We remap then mask it off.
LAPIC        Per-CPU. Handles IPIs, the local timer, and receives interrupts
             routed from the IOAPIC. Programmed via MMIO at 0xFEE00000 (or x2APIC
             via MSRs — prefer x2APIC).
IOAPIC       Routes external device IRQs to LAPICs. 24 redirection entries.
             Found via the ACPI MADT table.
MSI/MSI-X    Modern: the device performs a memory write to a magic address that
             the chipset turns into an interrupt. No shared lines, no routing
             tables, thousands of vectors, per-queue interrupts. **Prefer this.**
```

The path for a modern system: parse ACPI MADT → enable LAPIC (x2APIC) → mask the
PIC entirely → configure IOAPIC for legacy devices → use MSI-X for PCIe devices.

### Timers

| Timer | Notes |
|---|---|
| PIT (8254) | Ancient, 1.193182 MHz, I/O ports 0x40–0x43. Useful *once*: to calibrate other timers. |
| LAPIC timer | Per-CPU, fast to program, but its frequency is the (variable) bus clock — must be calibrated. **Your scheduler tick.** |
| TSC | `rdtsc`. Cycle counter. On modern CPUs it's invariant (constant rate regardless of P-states) — check CPUID. Best timestamp source. |
| TSC-deadline | LAPIC timer mode where you write an absolute TSC value to an MSR. **Ideal for tickless/high-resolution timers.** |
| HPET | MMIO, 64-bit, decent. Useful for calibration and as a fallback. |
| ACPI PM timer | Slow but reliable; another calibration source. |

Plan: calibrate TSC and LAPIC against the PIT or HPET at boot; then use
**TSC-deadline** for all timing. Do not build a fixed-100Hz tick — it's a design
you'll have to remove.

---

## 8. CPUID

`cpuid` with EAX = leaf returns feature bits. You must check before using
anything optional. Minimum checks for Nyx:

```
leaf 0x0            max leaf, vendor string
leaf 0x1     EDX    PAE(6) APIC(9) MSR(5) PGE(13) PAT(16) FXSR(24) SSE(25) SSE2(26)
             ECX    SSE3(0) PCID(17) x2APIC(21) XSAVE(26) OSXSAVE(27) RDRAND(30) HYPERVISOR(31)
leaf 0x7:0   EBX    FSGSBASE(0) SMEP(7) INVPCID(10) RDSEED(18) SMAP(20)
             ECX    UMIP(2) LA57(16) 
leaf 0x80000001 EDX NX(20) 1GB-pages(26) LM(29)
leaf 0x80000008 EAX physical/linear address bits  ← don't assume 52/48!
leaf 0x15/0x16      TSC and core crystal frequency (when available)
leaf 0xD            XSAVE state sizes (needed for FPU context)
```

Write a `cpu_features` struct at boot and consult it everywhere. Never
`#ifdef` a runtime feature.

---

## 9. Memory ordering (needed sooner than you think)

x86-64 is **TSO** (total store order): loads are not reordered with loads, stores
not with stores, but **a load may be reordered before an earlier store to a
different address**. That single exception is exactly what breaks Dekker-style
synchronization.

- `mfence` — full barrier. `lfence`/`sfence` — rarely what you want on TSO.
- **`lock`-prefixed RMW instructions are full barriers.** `lock xchg`,
  `lock cmpxchg`, `lock add` etc.
- Compiler reordering is a separate problem: use C11 `<stdatomic.h>` or GCC
  `__atomic_*` builtins, not `volatile`. `volatile` prevents compiler
  optimization but emits **no** CPU barriers.
- MMIO is different: mark device memory uncacheable (PCD/PWT bits or MTRR/PAT)
  and use explicit accessor functions.

Rule of thumb for Chapter 12: use `atomic_load_explicit(..., memory_order_acquire)`
and `atomic_store_explicit(..., memory_order_release)` and let the compiler emit
nothing extra on x86. Then your code is correct when you port to ARM64.

---

## 10. I/O

**Port I/O**: `in`/`out` on a 16-bit port space, gated by `IOPL` and the TSS I/O
permission bitmap. Legacy only (PIT, PIC, serial, PS/2, PCI config
0xCF8/0xCFC). We'll expose it to userspace drivers as an `IOPort` capability.

**MMIO**: device registers mapped into the physical address space. Must be mapped
uncacheable. This is how everything modern works.

**PCI/PCIe configuration space**: 256 bytes (PCI) or 4 KiB (PCIe) per function.
Access either via the legacy 0xCF8/0xCFC port pair or, better, the
**MCFG/ECAM** region found through ACPI — a flat MMIO window where
`base + (bus<<20 | dev<<15 | fn<<12)` gives you config space. BARs in config
space tell you where the device's MMIO/IO regions are.

**DMA**: devices write to *physical* addresses, bypassing the MMU. A buggy or
malicious driver programming a DMA engine can overwrite anything — including the
kernel. This is *the* argument-killer for "userspace drivers are safe": they are
**not**, unless you use an **IOMMU** (Intel VT-d / AMD-Vi) to give each device its
own address space. Chapter 11 covers this. It is one of the most important
modern additions to a MINIX-style design.

---

## 11. FPU / SSE / AVX state

`SSE2` is baseline on x86-64, and the compiler will use XMM registers unless you
pass `-mno-sse` — **do that for kernel code**. Then the kernel never touches FPU
state, and you only have to save/restore it for user threads.

Save/restore mechanism: `fxsave`/`fxrstor` (512 bytes, 16-byte aligned) or
`xsave`/`xrstor` (variable size from CPUID leaf 0xD, supports AVX etc.).

Optimization: **lazy FPU switching** — set `CR0.TS`, take a #NM fault on first
FPU use, then restore. *However*, lazy FPU restore was the Lazy FP State Restore
vulnerability (CVE-2018-3665). Modern practice is **eager** save/restore with
`xsaveopt`. Do eager.

---

## 12. Security features you will enable

| Feature | Enable via | Effect |
|---|---|---|
| **NX** | `EFER.NXE`, bit 63 in PTEs | Non-executable data pages |
| **SMEP** | `CR4.SMEP` | Ring 0 cannot *execute* user pages. Kills classic ret2user. |
| **SMAP** | `CR4.SMAP` | Ring 0 cannot *read/write* user pages unless `RFLAGS.AC` is set (`stac`/`clac`). Forces you to mark every deliberate user access. |
| **UMIP** | `CR4.UMIP` | Ring 3 can't `sgdt`/`sidt`/`sldt`/`smsw`/`str` (leaks kernel addresses) |
| **W^X** | Your VMM policy | No page is both writable and executable |
| **PCID** | `CR4.PCIDE` | Tagged TLB — big win for IPC-heavy workloads |
| **KPTI** | Separate user PML4 | Meltdown mitigation. Expensive; needed on affected CPUs. |
| **CET** | `CR4.CET` + MSRs | Shadow stacks and indirect-branch tracking (newer CPUs) |
| **Guard pages** | VMM policy | Unmapped page below each kernel/user stack |

SMAP in particular changes how you write code: any copy to/from user memory must
be bracketed by `stac`/`clac`. That's a *feature* — it makes every user-memory
access auditable by grep.

---

## 13. Virtualization (for later, but design for it)

VMX (Intel) / SVM (AMD) let you run guests with hardware-assisted nested paging
(EPT/NPT). A microkernel is an excellent hypervisor substrate — seL4, NOVA, and
Fiasco all do this. If you ever want Nyx to host Linux, the design requirement is
just: make VM control structures another capability-typed object. Chapter 13
sketches it.

Meanwhile you'll be *running under* a hypervisor. CPUID leaf 0x40000000 gives the
hypervisor vendor string ("TCGTCGTCGTCG" for QEMU/TCG, "KVMKVMKVM", "Microsoft Hv").
Useful for enabling QEMU-specific debug exits in your test harness.

---

## 14. Exercises

1. On paper, translate the virtual address `0xFFFF_FFFF_8010_1234` into its four
   9-bit table indices and page offset. Then do `0x0000_7FFF_FFFF_F000`.
2. Explain why `sysret` requires the user data descriptor to sit *before* the
   user code descriptor in the GDT. (Read the AMD64 manual vol.2 §6.1.2.)
3. Why does a #DF handler without an IST stack usually produce a triple fault?
   Trace the exact sequence.
4. Given TSO, write down a two-thread example where a store-then-load on each
   thread produces a result impossible under sequential consistency.
5. Look up the errata for `invlpg` on your target CPU family. What does this tell
   you about the value of conservatism in TLB management?

---

Next: [02 — Toolchain, build system, and the freestanding environment](02-toolchain-and-build.md)
