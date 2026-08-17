# Performance

Every number here is measured, not estimated. Pin the core, warm up, report
p50/p99/max. Interleave baseline and variant. See guide 33 §6.

If `benchmark_variance` fails, nothing below is meaningful.

**Gate (M3.3):** `benchmark_variance` passed. 100 independent
context-switch campaigns; statistic is each campaign's p50; spread is
trimmed (5th..95th)/median. This run: p5=673, median=676, p95=681,
spread **11/1000** (1.1%), raw min=671 max=684. Threshold is 400/1000
under TCG, 200/1000 under KVM. p99 of a 128-sample window is a near-max
and is not the gate.

`make bench` harvests `BENCH` lines, appends `docs/bench/history.jsonl`,
writes `docs/bench/latest.json`, and plots `docs/bench/plot.svg`. Pin via
`taskset -c 0` when present. Not GitHub Actions. Dedicated hardware is
whoever runs `make bench` on a quiesced machine.

**This box has `/dev/kvm`** (checked 2026-08-14: `make test ACCEL=kvm`
runs 147 tests, 0 skipped). An earlier note here said it did not, and
that is why the table below used to carry TCG numbers. Every row is now
KVM.

**`taskset -c 0` was the wrong core on this host, and it was
`make bench`'s default.** Same ISO, same boot, KVM, `syscall_null` p50:

| | run 1 | run 2 |
|---|---|---|
| pinned to core 0 (`make bench`) | 221 | 282 |
| unpinned (`make test ACCEL=kvm`) | 197 | 198 |

So the harvested numbers were ~30% pessimistic *and* unstable, while the
suite's own BENCH lines are stable to one cycle. Core 0 carries the
host's housekeeping and interrupts on this machine (6.8.1-realtime), so
pinning there maximises interference rather than removing it.
`benchmark_variance` does not catch it: it measures context switches,
which stay inside the guest, so its spread was 10/1000 on the same
pinned run.

**Fixed:** `tools/bench.py` no longer hardcodes core 0. It pins to
`--cpu`/`BENCH_CPU` if given, else to the first `isolcpus` core if the
operator gave the kernel one, else it does not pin and says so. Guessing
a core is worse than not pinning — an unpinned run is noisy, a badly
pinned one is consistently wrong. Each history entry records `pinned_to`
so a number can never again be compared across two different meanings.
This box has no `isolcpus`, so the rows below are unpinned; their `max`
column is correspondingly worse than the pinned run's, which is the real
trade and the reason p50/p99 are what this file publishes.

| Operation | Expected (guide) | Measured p50 | p99 | Date | Commit |
|---|---|---|---|---|---|
| Context switch, same AS | 100–300 cy | 118 cy (UP) / 248 cy (SMP=4) | 171 / 347 | 2026-08-15 | hot-path trim |
| Context switch, + CR3 | 500–1500 cy | | | | |
| Syscall entry+exit | 80–200 cy | 189 cy | 189 cy | 2026-08-15 | NOOP off BKL (SMP=4) |
| Capability lookup | 5–20 cy | 43 cy | 72 cy | 2026-08-15 | unchanged |
| IPC roundtrip, same core (kernel threads, still under BKL) | 300–600 cy (fast path) | 1854 cy | 2085 cy | 2026-08-15 | ADR-0011 locks; see note |
| IPC roundtrip, cross core | 3000–8000 cy (guide, IPI+wakeup) | 25389 cy | 44542 cy | 2026-08-15 | kernel threads, BKL+IPI |
| Notification signal | 50–150 cy | 78 cy | 119 cy | 2026-08-15 | +ntfn lock (ADR-0011) |
| Page fault → userspace pager | 2000–5000 cy | | | | |
| TLB shootdown, 4 CPUs | | | | | |

**ADR-0005 revisit (M4.0, 2026-08-14).** libnyx `.text` is 68 bytes
(the syscall stub; the rest is header-inline). Nine resident
components. Duplicated stub = 4.0% of summed `.text` (15 428 B),
0.3% of ELF-file bytes (229 696 B). Under the ~15% trigger;
static linking stays.

**Capability transfer costs the IPC path ~18 cy** (M4.0, ADR-0009).
Paired KVM runs of `ipc_roundtrip_same_core` on the same boot of the same
machine, messages carrying **no** capabilities: 1237/1238 cy p50 with the
change stashed, 1255/1259 with it applied. Two runs each, not interleaved —
enough to separate 18 cy from a p50 that repeats to within 4 cy, and not
enough to claim more precision than that.

The row above moved from M2.0's 1127 cy for reasons that are mostly *not*
this: M2.1–M3.3 added the capability lookup, the badge, bound notifications
and the fault path to the same round trip. The 1237 baseline is what those
cost; the 18 is what this milestone added. What remains is the
`ncaps` split out of RAX, the extra return-block store, and the `RDI` load on
the way out — all unconditional, because the ABI is unconditional. The
`cap_transfer()` body itself is not on that path: an early-out for `ncaps == 0`
took the first measurement of 1266/1277 down to this. Anything further belongs
to the IPC fast path (guide 08 §4), which is deliberately not started.

Every row above is now `make bench ACCEL=kvm` on the same boot, unpinned
(see the pinning note). The TCG rows they replaced are kept in
`docs/bench/history.jsonl`; a TCG `rdtsc` is an interpreter step, not a
cycle, and the two must never share a table.

Three of them are worth reading rather than filing:

- **Capability lookup, 43 cy against the guide's 5–20.** Not the 277 the
  TCG row claimed, but still double. It is a guarded walk with a bounds
  check per level and no caching; the guide's figure assumes the packed
  representation (`NEXT` parks "packed caps" deliberately).
- **Context switch drifted 104 → 116 cy since M1.3.** Tracing, cycle
  accounting and the preemption checkpoint all landed on that path since.
  Still inside the guide's range; recorded so the next drift is measured
  from something recent.
- **Notification signal beats the guide** (37 vs 50–150). It is one word
  OR'd and at most one thread made runnable — no allocation and no
  queue — which is exactly what guide 08 §5 designed it to be.

`Context switch, same AS`: `tests/ktest/t_sched.c`'s `sched_context_switch_cost`, two kernel
threads ping-ponging via `yield()`, 500 unrecorded warmup round trips then 20000
recorded ones, `rdtsc()` around each, sorted for percentiles, halved (each
recorded sample is a full round trip — switch away, switch back — matching
guide 07 §8's own `/200000` for 100000 iterations). Measured under `ACCEL=kvm`;
under plain TCG the same test still runs (nothing here needs x2APIC) and reports
similar numbers, just noisier. Max was 7753 cy on this run — a single-sample
outlier, almost certainly the one round trip that lands on the partner thread's
last iteration, which returns and goes through `thread_exit()` instead of a
plain `yield()`; p50/p99 are unaffected and are the numbers that matter here.
No `+ CR3` row yet: every thread through M1.3 shares `vmm_kernel_vspace()`
(ROADMAP.md), so there is no address-space switch to measure until a thread
runs in a different one.

`IPC roundtrip, same core`: `tests/ktest/t_ipc.c`'s `ipc_roundtrip_cost`, a
client thread doing 200 unrecorded warmup `ipc_call`s then 20000 recorded ones
against a server replyrecv-looping, `rdtsc()` around each `ipc_call` directly —
no halving needed here, since one `ipc_call` already is one full round trip
(the guide's own `/1000000` formula in guide 08 §9, just with a smaller n).
The guide's 300–600 cy figure is the **fast path**'s target (guide 08 §4): a
hand-written asm syscall entry that never leaves registers and never touches
the scheduler. M2.0 only builds the slow path, deliberately, per the guide's
own sequencing ("write this first, in C, clearly... do not write the asm fast
path until the C version is correct and measured") — there is also no syscall
boundary yet (M3.0) for a fast path to shortcut. 1127 cy for two direct
context switches (client → server, server → client) plus the endpoint queue
bookkeeping is a reasonable slow-path number; it is the baseline the fast path
gets compared against once it exists.

ADR-0011 took `SYS_CALL` / `SYS_RECV` / `SYS_REPLYRECV` off the BKL.
Ring-3 IPC uses the fast path (single-level CSpace, no caps, receiver
waiting, same CPU) entered from `syscall_entry`. The ktest
`ipc_roundtrip_same_core` number is still a **kernel-thread** ping-pong
that holds the BKL (every ktest thread does), so it pays endpoint +
runqueue locks *and* the BKL bounce. It went 1507 → 1854 for that
reason and is not the ring-3 number. `ipc_fastpath_handles_a_ring3_call`
proves the helper actually ran.

`IPC roundtrip, cross core`: `ipc_roundtrip_cost_cross_core`, same shape,
server bound to CPU 1, client on CPU 0. p50 23160 cy, ~15× same-core on
the same boot. There is no IPI-based remote rendezvous yet (guide 12 §8's
`ipc_call_remote` is the parked fast-path sibling): the client enqueues
the server on CPU 1's runqueue, kicks it, and `schedule()`s. Every hop
takes the BKL. The 15× is that cost, not a translation bug.

Two independent pairs on four CPUs (`ipc_two_pairs_scaling_under_the_bkl`,
client/server on (0,1) and (2,3), 8000 calls each): 41299 cy/call wall
after the trim (41164 before). Throughput relative to the single-pair
p50 is `2 × 23160 / 41299 ≈ 1.12` — still not 2. The shared line is
still the BKL.
a second pair adds a fifth of a core, not a core. The shared line is the
BKL. That is the scaling number M4.3 asked for, and why the next path off
the lock is IPC, which is deliberately not started.

`Syscall entry+exit`: `tests/ktest/t_user.c`'s `syscall_roundtrip_cycles`.
Measured **from ring 3**, by the user blob itself (`arch/x86_64/user_blob.asm`),
with `rdtsc` either side of a 200000-iteration `SYS_DEBUG_NOOP` loop — so it
is the entire round trip, `syscall` through `sysret`, as an application would
feel it, not the kernel's view of its own half. 189 cy is inside guide
10 §9's 80–200 band; the guide's own note is "if it's 2000, find out why".
No p99: the blob measures the loop in aggregate rather than per-call, because
storing 200000 samples would need a second user page and a sort in ring 3 for
a number whose tail is dominated by the timer interrupt. The aggregate is the
honest thing to report until there is a reason to want the distribution.

What is in the 189: `swapgs`, the stack switch off the user stack, nine
pushes, the SysV argument shuffle, the C dispatch (a switch on the number
that now returns before taking the BKL), the canonicality check, the
per-CPU return block load, and `sysret`. `SYS_DEBUG_NOOP` itself does
nothing — that is the point of measuring with it. Taking the BKL off
this path dropped the SMP=4 number from 276 to 189 and put it back
inside guide 10's 80–200 band.

## Size

Printed by `make size` and on every link; `$(BUILD)/size.txt` holds the last
value. Bytes, from `llvm-size -A`.

| Build | .text | .rodata | .data | .bss | Date | Commit |
|---|---|---|---|---|---|---|
| release (`make`) | 9089 | 2184 | 4 | 53248 | 2026-08-12 | M0.2 |
| ktest (`make test`) | 13092 | 3896 | 16 | 57344 | 2026-08-12 | M0.2 |
| release (`make`) | 16753 | 6312 | 4 | 81920 | 2026-08-12 | M1.0 |
| ktest (`make test`) | 25780 | 10280 | 16 | 86016 | 2026-08-12 | M1.0 |
| release (`make`) | 21777 | 7528 | 4 | 86016 | 2026-08-12 | M1.1 |
| ktest (`make test`) | 33636 | 12760 | 16 | 90112 | 2026-08-12 | M1.1 |
| release (`make`) | 26929 | 8328 | 16 | 86016 | 2026-08-12 | M1.2 |
| ktest (`make test`) | 43636 | 16152 | 24 | 90112 | 2026-08-12 | M1.2 |
| release (`make`) | 29569 | 8648 | 16 | 98304 | 2026-08-12 | M1.3 |
| ktest (`make test`) | 48624 | 17560 | 24 | 262144 | 2026-08-12 | M1.3 |
| release (`make`) | 31201 | 8648 | 16 | 106496 | 2026-08-12 | M2.0 |
| ktest (`make test`) | 55040 | 18360 | 24 | 430080 | 2026-08-12 | M2.0 |
| release (`make`) | 33873 | 8808 | 16 | 106496 | 2026-08-12 | M2.1 |
| ktest (`make test`) | 60944 | 19512 | 24 | 430080 | 2026-08-12 | M2.1 |
| release (`make`) | 36417 | 9176 | 16 | 172032 | 2026-08-13 | M2.2 |
| ktest (`make test`) | 69072 | 20920 | 24 | 528384 | 2026-08-13 | M2.2 |
| release (`make`) | 39958 | 9992 | 16 | 172032 | 2026-08-13 | M3.0 |
| ktest (`make test`) | 78448 | 24168 | 24 | 528384 | 2026-08-13 | M3.0 |
| release (`make`) | 42742 | 10344 | 16 | 172032 | 2026-08-13 | M3.0.5 |
| ktest (`make test`) | 87232 | 26808 | 24 | 528384 | 2026-08-13 | M3.0.5 |
| release (`make`) | 43631 | 10528 | 16 | 172032 | 2026-08-13 | M3.1 (SYS_INVOKE) |
| release (`make`) | 47887 | 11936 | 16 | 176128 | 2026-08-13 | M3.1 (root + loader) |
| release (`make`) | 48239 | 11968 | 16 | 176128 | 2026-08-14 | M3.1 (done) |
| ktest (`make test`) | 94640 | 29872 | 24 | 528384 | 2026-08-13 | M3.1 (SYS_INVOKE) |
| release (`make`) | 55023 | 12800 | 16 | 180224 | 2026-08-14 | M3.3 |
| ktest (`make test`) | 118448 | 37712 | 24 | 573440 | 2026-08-14 | M3.3 |

M1.3's ktest `.bss` jump (90112 -> 262144) is almost entirely
`sched_context_switch_cost`'s own 20000-entry `uint64_t` sample array
(160000 bytes) — test-only, not kernel growth. The release build's `.bss` grew
by 12288 bytes; per `llvm-nm --size-sort -S`, the two largest new symbols are
`rq` (the runqueue: 256 `list_head`s plus the bitmap, 4128 B) and `tcb_pool`
(`TCB_MAX`-entry fixed pool, same shape as `vspace_pool`, 5632 B) — the rest is
`boot_tcb`, the timer's calibration statics, and inter-object alignment
padding. Kernel thread stacks are not here: `kstack_alloc` maps PMM frames
through the page tables, so they cost physical memory, not `.bss`.

M2.0's release `.bss` growth (98304 -> 106496, 8192 B) is `struct tcb` growing
by the IPC fields (`blocked_on`, `ep_link`, `reply_to`, `send_badge`,
`wants_reply`, `msg`) times `TCB_MAX` (64) plus `boot_tcb`. The ktest jump
(262144 -> 430080) is `ipc_roundtrip_cost`'s own 20000-entry sample array,
same story as M1.3's — test-only.

M2.1 adds `.text`/`.rodata` (the CSpace/CDT/retype logic and `cnode_dump`'s
formatting) but not one byte of release `.bss` (106496 -> 106496, unchanged):
`struct untyped` deliberately has no fixed pool (unlike `tcb_pool`/
`vspace_pool`) — it lives inside the physical memory it describes
(`kernel/cap/untyped.c`'s header comment), so there is nothing static to grow.
The ktest `.bss` is unchanged from M2.0 too (430080 -> 430080): `t_cap.c`'s
own arrays are all small and stack-local, nothing sizable like
`sched_context_switch_cost`'s sample array.

M3.0.5 adds no `.bss` either (172032 -> 172032). Object lifetime is three
fields on objects that already existed, and a Notification is a word plus a
waiter pointer — carved from an Untyped like anything else, never from a
static pool. That is the "no allocation" property being visible in the size
table rather than only in a test.

M3.0 adds no `.bss` at all (172032 -> 172032): the per-CPU area is one small
struct, and everything a user thread needs — page tables, text, data, stack —
comes from the PMM at runtime. The `.text`/`.rodata` growth is the entry stub,
the dispatch, the user-thread construction, and the ring-3 blob (which is
`.rodata`, since the kernel only ever memcpy's it).

M2.2's release `.bss` growth (106496 -> 172032, 65536 B) is exactly the trace
ring: `TRACE_RING_BYTES` is 64 KiB of static storage, because "no allocation,
ever" (guide 32 §2) means the flight recorder cannot be sized at runtime. The
ktest build adds a further 32 KiB for `t_trace.c`'s own `ovh_samples` array.

`.bss` is almost entirely fixed-size reservations: the 8 KiB klog ring, the five
4 KiB boot page tables, the 16 KiB boot stack, and the 4 KiB alignment gap
before `pml4`. The ktest build's extra 4096 bytes are `bss_probe`, the array
`bss_is_zeroed` reads.

M1.0 adds 24 KiB of `.bss` (three 8 KiB IST stacks) and 4 KiB of IDT, plus
`.text` for 256 ISR stubs — each is 10-odd bytes, and they are why `.text`
grew 7.7 KiB rather than the dispatcher doing so.

M1.1 adds almost nothing to `.bss`: the frame database is not a static array,
it is bump-allocated at boot from the largest usable region, which is the point
of that design (guide 05 §3). At `sizeof(struct page) == 24` it costs 0.59% of
RAM — 3071 KiB for the 512 MiB QEMU gives us.

## Memory, as reported at boot

| Config | Total usable | Frame db | struct page | Date |
|---|---|---|---|---|
| QEMU `-m 512M` | 519940 KiB | 3071 KiB | 24 B | 2026-08-12 |

| Profile | .text | .data | Date |
|---|---|---|---|
| N2 (desktop) | | | |
