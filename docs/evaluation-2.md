# Evaluation 2 — hot paths, determinism, and the kernel we have

Written 2026-08-15, after M4.3 and after `docs/retrospective.md`.
That file asked what a V2 would change. This one asks a narrower
question: **given this kernel, what actually costs cycles, what the
hardware will let us have, and what we can change without adding
features.**

Numbers without a date are from `docs/performance.md` or from the
run that produced this file. TSC on this box is ~1.50 GHz under KVM
(printed at boot). Wall time is `cycles / 1.50e9`. The host is
2.6 GHz; a guest TSC tick is not a host nanosecond. Both are given
where it matters.

---

## 1. What “fast” can mean here

The request is: sub-microsecond context switch, nanosecond syscall,
nanosecond IPC if possible, more deterministic.

Those words have a floor that no C change will move.

| Operation | Hardware must spend | At 1.50 GHz guest TSC | seL4-class published |
|---|---|---|---|
| `syscall` + `sysret` | ~70–150 cy | 50–100 ns | — |
| callee-saved save/restore | ~20 cy | 13 ns | — |
| CR3 fill (no PCID) | ~150–400 cy | 100–270 ns | — |
| IPI + ACK | ~1–5 µs | — | — |
| Same-core IPC fast path (guide 08) | 300–600 cy | 200–400 ns | ~90–300 ns one-way |
| Context switch, same AS (guide 07) | 100–300 cy | 70–200 ns | — |

**A one-nanosecond syscall is 1.5 guest cycles.** The `syscall`
instruction alone is tens of cycles. The honest target is *tens of
nanoseconds* (guide 10’s 80–200 cy band), not one nanosecond. Anyone
advertising “nanosecond syscalls” on x86-64 is talking about that
band, or about a VMFUNC / syscall-less ring.

**A sub-microsecond context switch is 1500 guest cycles.** The
M4.2 number, 116 cy, is 77 ns. Even the post-M4.3 number, 342 cy,
is 228 ns. That target is already met. The work is not to invent
it; it is to stop giving it away.

**Same-core IPC at 1635 cy is 1.09 µs** — just over a microsecond.
The guide’s slow-path expectation (two switches + bookkeeping) is
roughly 2 × 116 + 200 ≈ 430 cy if the switches were still 116.
The rest is tax we put on the path after M2.0. Cross-core at
24 617 cy is 16 µs: an IPI plus the BKL, not a translation bug.

So the room is real, and it is not mystical:

- Context switch: keep it in the 100–200 cy band (already designed).
- Syscall: 80–150 cy is the band; 198–276 is at or over the edge.
- Same-core IPC: 400–700 cy is a plausible C slow path; 300–600 is
  the asm fast path; 1635 is a path that grew.
- Cross-core IPC: cannot be nanoseconds. An IPI is microseconds.
  Partition so the RT pair never pays it.
- Determinism: p99/p50, not the mean. Today cross-core IPC is 2.3×
  at p99. The BKL makes the worst case “whoever else is in the
  kernel,” which has no bound.

---

## 2. Cycle budgets, from the code, not from hope

### 2.1 Context switch (`yield` → `switch_to` → `context_switch`)

What the assembly does (`arch/x86_64/context_switch.asm`): six
pushes, a store, a load, six pops, a `ret`. That is the 20-cycle
hardware story.

What C adds, every time, in `kernel/sched/sched.c`:

1. `rq_add`: ticket lock, list insert, bitmap or, ticket unlock,
   `rq_kick` (no-op if local).
2. `rq_pick`: ticket lock, bitmap scan, list delete, ticket unlock.
3. A home-CPU assertion.
4. `rdtsc` + `trace_sched_switch_at` (trace is off in the common
   case; the enabled check is a load).
5. Optional `vspace_switch` (skipped when the AS is unchanged).
6. TSS kernel stack + `percpu_set_current`.
7. Cycle accounting.
8. **`bkl_release_all` + `context_switch` + `bkl_reacquire`.**

Item 8 did not exist at M4.2 (116 cy). Item 1–2’s locks did not
exist either. The 116 → 342 jump on `SMP=4` is those two things,
measured together, never separated until now.

On a uniprocessor, item 8 is a lock nobody else is waiting for.
On a multiprocessor it is load-bearing: without it a switch on
CPU 0 holds the whole kernel while CPU 1 sits in `hlt`.

The runqueue lock is **not** load-bearing while every RQ mutator
still holds the BKL. Idle does not touch a runqueue until it has
the BKL again. The sched-wake IPI only stores `need_resched`.
Two locks on the same path is why a yield got 200 extra cycles:
each uncontended ticket lock is cheap, but in a `CONFIG_KTEST`
build each also walks lockdep (GS load, rank check, array store)
on acquire and release. Four lockdep operations per yield, plus
the BKL’s own pair around the switch.

`docs/performance.md` publishes ktest numbers. A release kernel
does not pay lockdep. The published 342 is therefore a ktest
number, and comparing it to seL4’s release numbers is a category
error — but it is the number we have, and the tax is real even
without lockdep.

### 2.2 Null syscall (`SYS_DEBUG_NOOP`)

The stub (`syscall_entry.asm`) is already the right shape: one
`swapgs` in, one out, stack switch, callee-saved push, SysV
shuffle, `call`, load-don’t-scrub from the per-CPU return block,
canonical-RIP check, `sysret`.

The C side then:

1. Takes the BKL.
2. Clears the six-word return block (so a non-replying syscall
   cannot leak kernel registers — this stays).
3. Splits RAX, switches on the number, returns `E_OK`.
4. Drops the BKL.

Item 1 and 4 touch a contended cache line on every syscall from
every CPU. The null syscall shares no kernel object with anyone.
The BKL is not protecting anything it does.

198 cy (M4.2) to 276 cy (M4.3 SMP run) is the BKL plus whatever
else now sits on `this_cpu()`. Guide 10’s band is 80–200. The
stub alone should land in the low 100s; the lock is the rest.

### 2.3 Same-core IPC

One `SYS_CALL` plus the server’s `SYS_REPLYRECV`, two direct
switches, one cap lookup each way, the endpoint state machine,
`msg_transfer`, the BKL held across the whole of each syscall
(released only in `switch_to`).

M2.0: 1127 cy. M4.2: 1250. M4.3: 1635. The body of `cap_transfer`
is not on this path (`ncaps == 0` returns first). What landed on
it: capability lookup, badge, bound-notification check, RQ locks,
BKL bounce, home-CPU test.

`ep_from_cap` calls `cap_lookup`, which **copies the entire
`struct cap`** (type, rights, obj, badge, and four CDT pointers)
onto the stack, then reads four fields. `cap_lookup_slot` already
exists and returns a pointer. The copy is a leftover of “lookup
produces a value,” and it is on every IPC.

Cross-core is a different function: the receiver is on another
runqueue, so there is no direct switch, there is an IPI, and
both sides still take the BKL. 15× same-core is that, not a
missed optimisation in `msg_transfer`.

### 2.4 What we cannot have without a feature

| Want | Blocked by | Why it is a feature, not a trim |
|---|---|---|
| 300–600 cy IPC | Asm fast path (guide 08 §4) | New code path, new invariants, parked in `NEXT`. |
| Packed 16-byte caps | Representation change | Touches every cap field; ADR-sized. |
| Cross-core IPC in the hundreds of cycles | Would require no IPI | Physics. Place the pair on one core. |
| Bounded kernel latency | BKL off *every* path that an RT core can wait on | CSpace lock, endpoint lock, preemptible revoke. |
| One-nanosecond anything that uses `syscall` | The instruction | — |

Taking the BKL off same-core IPC is the one that looks like a
trim and is not. `cap_revoke` on CPU 1 (under the BKL) walks a
CSpace that `ipc_call` on CPU 0 would walk without it. The BKL
is the CSpace lock. The reserved ranks (20 endpoint, 40 CSpace)
exist so that path can come off; turning them on is the next
*lock*, not a deleted line.

---

## 3. Determinism

A real-time kernel is judged on the tail.

| Path | p50 | p99 | p99/p50 | What the tail is |
|---|---|---|---|---|
| Context switch (M4.2) | 116 | 170 | 1.5 | Host preemption, last-iteration `thread_exit` |
| Same-core IPC (M4.3) | 1635 | 1882 | 1.15 | Quiet. This path is already tight. |
| Cross-core IPC (M4.3) | 24617 | 56819 | 2.31 | BKL wait + IPI + host |
| Two pairs, wall | 41164 /call | — | — | Throughput 1.20×, not 2× |

Same-core IPC is the best-behaved number in the tree. Cross-core
is not a variance bug; it is the BKL’s definition: the wait is
whoever else is inside the kernel, including an unbounded
`cap_revoke` or a 256 KiB Untyped zero.

`IF=0` for the whole syscall (FMASK) means a device interrupt
aimed at this CPU waits for the entire kernel path, including
any blocking IPC until `switch_to` — and `switch_to` does not
`sti`. Interrupts return only on `sysret` (R11) or idle’s
`sti;hlt`. That is the non-preemptible region, and it is “all
of kernel entry,” which is why the retrospective called it
unbounded.

Ktest lockdep, the tracer’s `rdtsc` when enabled, and publishing
unpinned KVM `max` columns all make the *reported* tail worse
than a release RT image would see. They do not create the BKL
inversion. They decorate it.

For track A the only shape that produces a *provable* bound is
the one guide 12 §1 (c) already named: the RT core shares no
lock with a non-RT core. Everything short of that is a better
mean.

---

## 4. Design, not features

These change how existing mechanism is used. They do not add a
syscall, an object type, or a userspace-visible protocol.

1. **Do not take the runqueue lock while the BKL is held.**
   The BKL already serialises every RQ mutator. The second lock
   is why yield and IPC grew after M4.3. The RQ lock stays; a
   later BKL-free path will take it, because it will not hold
   the BKL. A flag, `rq_covered_by_bkl`, is the tripwire: the
   first path that mutates a runqueue without the BKL must
   flip it.
2. **Do not bounce the BKL around a switch on a uniprocessor.**
   Nobody is waiting. `smp_is_multiprocessor()` is constant
   after bring-up.
3. **Do not take the BKL for `SYS_DEBUG_NOOP`.**
   It touches only the per-CPU return block. This is the first
   *syscall* path off the lock, and it is the one the syscall
   benchmark is. Leaving the lock on it measures the lock.
4. **Look up a slot, do not copy a capability, on the IPC
   path.** `cap_lookup_slot` exists. `ep_from_cap` copies 56+
   bytes to read four fields.
5. **Keep publishing p50/p99 from a ktest build, but say so,
   and stop treating the BKL bounce on `SMP=4` as the context-
   switch number.** The switch itself is the assembly plus the
   RQ. The BKL bounce is a different operation that happens
   to sit in the same function.

What this evaluation will *not* do, matching `NEXT` and the
user’s “no new features unless required”:

- The asm IPC fast path.
- Packed capabilities.
- Reply objects.
- SchedContext / timeslices.
- Preemptible revoke.
- A per-thread IPC buffer.
- `TCB_SUSPEND`.
- Endpoint/CSpace locks (needed for BKL-free IPC; that *is*
  the next lock, and it is a design change with a race if
  done casually).

---

## 5. What I would do next, if the goal is this kernel’s
   numbers rather than a V2

Already ranked in the retrospective: IPC off the BKL, a bound
on every `IF=0` / lock-held region, Untyped migration.

This file splits the first item so it can be done without
lying about races:

1. The four trims in §4 — they recover the M4.2 band, or show
   that we cannot.
2. **Measure IF=0 length** of `SYS_CALL` and of `SYS_DEBUG_NOOP`
   (TSC in the stub, TSC at `sysret`). Until that number exists,
   “non-preemptible region” is a slogan.
3. **Endpoint + CSpace locks, then same-core IPC without the
   BKL.** That is the first path that *needs* a new lock. It is
   also the only path that moves same-core IPC from ~1 µs toward
   the 400–700 cy C band. Cross-core stays an IPI; do not chase
   it. Pin the RT pair.
4. Then, and only then, the asm fast path, compared against
   a C path that is no longer carrying two locks and a 56-byte
   copy.

If after (3) same-core IPC p99 is still dominated by something
inside `switch_to` (trace, accounting, TSS write), delete from
that function, do not add a second one.

---

## 6. Relation to the other documents

- `retrospective.md` is the P4 verdict and the V2 list. It stands.
- This file is the hot-path budget and the “trim vs feature”
  line. Where they disagree on a number, `performance.md` wins.
- `architecture.md` is the system as it is. §3 and §6 were
  updated for per-CPU runqueues; they are not a performance
  claim.
- Invariant 7 in `invariants.md` still says there are no locks.
  That line is false since M4.3 and is corrected with this
  work.

---

## 7. What this pass implemented, and what moved

§4 items 1–4, then a re-measure. `make test ACCEL=kvm` and
`make test SMP=4 ACCEL=kvm`, both 164 run, 0 failed.

| Path | Before (M4.3) | After | Notes |
|---|---|---|---|
| Context switch, UP | 340 cy (ktest+RQ lock) | **118 cy** | Back in the 100–300 band. |
| Context switch, SMP=4 | 342 cy | **248 cy** | RQ lock gone; BKL bounce remains. 165 ns at 1.50 GHz. |
| Null syscall, SMP=4 | 276 cy | **189 cy** | BKL off `SYS_DEBUG_NOOP`. Inside 80–200. 126 ns. |
| Same-core IPC, UP | 1632 cy | **1254 cy** | Slot lookup + no RQ lock. 836 ns. |
| Same-core IPC, SMP=4 | 1635 cy | **1507 cy** | 1.00 µs. Remaining extra is the BKL bounce. |
| Cross-core IPC | 24617 / 56819 | **23160 / 51861** | Still ~15×. Still the BKL + IPI. |

The trim recovered the M4.2 band on a uniprocessor and took the
syscall back inside the guide. Same-core IPC on four CPUs is
still a microsecond because `switch_to` still drops and retakes
the BKL so the other three CPUs can run. That bounce is not a
bug; taking it off same-core IPC needs the CSpace lock
(§2.4, §5 item 3).

Invariant 7 (`docs/invariants.md`) said there were no locks.
Corrected: every lock has a rank.
