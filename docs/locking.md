# Locking

Guide 12 §4. Promised for "the first lock (M4.3)"; this is that file.

The rule is one sentence: **a lock may only be taken while every lock
already held has a strictly lower rank.** A cycle in the acquisition
graph is then impossible, so deadlock is impossible, and neither
depends on anyone remembering the convention — `kernel/lock/spinlock.c`
checks it on every acquire in a `CONFIG_KTEST` build and panics with
both lock names and both ranks.

Equal rank counts as a violation. Two locks of the same rank taken in
opposite orders by two processors is the textbook cycle, and it is the
one a "lower or equal" rule would let through.

## The ranks

Declared once, in `include/nyx/spinlock.h`, because the number is what
the check uses and a second copy would drift.

| Rank | Lock | Notes |
|---|---|---|
| 5 | `bkl` | The big kernel lock. Outermost: taken at kernel entry, released across a context switch. |
| 10 | `rq0`..`rq3` | Per-CPU runqueue. Never nested with another RQ lock (equal rank is a cycle). |
| 20 | `ep` | Per-endpoint. Never held with a CSpace lock (ADR-0011). |
| 30 | TCB | Not split out yet. |
| 40 | `cspace` | Per-CNode. Dropped before any endpoint finalizer. |
| 50 | address space | TLB shootdown lock lives here until a vspace lock exists. |
| 60 | physical memory zone | Not split out yet. |
| 100 | `klog` | Innermost. |

Four of those nine ranks name locks that **do not exist yet**. IPC
left the BKL at ADR-0011: each endpoint and each CNode has a lock,
never held together. `SYS_CALL` / `SYS_RECV` / `SYS_REPLYRECV` take
no BKL. The runqueue lock is always taken; `rq_covered_by_bkl` is
gone.

## What each subsystem takes

| Subsystem | Takes | May it block while holding? |
|---|---|---|
| syscall entry (`syscall_dispatch`) | `bkl` | Yes — and this is the exception that proves the rule. |
| interrupt entry (`isr_dispatch`) | `bkl` | No. |
| sched-wake IPI (idle target) | nothing | No. Flag + EOI; idle's next `schedule()` takes the BKL. |
| scheduler (`rq_add` / `rq_pick`) | that CPU's `rq` **only if the BKL is not held** | No. While every mutator still takes the BKL, a second lock is why yield grew 116 → 342 cy. `rq_covered_by_bkl` is the tripwire. |
| `SYS_DEBUG_NOOP` | nothing | No. |
| `SYS_CALL` / `RECV` / `REPLYRECV` | CSpace 40, then (after drop) endpoint 20, then RQ 10 | Yes — `switch_to` drops whatever is held. |
| scheduler (`switch_to`) | releases `bkl`, restores it after | — |
| logger (`kvlog`) | `klog`, interrupts off | No. |

"May it block while holding" is normally *never* in a spinlock-based
kernel, and it is never here either — with one deliberate exception
that is not really one. A thread that blocks inside a syscall does not
carry the BKL into its wait: `switch_to` drops it entirely, recursion
depth and all, and restores it when something switches back. The lock
belongs to the **thread**, not to the CPU. Without that, one blocked
thread would hold the whole kernel for as long as it waited.

## Two rules that are not about ranks

**Any lock an interrupt handler can take must be taken with interrupts
disabled.** Otherwise the handler runs on a processor that already
holds it and spins on itself forever. `spin_lock_irqsave` exists for
this; `klog` uses it, because interrupt handlers log.

**The BKL is recursive per CPU.** An interrupt can arrive while this
processor is inside the kernel holding it, and the handler cannot know
that. The recursion is counted rather than flagged, because the count
is what `switch_to` has to save and restore.

## What is not here yet

- No lock is held across a `hlt` — the idle loop drops the BKL first.
  This is the single most important release point in the system: three
  idle processors holding the kernel is a deadlock on an idle machine.
- A `yield` that finds only itself on this CPU also drops the BKL for
  a `pause` on a multiprocessor. Without that, a waiter on an otherwise
  empty local runqueue holds the kernel while a thread bound to another
  CPU waits for the lock it needs to start.
- No reader/writer locks, no RCU (guide 12 §7). Nothing has a read-mostly
  access pattern worth the complexity while one lock covers everything.
- No lock ordering is *proved*, only checked at runtime, and only on
  paths a test exercises. That is the honest limit of "poor man's
  lockdep" and the guide says so.
