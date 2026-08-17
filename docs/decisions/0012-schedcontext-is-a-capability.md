# ADR-0012 — A scheduling context is a capability

- date: 2026-08-15
- status: accepted
- guide: 14 §4 (the object), §4.4 (donation), §5 (bands)

## Context

Track A blockers 2 and 3. Today a thread has a priority and nothing
else: no budget, no period, and no accounting beyond `cycles_total`,
which is a statistic rather than a control input. "Provably meeting a
deadline" is not available from that, and neither is the passive-server
story — a high-priority client calling a low-priority server inherits
nothing, so the inversion the whole vertical exists to avoid is present
in the one place it matters most.

The measurement that makes it concrete: cross-core IPC p99 is 21.9 µs
against a p50 of 9.5 µs (docs/performance.md). A control loop that does
one IPC per period sees that tail, and nothing in the kernel currently
lets a thread say what its deadline was.

## Decision

A **SchedContext is a kernel object with a capability**, retyped from
Untyped like every other object, carrying `(budget, period)` and a
replenishment. A TCB is runnable only while bound to one.

1. Time is charged to the context that is *running*, not to the thread
   that owns it. `switch_to` already reads the TSC once and accumulates
   `cycles_total`; that is the seam.
2. **A passive server runs on its client's context.** `ipc_call` lends
   the caller's SchedContext to the receiver for the duration of the
   request, which is what makes a server's work accountable to whoever
   asked for it, and what removes the inversion without a priority
   inheritance protocol.
3. Budget exhaustion is an event with a defined outcome (guide 14 §4.3),
   not a missed tick: the thread is removed from its runqueue and its
   replenishment is scheduled.
4. Priority bands (guide 14 §5) sit above this, not instead of it.

## Alternatives rejected

- **Budget fields on the TCB.** About a third of the work and enough
  for periodic threads on an isolated core, but a server has no context
  of its own to be lent, so passive servers and donation stay
  impossible. That is the case track A cares about, so this saves effort
  on everything except the thing that matters.
- **Bands now, contexts later.** Gets isolation from non-RT work
  quickly, but an RT thread that overruns is unbounded, so the
  guarantee remains "best effort, loudly". Bands are kept as a layer
  *on top*, which costs nothing to defer.

## Consequences

- A new object type, `CAP_SCHEDCONTEXT`, appended to `enum cap_type`,
  with a size, a finalizer and a retype case — the pattern is already
  established five times over.
- `thread_resume` gains a precondition: no context, no run. Every
  existing caller (root, pm, the ktests) has to supply one, which is
  the same shape as TCB_CONFIGURE's existing requirement.
- Lending across IPC means the reply path must return the context. That
  is the same symmetry ADR-0003 and invariant 13a already demand of the
  reply obligation, and it should be enforced the same way: both
  directions, or neither.
