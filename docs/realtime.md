# Real-time: bounding the kernel

Guide 14 §6.2 asks for one table: every kernel operation, its analytical
bound, and its **measured** worst case beside it — "and when the two
diverge, you have learned something." This is that table. M4.5.0.

It is regenerated from a boot log, not retyped: `make test` prints
`LATENCY` lines and the numbers below are those lines.

---

## 1. How the measurement works, and what it cannot see

Two kinds of region are recorded, because they delay different things:

- **IF=0** — this processor is not taking interrupts. `FMASK` clears IF
  on `syscall`, so *the whole of every syscall* is one such region, as
  is every interrupt handler. This delays the local CPU's response to a
  device.
- **Lock-held** — another processor cannot enter the path that lock
  covers. This delays a *remote* wakeup, which is what makes it a
  real-time concern and not only a throughput one.

**A region measures running time, not wall time.** A syscall that blocks
is descheduled inside its region; the time its thread waits is not time
this CPU refuses interrupts. `switch_to` banks the open region into the
outgoing thread and reloads the incoming one's. Before that was true,
`sys/replyrecv` reported a 128-million-cycle "non-preemptible region",
which was a server sitting in a receive.

**The bound is checked against the *share of entries that went over*, not
against the max and not against a percentile.** This is not a softening;
it is the strongest claim available *inside a VM*.

Chasing a 3 045 159-cycle hold on the runqueue lock — which guards a
bitmap and a list splice, with interrupts already disabled — found no
code path that could take that long, because there is none. It is the
host preempting the vCPU inside the critical section, and from inside
the guest that is indistinguishable from the region running that long.

A percentile does not survive that either: with the ~700 samples a
region like `sys/yield` sees in one suite run, p99.9 *is* the maximum,
so a single host preemption decides it and the test flaps — which it
did, twice, before this was understood. The assertion is therefore
"at most 5 entries in 1000 exceeded the budget", counted from the log2
histogram and only for samples whose whole bucket is at or above the
bound, so a counted sample cannot have been under it. On bare metal that
share should be zero, and if it is not, the budget is wrong.

So both are reported. On bare metal they converge; here, their distance
is a measure of how much the host interfered. **No number in the `max`
column should be quoted as a property of this kernel.** Getting a
trustworthy max needs bare metal, or a host with `isolcpus` and pinned
vCPUs — which this machine does not have (`docs/performance.md`).

Cost of the instrument: two `rdtsc` per region, ~74 cycles. It is behind
`LATENCY=1` (default on for `make test`, off for `make bench`, because
74 cycles on a 189-cycle syscall would be measuring the instrument).

---

## 2. The table

`make test SMP=4 ACCEL=kvm`, 2.6 GHz, whole suite as the workload:
165 tests, the root task, nine components and a 32-round chaos loop.
26 000 cycles is 10 µs.

Budgets are in CPU cycles, so the check runs under KVM only: a `rdtsc`
under TCG counts interpreter steps and every region reads 10–30× its
real size (`sys/yield` alone goes over on 458 entries in 1000 there).
The table still prints under TCG, because its *shape* is informative
even when its numbers are not comparable.

| Region | Analytical bound | Technique | p99.9 (cy) | max (cy) | Budget |
|---|---|---|---|---|---|
| `sys/yield` | O(1) | bitmap pick | 4 096 | 4 015 | 26 000 |
| `sys/call` | O(1) | no loops but message words | 4 096 | 3 992 | 26 000 |
| `sys/recv` | O(1) | | 4 096 | 3 718 | 26 000 |
| `sys/replyrecv` | O(1) | | 4 096 | 3 789 | 26 000 |
| `sys/poll` | O(1) | | 2 048 | 1 929 | 26 000 |
| `sys/invoke` | O(N) | `E_RESTART` every `CONFIG_RETYPE_PAGES` (4) pages / `CONFIG_REVOKE_STEPS` (16) leaves | 131 072 | 4 583 695 | 131 072 |
| `sys/debug` | O(chars) | a 115200-baud UART | 2 097 152 | 3 047 510 | **none** |
| `irq/timer` | O(1) | mark a reschedule | — | — | 26 000 |
| `irq/shootdown` | O(1) | flush + acknowledge | 8 192 | 11 841 | 26 000 |
| `irq/other` | O(1) + lock wait | dominated by `bkl_lock` spin | 8 192 | 4 528 655 | **none** |
| `exception` | O(dump) | the panic printer | 4 096 | 3 307 | **none** |
| `lock/cnode` | O(depth ≤ 4) | guarded walk | 1 024 | 1 534 | 26 000 |
| `lock/ep` | O(1) | queue splice | 512 | 4 525 629 | **none** |
| `lock/rq` | O(1) | bitmap + list | 2 048 | 6 562 070 | **none** |
| `lock/bkl` | **unbounded** | held for as long as a thread runs | 131 072 | 188 134 007 | **none** |
| `lock/tlb` | O(cores) + remote ack | guide 12 §6 names the ack as the risk | 1 048 576 | 1 087 092 | **none** |
| `lock/log` | O(chars) | held across a UART line | 8 388 608 | 6 190 621 | **none** |

**The p99.9 column repeats run to run; the max column does not.** Across
four consecutive runs the p99.9 figures above were identical, while
`lock/ep`'s max moved between 140 704 and 4 525 629 and `sys/invoke`'s
between 4.5 M and 11 M. That is the host preemption argument in one
observation, and it is why the assertion uses neither column.

`irq/timer` has no row because the suite's timer never fired during a
measured window on this run — which is itself worth knowing, and is why
the report omits regions with zero samples rather than printing zeros.

### Where the two diverge

- **`sys/invoke` p99.9 is 131 072 cycles — still ~90 µs at 1.5 GHz.**
  ADR-0013 made Retype's zeroing and revoke restartable: one invoke
  zeroes at most `CONFIG_RETYPE_PAGES` (4) pages and detaches at most
  `CONFIG_REVOKE_STEPS` (16) CDT leaves, then returns `E_RESTART`.
  libnyx loops. The row now has a budget. The remaining p99.9 is
  VSPACE_MAP (still allocates intermediate tables — M4.5.4) plus the
  host preempting a vCPU; the max is not a property of the kernel.
- **`lock/bkl` p99.9 is 131 072 cycles — 50 µs.** That is how long
  another processor can be kept out of the kernel at p99.9. It is
  dominated by kernel *test* threads, which hold the lock for as long as
  they run (including while they print), so it overstates a release
  build — where the BKL is held only inside a syscall, and the `sys/*`
  rows bound that. It is recorded because it is the number that would
  matter the moment a kernel thread did real work.
- **`lock/tlb` p99.9 is 1 048 576 cycles — 400 µs**, on only 135
  samples. The shootdown lock
  is held across a *remote acknowledgement*, and guide 12 §6 flags that
  wait as the risk. Capping it is a change in its own right.
- **`irq/other`'s tail is `bkl_lock` spinning inside the handler.** That
  is genuine non-preemptible time, and it is a measurement of BKL
  contention rather than of any handler's work. It becomes boundable
  when the remaining entry paths come off the lock.

---

## 3. What this found

**A latent self-deadlock in the runqueue lock.** The instrument reported
holds of over a millisecond on a lock that guards a bitmap. The cause
was not slowness: `rq_lock` was taken with interrupts *enabled*, and an
interrupt handler takes the same lock by way of `isr_dispatch →
sched_preempt_check → schedule → rq_pick`. A CPU could hold it, take a
timer interrupt, and spin for a lock it already held. The window is a
few instructions wide and it had never fired.

That is guide 12 §4.2's rule — any lock an interrupt handler can also
take must be taken with interrupts disabled — and the fix is
`spin_lock_irqsave`. Its side effect is the second finding: **`sys/yield`
dropped from 30 821 cycles to 2 685**, because a yield's non-preemptible
time had included whatever interrupt happened to land while it held the
runqueue.

Neither was visible by reading the code. Both fell out of asking a
number to justify itself.

---

## 4. What is not measured

- **The IPC fast path.** It is assembly in `syscall_entry.asm` and
  carries no instrumentation. It is shorter than the C path it
  shortcuts, so the `sys/call` row bounds it from above — but that is an
  argument, not a measurement.
- **Interrupt entry latency**, from the device asserting to the first
  instruction of the handler. That needs a device that can timestamp its
  own assertion; guide 14 §6.1 puts it at ~0.1 µs and this system has
  not confirmed it.
- **`cap_revoke` separately from `sys/invoke`.** Both live in the same
  region today. They separate when ADR-0013 gives each a preemption
  point.
- **Anything on bare metal.** Every number here is from a guest whose
  vCPUs the host may preempt.

---

## 5. The deadline this supports today

Adding the terms an interrupt→driver→response chain actually pays, at
p99.9, on a CPU that is not retyping:

| Term | p99.9 |
|---|---|
| interrupt handler (`irq/other`) | 8 192 cy ≈ 3.2 µs |
| notification signal + wakeup | (measured separately: 78 cy) |
| context switch | 248 cy ≈ 0.1 µs |
| driver's `sys/replyrecv` | 4 096 cy ≈ 1.6 µs |
| **worst BKL wait if another CPU is inside the kernel** | 131 072 cy ≈ **50 µs** |

**Estimate:** without the BKL term — one CPU, or every entry path off
the lock — the chain is a few microseconds and a 1 ms loop has enormous
margin. With it, the tail is 50 µs, and a 1 ms loop with a 100 µs jitter
budget survives while a 100 µs loop does not.

Every one of these is a p99.9 measured in a guest. None of them is a
worst case, and this document should not be read as providing one until
it is regenerated on hardware the host cannot preempt.

Retype and revoke are now restartable. The remaining unbounded
syscall-path cost is `VSPACE_MAP` allocating page tables, which is
M4.5.4.
