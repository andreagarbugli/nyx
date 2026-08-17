# ADR-0014 — After init, the kernel allocates nothing

- date: 2026-08-15
- status: accepted
- guide: 09 §4 (untyped migration), 14 §6.2 (bounding the kernel)

## Context

Track A blocker 6, and `docs/invariants.md`'s one **Not held** line:
"no kernel heap after the untyped migration". `pmm_alloc` is live, and
it is reachable from a syscall — `arch/x86_64/vmm.c:102` allocates
intermediate page tables inside the map walk, so `VSPACE_MAP` can
allocate. `struct vspace` and `struct tcb` still come from fixed pools
(`VSPACE_MAX`, `TCB_MAX`).

Two separate problems wear the same clothes here, and only one of them
is about purity:

1. **Charging.** Memory the kernel finds for itself is memory no
   component paid for, so a component's Untyped budget stops being a
   bound on what it can cost the system.
2. **Latency.** An allocation on a syscall path is an unbounded search
   with an interesting failure mode. That is blocker 5's problem, and
   it is the reason this matters to track A at all.

## Decision

**No allocation on any path reachable from a syscall.** Boot keeps an
arena for what exists before any program does.

- Page tables become explicit: the caller supplies the storage, as seL4
  does. `VSPACE_MAP` no longer conjures intermediate levels.
- `struct tcb` and `struct vspace` are retyped from Untyped like every
  other object; the pools go, and with them `TCB_MAX` and `VSPACE_MAX`.
- The boot arena serves the frame database, the per-CPU areas, the IST
  stacks and the IDT — things created before there is a program to
  charge — and **never runs again**. A flag set at the end of init makes
  a later call a panic in ktest builds, so the property is enforced
  rather than asserted in prose.

The invariant becomes stateable and true: *after init, the kernel
allocates nothing.*

## Alternatives rejected

- **Full purity, including boot.** Pre-carving boot memory as an Untyped
  before the frame database exists is a bootstrapping knot for no
  benefit: nothing at that point can be charged to anyone, and the
  allocator provably never runs again. The stricter claim would be true
  and would cost a boot path that is currently simple and correct.
- **Defer entirely.** Nothing in P6's demo obviously needs it — an RT
  thread that never retypes never allocates. But `VSPACE_MAP` *does*
  allocate, an RT thread that maps a page pays for it, and the
  invariants file keeps its "Not held" line indefinitely.

## Consequences

- The largest single change on the track-A list: it touches every
  allocation site and the `VSPACE_MAP` ABI, so every loader (root, pm,
  mem) learns to supply page-table objects.
- The static ceilings go, which also removes the "never run at a size
  where the allocator matters" gap the retrospective names.
- Ordering: this lands **after** ADR-0013, because retyping a page-table
  object zeroes it, and zeroing is one of the operations that has to
  become preemptible first.
