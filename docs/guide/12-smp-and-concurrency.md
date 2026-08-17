# 12 — SMP, concurrency, and memory ordering

> Goal: multiple cores running, per-CPU state, a locking discipline you can
> defend, correct TLB shootdown, and an understanding of why "just add locks" is
> the wrong answer.

---

## 1. Theory: the three approaches to a multiprocessor kernel

### (a) Big kernel lock

One lock around the entire kernel. Any CPU entering the kernel takes it.

- Trivially correct (given a correct uniprocessor kernel).
- Scales to about 2 cores.
- Linux used this from 1996 to 2011. It took 15 years to remove.

### (b) Fine-grained locking

Every data structure has its own lock; lock ordering rules prevent deadlock.

- Scales well if the locking is right.
- Enormously error-prone: lock ordering violations, missing locks, lock
  convoys, and the fact that "correct" is not testable.
- This is where most of a monolithic kernel's complexity lives.

### (c) Multikernel / partitioned

Each core runs a nearly independent kernel instance with its own data structures.
Cores communicate by *message passing*, not shared memory. Shared state is
replicated and kept consistent by an explicit protocol.

- Barrelfish (ETH Zurich) is the research system; seL4's SMP support leans this
  way; Fuchsia partitions heavily.
- Rationale: modern machines are already distributed systems internally (cache
  coherence *is* a message protocol, just an implicit one). Making it explicit
  gives you scalability, NUMA-awareness, and heterogeneity support.
- Cost: more complex bootstrapping, and cross-core operations become explicitly
  asynchronous.

### The Nyx position

**A microkernel is small enough that (c) is actually achievable**, and it's the
more interesting design. But it's also a lot to take on at once.

Recommended path:

1. **Design as if partitioned**: per-CPU run queues, per-CPU allocator caches,
   per-CPU current pointer, and objects with a home CPU.
2. **Implement a big kernel lock first** so you can boot APs and make progress.
3. **Remove it incrementally**, path by path, measuring as you go. The IPC fast
   path is the one that matters: make same-core IPC lock-free by construction
   (both threads are on this core; the endpoint has a home CPU; cross-core IPC
   goes through an explicit IPI-based path).

The measurement discipline matters more than the choice. Have a benchmark that
runs N cores doing IPC and report scaling. If adding a core doesn't add
throughput, find out why before writing more code.

---

## 2. Booting the application processors

The **BSP** (bootstrap processor) is the one your kernel started on. The **APs**
are halted at reset and must be woken with a specific sequence.

### The INIT-SIPI-SIPI dance

```c
void ap_startup(uint32_t apic_id, paddr_t trampoline) {
    /* trampoline must be page-aligned, below 1 MiB — the AP starts in
       REAL MODE at physical address (vector << 12). */
    uint8_t vector = trampoline >> 12;

    lapic_send_ipi(apic_id, IPI_INIT | IPI_ASSERT, 0);
    udelay(10000);                              /* 10 ms */

    for (int i = 0; i < 2; i++) {               /* SIPI, twice per spec */
        lapic_send_ipi(apic_id, IPI_STARTUP, vector);
        udelay(200);
    }

    /* Wait for the AP to signal it's alive. */
    for (int i = 0; i < 1000 && !ap_ready[apic_id]; i++) udelay(1000);
    if (!ap_ready[apic_id]) KWARN("CPU %u failed to start", apic_id);
}
```

> **No INIT level de-assert in x2APIC mode.** Older versions of this
> sequence — and the P6-era "universal start-up algorithm" it comes from —
> send a second, de-asserted INIT (`IPI_INIT | IPI_LEVEL`, no assert bit)
> after the first. The SDM says that delivery mode is **not supported in
> x2APIC mode**, and writing that encoding to the ICR MSR faults. The
> failure has no output at all: the write is inside AP bring-up, before
> the AP can report anything and while the BSP is mid-sequence, so the
> machine simply stops. If you are writing xAPIC as well, the de-assert
> belongs only on that path. Corrected 2026-08-15, found by
> implementation.

The APs are discovered from the **ACPI MADT** (one Local APIC entry per logical
CPU, with an "enabled" flag).

Three more things are per-CPU state that a bring-up sequence must set on the
AP itself, because the BSP cannot set them on its behalf and each one is
silent when missing:

- **`EFER.SCE`** — without it `syscall` is `#UD`. The symptom is a user
  thread faulting with an invalid opcode at a perfectly valid instruction,
  which reads as memory corruption and is not.
- **`CR0.WP` and `CR4.SMEP`/`SMAP`/`UMIP`** — the kernel's own protections,
  absent on every processor but the one the boot stub ran on.
- **`CR4.PGE`** — a CPU that ignores the global bit merely flushes more than
  it needs to, silently, on that processor only.

The general rule, and it is worth writing down before the first AP: **there
is exactly one `cpu_init()` and every processor runs it, including the BSP.**
Anything the boot stub does for the BSP alone is a bug waiting for a second
CPU. See chapter 0.5.

### The trampoline

The AP starts in **16-bit real mode** at a page-aligned physical address below
1 MiB. So you need a small blob of 16-bit code, copied into low memory, that
repeats the whole boot sequence: enable A20 (already done), load a GDT, enter
protected mode, enable PAE + long mode, load the *same* CR3 the BSP is using,
and jump to a 64-bit entry point.

```nasm
; arch/x86_64/ap_trampoline.asm — assembled separately, copied to 0x8000
[bits 16]
org 0x8000
ap_start:
    cli
    cld
    lgdt [ap_gdt32_ptr - ap_start + 0x8000]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp 0x08:(ap_pm - ap_start + 0x8000)

[bits 32]
ap_pm:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, [ap_cr3]          ; filled in by the BSP before starting us
    mov cr3, eax
    mov eax, cr4
    or  eax, (1 << 5) | (1 << 7)
    mov cr4, eax
    mov ecx, 0xC0000080
    rdmsr
    or  eax, (1 << 8) | (1 << 11) | (1 << 0)
    wrmsr
    mov eax, cr0
    or  eax, (1 << 31) | (1 << 16)
    mov cr0, eax

    lgdt [ap_gdt64_ptr - ap_start + 0x8000]
    jmp 0x08:(ap_long - ap_start + 0x8000)

[bits 64]
ap_long:
    ; Each AP needs its OWN stack. The BSP writes a pointer here first,
    ; and starts APs ONE AT A TIME (serialized by ap_ready).
    mov rsp, [ap_stack]
    mov rax, [ap_entry]        ; = ap_main, a higher-half address
    jmp rax
```

**The serialization matters:** start one AP, wait for it to signal readiness,
then start the next. Otherwise they all read the same `ap_stack` and share a
stack, which fails spectacularly and intermittently.

Alternative: **Limine starts the APs for you** and parks them in a spinloop
waiting for you to write an entry-point pointer. If you're using the Limine path,
this whole section becomes ten lines. That's a real argument for Limine.

---

## 3. Per-CPU data

The foundation of all SMP work. `GS` base points at a per-CPU structure.

```c
struct percpu {
    struct percpu   *self;          /* so `mov %gs:0, %rax` gets the pointer */
    uint32_t         cpu_id, apic_id;
    struct tcb      *current;
    struct tcb      *idle;
    void            *kernel_rsp;    /* used by syscall entry */
    void            *user_rsp;      /* scratch, used by syscall entry */
    struct runqueue  rq;
    struct tss       tss;
    uint64_t         gdt[7];
    struct idt_entry idt[256];      /* or share one IDT; per-CPU is safer */
    bool             need_resched;
    uint32_t         preempt_count;
    struct kmem_cache_cpu caches[NCACHES];   /* per-CPU slab magazines */
    uint64_t         tlb_gen;
    /* padded to a multiple of 64 to avoid false sharing */
} __attribute__((aligned(64)));

static inline struct percpu *this_cpu(void) {
    struct percpu *p;
    __asm__("mov %%gs:0, %0" : "=r"(p));
    return p;
}
#define current (this_cpu()->current)
```

**Discipline:** everything that can be per-CPU should be. Every per-CPU field is
a lock you don't need. Statistics, allocator caches, run queues, timer wheels,
log buffers — all per-CPU, aggregated only when someone asks.

**Hazard:** reading per-CPU data while preemptible is a bug (you might migrate
between reading the pointer and using it). Either disable preemption around
per-CPU access or ensure the code runs with interrupts off.

```c
#define with_preempt_disabled(body) do { \
    preempt_disable(); body; preempt_enable(); \
} while (0)
```

---

## 4. Locks

### The ticket spinlock

A plain test-and-set spinlock is unfair (a CPU can starve) and has terrible cache
behaviour under contention. Use a ticket lock:

```c
typedef struct {
    _Atomic uint32_t next;      /* ticket dispenser */
    _Atomic uint32_t owner;     /* now serving */
#ifdef CONFIG_LOCK_DEBUG
    const char *name;
    uint32_t holder_cpu;
    void *acquired_at;
#endif
} spinlock_t;

static inline void spin_lock(spinlock_t *l) {
    uint32_t t = atomic_fetch_add_explicit(&l->next, 1, memory_order_relaxed);
    while (atomic_load_explicit(&l->owner, memory_order_acquire) != t)
        cpu_relax();            /* `pause` — critical for SMT and power */
}

static inline void spin_unlock(spinlock_t *l) {
    atomic_store_explicit(&l->owner, l->owner + 1, memory_order_release);
}
```

`cpu_relax()` = the `pause` instruction. It hints to the CPU that this is a spin
loop, which avoids memory-order violation penalties on exit and yields
resources to the other SMT thread. Omitting it costs 10–20× on hyperthreaded
cores.

For high contention, **MCS locks** (queue-based, each waiter spins on its own
cache line) scale much better. Ticket locks are fine up to ~8 cores.

### Interrupt-safe locks

If a lock is taken both in normal context and in an interrupt handler, you must
disable interrupts while holding it — or the handler will deadlock against
itself.

```c
static inline unsigned long spin_lock_irqsave(spinlock_t *l) {
    unsigned long f = read_rflags();
    __asm__ volatile("cli" ::: "memory");
    spin_lock(l);
    return f;
}
static inline void spin_unlock_irqrestore(spinlock_t *l, unsigned long f) {
    spin_unlock(l);
    if (f & RFLAGS_IF) __asm__ volatile("sti" ::: "memory");
}
```

### Lock ordering

Deadlock requires a cycle in the lock acquisition graph. Prevent it by assigning
every lock a **rank** and asserting that you only acquire locks in increasing
rank order:

```c
#ifdef CONFIG_LOCK_DEBUG
void lockdep_acquire(spinlock_t *l) {
    struct percpu *c = this_cpu();
    if (c->nheld && c->held[c->nheld-1]->rank >= l->rank)
        panic("lock order violation: %s (rank %d) after %s (rank %d)",
              l->name, l->rank, c->held[c->nheld-1]->name,
              c->held[c->nheld-1]->rank);
    c->held[c->nheld++] = l;
}
#endif
```

This is a poor man's `lockdep` and it takes an hour to write. It will find bugs
that would otherwise appear once a month in production. **Write it.**

Publish the rank order in `docs/locking.md`:

```
rank 10: scheduler run queue
rank 20: endpoint
rank 30: TCB
rank 40: CSpace / CNode
rank 50: address space
rank 60: physical memory zone
```

Also record, for each subsystem: which locks it takes, in which order, and
whether it may block while holding them (in a spinlock-based kernel: never).

---

## 5. Memory ordering in practice

x86-64 is TSO, which forgives most mistakes. That is a *trap*: your code will be
wrong on ARM64 and RISC-V and you won't find out for two years.

**Rule: use C11 atomics with explicit orderings everywhere, never `volatile`.**

```c
/* Publishing a new object: the initialization must be visible before the
   pointer. */
obj->field = 42;
atomic_store_explicit(&global_ptr, obj, memory_order_release);

/* Consuming: reading the pointer must happen before reading the fields. */
struct obj *o = atomic_load_explicit(&global_ptr, memory_order_acquire);
if (o) use(o->field);
```

On x86 both compile to plain `mov` (the CPU already guarantees this), so you pay
nothing. On ARM you get `stlr`/`ldar`. Correct by construction, free on x86.

The one place x86 needs a real barrier is store→load ordering:

```c
/* Dekker / seqlock pattern: needs a full fence even on x86. */
atomic_store_explicit(&flag_a, 1, memory_order_seq_cst);
/* implies mfence or a locked op */
if (atomic_load_explicit(&flag_b, memory_order_seq_cst) == 0) enter_cs();
```

**Compiler barriers are separate.** `__asm__ volatile("" ::: "memory")` stops
compiler reordering with no CPU cost. Useful for MMIO sequencing.

---

## 6. TLB shootdown

The problem: CPU 0 unmaps a page. CPU 1 has a cached translation for it in its
TLB. CPU 1 will keep accessing the old physical page — a use-after-free with the
MMU's cooperation. This is a security bug, not just a correctness bug.

The protocol:

```c
void tlb_shootdown(struct vspace *as, vaddr_t start, vaddr_t end) {
    /* 1. The page table entry has ALREADY been cleared by the caller. */

    /* 2. Invalidate locally. */
    for (vaddr_t v = start; v < end; v += PAGE_SIZE) invlpg(v);

    /* 3. Which CPUs might have this address space in their TLB? */
    cpumask_t targets = atomic_load(&as->active_on);
    cpumask_clear_cpu(&targets, this_cpu()->cpu_id);
    if (cpumask_empty(&targets)) return;

    /* 4. Publish the request, then IPI. */
    struct shootdown req = { .as = as, .start = start, .end = end,
                             .pending = cpumask_weight(&targets) };
    atomic_store_explicit(&this_cpu()->shootdown, &req, memory_order_release);
    lapic_send_ipi_mask(&targets, VEC_TLB_SHOOTDOWN);

    /* 5. Wait for acknowledgement. THIS IS MANDATORY — you cannot free the
          frame until every CPU has flushed. */
    while (atomic_load_explicit(&req.pending, memory_order_acquire) != 0)
        cpu_relax();
}

void tlb_shootdown_ipi(void) {           /* the IPI handler on target CPUs */
    struct shootdown *req = current_shootdown();
    if (this_cpu()->current->vspace == req->as || req->as == NULL) {
        for (vaddr_t v = req->start; v < req->end; v += PAGE_SIZE) invlpg(v);
    }
    atomic_fetch_sub_explicit(&req->pending, 1, memory_order_release);
    lapic_eoi();
}
```

Costs and optimizations:

- A shootdown is expensive: an IPI plus a round-trip wait, easily 5–20 µs. It's
  often the dominant cost of `munmap` in real systems.
- **Batch**: unmap many pages, then one shootdown.
- **Track precisely**: `as->active_on` should be a bitmask updated on
  `vspace_switch`, so you only IPI CPUs that could possibly have the entries.
- **Use PCID generation counters**: instead of IPIing a CPU that isn't currently
  running the address space, bump a generation counter; the CPU flushes lazily
  when it next switches to that address space. Linux does this and it's a big win.
- **Deferred/RCU-style freeing**: don't free the frame until you know all CPUs
  have passed a quiescent point.

---

## 7. RCU and lock-free reads

For structures read constantly and modified rarely (capability tables, the
IRQ routing table, the list of CPUs), **RCU** gives you zero-cost reads.

The idea: readers never block or write shared state. Writers create a new version
and publish it atomically; the old version is freed only after every CPU has
passed through a **quiescent state** (a point where it provably holds no
references — e.g. it has returned to userspace or run the idle loop).

```c
/* Reader — no atomics beyond an acquire load, no locks. */
rcu_read_lock();                          /* often just preempt_disable() */
struct config *c = rcu_dereference(global_config);
use(c);
rcu_read_unlock();

/* Writer */
struct config *new = make_new_config();
struct config *old = rcu_assign_pointer(&global_config, new);
synchronize_rcu();                        /* wait for all readers to finish */
free(old);
```

A microkernel makes RCU unusually easy: **every return to userspace is a
quiescent state**, and the kernel's non-preemptible-with-bounded-operations
design (Chapter 07) means grace periods are short and easy to detect. A
counter-based scheme is a couple hundred lines.

Where to use it in Nyx:
- The CPU list and IRQ routing tables
- The capability lookup fast path (if you ever make CNodes resizable)
- Any global configuration read on every syscall

Where **not** to: anything mutated frequently. RCU trades write cost for read
cost.

---

## 8. Making IPC scale

The reason to care about all this: IPC is the thing you'll do millions of times
per second.

### Same-core IPC (the common case, make it lock-free)

If both threads are on this core, and the endpoint's "home CPU" is this core,
then no other CPU can be touching them — interrupts are off during the fast path,
and preemption doesn't happen mid-syscall. **No locks needed at all.** This is the
big win from the partitioned design: the common case has zero synchronization.

Enforce it: give every endpoint a home CPU. Threads that want to use it migrate
to that CPU, or use the slow cross-core path.

### Cross-core IPC

```c
long ipc_call_remote(struct tcb *t, struct endpoint *ep) {
    /* Enqueue on the target CPU's incoming queue (an MPSC lock-free queue),
       then IPI. Our thread blocks. */
    mpsc_push(&percpu[ep->home_cpu].ipc_inbox, t);
    lapic_send_ipi(percpu[ep->home_cpu].apic_id, VEC_IPC_WAKE);
    t->state = TS_BLOCKED_REPLY;
    schedule();
}
```

Costs an IPI (~1–3 µs). The alternative — locking the endpoint and touching a
remote TCB — causes cache line ping-pong that's often worse under contention, and
is much harder to reason about.

**Design implication:** *place* your servers thoughtfully. A driver that's called
constantly by a client should be on the same core (or the client should migrate).
This is the microkernel version of NUMA placement, and it's a real, measurable
effect. It's also an interesting research direction: automatic component
placement based on observed IPC graphs.

---

## 9. Verification

Concurrency bugs are not found by ordinary testing. Use:

- **Stress tests with assertions.** N threads hammering a structure, with an
  invariant checked continuously.
- **Randomized delays.** Under `CONFIG_DEBUG_SCHED`, insert random `pause` loops
  and random preemptions at every safe point. This dramatically widens race
  windows.
- **A "chaos" IPI**: randomly IPI other CPUs to perturb timing.
- **Host-side model checking.** Extract your lock-free data structures (rings,
  MPSC queues, RCU) into standalone files and check them with
  **[CBMC](https://www.cprover.org/cbmc/)** or **[Loom](https://github.com/tokio-rs/loom)**
  (if you write them in Rust). Model checking a 200-line ring buffer for all
  interleavings is *feasible* and finds bugs testing never will.
- **`herd7`/`litmus`** for reasoning about specific memory-ordering questions.
- **TSan on host-compiled subsystems.**

```c
KTEST_SMP(spinlock_mutual_exclusion) {
    static _Atomic int in_cs;
    parallel_for_each_cpu({
        for (int i = 0; i < 100000; i++) {
            spin_lock(&test_lock);
            KASSERT(atomic_fetch_add(&in_cs, 1) == 0);
            cpu_relax();
            atomic_fetch_sub(&in_cs, 1);
            spin_unlock(&test_lock);
        }
    });
}

KTEST_SMP(tlb_shootdown_correctness) {
    /* CPU A maps a page, writes a magic value; CPU B reads it;
       CPU A unmaps and remaps a DIFFERENT frame at the same address;
       CPU B must NOT see the old value. */
}
```

That TLB test is worth writing carefully. It's the exact bug that's invisible on
a uniprocessor, catastrophic on SMP, and unlikely to be found by accident.

---

## 10. Exercises

1. Boot 4 CPUs and have each print its APIC ID. Then find and fix the race you
   almost certainly have in the trampoline.
2. Implement lockdep as described and run your existing test suite. How many
   ordering violations does it find?
3. Measure IPC throughput with 1, 2, 4, and 8 cores, with independent
   client/server pairs. Is it linear? If not, find the shared cache line.
4. Implement per-CPU slab magazines and measure allocation throughput before and
   after.
5. Implement the lazy PCID-generation TLB shootdown optimization and measure the
   improvement on an `munmap`-heavy benchmark.
6. Take your SPSC ring buffer (Chapter 08), write it in Rust, and verify it with
   Loom. Then port the fix back to C.
7. Argue: should Nyx's scheduler support thread migration between cores at all?
   What does a partitioned design lose, and is it worth it?

---

Next: [13 — Modern and experimental directions](13-modern-and-research.md)
