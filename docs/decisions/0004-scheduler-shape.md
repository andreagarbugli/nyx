# ADR-0004 — Fixed-priority is the mechanism; MCS layers on top

- date: 2026-08-13
- status: accepted (2026-08-13)
- guide: 00 §4.1, 07 §4, 14; ADR-0002

## Context

The guide specifies the scheduler twice, and the two specifications are not
the same design:

- **Guide 00 §4.1 / 07 §4** — fixed-priority preemptive round-robin, 256
  levels, O(1) bitmap selection, with priorities and timeslices set from
  userspace through capabilities on a TCB.
- **Guide 14** — seL4's MCS model: `SchedContext` capabilities carrying
  budget and period, passive servers with no scheduling context of their own,
  time donated by the caller.

They are compatible — a userspace scheduler can hold `SchedContext`
capabilities — but they are not interchangeable, and M1.3 implemented neither
completely: the bitmap runqueue exists, timeslices do not, and priority can
only be set by a thread's creator.

ADR-0002 accepted track A, which is stated in MCS vocabulary (budget, period,
temporal isolation). Without a written boundary between the two designs, the
plausible outcome is that the scheduler is built twice: once to add
timeslices to the M1.3 shape, and again to replace that with `SchedContext`.

## Decision

The **M1.3 fixed-priority bitmap runqueue is the mechanism** and stays.
Timeslice accounting is added to it now, as guide 07 §4 describes. Guide 14's
`SchedContext` and passive servers arrive **as a layer on top** for track A —
a `SchedContext` supplies the budget that replenishes a thread's timeslice
and names who is charged for it; it does not replace priority selection.

Concretely, the boundary:

| Stays in the M1.3 mechanism | Arrives with MCS (track A) |
|---|---|
| 256-level bitmap runqueue, O(1) pick | `SchedContext` as a capability |
| Priority as a TCB field | Budget + period, replenishment |
| A timeslice counted down per tick | Where the timeslice *comes from* |
| Preemption at the interrupt-return checkpoint | Donation to passive servers |
| The direct-switch priority check (guide 07 §7) | Charging the donor, not the donee |

## Alternatives rejected

- **Go straight to MCS.** Rejected on sequencing, not on merit. MCS is a
  substantial design and there is no workload to validate it against yet —
  building it before track A's control loop exists means the model is shaped
  by guesswork. It would also land before the direct-switch priority check,
  which is a *current* correctness bug and a ten-line fix.
- **Leave it open until the A-blockers are scheduled.** Rejected: this is
  precisely the deferral that produces two rewrites, and `docs/evaluation.md`
  §4.4 flagged it by name.
- **Fixed-priority only, no MCS ever.** Rejected because track A's claim is
  temporal isolation under an adversary, and "this partition cannot overrun
  its share" is a statement about budget, which priority alone cannot make.

## Consequences

Makes easy:

- Timeslice accounting can land immediately against the existing runqueue,
  and it is a prerequisite for track A regardless of which model supplies the
  budget.
- The direct-switch priority check is a fix to the mechanism, not a decision
  deferred pending a scheduler rewrite.
- The M1.3 tests stay valid: priority ordering, FIFO within a level, and the
  idle thread are all mechanism properties.

Makes hard:

- `switch_to` will grow a third concern (whose budget is being charged)
  alongside address space and kernel stack. Worth watching; it is already the
  most delicate function in the tree.
- Passive servers mean a thread can run with *no* scheduling context of its
  own, which the current `struct tcb` cannot express. That field is an MCS
  addition, not something to add speculatively now.

Forecloses: a scheduler whose policy is entirely in the kernel. That was
never the intent (guide 00 §4.1 puts policy in userspace), so nothing is
lost.

## Revisit when

Track A's first measurement shows fixed-priority selection itself — not
budget accounting — is the source of a missed deadline. That would mean the
mechanism, not the layer, is wrong, and EDF (guide 07 §4's table) becomes the
question instead.
