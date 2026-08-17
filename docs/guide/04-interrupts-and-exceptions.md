# 04 — Interrupts, exceptions, and time

> Goal: a working IDT with informative exception dumps, a GDT+TSS with IST
> stacks, the PIC disabled, the LAPIC running with a calibrated timer, and a
> design for delivering interrupts to *userspace* drivers.

---

## 1. Theory: interrupts as the OS's control-flow inversion

An OS is fundamentally **event-driven** even though it's written as sequential
code. Three kinds of events preempt normal flow:

| Kind | Source | Synchronous? | Restartable? |
|---|---|---|---|
| **Fault** | Instruction execution (#PF, #GP, #DE) | Yes — caused by the current instruction | Fault: yes, retry the instruction. Trap: no, continue after. Abort: no. |
| **Trap** | Deliberate (`int3`, `syscall`) | Yes | Continue after |
| **Interrupt** | External device / another CPU | No — arbitrary timing | Yes, transparently |

The distinction matters for saved-RIP semantics: for **faults** the CPU pushes
the address of the *faulting* instruction (so `iretq` retries); for **traps**,
the address of the *next* instruction.

### Why this is central to a microkernel

In a monolithic kernel, a page fault is handled in the kernel. In a microkernel,
the kernel's job is to **convert the event into a message** and deliver it to the
component that has policy authority:

```
#PF in a user thread
  → kernel builds a fault message (address, access type, faulting IP)
  → sends it, as if from the faulting thread, to that thread's fault endpoint
  → the thread blocks
  → a userspace *pager* receives it, does something (maps a frame, kills the
    thread, reads from a file server), and replies
  → the reply resumes the faulting thread
```

This is the **upcall** pattern, and it's the mechanism that lets memory
management *policy* live outside the kernel. Same for hardware interrupts:

```
IRQ n fires
  → kernel acknowledges the LAPIC (must be fast, must be in-kernel)
  → kernel signals a Notification object bound to that IRQ
  → a userspace driver blocked in wait() on that Notification wakes up
  → driver talks to the device via its MMIO mapping / IOPort capability
  → driver invokes IRQHandler_Ack to re-enable the line
```

The kernel never knows what device it is. That's the whole design.

---

## 2. GDT and TSS

You need your own GDT (the bootloader's is gone or untrusted) and a TSS.

```c
/* arch/x86_64/gdt.c */
#include <nyx/cpu.h>

struct tss {
    uint32_t reserved0;
    uint64_t rsp[3];        /* RSP0..RSP2: stack on privilege change */
    uint64_t reserved1;
    uint64_t ist[7];        /* IST1..IST7 */
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
} __attribute__((packed));

_Static_assert(sizeof(struct tss) == 104, "TSS layout");

struct gdt_ptr { uint16_t limit; uint64_t base; } __attribute__((packed));

/* Descriptor bit helpers */
#define D_ACCESSED   (1UL << 40)
#define D_RW         (1UL << 41)
#define D_CONFORMING (1UL << 42)
#define D_EXEC       (1UL << 43)
#define D_CODEDATA   (1UL << 44)
#define D_DPL(x)     ((uint64_t)(x) << 45)
#define D_PRESENT    (1UL << 47)
#define D_LONG       (1UL << 53)
#define D_DB         (1UL << 54)
#define D_GRAN       (1UL << 55)

/* Selector layout — the order is forced by sysret. See §2.1. */
#define SEL_KCODE 0x08
#define SEL_KDATA 0x10
#define SEL_UDATA 0x18   /* must be (STAR_user_base + 8)  */
#define SEL_UCODE 0x20   /* must be (STAR_user_base + 16) */
#define SEL_TSS   0x28

static uint64_t gdt[7];              /* per-CPU in Ch.12 */
static struct tss tss;
static uint8_t  ist_stacks[3][8192] __attribute__((aligned(16)));

void gdt_init(void) {
    gdt[0] = 0;
    gdt[1] = D_RW|D_EXEC|D_CODEDATA|D_PRESENT|D_LONG;            /* kcode */
    gdt[2] = D_RW|D_CODEDATA|D_PRESENT;                          /* kdata */
    gdt[3] = D_RW|D_CODEDATA|D_PRESENT|D_DPL(3);                 /* udata */
    gdt[4] = D_RW|D_EXEC|D_CODEDATA|D_PRESENT|D_LONG|D_DPL(3);   /* ucode */

    /* TSS descriptor: 16 bytes, occupies gdt[5] and gdt[6] */
    uint64_t base  = (uint64_t)&tss;
    uint64_t limit = sizeof(tss) - 1;
    gdt[5] = (limit & 0xFFFF)
           | ((base & 0xFFFFFF) << 16)
           | (0x9UL << 40)              /* type: 64-bit available TSS */
           | D_PRESENT
           | (((limit >> 16) & 0xF) << 48)
           | (((base >> 24) & 0xFF) << 56);
    gdt[6] = (base >> 32) & 0xFFFFFFFF;

    tss.ist[0] = (uint64_t)ist_stacks[0] + sizeof(ist_stacks[0]);  /* #DF */
    tss.ist[1] = (uint64_t)ist_stacks[1] + sizeof(ist_stacks[1]);  /* NMI */
    tss.ist[2] = (uint64_t)ist_stacks[2] + sizeof(ist_stacks[2]);  /* #MC */
    tss.iomap_base = sizeof(tss);       /* no I/O bitmap */

    struct gdt_ptr p = { sizeof(gdt) - 1, (uint64_t)gdt };
    __asm__ volatile(
        "lgdt %0\n"
        "pushq %1\n"          /* new CS  */
        "leaq 1f(%%rip), %%rax\n"
        "pushq %%rax\n"
        "lretq\n"             /* far return: reloads CS */
        "1:\n"
        "mov %w2, %%ds\n mov %w2, %%es\n mov %w2, %%ss\n"
        "ltr %w3\n"
        :: "m"(p), "i"(SEL_KCODE), "r"(SEL_KDATA), "r"(SEL_TSS)
        : "rax", "memory");
}
```

### 2.1 The `sysret` selector ordering constraint

`sysret` (64-bit variant) computes:

```
CS = IA32_STAR[63:48] + 16
SS = IA32_STAR[63:48] + 8
```

and `syscall` computes `CS = STAR[47:32]`, `SS = STAR[47:32] + 8`. So the GDT
**must** be laid out kernel code, kernel data, user data, user code. If you put
user code before user data, `sysret` returns to ring 3 with SS pointing at a code
descriptor and everything breaks in a maximally confusing way. Bake the
requirement into a `_Static_assert`:

```c
_Static_assert(SEL_UDATA == SEL_KDATA + 8, "sysret layout");
_Static_assert(SEL_UCODE == SEL_KDATA + 16, "sysret layout");
```

---

## 3. The IDT

```c
/* arch/x86_64/idt.c */
struct idt_entry {
    uint16_t off_lo;
    uint16_t selector;
    uint8_t  ist;        /* bits 0..2 = IST index, rest zero */
    uint8_t  type_attr;  /* P | DPL | 0 | type(0xE=interrupt, 0xF=trap) */
    uint16_t off_mid;
    uint32_t off_hi;
    uint32_t zero;
} __attribute__((packed));

static struct idt_entry idt[256];

#define GATE_INT   0x8E   /* present, DPL=0, interrupt gate (clears IF) */
#define GATE_TRAP  0x8F   /* present, DPL=0, trap gate (leaves IF) */
#define GATE_USER  0xEE   /* present, DPL=3, interrupt gate (int3 from user) */

static void idt_set(int vec, void *handler, uint8_t attr, uint8_t ist) {
    uint64_t a = (uint64_t)handler;
    idt[vec] = (struct idt_entry){
        .off_lo = a & 0xFFFF, .selector = SEL_KCODE, .ist = ist,
        .type_attr = attr, .off_mid = (a >> 16) & 0xFFFF,
        .off_hi = a >> 32, .zero = 0,
    };
}
```

**Interrupt gate vs trap gate:** an interrupt gate clears `IF` on entry (no
nested interrupts); a trap gate leaves it set. Use interrupt gates for
everything unless you have a specific reason. Nested interrupts in a microkernel
are almost never worth the complexity.

**Which vectors get an IST:**

```c
idt_set(8,  isr8,  GATE_INT, 1);   /* #DF  -> IST1 */
idt_set(2,  isr2,  GATE_INT, 2);   /* NMI  -> IST2 */
idt_set(18, isr18, GATE_INT, 3);   /* #MC  -> IST3 */
idt_set(3,  isr3,  GATE_USER, 0);  /* int3 from ring 3, for debuggers */
```

---

## 4. ISR stubs in assembly

The CPU pushes a different frame for vectors with and without an error code. Your
stubs normalize this, save all registers into a `struct regs` on the stack, and
call one C function.

```nasm
; arch/x86_64/entry.asm
extern isr_dispatch

; --- register save/restore macros -------------------------------------------
%macro PUSH_ALL 0
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax
%endmacro

%macro POP_ALL 0
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
%endmacro

; --- stub generators --------------------------------------------------------
%macro ISR_NOERR 1
global isr%1
isr%1:
    push qword 0          ; dummy error code
    push qword %1         ; vector number
    jmp isr_common
%endmacro

%macro ISR_ERR 1
global isr%1
isr%1:
    ; CPU already pushed the error code
    push qword %1
    jmp isr_common
%endmacro

isr_common:
    cld                   ; SysV ABI requires DF=0 on entry to C
    PUSH_ALL

    ; If we came from ring 3, swap GS so %gs points at per-CPU data.
    mov ax, [rsp + 15*8 + 3*8]     ; saved CS
    test ax, 3
    jz .kernel_entry
    swapgs
.kernel_entry:

    mov rdi, rsp                   ; struct regs *
    call isr_dispatch

    mov ax, [rsp + 15*8 + 3*8]
    test ax, 3
    jz .kernel_exit
    swapgs
.kernel_exit:

    POP_ALL
    add rsp, 16                    ; pop vector + error code
    iretq

; --- instantiate all 256 ----------------------------------------------------
%assign i 0
%rep 256
  %if i == 8 || i == 10 || i == 11 || i == 12 || i == 13 || i == 14 || i == 17 || i == 21 || i == 29 || i == 30
    ISR_ERR i
  %else
    ISR_NOERR i
  %endif
  %assign i i+1
%endrep

; --- table of stub addresses, for idt_init() to walk ------------------------
section .rodata
global isr_table
isr_table:
%assign i 0
%rep 256
    dq isr %+ i
  %assign i i+1
%endrep
```

The matching C structure — **the field order must exactly mirror the pushes,
reversed**:

```c
struct regs {
    uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
    uint64_t vector, error;
    uint64_t rip, cs, rflags, rsp, ss;   /* pushed by the CPU */
};
```

Write a `_Static_assert(offsetof(struct regs, rip) == 17*8, ...)` so a future edit
to the macro breaks the build instead of the kernel.

### The `swapgs` correctness hazard

`swapgs` must be executed **exactly once** on entry from user mode and once on
exit. Getting this wrong means `%gs` points at user-controlled data while in
ring 0 — a privilege escalation. The `test ax, 3` check above is the standard
pattern. There is a notorious edge case: an NMI arriving *between* the `syscall`
instruction and your `swapgs`. Real kernels handle this with a paranoid entry
that reads `IA32_GS_BASE` and decides. Note it, and handle it when you add NMI
watchdogs.

---

## 5. The C dispatcher

```c
static const char *exc_name[32] = {
    "#DE divide error", "#DB debug", "NMI", "#BP breakpoint",
    "#OF overflow", "#BR bound range", "#UD invalid opcode",
    "#NM device not available", "#DF double fault", "coprocessor overrun",
    "#TS invalid TSS", "#NP segment not present", "#SS stack fault",
    "#GP general protection", "#PF page fault", "reserved",
    "#MF x87 fp", "#AC alignment check", "#MC machine check",
    "#XM simd fp", "#VE virtualization", "#CP control protection",
    /* ... */
};

void isr_dispatch(struct regs *r) {
    if (r->vector < 32)      exception_handler(r);
    else if (r->vector < 48) legacy_irq(r);       /* if PIC still used */
    else                     irq_handler(r);      /* APIC / MSI vectors */
}

static void exception_handler(struct regs *r) {
    if (r->vector == 14 && page_fault(r) == 0)
        return;                                   /* handled (demand paging) */

    if (from_user(r)) {
        /* Convert to an IPC to the thread's fault endpoint (Ch.08). */
        thread_fault(current, r);
        return;
    }
    panic_regs(r);   /* kernel exception: dump everything and stop */
}
```

### The exception dump — build this *now*

Your first hundred bugs will be exceptions. Make the dump excellent:

```c
void panic_regs(struct regs *r) {
    klog_flush();
    kprintf("\n=== KERNEL PANIC: %s (vec %lu, err %#lx) ===\n",
            r->vector < 32 ? exc_name[r->vector] : "interrupt",
            r->vector, r->error);
    kprintf("RIP %016lx  CS %04lx  RFLAGS %016lx\n", r->rip, r->cs, r->rflags);
    kprintf("RSP %016lx  SS %04lx\n", r->rsp, r->ss);
    kprintf("RAX %016lx RBX %016lx RCX %016lx RDX %016lx\n",
            r->rax, r->rbx, r->rcx, r->rdx);
    kprintf("RSI %016lx RDI %016lx RBP %016lx R8  %016lx\n",
            r->rsi, r->rdi, r->rbp, r->r8);
    /* ... r9-r15 ... */
    kprintf("CR0 %016lx CR2 %016lx CR3 %016lx CR4 %016lx\n",
            read_cr0(), read_cr2(), read_cr3(), read_cr4());

    if (r->vector == 14) {
        uint64_t e = r->error;
        kprintf("PF at %016lx: %s %s %s%s%s\n", read_cr2(),
                e & 1 ? "protection-violation" : "not-present",
                e & 2 ? "write" : "read",
                e & 4 ? "user " : "kernel ",
                e & 8 ? "reserved-bit " : "",
                e & 16 ? "instruction-fetch" : "");
        vmm_dump_walk(read_cr3(), read_cr2());   /* print each PTE level! */
    }

    kprintf("symbol: %s+%#lx\n", ksym_lookup(r->rip, &off), off);
    backtrace_from(r->rbp);
    for (;;) __asm__ volatile("cli; hlt");
}
```

`vmm_dump_walk` — printing the PML4/PDPT/PD/PT entries for the faulting address —
is worth an hour to write and will save you many. Do it in Chapter 06.

---

## 6. Disabling the PIC, enabling the LAPIC

### Remap and mask the 8259

Even if you never use it, you must remap it: its default vectors (0x08–0x0F)
collide with CPU exceptions, and spurious IRQ7 will look like a #DF.

```c
#define PIC1 0x20
#define PIC2 0xA0

void pic_remap_and_disable(void) {
    outb(PIC1, 0x11); io_wait();   /* ICW1: init, expect ICW4 */
    outb(PIC2, 0x11); io_wait();
    outb(PIC1+1, 0x20); io_wait(); /* ICW2: master offset -> 0x20 */
    outb(PIC2+1, 0x28); io_wait(); /* slave offset -> 0x28 */
    outb(PIC1+1, 0x04); io_wait(); /* ICW3: slave on IRQ2 */
    outb(PIC2+1, 0x02); io_wait();
    outb(PIC1+1, 0x01); io_wait(); /* ICW4: 8086 mode */
    outb(PIC2+1, 0x01); io_wait();
    outb(PIC1+1, 0xFF);            /* mask everything */
    outb(PIC2+1, 0xFF);
}
```

Also set `IMCR` (I/O port 0x22/0x23) on old chipsets to route interrupts to the
APIC instead of the PIC. ACPI tells you if this is needed (MADT flag PCAT_COMPAT).

### LAPIC

Prefer **x2APIC** (MSR-based, no MMIO mapping, 32-bit APIC IDs, required for
>255 CPUs). Detect with CPUID.1:ECX[21].

```c
#define IA32_APIC_BASE   0x1B
#define X2APIC_ID        0x802
#define X2APIC_EOI       0x80B
#define X2APIC_SVR       0x80F
#define X2APIC_LVT_TIMER 0x832
#define X2APIC_TIMER_ICR 0x838
#define X2APIC_TIMER_CCR 0x839
#define X2APIC_TIMER_DCR 0x83E

void lapic_init_x2(void) {
    uint64_t base = rdmsr(IA32_APIC_BASE);
    wrmsr(IA32_APIC_BASE, base | (1 << 10) | (1 << 11));  /* EXTD | EN */
    wrmsr(X2APIC_SVR, 0x100 | 0xFF);   /* enable + spurious vector 0xFF */
}

void lapic_eoi(void) { wrmsr(X2APIC_EOI, 0); }
```

**Always send EOI**, and send it *after* you've dealt with the interrupt but
*before* you might block. Forgetting EOI means that IRQ (and everything at lower
priority) never fires again — a hang that looks like a scheduler bug.

### Timer calibration and TSC-deadline

Don't hardcode a tick. Calibrate:

```c
uint64_t tsc_hz, lapic_hz;

void timer_calibrate(void) {
    /* Use the PIT channel 2 (speaker gate) as a 50ms reference. */
    outb(0x61, (inb(0x61) & ~0x02) | 0x01);   /* gate on, speaker off */
    outb(0x43, 0xB2);                          /* ch2, lobyte/hibyte, mode 0 */
    uint16_t div = 1193182 / 20;               /* 50 ms */
    outb(0x42, div & 0xFF);
    outb(0x42, div >> 8);

    /* restart the countdown */
    uint8_t p = inb(0x61) & ~0x01;
    outb(0x61, p); outb(0x61, p | 0x01);

    wrmsr(X2APIC_TIMER_DCR, 0x3);              /* divide by 16 */
    wrmsr(X2APIC_TIMER_ICR, 0xFFFFFFFF);
    uint64_t t0 = rdtsc();

    while (!(inb(0x61) & 0x20)) { }             /* wait for OUT2 to go high */

    uint64_t t1 = rdtsc();
    uint32_t lapic_ticks = 0xFFFFFFFF - (uint32_t)rdmsr(X2APIC_TIMER_CCR);
    wrmsr(X2APIC_TIMER_ICR, 0);

    tsc_hz   = (t1 - t0) * 20;
    lapic_hz = (uint64_t)lapic_ticks * 16 * 20;
    KINFO("TSC %lu MHz, LAPIC bus %lu MHz", tsc_hz/1000000, lapic_hz/1000000);
}
```

Then, if CPUID.1:ECX[24] (TSC-deadline) is set — and it is on anything modern
and in QEMU with `-cpu host` — switch to deadline mode:

```c
void timer_set_deadline_ns(uint64_t ns_from_now) {
    wrmsr(X2APIC_LVT_TIMER, VEC_TIMER | (2 << 17));   /* TSC-deadline mode */
    wrmsr(IA32_TSC_DEADLINE, rdtsc() + ns_to_tsc(ns_from_now));
}
```

**Why this matters for design:** a fixed 100/1000 Hz tick forces every timeout to
round to the tick, wastes energy waking idle cores, and makes your scheduler
coarse. TSC-deadline gives nanosecond one-shot timers, which is what you need for
IPC timeouts, MCS scheduling budgets, and realistic latency measurements. Build
a **timer wheel** or a simple sorted list of `(deadline, callback)` and program
the next deadline each time you return to the scheduler. This is "tickless"
design and it's the modern default.

Also check CPUID.80000007:EDX[8] for **invariant TSC** before trusting `rdtsc`
for wall-clock timing.

---

## 7. IOAPIC and ACPI

To route legacy device IRQs you need the IOAPIC's MMIO base, which comes from
ACPI's **MADT** table. The chain:

```
RSDP (from Multiboot2 tag 15 / Limine / EFI config table)
  → XSDT (64-bit pointers) or RSDT (32-bit)
    → MADT (signature "APIC")   : LAPIC addr, per-CPU LAPIC entries, IOAPICs,
                                  interrupt source overrides
    → FADT (signature "FACP")   : ACPI registers, PM timer
    → MCFG (signature "MCFG")   : PCIe ECAM base — how you enumerate PCIe
    → HPET (signature "HPET")   : HPET base
```

You must handle **Interrupt Source Overrides** — the MADT tells you e.g. "ISA
IRQ 0 is actually GSI 2". Ignoring these is why the timer interrupt mysteriously
doesn't fire on some machines.

Keep ACPI parsing minimal and in the kernel *only* for MADT/MCFG. Full AML
interpretation (for power management, hotplug, laptop buttons) is enormous and
belongs in a userspace ACPI server — a nice illustration of the microkernel
principle, and a good use for [uACPI](https://github.com/uACPI/uACPI) later.

### Routing an IRQ

```c
void ioapic_route(uint8_t gsi, uint8_t vector, uint32_t lapic_id,
                  bool level, bool active_low) {
    uint32_t idx = 0x10 + gsi * 2;
    uint64_t entry = vector
                   | (0UL << 8)                 /* fixed delivery */
                   | (0UL << 11)                /* physical dest */
                   | ((uint64_t)active_low << 13)
                   | ((uint64_t)level << 15)
                   | ((uint64_t)lapic_id << 56);
    ioapic_write(idx,     (uint32_t)entry);
    ioapic_write(idx + 1, (uint32_t)(entry >> 32));
}
```

---

## 8. Design: delivering interrupts to userspace

This is the microkernel-specific part, and it's where you make choices.

### The problem

A user driver must (a) learn that an interrupt occurred, (b) service the device,
(c) tell the kernel it's done so the line can be unmasked. Meanwhile the kernel's
handler must be *bounded time* — it can't run driver logic.

### The seL4/Nyx design

```c
/* Kernel objects */
struct irq_handler {          /* capability-invocable */
    uint8_t  gsi;
    struct notification *notif;   /* bound target, or NULL */
    uint8_t  badge_bit;           /* which bit to set in the notification word */
    bool     masked;
};
```

Kernel ISR, for a routed IRQ:

```c
void irq_handler(struct regs *r) {
    unsigned gsi = vector_to_gsi[r->vector];
    struct irq_handler *h = irq_table[gsi];

    if (h && h->notif) {
        ioapic_mask(gsi);              /* level-triggered: mask until acked */
        h->masked = true;
        notification_signal(h->notif, 1UL << h->badge_bit);
        /* may make a thread runnable; scheduler runs on return */
    }
    lapic_eoi();
}
```

Userspace driver loop:

```c
for (;;) {
    word_t badge = nyx_wait(irq_notification_cap);
    if (badge & (1 << NIC_RX_BIT)) {
        nic_service_rx();
        nyx_invoke(irq_handler_cap, IRQHandler_Ack);   /* unmasks the line */
    }
}
```

Key properties:

- **Kernel handler is O(1)** and allocates nothing.
- **Notifications coalesce**: if 5 interrupts arrive before the driver runs, the
  bit is set once. The driver must therefore be written to drain the device
  completely, not to assume one interrupt = one event. *This is exactly how real
  NIC drivers work anyway (NAPI).*
- **Authority is explicit**: only the holder of the `IRQHandler` capability for
  GSI 11 can receive or acknowledge it.
- **Latency** is one interrupt + one thread wakeup + one mode switch. With direct
  handoff scheduling (Chapter 07) you can make the driver thread run immediately
  on return from the ISR.

### MSI-X (do this for anything modern)

MSI-X removes masking/sharing entirely: each queue gets its own vector, edge
triggered, no EOI ambiguity, no level-mask dance. Allocate a vector, program the
device's MSI-X table entry with `0xFEE00000 | (lapic_id << 12)` as address and
the vector as data, and you're done. Your userspace driver asks a PCI server for
"a vector bound to this notification bit", which invokes a kernel `IRQControl`
capability.

---

## 9. Verification

- [ ] Deliberately execute `int 3` and see a clean dump with correct RIP.
- [ ] Dereference a null pointer in kernel and get a #PF dump with `CR2 == 0`.
- [ ] Recurse infinitely and confirm your #DF handler (with IST) prints
      "stack overflow" instead of the machine resetting.
- [ ] Enable interrupts (`sti`) with the LAPIC timer at 100 Hz and count ticks;
      compare to `qemu`'s wall clock. They should match within 1%.
- [ ] Force a spurious interrupt (vector 0xFF) and confirm it's handled without
      an EOI.
- [ ] Run with `-d int` and confirm no unexpected vectors appear.

A useful in-kernel self-test:

```c
KTEST(idt_breakpoint_returns) {
    volatile int hit = 0;
    ktest_bp_hook = &hit;
    __asm__ volatile("int3");
    KASSERT(hit == 1);      /* handler ran AND we resumed correctly */
}
```

---

## 10. Exercises

1. Why must `cld` be executed before calling into C? Construct a case where
   omitting it corrupts memory.
2. Implement the "paranoid entry" for NMI: read `IA32_GS_BASE` via `rdmsr` and
   only `swapgs` if it's a user value. Explain the race it closes.
3. Measure interrupt entry cost: in your ISR, `rdtsc` at entry and compare with a
   `rdtsc` immediately before triggering `int 0x80`. What's the cost? How does it
   change with `-cpu host` vs TCG?
4. Add a per-IRQ statistics table (count, max latency, total time) printable from
   a debug command. This is your first observability feature.
5. Design (don't implement yet): how would you support an interrupt shared
   between two drivers in different processes, given that only one holds the
   `IRQHandler` capability?

---

Next: [05 — Physical memory: frames, zones, and allocators](05-physical-memory.md)
