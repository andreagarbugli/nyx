# 34 — Partitioning: resource isolation for real-time and mixed criticality

> Goal: guarantee that what one workload does cannot affect another's timing —
> not "usually", but with an argument you could show a certification authority.
> The claim of this chapter is that a capability system gets most of this for
> free, that the remaining pieces are microarchitectural, and that the result is
> both simpler and stronger than cgroups v2.

---

## 1. What cgroups v2 is, and what's wrong with it

cgroups is the state of the art in Linux resource control, and it's genuinely
good engineering. The problems are structural, not sloppy:

| Property | cgroups v2 | Why it's a problem |
|---|---|---|
| **Membership is ambient** | A process *is in* a cgroup; something external puts it there | The process has no say and no view. Authority over it is elsewhere, which is the ACL model again (Chapter 09 §1). |
| **Accounting is approximate** | Memory charged to first-toucher; kernel memory partially attributed; work done by kernel threads on your behalf charged to nobody | You cannot state a bound. Over-commit and the OOM killer are the consequences. |
| **Controllers are independent** | CPU, memory, IO, PIDs each a separate hierarchy-walking controller | No unified statement of "this partition's resources" |
| **Real-time is bolted on** | `RT_RUNTIME` throttling exists to stop RT tasks from starving the system | An admission that the model doesn't compose with real-time |
| **Microarchitecture invisible** | No cache, no memory bandwidth, no TLB | Two "isolated" containers on the same LLC interfere freely. This is where real interference lives. |
| **Interference is unbounded** | No mechanism to state or verify it | You cannot certify anything |

The last two are the killers for real-time. Two cgroups with identical CPU shares
can differ by 3× in throughput depending on what the *other* one is doing to the
last-level cache. Nothing in cgroups sees that.

---

## 2. What Nyx already has

Here's the thing: **most of partitioning is already built**, and it wasn't built
as a partitioning feature.

| Resource | Mechanism | Property |
|---|---|---|
| **Memory** | Untyped capability (Chapter 09 §4) | Exact. A component's memory is the sum of its untypeds; it *cannot* exceed it. No over-commit, no OOM killer, no accounting heuristic. |
| **CPU time** | SchedContext (Chapter 14) | Exact `(budget, period)`. With donation, a client pays for the work a server does on its behalf — the thing cgroups cannot do. |
| **Kernel memory** | Untyped again | Every kernel object came from *someone's* untyped. There is no unattributed kernel allocation, because the kernel has no heap. |
| **Devices, IRQs, ports** | Capabilities | You have access or you don't |
| **Communication** | Endpoints | The graph is the policy |

So a "partition" needs no new kernel concept:

> **A partition is a subtree of the capability graph, plus a set of resource
> budgets. Nothing more.**

That's a much simpler statement than cgroups' controller hierarchy, and it's
stronger, because membership isn't ambient: a component doesn't *belong to* a
partition, it *holds* a set of capabilities, and that set is what a partition is.

Two consequences worth stating:

- **Nesting is free.** A partition can subdivide its untypeds and scheduling
  contexts among children. Hierarchical resource control is just delegation, which
  the capability model already does.
- **The partition boundary is auditable.** "What can this partition affect?" is
  the reachability query from Appendix E §E4, over a graph you can print.

---

## 3. What's actually missing: the microarchitecture

Capabilities partition *logical* resources perfectly and *physical* resources not
at all. Two components with disjoint capability sets still share:

| Shared resource | Effect | Mechanism to partition it |
|---|---|---|
| Last-level cache | 2–3× throughput swings | **Intel CAT / AMD L3 QoS / ARM MPAM**, or page colouring |
| Memory bandwidth | Latency inflation under load | **Intel MBA / MPAM** bandwidth throttling |
| Memory controller / DRAM banks | Row-buffer conflicts | Bank-aware allocation (research-grade) |
| TLB, branch predictors, prefetchers | Timing variation, side channels | Mostly nothing. Flush on switch (Chapter 13 §B1) |
| SMT sibling | Massive; shares almost everything | **Disable SMT, or co-schedule only within a partition** |
| Interconnect / uncore | Cross-socket latency | NUMA-aware placement |
| Device DMA bandwidth | Storage/network interference | Queue-level QoS, IOMMU-side throttling |

### 3.1 Cache partitioning

Two approaches, and you want the first if the hardware has it:

**Hardware (CAT/MPAM).** Assign each partition a class of service (CLOS) and a
bitmask of LLC ways. Program `IA32_PQR_ASSOC` on context switch (one MSR write,
~100 cycles — measure it) and the way-masks once at partition creation.

```c
/* On switch into a partition: */
wrmsr(IA32_PQR_ASSOC, ((uint64_t)partition->clos << 32) | partition->rmid);
```

`rmid` also gives you **monitoring**: per-partition LLC occupancy and memory
bandwidth, readable via `IA32_QM_CTR`. That turns interference from invisible into
measured, which is the prerequisite for doing anything about it.

**Software (page colouring).** Allocate physical frames whose colour bits
(`(paddr >> 12) & (n_colours - 1)`) map to disjoint cache sets. Works on any
hardware, costs you allocator flexibility, and integrates with Chapter 05's buddy
allocator as a constraint on `pmm_alloc`. This is also the mechanism for time
protection (Chapter 13 §B1), so building it serves two purposes.

**Recommendation:** page colouring in the PMM as the portable baseline, CAT/MPAM
as the fast path when present. Expose both through one `cache_ways` field in the
partition spec.

### 3.2 The honest caveat

Even with CAT, MBA, colouring, and SMT disabled, you have not eliminated
interference — you've bounded the big terms. Prefetchers, the memory controller's
scheduling, and shared uncore structures remain. **Measure the residual (§7) and
state it**; don't claim isolation you can't demonstrate.

---

## 4. Real-time, honestly categorized

"Real-time" covers domains with very different requirements. Be specific about
which you're serving:

| Domain | Class | Deadline | Miss consequence | Typical periods |
|---|---|---|---|---|
| **Audio** | Firm | 1–10 ms | Audible glitch; users notice one per hour | 128–512 samples |
| **Video / compositing** | Soft | 8–16 ms | Dropped frame, judder | Frame period |
| **Industrial control** | Hard | 100 µs – 10 ms | Damaged product, unsafe machine | Cyclic, fixed |
| **Automotive (ADAS/powertrain)** | Hard, mixed criticality | 1–100 ms | Safety event; ISO 26262 ASIL A–D | Fixed |
| **Avionics** | Hard, certified | Fixed frames | Certification failure; DO-178C | ARINC 653 major frame |
| **Telecom (RAN)** | Hard-ish | 100 µs – 1 ms | Dropped calls, spec violation | Slot-aligned |
| **Robotics** | Mixed | 1–10 ms control loop | Instability | Cyclic |

Two observations that shape the design:

**Audio is closer to hard real-time than people admit.** A 128-sample buffer at
48 kHz is 2.67 ms; miss it and there's an audible click. The reason desktop audio
is unreliable is that no mainstream desktop OS gives audio a real guarantee — it
gives it a high priority and hopes. This is a place where the architecture could
just *win*, visibly, on a laptop.

**Mixed criticality is the actual problem.** Real systems run a certified control
loop *and* an infotainment stack on one SoC, because a separate ECU costs money.
The requirement is that the uncertified workload cannot affect the certified one —
which is precisely §2 plus §3.

---

## 5. Two-level scheduling

The standard structure for partitioned real-time, and it's what ARINC 653
mandates:

```
┌─────────────────────────────────────────────────────┐
│ Level 1: partition scheduler                        │
│   Either: fixed cyclic windows (ARINC 653)          │
│   Or:     periodic budget reservations              │
├──────────────┬──────────────┬───────────────────────┤
│ Partition A  │ Partition B  │ Partition C           │
│ (certified)  │ (multimedia) │ (best effort)         │
│ EDF          │ fixed prio   │ round robin           │
└──────────────┴──────────────┴───────────────────────┘
```

**Level 1 options:**

- **ARINC 653 cyclic**: a fixed *major frame* divided into fixed windows, each
  assigned to a partition. Perfectly deterministic, trivially analyzable, and
  wasteful — a partition that finishes early idles its window. This is what
  certifies in avionics, and the waste is considered an acceptable price.
- **Reservation-based**: each partition gets `(budget, period)`; a
  server-based algorithm (deferrable, sporadic, or constant-bandwidth server)
  schedules them. Better utilization, still analyzable, harder to certify.

**Chapter 14's scheduling contexts already implement the second.** A partition's
top-level SchedContext *is* its reservation. Adding ARINC-style cyclic windows is
a different Level-1 policy over the same mechanism — and in a microkernel, the
Level-1 scheduler can be a userspace component (Chapter 07 §5's scheduler server).

**Compositional analysis.** The theory here is solid and worth using: a
partition's *interface* is `(period, budget)`, and you can analyze each partition's
internal schedulability against that interface independently, then check that the
interfaces fit the platform. Shin & Lee's compositional real-time framework is the
reference. This is what makes partitioning tractable at scale: you don't re-verify
the whole system when one partition changes.

---

## 6. The API

Keep it small. A partition spec is data, and it lives in the manifest (Chapter
30 §4) — because a partition is a deployment concern:

```toml
[partition.control_loop]
criticality  = "hard"
memory       = "8MiB"                    # an Untyped budget
cpu          = { period = "1ms", budget = "200us" }
cpus         = [2, 3]                    # exclusive; not shared with other partitions
cache_ways   = 4                         # CAT/colouring
mem_bw_pct   = 20                        # MBA
irqs         = ["ethercat0"]             # IRQ capabilities, routed to these CPUs only
smt          = "disabled"
scheduler    = "edf"                     # within-partition policy

[partition.infotainment]
criticality  = "none"
memory       = "2GiB"
cpu          = { period = "10ms", budget = "7ms" }
cpus         = [4, 5, 6, 7]
cache_ways   = 8
mem_bw_pct   = 60
scheduler    = "fixed-priority"
```

Compare the equivalent in cgroups v2 + `sched_setattr` + `resctrl` + IRQ affinity
+ `isolcpus` + kernel boot parameters: five mechanisms, three configuration
systems, and no single place that states the policy. Here it's one declaration,
and it's the same file that states the *authority* — which is right, because
"what you may consume" and "what you may reach" are the same kind of statement.

**Core isolation** deserves a note: dedicating CPUs to a partition means removing
them from everything else — no other partition's threads, no unrelated IRQs, and
ideally no timer tick (Chapter 04 already uses TSC-deadline, so a fully idle core
takes *zero* interrupts). Linux needs `isolcpus`, `nohz_full`, `rcu_nocbs`, IRQ
affinity, and workqueue masks to approximate this. Here it's a consequence of not
giving anyone else a capability to those cores.

---

## 7. Verifying isolation

This is the part that distinguishes a claim from a guarantee. **Build an adversary
and measure.**

```
tests/partition/interference/
  cache_thrash      — streams through a buffer sized to the whole LLC
  membw_hog         — saturates memory bandwidth
  irq_storm         — generates maximum interrupt load
  ipc_flood         — maximum IPC rate
  alloc_churn       — maximum kernel object creation/destruction
  smt_sibling_load  — pins load to the SMT sibling of the victim
```

The test: run the victim partition's real workload, measure its WCET distribution
with the adversary **off**, then with each adversary **on**, in another partition.

```
                          p50      p99      max     Δmax
baseline (idle system)   82 µs    91 µs    104 µs      —
+ cache_thrash           84 µs    96 µs    118 µs   +13%
+ membw_hog              83 µs    94 µs    111 µs    +7%
+ irq_storm              82 µs    92 µs    106 µs    +2%
+ all simultaneously     87 µs   102 µs    129 µs   +24%
```

**That table is the deliverable.** Publish it, track it in CI, and fail the build
if `Δmax` exceeds the partition's declared interference bound. Without partitioning
mechanisms enabled, the same table will show 2–3× — which is exactly the
demonstration that the mechanisms are doing something.

This is also a genuine research contribution if done rigorously: careful,
reproducible interference measurements across mechanisms on modern hardware are
scarce, and everybody needs them.

---

## 8. Certification, if you go there

Not required, but knowing the vocabulary shapes the design well:

| Standard | Domain | Key requirement |
|---|---|---|
| **DO-178C** + DO-297 (IMA) | Avionics | Requirements traceability, structural coverage, and **robust partitioning** in time and space |
| **ARINC 653** | Avionics APEX | Fixed cyclic partition scheduling, health monitoring, defined partition API |
| **ISO 26262** | Automotive | ASIL levels; **"freedom from interference"** in space, time, and exchange of information |
| **IEC 61508** | Industrial | SIL levels; systematic capability |
| **Common Criteria / seL4's proof** | Security | Formal correspondence between spec and implementation |

Note the ISO 26262 phrasing: *freedom from interference in space, time, and
exchange of information*. That is, essentially verbatim, what capabilities
(space + information) plus scheduling contexts and cache partitioning (time)
provide. **The certification standards are asking for exactly what this
architecture gives structurally**, whereas a monolithic kernel has to argue for it
after the fact — which is why seL4 and the classic separation kernels (PikeOS,
INTEGRITY-178B, LynxSecure, Green Hills) all have this shape.

Worth writing in `docs/partitioning.md`: a mapping table from each standard's
requirements to the mechanism that provides it. Even if you never certify, it's a
good design review.

---

## 9. Soft real-time: multimedia specifically

The soft-RT case has different mechanics and is where most people will actually
feel the difference:

- **Deadline propagation** (Chapter 26 §3): the compositor knows the vblank
  deadline; a client rendering for that frame should inherit it. Generalize:
  the deadline is a property of the *request* (Chapter 32 §5's trace id already
  flows the right way), inherited by everything on its critical path.
- **Buffer-based scheduling**: an audio pipeline's real requirement isn't "run
  every 2.67 ms", it's "keep the ring buffer non-empty". Scheduling to buffer
  occupancy rather than to a timer is more robust and tolerates jitter. This is
  what good audio systems do and what most OSes make hard.
- **Graceful degradation**: a soft-RT partition that exceeds its budget should
  degrade (drop a frame, reduce quality) rather than be killed. That means the
  budget-exhaustion exception (Chapter 14) must be deliverable to the component as
  a *signal*, not just a suspension.
- **Measure glitches, not averages**: the metric for audio is
  underruns-per-hour; for video, dropped frames and frame-time variance. Put those
  in CI with the interference adversaries running.

A concrete, achievable, demonstrable goal: **zero audio underruns at a 2.67 ms
buffer while a kernel build and a cache-thrashing adversary run in another
partition.** No mainstream desktop OS reliably manages that, and it's the kind of
result that needs no explanation.

---

## 10. Verification

| Test | Asserts |
|---|---|
| `interference_matrix` | The §7 table, in CI, with declared bounds enforced |
| `budget_enforced` | A partition exceeding its CPU budget is throttled exactly at the boundary |
| `memory_bounded` | A partition cannot allocate beyond its untypeds, even under adversarial patterns |
| `no_priority_inversion_across_partitions` | A low-criticality partition holding a shared server cannot delay a high one (passive servers, Chapter 14) |
| `irq_isolation` | An IRQ storm on partition B's devices does not perturb partition A's WCET |
| `cache_ways_respected` | Read CAT monitoring counters; assert occupancy stays within the assigned mask |
| `core_exclusivity` | Nothing but the owning partition ever runs on a dedicated core; assert via trace (Chapter 32) |
| `arinc_windows` | Under cyclic scheduling, a partition never runs outside its window — not once, over millions of frames |
| `audio_no_underrun` | The §9 goal, under full adversarial load |
| `degradation_not_death` | Budget exhaustion delivers an exception the component handles |

---

## 11. Exercises

1. Build the interference adversaries and produce the §7 table with all
   partitioning mechanisms *disabled*. Note the numbers; they'll be worse than you
   expect.
2. Implement CAT (or page colouring) and produce the table again. Quantify what
   you bought.
3. Implement the ARINC 653 cyclic Level-1 scheduler as a userspace component. Test
   window enforcement over ten million frames.
4. Implement deadline propagation through IPC and measure the p99 improvement on
   a compositor-plus-client pipeline.
5. Build the audio underrun test and get to zero under load. Document what you had
   to fix.
6. Write the standards-to-mechanism mapping table (§8) for ISO 26262's freedom
   from interference. Identify the requirements you *don't* satisfy.
7. Measure the residual interference after every mechanism is enabled, and write
   down what it comes from. That number is the honest limit of your isolation.
8. **Argue the other side:** make the case that strict partitioning wastes so much
   capacity (idle windows, reserved cache ways, disabled SMT, dedicated cores) that
   a well-tuned best-effort system with high priorities is better in practice for
   everything except certified systems. What measurement would settle it?

---

← [Back to the index](README.md)

Next: [35 — APIs for real-time programming](35-realtime-api.md)
