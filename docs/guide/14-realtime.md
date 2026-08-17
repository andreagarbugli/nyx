# 14 — Real-time: predictability as a first-class property

> Goal: understand what real-time actually requires, why almost every general
> purpose OS fails at it, and design Nyx so that temporal guarantees are a
> *property of the architecture* rather than a patch applied afterwards. By the
> end you will have scheduling contexts as capabilities, a partitioned EDF +
> fixed-priority scheduler, bounded kernel operations with published WCET
> figures, and a latency measurement harness.

This is the first of four chapters that revisit the design with a specific
agenda. Chapters 14–17 are where Nyx stops being "a nice microkernel" and starts
being *a position on how an OS should be built*.

---

## 1. Theory: what real-time means

**Real-time does not mean fast.** It means *predictable*. A system with 50 µs
average latency and a 40 ms tail is worse, for real-time purposes, than one with
500 µs average and a 600 µs bound. Real-time engineering optimizes the maximum,
not the mean — which is the exact opposite of what throughput engineering does,
and why the two goals fight each other in every general purpose kernel.

### 1.1 The vocabulary

| Term | Meaning |
|---|---|
| **Task / job** | A unit of recurring work. A task releases jobs. |
| **Period `T`** | Minimum inter-arrival time of jobs. *Periodic* = exactly T; *sporadic* = at least T. |
| **WCET `C`** | Worst-case execution time of a job. |
| **Deadline `D`** | Time after release by which the job must complete. Usually `D ≤ T`. |
| **Response time `R`** | Actual completion time after release. Schedulable ⟺ `R ≤ D` always. |
| **Utilization `U`** | `Σ Cᵢ/Tᵢ`. The fraction of the CPU demanded. |
| **Jitter** | Variation in release or completion times. |
| **Latency** | Time from a physical event to the first instruction of the handler. |

### 1.2 Hard, firm, soft

- **Hard**: a missed deadline is a system failure. Flight control, engine
  timing, medical devices, motor control. Requires *analysis*, not measurement:
  you must be able to argue the bound, not merely observe it.
- **Firm**: a late result is worthless but not catastrophic. Frame deadlines in
  a video pipeline; a robot control loop that can skip a cycle.
- **Soft**: late results degrade quality. Audio, UI responsiveness, games,
  trading. Statistical bounds ("99.99th percentile under 1 ms") are the goal.

Most people who say "real-time" mean **firm or soft with a hard tail
requirement**: audio at 128 samples/48 kHz gives you 2.67 ms and *every* miss is
an audible click. This is the target you should design for, because it is where
Linux is genuinely painful and where a microkernel can be genuinely better.

### 1.3 The three questions

Any real-time design must answer:

1. **Latency**: how long from interrupt to handler instruction? (Determined by
   the kernel's longest non-preemptible region.)
2. **Schedulability**: given a task set, will all deadlines be met? (Determined
   by the scheduling algorithm plus the ability to bound `C`.)
3. **Isolation**: can a misbehaving component cause another to miss? (Determined
   by whether resources — CPU, cache, memory bandwidth, locks, servers — are
   *partitioned* or *shared*.)

Most OS discussion focuses on (1) because it is easy to measure. (3) is where
real systems actually fail.

---

## 2. Why general purpose kernels are bad at this

A catalogue, because each item is a design constraint for us:

| Source of unpredictability | Why it hurts | Nyx's answer |
|---|---|---|
| Long non-preemptible kernel paths | Directly adds to latency | Kernel operations are O(1) or preemptible-restartable (Ch. 07 §5); publish the bound |
| Interrupt storms | Unbounded interference from a device | Kernel ISR is O(1) mask + signal (Ch. 04 §8); driver runs at its own priority under its own budget |
| Priority inversion via shared servers | A low-priority client blocks a high-priority one | **Passive servers with donated scheduling contexts** (§4) |
| Lock hold times | Unbounded blocking | Rank-ordered short spinlocks only (Ch. 12 §4); no sleeping locks in the kernel |
| Dynamic memory allocation | Unbounded allocator latency, OOM | **Kernel never allocates** (untyped model, Ch. 09) — this is a real-time property, not just a security one |
| Cache and TLB interference | Another core evicts your working set | Cache colouring + Intel CAT (§7) |
| Memory bandwidth contention | A streaming task starves a control task | Intel MBA / bandwidth budgeting (§7) |
| SMT siblings | Sharing every execution resource | Disable SMT, or co-schedule only within a domain |
| DVFS, turbo, C-states, SMM | The hardware silently changes your timing | Pin frequency; measure with SMM in mind; **SMIs are invisible and can cost hundreds of µs** |
| Page faults | Unbounded I/O in the middle of a job | Pre-fault and pin real-time address spaces |
| DMA contention | A device saturates the memory controller | IOMMU + bandwidth partitioning; treat devices as tasks |

Two of these deserve a note.

**SMM is a genuine problem.** System Management Interrupts run firmware code
that the OS cannot see, preempt, or bound. On some server boards a single SMI
takes 200–1000 µs. If you measure a mysterious latency spike that GDB cannot
explain, suspect SMM. Vendors sometimes provide a "low latency" BIOS profile.
Measure it (`rdmsr` on `MSR_SMI_COUNT`, 0x34, on Intel) and record it in your
results, because otherwise your numbers are not reproducible.

**"The kernel never allocates" is a temporal property.** In Chapter 09 we
adopted untyped memory for security and accounting reasons. Notice what you also
bought: no allocator on any kernel path, therefore no allocator latency, no
fragmentation-induced worst case, no OOM path, and no lock on a global heap. A
lot of the hard parts of real-time Linux are consequences of the kernel
allocating. We simply do not have that problem. **Write this down in
`docs/realtime.md`; it is one of the strongest arguments for this architecture.**

---

## 3. Scheduling algorithms, honestly compared

| Algorithm | Schedulability bound | Overhead | Overload behaviour | Verdict for Nyx |
|---|---|---|---|---|
| Fixed priority (RM/DM) + RTA | `U ≤ 0.69` for RM with harmonic exceptions; exact via response-time analysis | Very low, O(1) | Graceful: low priorities miss first, predictably | **Base layer.** Simple, analysable, what avionics uses |
| EDF | `U ≤ 1.0` for `D = T` — provably optimal on one core | Needs a sorted structure; O(log n) | **Catastrophic**: under overload, everything misses ("domino effect") | Excellent *with* budget enforcement |
| EDF + CBS (Constant Bandwidth Server) | `U ≤ 1.0` with isolation | O(log n) | Contained: an overrunning task is throttled, others unaffected | **The right answer for mixed workloads** |
| Sporadic server / deferrable server | Bounds aperiodic interference | Moderate; refill bookkeeping | Contained | Used for interrupt/driver threads |
| MLFQ / CFS / EEVDF | None | Low | Fair-ish, no guarantees | Fine for best-effort band only |
| seL4 MCS | Budget+period capabilities, donation | Small constant added to IPC | Contained per-scheduling-context | **The model we adopt** |

The synthesis is now well established in the literature and in practice
(SCHED_DEADLINE in Linux is EDF+CBS; seL4 MCS is fixed-priority + budgets +
donation):

> Use **budgets to isolate** and **priorities or deadlines to order**. Neither
> alone is sufficient. Priorities without budgets means one task can monopolize;
> budgets without ordering means you cannot express urgency.

### 3.1 Response-time analysis, briefly

For fixed priority with tasks sorted by decreasing priority, the response time
of task `i` is the fixed point of:

```
R⁰ᵢ = Cᵢ + Bᵢ
Rⁿ⁺¹ᵢ = Cᵢ + Bᵢ + Σ_{j ∈ hp(i)} ⌈Rⁿᵢ / Tⱼ⌉ · Cⱼ
```

where `Bᵢ` is the maximum blocking time (from priority inversion) and `hp(i)` is
the set of higher-priority tasks. Iterate until it converges or exceeds `Dᵢ`.

Three things fall out of this formula that shape the design:

1. **`Bᵢ` must be bounded**, or the analysis is meaningless. That is the entire
   justification for §4.
2. **Interference is a ceiling function**, so short periods hurt
   disproportionately. Coalescing interrupt delivery (Ch. 04 §8) directly
   improves schedulability.
3. **`Cⱼ` must include all kernel time charged to `j`** — its syscalls, its page
   faults, its IPC. Which means the kernel must *charge time to the right
   scheduling context*, which is exactly what donation gives us.

Implement this analysis as a **host-side Python tool in `tools/rta.py`** that
reads a task-set description and prints response times. You will use it
constantly, and it costs an afternoon.

---

## 4. The Nyx design: scheduling contexts as capabilities

This is the change flagged back in Chapter 07 §6 as "the first real research
feature". We now specify it fully.

### 4.1 The object

```c
/* include/nyx/sched_context.h */

#define MAX_REFILLS 8

struct refill {
    uint64_t time;      /* absolute time (TSC ticks) at which it becomes usable */
    uint64_t amount;    /* budget in ticks */
};

struct sched_context {
    struct kobject   hdr;

    uint64_t period;            /* replenishment period, ticks               */
    uint64_t budget;            /* total budget per period, ticks            */
    uint64_t consumed;          /* charged this period (for accounting)      */

    /* Sporadic-server refill queue: a circular buffer of (time, amount).
     * Preserves the sporadic-server property that a context can never
     * interfere more than `budget` in any window of `period`. seL4 MCS
     * uses exactly this structure; it is the subtle part. */
    struct refill refills[MAX_REFILLS];
    uint8_t  refill_head, refill_tail;

    struct tcb *bound_tcb;      /* the thread that owns this SC, or NULL     */
    struct tcb *running_tcb;    /* the thread currently *using* it (donation)*/
    cap_t    timeout_fault_ep;  /* where to send a budget-exhaustion fault   */

    uint8_t  prio;              /* priority band (see §5)                    */
    uint8_t  flags;             /* SC_EDF, SC_HARD, SC_PASSIVE               */
    uint64_t deadline;          /* absolute deadline, for EDF ordering       */
    uint8_t  home_cpu;          /* partitioned: an SC belongs to one core    */
};
```

Rules:

- A thread is runnable **only** if it has a scheduling context with available
  budget. `tcb->sc == NULL` means "runnable in principle, but never scheduled" —
  which is exactly what a **passive server** is.
- Creating a `SchedContext` requires an `SchedControl` capability, which the
  root task holds and hands out according to policy. **Admission control lives
  in userspace**, in the component that owns `SchedControl`. The kernel enforces;
  it does not decide.
- Budget is *charged* to whichever context is currently running, including time
  spent in the kernel on that thread's behalf.

### 4.2 Charging time

```c
/* kernel/sched/sc.c */

static inline void sc_charge(struct sched_context *sc, uint64_t now)
{
    uint64_t used = now - this_cpu()->last_charge;
    this_cpu()->last_charge = now;

    sc->consumed += used;

    /* Consume from the head refill. */
    struct refill *r = &sc->refills[sc->refill_head];
    if (used >= r->amount) {
        uint64_t leftover = used - r->amount;
        refill_pop(sc);
        /* Schedule the consumed amount for replenishment one period later. */
        refill_add_tail(sc, now + sc->period, r->amount);
        if (leftover && sc_ready(sc))
            sc_charge_leftover(sc, leftover, now);
    } else {
        r->amount -= used;
        /* Split refill: the consumed part comes back one period from now. */
        refill_add_tail(sc, now + sc->period, used);
    }
}
```

The refill split is what makes this a **sporadic server** rather than a naive
"reset budget every period" scheme. The naive scheme has a well-known flaw: a
task that uses its whole budget at the end of period *n* and again at the start
of period *n+1* delivers `2 × budget` of interference in a short window,
breaking the analysis. Splitting refills by their consumption time removes it.

> This is the single subtlest piece of code in the scheduler. Write the state
> machine down, model check it (Chapter 13 A4), and write a KTEST that asserts
> the sporadic property directly: *for a random consumption pattern, no window of
> length `period` ever contains more than `budget` of execution*.

### 4.3 Budget exhaustion

When a running SC hits zero budget, the kernel:

1. Removes the thread from the runqueue (state `BLOCKED_BUDGET`).
2. Programs the timer for the next refill time.
3. If `timeout_fault_ep` is present, sends a **timeout fault message** to it.

The fault handler is a userspace policy component. It can: grant more budget
(from its own), lower the task's priority band, kill it, log it, or simply let it
wait for replenishment. **This is policy/mechanism separation applied to time**,
and it is a genuinely nice property: "what happens when a task overruns" becomes
a program you write, not a kernel constant.

### 4.4 Donation and passive servers

The core of the design. When a client `Call`s an endpoint whose receiving thread
has no scheduling context:

```c
/* In ipc_call(), slow path, after the receiver is chosen: */
if (receiver->sc == NULL) {
    /* Donate: the server runs on the client's budget, at the client's
     * priority (or the endpoint's ceiling — see below). */
    receiver->sc = sender->sc;
    receiver->sc->running_tcb = receiver;
    sender->donated = true;
    /* Sender blocks on reply; its SC continues to be charged, but the
     * charges are for work done on its behalf. Accounting is *correct*. */
}
```

On reply, the context returns to the client. Properties:

- **No priority inversion by construction.** The server has no priority of its
  own to be too low. A high-priority client's request runs at high priority even
  if a low-priority client called first — because that low-priority request is
  running on the *low* priority client's donated context and is therefore
  preemptible by the high-priority one.
- **Correct accounting.** The CPU time consumed by the filesystem server on your
  behalf is charged to you. In Linux this is famously wrong (kernel work is
  charged haphazardly; softirq time is charged to whoever is unlucky).
- **A server cannot be a denial-of-service vector.** It has no budget to
  exhaust, so it cannot starve anyone; and it cannot be starved, because it only
  runs when someone who *does* have budget wants it to.
- **Fewer threads.** A passive server needs no thread per client for
  concurrency — the concurrency comes from the callers.

The cost and the catch:

- A passive server must be **reentrancy-aware**: it can be preempted mid-request
  by a higher-priority client entering the same code. Either make it
  non-preemptible internally (an endpoint *ceiling* — raise the effective
  priority for the duration, the classic priority-ceiling protocol) or make it
  properly reentrant with per-client state. **Start with the ceiling.** Record
  the ceiling in the endpoint object:

```c
struct endpoint {
    /* ... existing fields from Chapter 08 ... */
    uint8_t ceiling_prio;   /* effective priority while executing a request  */
};
```

- The blocking term `B` in your response-time analysis becomes the longest
  single request any lower-priority client can be inside when you arrive. So
  **server request handlers must be short and bounded** — which is a design
  discipline you want anyway. Long operations must be split into a bounded
  submit + an asynchronous completion (which is exactly the I/O model of Chapter
  15 — these two chapters reinforce each other).

### 4.5 What is genuinely open here

seL4's MCS was designed for single-core mixed-criticality embedded systems. Open
questions you are now equipped to investigate:

1. **Cross-core donation.** If the server's home core is different, do you
   migrate the request (message) or the context (thread)? Migration of the
   scheduling context across cores breaks partitioned analysis. Probably the
   right answer is: servers are pinned, requests are messages, and a cross-core
   call costs a bounded IPI + the remote core's scheduling latency, which must
   appear in the analysis. Nobody has properly analysed this.
2. **Donation through chains.** A → B → C. Does C run on A's context? (It
   should.) What is the depth bound, and what happens on a cycle?
3. **Donation to interrupt handlers.** An interrupt arrives on behalf of a
   pending request. Can you charge the driver's work to the requester rather
   than to a generic driver budget? This would make I/O accounting correct for
   the first time in any OS. It requires the request to be traceable from the
   completion — which your I/O design (Chapter 15) can provide, because
   completions carry a user token. **This is a strong project.**

---

## 5. Priority bands and the two-level scheduler

Fixed priority and EDF are complementary, so use both. Nyx's runqueue is
organized as 256 priority bands (Chapter 07's bitmap), with a rule:

| Band | Class | Ordering within band |
|---|---|---|
| 255–224 | Kernel-critical (timer, IPI helpers) | FIFO |
| 223–160 | **Hard real-time** | EDF, budgets mandatory (`SC_HARD`) |
| 159–96 | Firm/soft real-time (audio, drivers) | EDF, budgets mandatory |
| 95–32 | Interactive | Round robin with budget |
| 31–0 | Best effort / batch | Round robin, budget optional |

Selection is: highest non-empty band (one `lzcnt`), then within the band either
FIFO or the earliest deadline. Keep an `O(log n)` structure per EDF band — a
small pairing heap or a 4-ary heap is fine; you rarely have more than a few dozen
real-time tasks per core.

```c
struct tcb *sched_pick(struct percpu *cpu)
{
    int band = 63 - __builtin_clzll(cpu->rq.bitmap_hi ?: cpu->rq.bitmap_lo);
    struct runband *b = &cpu->rq.band[band];

    struct tcb *t = (b->policy == POLICY_EDF)
                  ? heap_min(&b->edf)          /* earliest deadline          */
                  : list_first(&b->fifo);

    /* Skip contexts with no budget: they should already have been dequeued,
     * so this is an assertion, not a loop. */
    assert(t == NULL || sc_ready(t->sc));
    return t;
}
```

**Partitioned, not global.** Each core has its own runqueue and its scheduling
contexts have a `home_cpu`. This is a deliberate real-time choice:

- Global EDF has better theoretical utilization but its schedulability analysis
  is much weaker and its overhead (a shared, contended runqueue plus migration)
  is unbounded in practice.
- Partitioned scheduling reduces the problem to N independent single-core
  problems, each with exact analysis. Placement becomes a bin-packing problem
  solved *offline, in userspace*, which is where policy belongs.
- It also aligns exactly with the partitioned-kernel position from Chapter 12: no
  shared runqueue means no runqueue lock on the fast path.

Migration exists, but it is an explicit operation (`SchedContext_SetCore`),
performed by a policy component, not something the scheduler does on its own.

---

## 6. Interrupt and kernel latency

### 6.1 The latency chain

```
device asserts ─┬─ IOAPIC/MSI delivery            ~0.1 µs
                ├─ current kernel non-preemptible region   ← YOUR NUMBER
                ├─ CPU interrupt entry (~100 cycles + IST)
                ├─ kernel ISR: mask + signal notification  ~200 cycles
                ├─ scheduler decision + context switch      ~0.3–1 µs
                └─ driver thread first instruction
```

Everything except the second line is a small constant. The second line is the
number that defines your system, and it is the one you must *bound by argument*,
not just measure.

### 6.2 Bounding the kernel

Go through every kernel entry point and classify it:

| Operation | Bound | Technique |
|---|---|---|
| IPC (fast and slow path) | O(1) | No loops except fixed message words |
| Capability lookup | O(depth), depth ≤ 4 | Guarded radix, bounded by construction |
| `cap_revoke` | Unbounded | **Preemptible + restartable** (Ch. 09 §3) |
| `Untyped_Retype` (zeroing) | O(size) | Preemption points every N pages |
| `vspace_destroy` | O(mappings) | Preemptible, restartable |
| TLB shootdown | O(cores) + remote ack | Bounded by core count; the remote ack is the risk — cap it and log |
| Scheduler pick | O(1) or O(log n) | Bitmap / heap |
| Interrupt masking | O(1) | |

Produce a table like that in `docs/realtime.md` with **measured** numbers next to
the analytical bounds, and make it a CI artifact. When the two diverge, you have
learned something.

**Preemption points, concretely:**

```c
/* Long operations follow this shape. The operation stores its own progress
 * in the capability/object so it can be resumed after preemption. */
static int untyped_retype_step(struct untyped *ut, struct retype_state *st)
{
    while (st->done < st->total) {
        zero_page(st->base + st->done * PAGE_SIZE);
        st->done++;

        if ((st->done & 0x3F) == 0 && need_resched_or_irq_pending()) {
            /* Save progress in the object, return "restart me". */
            ut->pending = *st;
            return -ERESTART;      /* syscall returns; userspace retries    */
        }
    }
    return 0;
}
```

64 pages of zeroing is roughly 20–40 µs on a modern core — probably still too
coarse for a 100 µs target, so make the granularity a `CONFIG_` knob and measure.
The `-ERESTART` convention (the syscall returns and userspace re-invokes) is
seL4's, and it keeps the kernel stackless with respect to long operations, which
in turn keeps it verifiable.

### 6.3 The rule for drivers

Already stated in Chapter 04, restated here because it is a real-time rule:

> **The kernel ISR does two things: mask the interrupt and signal a
> notification.** No device register access, no buffer processing, no
> allocation, no locks other than the notification's. Everything else is a
> userspace driver thread with its own scheduling context, priority, and budget.

The consequence is that **interrupt load becomes schedulable load**. A device
that interrupts 200 000 times a second cannot livelock your system, because the
driver that processes those interrupts has a budget, and when it exhausts the
budget it stops and the interrupts stay masked. Linux needed NAPI, softirq
threading, and `PREEMPT_RT`'s threaded IRQs to approximate this; here it is the
default and it falls out of the architecture.

---

## 7. Isolating what the scheduler cannot: cache, bandwidth, and the rest

CPU time is the *easy* resource to partition. The ones that actually cause your
99.99th percentile misses are shared microarchitectural resources.

### 7.1 Last-level cache

Two mechanisms:

**Page colouring (works everywhere).** A physically-indexed LLC maps a physical
address to a set using bits that overlap the page frame number. Frames whose
`(paddr >> 12) & (ncolours - 1)` differ never collide in the same cache sets.
Partition colours between domains and allocate accordingly:

```c
/* kernel/mm/pmm.c — colour-aware allocation */
struct page *pmm_alloc_coloured(int order, uint32_t colour_mask)
{
    /* Maintain per-colour free lists, or filter the buddy result. Filtering
     * wastes; per-colour lists fragment. Start by filtering with a bounded
     * retry, and measure how bad it is before optimizing. */
}
```

Cost: you lose allocation flexibility, and huge pages fight colouring (a 2 MiB
page spans all colours by definition). This is a real tension — document it.

**Intel CAT / RDT (works on server parts).** Class-of-service MSRs let you assign
LLC way masks per core or per task, and MBA lets you throttle memory bandwidth.
Far cleaner than colouring:

```c
/* IA32_PQR_ASSOC (0xC8F): sets the COS for the current core.
 * IA32_L3_MASK_n (0xC90 + n): the way bitmask for COS n.
 * IA32_L2_QoS_Ext_BW_Thrtl_n (0xD50 + n): MBA throttle for COS n. */
static void rdt_set_cos(uint32_t cos) { wrmsr(0xC8F, (uint64_t)cos << 32); }
```

Set the COS in `switch_to()` from a field on the scheduling context. That is a
two-line change and it gives you per-task cache partitioning. AMD has an
equivalent (Platform QoS). Check CPUID leaf 0x10 for support and degrade to
colouring when absent.

### 7.2 Everything else

- **SMT**: a sibling shares L1, L2, TLB, execution ports and branch predictors.
  For hard real-time, disable it (don't start those APs) or ensure siblings are
  only ever scheduled from the same domain. Note this interacts with the
  security story: SMT is also the strongest microarchitectural side channel.
- **DVFS/turbo**: pin the frequency for benchmark and hard-RT configurations, or
  your WCET is a function of what other cores are doing. Record the P-state in
  every result file.
- **Memory pinning**: a hard-RT address space should be fully mapped and pinned
  at admission time. Add a `VSpace_Pin` invocation; make the memory server refuse
  to reclaim from pinned spaces. Otherwise a page fault → IPC → pager → disk chain
  is an unbounded term in your analysis.
- **DMA**: a device streaming at 20 GB/s is a task with a memory-bandwidth budget
  and no scheduler. IOMMU-based partitioning is coarse; MBA does not cover
  device traffic. **This is a genuine open problem** and worth flagging in
  anything you write.

---

## 8. Verification: measuring latency properly

### 8.1 The cyclictest analogue

The standard test: program a timer for `now + T`, sleep, and on wakeup record
`actual - expected`. Do it a few million times and report the histogram, the
maximum, and the configuration.

```c
/* user/tests/rtlat.c — the single most important number your OS produces */
void rt_latency_test(uint64_t period_ns, uint64_t iterations)
{
    uint64_t hist[512] = {0};       /* 1 µs buckets, saturating              */
    uint64_t max = 0, next = now_ns() + period_ns;

    for (uint64_t i = 0; i < iterations; i++) {
        nyx_timer_set(timer_cap, next);      /* absolute deadline            */
        nyx_wait(timer_notification);
        uint64_t t = now_ns();
        uint64_t late = t > next ? t - next : 0;

        hist[MIN(late / 1000, 511)]++;
        if (late > max) max = late;
        next += period_ns;                   /* absolute, no drift           */
    }
    report_histogram(hist, max);
}
```

Rules for this test to mean anything:

1. **Report the maximum and the full histogram**, never the average. An average
   latency number is a marketing number.
2. **Run it under load**, and say what the load was. Idle-system latency is
   trivial. Run it with: a `memset` loop on every other core (cache/bandwidth
   pressure), heavy IPC traffic, a driver taking 100k interrupts/s, and
   filesystem activity. Publish all four.
3. **Run it for hours.** The interesting event happens once every 10⁸
   iterations. A 30-second run proves nothing.
4. **Record the environment**: CPU model, frequency policy, SMT on/off, KVM or
   TCG, SMI count before and after, mitigations enabled.

Expected order of magnitude for a well-built microkernel on bare metal, with SMT
off and frequency pinned: **max latency in the 10–30 µs range**, versus
`PREEMPT_RT` Linux's typical 30–100 µs and mainline Linux's occasional
milliseconds. Under QEMU/KVM add tens of µs of host noise — which is why the
number is only meaningful on hardware, and why you should say so.

### 8.2 Tests to write

```c
KTEST(sc_sporadic_property) {
    /* Random consume/replenish sequence; assert no window of length `period`
     * ever contains more than `budget` of execution. This is THE invariant. */
}

KTEST(sc_exhaustion_dequeues_and_faults) {
    /* Burn budget; assert the thread is dequeued and a timeout fault arrives
     * at the fault endpoint. */
}

KTEST(passive_server_no_inversion) {
    /* Low-prio client calls a passive server that spins for a long time.
     * High-prio client calls the same server. Assert the high-prio client's
     * response time is bounded by (ceiling hold time), not by the low-prio
     * client's full request. Measure and assert the bound. */
}

KTEST(donation_accounting_is_correct) {
    /* Client calls a passive server that burns exactly X ticks.
     * Assert client->sc->consumed increased by X ± epsilon, and that no
     * other SC was charged. This is the test that proves the accounting
     * claim you will make in your write-up. */
}

KTEST(irq_storm_does_not_starve) {
    /* Fire a synthetic IRQ at maximum rate at a driver with a small budget.
     * Assert a lower-priority compute thread still makes progress and that
     * the rt_latency of a third thread is unaffected. */
}

KTEST(revoke_is_preemptible) {
    /* Revoke a capability with a huge derivation tree while a high-priority
     * timer thread runs. Assert the timer thread's jitter stays under bound. */
}
```

`passive_server_no_inversion` and `donation_accounting_is_correct` are the two
that justify the whole chapter. Write them first; they will also find your bugs.

### 8.3 Tracing

Latency work is impossible without a trace. Chapter 18 builds the harness, but
the real-time-specific requirement is: **timestamp every scheduling decision,
every SC charge, and every IPC, into a per-CPU lock-free ring, and dump it after
a latency violation**. When you see a 300 µs outlier, you want the last 10 ms of
events leading to it, not a guess. Trigger the dump automatically from the
latency test when a sample exceeds a threshold.

---

## 9. Where this leaves the design

You now have three properties that are genuinely hard to get in a general
purpose OS and that come almost free from this architecture:

1. **No kernel allocation** ⇒ no allocator latency, no OOM path, bounded
   operations.
2. **Interrupts are schedulable load** ⇒ no livelock, no unbounded interference.
3. **Donated scheduling contexts** ⇒ no priority inversion through servers, and
   correct CPU accounting across component boundaries.

And two that require real work:

4. **Bounded kernel operations** — needs the preemption-point discipline and a
   published table, maintained forever.
5. **Microarchitectural isolation** — needs colouring/CAT and honesty about
   what you cannot partition.

The one thing that would make this a research contribution rather than a good
engineering effort: **charge device and driver time to the requesting client**
(§4.5 item 3). No OS does this correctly, it is only tractable when requests
carry identity end-to-end, and the I/O architecture of the next chapter is
exactly what makes it possible.

---

## 10. Exercises

1. Implement `tools/rta.py` and use it to compute response times for a task set
   of your invention. Then implement that task set on Nyx and compare predicted
   with measured response times. Explain every discrepancy — each one is a term
   you forgot.
2. Implement the sporadic-server refill queue and write the invariant test.
   Then deliberately implement the naive "reset budget each period" version and
   construct a task set where it breaks the bound. This is the most instructive
   hour in the chapter.
3. Implement `passive_server_no_inversion` with the priority-ceiling protocol.
   Then remove the ceiling and observe the reentrancy bug. Write down what
   invariant the ceiling was protecting.
4. Measure the effect of cache colouring: run the latency test with a
   cache-thrashing neighbour, with and without colour partitioning. Report the
   maximum, not the mean.
5. Read your CPU's SMI count MSR before and after a one-hour latency run.
   Correlate spikes with SMI count changes. Report what fraction of your worst
   outliers are firmware, not you.
6. **Argue the other side**: make the case that EDF is the wrong choice for a
   general purpose system and that fixed priority with budgets is sufficient.
   What does EDF actually buy at the utilizations real systems run at?
7. **Design exercise**: specify cross-core scheduling-context donation. Define
   the semantics, the analysis implications, and the failure modes. Decide
   whether you would ship it, and write down why.

---

Next: [15 — I/O architecture: zero-copy, asynchronous, and direct to the device](15-io-architecture.md)
