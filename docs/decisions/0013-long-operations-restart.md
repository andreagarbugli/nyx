# ADR-0013 — Long kernel operations preempt by restarting

- date: 2026-08-15
- status: accepted
- guide: 09 §3 (revoke), 14 §6.2 (bounding the kernel)

## Context

Track A blocker 4, and the retype-zeroing row of guide 14 §6.2's table.
Two kernel operations have no bound: `cap_revoke` walks a CDT subtree of
unknown size, and `untyped_retype` zeroes O(size) bytes — 64 pages is
20–40 µs by the guide's own figure, which is already most of a 100 µs
budget and all of it if the object is larger.

Both currently run to completion with the caller waiting, and (until
ADR-0011) with the big kernel lock held, so their cost was the whole
system's worst-case latency rather than one caller's.

## Decision

A long operation stores its own progress **in the object it is
operating on**, returns `E_RESTART` at a preemption point, and the
syscall returns. Userspace re-invokes until it gets `E_OK`.

- Preemption points are taken on a fixed count (every N pages, N slots)
  *and* when a reschedule or an interrupt is pending.
- The granularity is a `CONFIG_` knob with a measured number next to it,
  because the right N is a property of the machine, not of the design.
- Applies to `cap_revoke`, `untyped_retype`'s zeroing, and
  `vspace_destroy` when it exists.

## Alternatives rejected

- **Kernel-side continuations.** Callers stay simple, but the kernel
  then owns unbounded pending work that no capability names — which is
  exactly what the object model exists to prevent, and it makes "the
  kernel allocates nothing" harder rather than easier (ADR-0014).
- **A kernel worker thread.** Simple to reason about and the RT path
  never waits on it, but it reintroduces a schedulable entity with no
  SchedContext and no capability (contradicting ADR-0012), and deletion
  becomes asynchronous — so `cap_revoke` would stop being observable at
  its call site, which is the property every teardown test relies on.

## Consequences

- `E_RESTART` is appended to `enum nyx_err`; it is a normal outcome, not
  a failure, and libnyx wraps the loop so no caller open-codes it.
- Root's 64-slot teardown sweep and the reincarnation server's reclaim
  both become loops. They are already loops; they gain a retry.
- The kernel stays stackless with respect to long operations, which is
  the property that keeps it verifiable — and the reason this convention
  is seL4's rather than an invention here.
