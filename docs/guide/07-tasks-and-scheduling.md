# 07 — Threads, context switching, and scheduling

> Goal: multiple kernel threads running, preemptible, with a scheduler whose
> *policy* can be influenced from userspace, and a context switch you understand
> instruction by instruction.

---

## 1. Theory: what a thread is, precisely

A thread is a **saved CPU state plus a stack plus scheduling metadata**. That's
it. Everything else people associate with threads (address space, file handles,
identity) belongs to other objects.

This separation is a microkernel hallmark and it's worth being strict about:

| Concept | Object in Nyx | Contains |
|---|---|---|
| Execution | **TCB** | registers, kernel stack, sched params, state |
| Memory | **VSpace** | page tables |
| Authority | **CSpace** (CNode tree) | capability slots |
| Time | **SchedContext** (Ch.13) | budget, period |

A "process" in the UNIX sense is a *userspace convention*: one VSpace, one
CSpace, one or more TCBs, managed by the process manager server. The kernel has
no `struct process`. This is not pedantry — it's what lets you build threads,
processes, containers, VMs, and green threads all out of the same parts.

### Thread states

```
                 thread_resume()
    Inactive ─────────────────────► Ready ◄────────────┐
        ▲                            │  ▲              │
        │ thread_suspend()           │  │ preempt /    │ wakeup
        │                    dispatch│  │ yield        │
        │                            ▼  │              │
        └──────────────────────── Running ─────────────┤
                                     │   block on IPC  │
                                     ▼                 │
                        BlockedSend / BlockedRecv ─────┘
                        BlockedNotify / BlockedReply
```

Keep the state enum small and make illegal transitions assert. State machine bugs
in the scheduler are the worst bugs in a kernel because they manifest as
"sometimes a thread never runs again."

```c
enum thread_state {
    TS_INACTIVE, TS_READY, TS_RUNNING,
    TS_BLOCKED_SEND, TS_BLOCKED_RECV, TS_BLOCKED_REPLY, TS_BLOCKED_NOTIFY,
    TS_IDLE,
};
```

---

## 2. The TCB

```c
struct tcb {
    /* --- hot: touched on every switch. Keep in the first cache lines. --- */
    void            *ksp;             /* saved kernel stack pointer */
    struct vspace   *vspace;
    uint8_t          state;
    uint8_t          prio;            /* 0..255, higher = more urgent */
    uint16_t         cpu;             /* last/current CPU */
    uint32_t         timeslice_left;  /* in ns */

    /* --- IPC state (Ch.08) --- */
    struct endpoint *blocked_on;
    struct list_head ep_link;         /* queue linkage on the endpoint */
    struct tcb      *reply_to;        /* one-shot reply capability, "caller" */
    word_t           badge;           /* badge of the cap used to reach us */
    struct message   msg;             /* the register-message buffer */

    /* --- authority --- */
    struct cnode    *cspace_root;
    struct endpoint *fault_ep;

    /* --- cold --- */
    uint32_t         id;
    char             name[16];        /* for debugging. Always name threads. */
    void            *kstack_base;
    struct fpu_state *fpu;
    struct list_head sched_link;
    uint64_t         cycles_total;    /* accounting */
    uint64_t         ipc_count;
};
```

Design notes:

- **Cache layout matters.** The scheduler and IPC fast path touch `ksp`, `state`,
  `prio`, `blocked_on`, `msg`. Put them together. Measure with a benchmark before
  and after; on a hot IPC path, one extra cache miss is ~30% of the cost.
- **`name[16]`** is not optional. When you have 40 threads and one is stuck, a
  numeric ID is useless.
- **`msg` in the TCB, not on the stack.** L4's insight: the message buffer must be
  reachable without a copy from either side.

### Kernel stack per thread

Each thread gets its own kernel stack (16 KiB is generous; 8 KiB is typical),
with a guard page below (Chapter 06). The alternative — a per-CPU kernel stack,
with threads never blocking in kernel mode — is a real design (it's what "process
model" vs "interrupt model" kernels differ on):

| Model | Kernel stacks | Blocking in kernel | Notes |
|---|---|---|---|
| **Process model** | One per thread | Natural: just block, the stack holds your state | More memory (8 KiB × N threads), simpler code. **Use this.** |
| **Interrupt model** | One per CPU | Must be restructured into continuations | Tiny memory footprint, harder code. seL4 uses this; it's part of why it's verifiable. |

seL4's choice of the interrupt model with explicit continuations is a big reason
its proof is tractable — there's no arbitrary kernel stack state to reason about.
If formal verification is a long-term goal for you, consider it. For learning,
process model first.

---

## 3. Context switching

### The minimal switch

Because we call it from C, the System V ABI already guarantees caller-saved
registers are dead. We only need to save the **callee-saved** set.

```nasm
; void context_switch(void **old_ksp, void *new_ksp);
;   rdi = &old->ksp    rsi = new->ksp
global context_switch
context_switch:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rdi], rsp          ; save old stack pointer
    mov rsp, rsi            ; switch stacks

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret                     ; returns into the *new* thread's caller
```

That's the whole thing. Six pushes, a stack swap, six pops. The magic is in the
`ret`: the new stack's top holds a return address from when *that* thread called
`context_switch`, so control resumes there.

### Bootstrapping a new thread

A brand-new thread has never called `context_switch`, so you must fabricate a
stack that looks like it did:

```c
struct switch_frame {
    uint64_t r15, r14, r13, r12, rbx, rbp;
    uint64_t rip;            /* what `ret` will jump to */
};

void thread_setup_kernel_entry(struct tcb *t, void (*entry)(void *), void *arg) {
    uint8_t *sp = (uint8_t *)t->kstack_top;
    sp -= sizeof(struct switch_frame);
    struct switch_frame *f = (void *)sp;
    memset(f, 0, sizeof(*f));
    f->rip = (uint64_t)thread_trampoline;
    f->rbx = (uint64_t)entry;      /* trampoline reads these */
    f->r12 = (uint64_t)arg;
    t->ksp = sp;
}
```

```nasm
global thread_trampoline
thread_trampoline:
    mov rdi, r12          ; arg
    call rbx              ; entry(arg)
    call thread_exit      ; if it returns
    ud2                   ; must not reach
```

For a thread that will run in **userspace**, the trampoline instead builds an
`iretq` frame and returns to ring 3 (Chapter 10).

### The full switch, with everything

```c
void switch_to(struct tcb *next) {
    struct tcb *prev = current;
    if (prev == next) return;

    /* 1. FPU state. Eager, not lazy (CVE-2018-3665). */
    if (prev->fpu) fpu_save(prev->fpu);

    /* 2. Address space. Skip if the same — this is a common and valuable
          optimization for threads in the same process. */
    if (next->vspace != prev->vspace)
        vspace_switch(next->vspace);

    /* 3. The kernel stack the CPU will use on the next ring 3 -> 0 entry. */
    this_cpu()->tss.rsp[0] = (uint64_t)next->kstack_top;

    /* 4. Per-CPU current pointer, and user FS/GS bases. */
    this_cpu()->current = next;
    wrmsr(IA32_KERNEL_GS_BASE, next->user_gs_base);
    wrmsr(IA32_FS_BASE, next->user_fs_base);

    if (next->fpu) fpu_restore(next->fpu);

    /* 5. Accounting. */
    uint64_t now = rdtsc();
    prev->cycles_total += now - prev->sched_in_tsc;
    next->sched_in_tsc = now;

    /* 6. The actual switch. */
    context_switch(&prev->ksp, next->ksp);
    /* When we return here, `prev` is running again. `current` is prev. */
}
```

**The mental model that unsticks people:** `context_switch` is a function that
takes a long time to return, and when it returns, the world has changed. Anything
you cached in a local variable before the call (like `current`) may now be stale.

---

## 4. Scheduling

### Theory: what a scheduler optimizes

Schedulers trade off:

- **Throughput** — work completed per unit time
- **Latency / response time** — time from ready to running
- **Fairness** — proportional share of CPU
- **Predictability** — bounded worst-case (real-time)
- **Energy** — race-to-idle vs. slow-and-steady

No single policy wins on all. Hence the microkernel position: **the kernel
implements a mechanism general enough to express several policies, and userspace
picks.**

### The algorithm zoo

| Algorithm | Idea | Good for | Bad at |
|---|---|---|---|
| **Round robin** | FIFO with timeslice | Simplicity | Latency, priority |
| **Fixed-priority preemptive** | Always run the highest-priority runnable thread | Real-time, microkernels (MINIX, L4, seL4) | Starvation, needs priority assignment |
| **MLFQ** | Multiple priority queues; demote CPU hogs, promote I/O-bound | General purpose, no config | Gameable, tuning-heavy |
| **Lottery / stride** | Proportional-share by ticket count | Fairness with a knob | Latency jitter |
| **CFS** | Virtual runtime; run the thread with the smallest vruntime, kept in an RB-tree | Desktop fairness | Complex, poor real-time |
| **EEVDF** | CFS successor: virtual deadline, provable lag bounds | Fairness + latency | Newer, complex |
| **EDF** | Earliest deadline first | Hard real-time, optimal on uniprocessor | Needs deadlines, degrades badly on overload |
| **MCS (seL4)** | Scheduling contexts with budget+period as capabilities | Mixed criticality, temporal isolation | Requires rethinking every server |

### The Nyx design

**In-kernel mechanism:** fixed-priority preemptive round-robin within a priority
level, 256 levels, O(1) selection via a bitmap.

```c
struct runqueue {
    uint64_t         bitmap[4];         /* 256 bits: which priorities are non-empty */
    struct list_head q[256];
    struct tcb      *idle;
};

static inline void rq_add(struct runqueue *rq, struct tcb *t) {
    list_add_tail(&rq->q[t->prio], &t->sched_link);
    rq->bitmap[t->prio >> 6] |= 1UL << (t->prio & 63);
    t->state = TS_READY;
}

static inline struct tcb *rq_pick(struct runqueue *rq) {
    for (int i = 3; i >= 0; i--) {
        if (rq->bitmap[i]) {
            int prio = i * 64 + (63 - __builtin_clzll(rq->bitmap[i]));
            struct tcb *t = list_first(&rq->q[prio], struct tcb, sched_link);
            return t;
        }
    }
    return rq->idle;
}
```

`__builtin_clzll` compiles to a single `lzcnt`/`bsr`. Selection is ~5
instructions regardless of thread count. This is the L4/seL4 approach and it's
the right default for a microkernel because it makes latency *predictable*, which
matters enormously when a "system call" is a chain of server IPCs — each server
hop must not introduce unbounded delay.

**Userspace policy** is exercised through:

- A `TCB_SetPriority` invocation, gated by a capability. Only a thread holding
  authority over a TCB (and holding a priority no lower than the one being set —
  the *maximum controlled priority* rule from seL4) can raise its priority. This
  prevents privilege escalation via priority.
- A `TCB_SetTimeslice` invocation.
- A userspace scheduler server that holds TCB capabilities for a group of threads
  and implements CFS, EDF, or anything else by manipulating priorities and
  suspend/resume. This is the "scheduler activations" idea, done with
  capabilities.

### Preemption

```c
void timer_tick(void) {
    struct tcb *t = current;
    uint64_t now = rdtsc();
    uint64_t used = tsc_to_ns(now - t->sched_in_tsc);

    if (used >= t->timeslice_left) {
        t->timeslice_left = 0;
        set_need_resched();
    } else {
        t->timeslice_left -= used;
    }
    timer_set_deadline_ns(MIN(t->timeslice_left, next_timer_deadline()));
}
```

`need_resched` is a per-CPU flag; the actual `schedule()` call happens at a safe
point — on the return path from the interrupt, just before restoring registers.
**Never call `schedule()` from inside an ISR while holding a lock.**

```c
/* Called at the end of isr_common, before POP_ALL */
void preempt_check(struct regs *r) {
    if (this_cpu()->need_resched && preempt_count == 0) {
        this_cpu()->need_resched = false;
        schedule();
    }
}
```

### Preemptibility of the kernel itself

Three levels:

1. **Non-preemptible kernel.** Once in the kernel, run to completion. Simple,
   safe, terrible worst-case latency.
2. **Preemption points.** The kernel checks `need_resched` at specific safe
   points in long operations. seL4 does this: long operations (like destroying a
   large object) are made *restartable* — they save progress and return, and the
   syscall is re-entered. This preserves the "no arbitrary kernel state" property
   needed for verification.
3. **Fully preemptible kernel.** Any kernel code can be preempted, requiring
   fine-grained locking everywhere.

**Choose #2.** It's the microkernel answer: keep operations short, and make the
few long ones explicitly restartable. Bounded worst-case latency without
fine-grained locking complexity. Write down, in `docs/`, the maximum number of
operations any syscall performs before yielding — that's your latency bound, and
it's a number you can defend.

---

## 5. The idle thread

Every CPU needs one. Its job:

```c
static void idle_loop(void *unused) {
    for (;;) {
        /* Opportunity: zero free pages, flush deferred work, run RCU
           callbacks — but keep it interruptible. */
        if (!work_pending())
            __asm__ volatile("sti; hlt");   /* atomically enable + halt */
        schedule();
    }
}
```

`sti; hlt` in that order is required: `sti` takes effect after the *next*
instruction, so the pair is atomic with respect to interrupt delivery. Writing
`sti` then `hlt` as separate C statements risks the compiler inserting something
between them — use one asm block.

Under QEMU, `hlt` is what lets your VM not spin a host core at 100%. If your
idle loop busy-waits, you'll notice immediately.

**Power management** later: `monitor`/`mwait` for lower-latency wakeup, C-states
via ACPI. Design hook: make `cpu_idle()` an arch function.

---

## 6. Priority inversion, and why microkernels care

Classic scenario: low-priority thread L holds a resource; high-priority H needs
it; medium-priority M preempts L; H is blocked indefinitely by M. This killed
Mars Pathfinder.

In a microkernel this is *structural*, not incidental: every server is a shared
resource, and a low-priority client's request occupies the server thread while a
high-priority client waits.

Solutions:

1. **Priority inheritance.** The server temporarily runs at the priority of its
   highest-priority waiting client. Requires the kernel to track the dependency
   chain. Effective, but adds complexity and can chain deeply.
2. **Priority ceiling.** Each server has a fixed priority ≥ any client that can
   call it. Simple, but requires knowing the client set, and a high-ceiling server
   can hog the CPU.
3. **Run the server on the client's time** — the "migrating threads" or
   "passive server" model. The client's *scheduling context* is donated to the
   server for the duration of the call. This is seL4's MCS answer, and it's
   elegant: the server has no scheduling context of its own; it runs on whoever
   called it. Accounting is automatically correct, and inversion cannot occur
   because there is no separate server priority.

**Design decision for Nyx:** start with (2) — a per-server fixed priority — and
document the limitation. Then implement (3) in Chapter 13 as your first real
research feature. Passive servers with donated scheduling contexts is genuinely
state-of-the-art and it's a satisfying thing to build.

---

## 7. Direct process switch (the IPC/scheduler interaction)

The single most important scheduler optimization in a microkernel:

```c
/* Naive: sender blocks, scheduler picks someone. */
ipc_call(ep, msg) {
    enqueue_on(ep, current);
    current->state = TS_BLOCKED_REPLY;
    schedule();                     /* runs rq_pick(): O(1) but a full switch */
}

/* Direct switch: if the receiver is ready and eligible, go straight to it,
   donating the remainder of our timeslice. */
ipc_call(ep, msg) {
    struct tcb *r = ep_dequeue_receiver(ep);
    if (r) {
        transfer_message(current, r);
        current->state = TS_BLOCKED_REPLY;
        r->timeslice_left = current->timeslice_left;   /* donate */
        switch_to(r);                                  /* no scheduler! */
        return;
    }
    ...
}
```

Effects:

- Skips the scheduler entirely on the common path.
- The call behaves like a protected procedure call: the client's time pays for
  the server's work, which is the *correct* accounting.
- Latency is one context switch, not two plus a scheduling decision.

**Caveat:** if the receiver has lower priority than some other ready thread,
running it directly violates the priority invariant. Correct rule: switch
directly only if the receiver's priority ≥ the highest-priority ready thread.
seL4 handles this precisely; be careful and write the check.

---

## 8. Verification

```c
KTEST(sched_round_robin_fairness) {
    static volatile int counts[4];
    for (int i = 0; i < 4; i++)
        thread_create_kernel(spin_and_count, (void *)(long)i, PRIO_NORMAL);
    sleep_ms(100);
    for (int i = 0; i < 4; i++)
        KASSERT(counts[i] > 0 && abs(counts[i] - counts[0]) < counts[0] / 4);
}

KTEST(sched_priority_respected) {
    /* A high-priority spinner must completely starve a low-priority one. */
}

KTEST(context_switch_preserves_callee_saved) {
    /* Set rbx/r12-r15 to magic values, yield, check they survived. */
}
```

**Measure your switch cost:**

```c
uint64_t t0 = rdtsc();
for (int i = 0; i < 100000; i++) yield_to(&other);
uint64_t t1 = rdtsc();
kprintf("switch: %lu cycles\n", (t1 - t0) / 200000);
```

Expected ballpark on modern x86 with KVM: 100–300 cycles for a same-address-space
switch, 500–1500 with a CR3 change (much better with PCID). If you see 5000, find
out why — usually an unnecessary FPU save or a TLB flush.

**Debugging aid to build now:** a `ps`-like command over serial that dumps every
thread's name, state, priority, blocked-on object, and CPU time. When the system
hangs, this one command tells you which of the ten "everything is blocked"
scenarios you're in.

---

## 9. Exercises

1. Explain why `context_switch` doesn't save RAX, RCX, RDX, RSI, RDI, R8–R11.
   Then construct a scenario where calling it from assembly (not C) breaks.
2. Implement `thread_exit` correctly. The hard part: you cannot free your own
   kernel stack while running on it. What are the two standard solutions?
3. Implement priority inheritance for endpoint queues. What data structure do
   you need to un-inherit correctly when there are nested dependencies?
4. Implement a userspace scheduler server that provides CFS semantics using only
   `TCB_SetPriority`, `TCB_Suspend`, `TCB_Resume`, and a timer notification.
   What's the overhead compared to in-kernel CFS?
5. The `switch_to` code caches `prev = current` before the switch. Identify every
   place in your kernel where a variable might be stale after a switch. Consider
   adding a `__after_switch_invalid` annotation convention.

---

Next: [08 — IPC: the heart of a microkernel](08-ipc.md)
