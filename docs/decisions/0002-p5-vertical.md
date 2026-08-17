# ADR-0002 — Take real-time + TSN as the P5 vertical

- date: 2026-08-13
- status: accepted (2026-08-13)
- guide: 14, 34, 35, 37; ROADMAP.md P5; appendix E §E1

## Context

`ROADMAP.md` P5 offers four verticals and says to pick **one** by M3.0 and
record it as an ADR. M3.0 is now done and no such ADR exists. The decision is
therefore late, and every chapter from 13 onward is available as a
distraction in the meantime — `docs/evaluation.md` ranks this as its top risk
(R1: "a year of horizontal work and no number").

The workbench's purpose is to produce findings, and a finding needs a claim
sharp enough to be wrong. Appendix E §E1 states the one that would justify
the architecture: *what does a microkernel actually cost in 2026*, decomposed
into mode switches, cache/TLB, scheduling, and copies. A vertical is only
worth choosing if it forces that number into the open.

There is also a schedule constraint that is easy to miss: several of the
"deliberate simplifications" recorded in earlier milestones stop being
simplifications and become correctness bugs under a priority-diverse,
budgeted workload. Choosing the vertical decides whether those are backlog
items or blockers.

## Decision

P5 is **track A: real-time + TSN**. The deliverable is a number, not a demo:
a 1 ms control loop meeting its deadline while an adversary saturates cache,
memory bandwidth, and network from another partition — sensor to actuator
across a TSN link, fully traced.

Track C (virtualization) is retained as a later *instrument* for measuring A
against Linux on the same hardware, not as a goal. Tracks B (graphics) and D
(distributed) are out of scope for P5 and may share this kernel later if A
works.

## Alternatives rejected

- **B — graphics (guides 21–26).** Highest demo value and a genuinely novel
  result is available (a capability window system with a machine-checkable
  "what can observe keystrokes" report). Rejected because it is a second
  operating system: display, compositor, input, window API, and GPU are five
  subsystems, none of which exercise the kernel property the project exists
  to test. Starting it before M4.0 is the most plausible way this workbench
  dies.
- **C — virtualization (guide 29) as the goal.** Booting Linux buys software
  and a comparison baseline cheaply. Rejected as the *goal* because the
  project then becomes a hypervisor with a research story attached, and the
  capability system ends up justified by guest isolation that the hardware
  already provides. Kept as a tool for E1.
- **D — distributed (guide 28).** The claim — that a capability and a message
  do not change meaning when the other end is a different machine — is real
  research. Rejected for now because it needs a working local system first,
  including the failure model (appendix E §E3) that is currently undesigned:
  endpoint teardown does not exist, so "the other end went away" has no
  encoding even within one machine. See ADR-0003.
- **Stay horizontal / decide later.** Rejected because "later" has already
  happened once: the roadmap said M3.0.

## Consequences

Makes easy:

- The vertical matches what the kernel already is. Bounded operations are
  already a stated goal, IPC already allocates nothing, tracing already
  exists and is measured, and ADR-0001 already pushes liveness to a userspace
  watchdog. Track A is the only option that reuses all four.
- The result is falsifiable and nobody has published it: the
  partitioned-adversary latency number on current hardware.

Makes hard — and this is the part that must not be discovered late. The
following are recorded across M1.3–M3.0 as deliberate simplifications, and
under track A each becomes a **blocker**, not a nicety:

| Simplification | Why A breaks it |
|---|---|
| Direct switch without the priority check (guide 07 §7) | A low-priority server displaces a high-priority ready thread for a full timeslice the caller never accounted. This is the one that is already a latent correctness bug. |
| No timeslice accounting | A quantum is unbounded, so "meets its deadline" has no mechanism behind it. |
| No `SchedContext` / passive servers (guide 14) | Budget and period are the vocabulary track A's claim is stated in. |
| `cap_revoke` is unbounded recursion | Violates bounded syscall time and can exhaust the kernel stack. |
| Whole syscall path runs `IF=0` | The kernel's non-preemptible region is currently "all of it", which is exactly the quantity a latency bound is about. |
| `pmm_alloc` still live as a general allocator | Guide 14's table claims "kernel never allocates"; today that is a claim about a kernel that does not exist. |

Forecloses: nothing permanently. B and D remain possible on this kernel; the
cost of resuming either is that their guide chapters stay unimplemented, not
that they become impossible.

## Revisit when

Any of:

- A measurement shows the partitioned-adversary number is uninteresting —
  i.e. Linux with `PREEMPT_RT`, cache partitioning, and a tuned TSN stack
  lands within noise of what this kernel achieves. Then the architecture is
  not buying what the thesis claims and the vertical should change.
- The A-blockers above turn out to require rewriting the scheduler twice (the
  M1.3 fixed-priority shape and the MCS shape are compatible but are not the
  same design — guide 00 §4.1 versus guide 14). If the second rewrite is
  larger than the vertical, reconsider sequencing rather than the vertical.
