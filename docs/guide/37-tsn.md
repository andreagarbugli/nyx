# 37 — Deterministic and real-time networking (TSN)

> Goal: bounded, provable network latency. Time-Sensitive Networking is a set of
> IEEE standards that make Ethernet deterministic; almost no general-purpose OS
> supports it natively, and the Linux support is a set of qdiscs bolted onto a
> best-effort stack. Chapter 36's API already carries `launch_time` and
> `deadline`, so most of the work here is a **userspace network scheduler** and a
> disciplined time base.

---

## 1. Why Ethernet is nondeterministic, and what TSN fixes

A frame's latency across a switched network varies because of **queueing**: your
frame arrives at a switch port while a 1518-byte frame is being transmitted, so
you wait up to 12 µs at 1 Gbps — and behind any other frames already queued.
Across five hops with congestion, the tail is unbounded.

TSN's answer is to schedule the network the way a real-time OS schedules a CPU:

| Standard | Name | What it does |
|---|---|---|
| **802.1AS** | gPTP | Sub-microsecond time synchronization across all bridges and endpoints. **The foundation — nothing else works without it.** |
| **802.1Qbv** | Time-Aware Shaper | A gate control list per port: each traffic class's gate opens and closes on a schedule aligned to the global clock. Reserved windows mean zero queueing delay. |
| **802.1Qbu** + 802.3br | Frame Preemption | An express frame interrupts a preemptable one mid-transmission, cutting the 12 µs blocking term to ~1 µs |
| **802.1Qav** | Credit-Based Shaper | Bandwidth reservation with bounded burst — for audio/video streams that need rate, not slot precision |
| **802.1Qci** | Per-Stream Filtering and Policing | Enforces that a stream stays within its declared envelope. **The network's admission control.** |
| **802.1CB** | Frame Replication and Elimination | Send over disjoint paths, deduplicate at the receiver: zero-recovery-time redundancy |
| **802.1Qch** | Cyclic Queuing and Forwarding | Simpler determinism: bounded per-hop delay without a global schedule |
| **802.1Qcc** | Stream Reservation / Configuration | How streams are declared and schedules distributed — the control plane |

Notice how closely this maps onto Chapter 34: gate control lists are ARINC 653
windows for a wire, Qci is budget enforcement, and Qcc is admission control. **The
network and the CPU are the same scheduling problem**, which is exactly why the
chain abstraction from Chapter 35 §6 should extend across both.

---

## 2. Time is the foundation

Nothing in TSN works without a synchronized clock. This is the piece to build
first and the piece most likely to be quietly wrong.

**Hardware timestamping is mandatory.** The NIC records the exact time a frame's
first symbol crossed the wire, in the NIC's own clock domain. Software timestamps
have microseconds of jitter from interrupt latency and scheduling — a hundred
times worse than what TSN needs.

The pieces:

| Piece | Notes |
|---|---|
| NIC PTP hardware clock (PHC) | A free-running counter, adjustable in rate and offset |
| TX/RX timestamping | Per-frame, at the MAC/PHY boundary |
| gPTP/PTP protocol | Grandmaster election, peer delay measurement, offset computation |
| Servo | A PI controller adjusting the PHC's rate to track the master. Tune it; a badly tuned servo oscillates and every latency measurement becomes noise. |
| PHC ↔ system clock sync | So that Chapter 35's deadlines and the NIC's launch times are in the same time base |
| Holdover | What happens when the grandmaster disappears — free-run with a known drift budget, and *report* the degradation |

That PHC-to-system-clock link is the subtle one. Two clocks (the CPU's TSC and the
NIC's PHC) drift relative to one another, so you need a continuously-updated
conversion. Most NICs support a cross-timestamp mechanism (`PTP_SYS_OFFSET` on
Linux, ART-to-TSC correlation on Intel parts) that samples both atomically —
use it, because a linear-regression estimate from separate reads has jitter that
will dominate your error budget.

**This work pays off far beyond TSN.** Chapter 32's cross-node causal tracing and
Chapter 28's distributed timing all depend on synchronized clocks, and PTP gives
you sub-microsecond where NTP gives you milliseconds.

---

## 3. Transmission scheduling

### 3.1 Launch time (the easy, powerful primitive)

Modern Intel NICs (i210, i225/i226) support **LaunchTime**: a descriptor carries an
absolute time and the NIC transmits at exactly that moment, ±a few hundred
nanoseconds. Linux exposes this as `SO_TXTIME` plus the `etf` qdisc.

Chapter 36's `net_send.launch_time` maps directly onto it. The consequences are
larger than they look:

- Transmission jitter stops depending on scheduling jitter. Your task can wake up
  200 µs early or 50 µs late; the frame still leaves at exactly T.
- The CPU-side deadline becomes soft while the *wire* timing stays hard, which
  moves the hard requirement from the OS to the NIC, where it's much easier to
  meet.
- Combined with a global time base, all senders in a network can be given
  non-overlapping slots — which is time-division multiplexing implemented purely
  at the endpoints, with no switch support at all. **This is the single highest
  value-per-effort feature in the chapter**, and worth implementing before any
  Qbv work.

### 3.2 The gate control list (Qbv)

For per-port scheduling, the NIC (and each switch) holds a cyclic list:

```
base_time = T0, cycle = 1 ms
  offset      0 µs  gates: 10000000   (only class 7 may transmit)
  offset    125 µs  gates: 01000000   (class 6)
  offset    250 µs  gates: 00111111   (everything else)
  offset   1000 µs  → wrap
```

Every port in the network runs its list aligned to the same clock, with offsets
chosen so a frame arrives at each hop exactly when its gate opens. Queueing delay
becomes zero by construction, and end-to-end latency becomes a computed constant.

**The guard band problem:** a frame that starts transmitting just before a gate
closes would run past it. So the scheduler must either leave a guard band the size
of the largest frame (wasting up to 12 µs per window at 1 Gbps) or use frame
preemption (Qbu) to cut it to ~1 µs. Guard bands are why naive Qbv schedules waste
a lot of bandwidth, and why Qbu matters more than its obscurity suggests.

---

## 4. The network scheduler as a userspace component

You asked whether the scheduler could live in userspace. It should, and the
standards agree — 802.1Qcc defines a **Centralized Network Configuration** entity
that does exactly this. Building it as a Nyx component is a natural fit:

```
┌────────────────────────────────────────────────────────────┐
│ network scheduler (userspace component)                    │
│   inputs:  stream requirements (period, size, deadline,    │
│            source, destination, redundancy)                │
│            topology + link speeds + per-hop delays         │
│   output:  gate control lists per port                     │
│            launch times per talker                         │
│            Qci policing parameters                         │
│            admit / reject with a diagnosis                 │
└────────────────────────────────────────────────────────────┘
```

**Why userspace is the right place:**

- The computation is a constraint-satisfaction problem (an ILP or SMT instance,
  or a heuristic for large networks). That is emphatically not kernel code.
- It's replaceable: try a different algorithm without touching the system.
- It's restartable — a scheduler crash doesn't disturb running streams, because
  the schedules are already programmed into the hardware.
- It's testable offline against a topology model with no hardware at all.
- It's the same shape as the schedulability analysis in Chapter 35 §10, and should
  produce the same kind of artifact: **a network schedule committed to the repo,
  diffable, with CI failing if a stream can't be admitted.**

### 4.1 Admission control, again

`net_flow_create` with `bandwidth_min` and `deadline` goes to the scheduler, which
either admits the stream and programs the gates, or refuses with a reason:

```
ERR_INFEASIBLE:
  reason        = NET_NO_SLOT_AVAILABLE
  bottleneck    = link "sw1:port3" (utilization 0.94 in class 6)
  suggestion    = period >= 500us, or class 5, or reduce payload to 512B
```

Same principle as Chapter 35 §2.1: the requirement was declared, so the system can
verify it and explain the failure. Compare configuring TSN on Linux today —
hand-computed `taprio` schedules in a shell script, with errors discovered by an
oscilloscope.

### 4.2 Extending the chain across the network

Chapter 35 §6's end-to-end chain gains a network stage:

```
sensor task (2ms) → [network: 1 hop, 200µs bounded] → control task (1ms)
                  → [network: 2 hops, 350µs bounded] → actuator
```

The chain's deadline decomposition now includes the network, and the network's
contribution is a *computed bound* rather than a measured average. The chain
instance id (Chapter 32 §5's trace id) can travel in a packet header, so the
tracing waterfall spans hosts. **That's a genuinely unified story — one requirement
model, one analysis, one trace, across CPU and wire** — and I'm not aware of any
system that provides it.

---

## 5. The real-time data path

Beyond scheduling, the stack itself must be bounded. Chapter 36 §8 lists the
rules; here's what they mean concretely for an RT flow:

- **Pre-established everything.** Flow state, buffers, ARP/neighbour entries,
  routes, and security keys are resolved at flow creation. A real-time frame must
  never trigger a lookup, a resolution, or a handshake.
- **No fragmentation, ever.** Fragment reassembly is unbounded state and unbounded
  time. Fix the MTU at admission and reject oversized messages at the API.
- **Bounded header processing.** No arbitrary option chains, no tunnels of
  unbounded depth, no recursive decapsulation.
- **Static receive dispatch.** A frame's flow is determined by the hardware's
  flow-steering rule (Chapter 36 §6), so the receive path is: DMA into the flow's
  queue, deliver. There is no lookup table walk and no shared state.
- **Poll, don't interrupt, for the lowest-latency queues** — but see §7, because
  polling costs power and a core.
- **Drop late data** (`NET_DROP_LATE`). Timeliness beats completeness.
- **No congestion control** on a scheduled flow: the network guaranteed the
  bandwidth, so probing for it is both pointless and harmful.

### 5.1 Redundancy (802.1CB)

For anything safety-related, single-path is unacceptable and retransmission is too
slow. FRER sends every frame over two disjoint paths with a sequence number; the
receiver takes the first and discards the duplicate. Recovery time from a link
failure is **zero** — there's no detection, no failover, no gap.

In Chapter 36's model this is a path-set property of the flow (`NET_REDUNDANT`),
which is exactly the kind of thing the identity/path separation in §3 of that
chapter was designed to make easy. On a socket API it would need a new protocol.

---

## 6. Beyond the standards

Where a workbench could push further:

**Deadline-aware transmission scheduling.** TSN schedules by *class* and by
*time slot*. Chapter 36's API carries a per-message deadline. A NIC queue could be
scheduled EDF over pending messages — which is strictly better for mixed traffic
than static class priorities, and there's no reason it can't be done in the
driver's transmit path today, without any hardware support. Nobody does this.

**Deadline propagation into the network.** Appendix E §E6: a request with 3 ms
remaining should be transmitted ahead of one with 30 ms, everywhere along the
path. Chapter 32's trace id already carries the request identity; adding the
absolute deadline to the header is a few bytes and makes every queue in the path
able to schedule properly. This is the network analogue of the CPU deadline
inheritance in Chapter 35, and it's an open, tractable, genuinely valuable
problem.

**Joint CPU/network scheduling.** Currently the CPU scheduler and the network
scheduler are separate and unaware of each other, so a task can be scheduled to
produce data 100 µs after its transmission slot. Chapter 35's task specs and §4's
network scheduler have the same inputs; solving them together is a well-posed
optimization problem, and no system attempts it.

**TSN over wireless and over the wide area.** 5G URLLC and Wi-Fi 7 have
deterministic modes; DetNet extends the ideas to routed networks. The interesting
question is whether the bound composes across heterogeneous segments.

---

## 7. Costs, honestly

State them, because TSN is often sold as free:

- **Bandwidth waste.** Reserved windows that go unused are lost. Guard bands cost
  up to 12 µs per gate close without preemption. A heavily-scheduled network may
  run at 50% utilization by design.
- **Configuration complexity.** The schedule must be globally consistent. Change
  one stream and you may need to recompute everything — which is why §4's tooling
  matters as much as the mechanism.
- **Hardware requirements.** Every switch in the path must support it. One
  best-effort switch and the guarantee is gone.
- **Polling costs a core and watts.** The lowest-latency receive path is a busy
  poll; that's a full core at 100% and a real power cost (Appendix D §1). Use a
  hybrid: poll while traffic is present, arm an interrupt when idle. Measure both.
- **The clock is a dependency.** Lose PTP sync and your deterministic network
  degrades to best-effort — hopefully detectably. Design the failure behaviour and
  test it, because it *will* happen.

---

## 8. Verification

Measurement here needs care: you cannot validate microsecond determinism with
software timestamps on the machine under test.

| Test | Asserts |
|---|---|
| `ptp_sync_quality` | Offset from grandmaster stays within ±200 ns over hours; log the distribution |
| `launch_time_accuracy` | Measured on a **second machine's** hardware RX timestamps: frames leave within ±X ns of the requested time |
| `gate_never_violated` | Over 10⁸ cycles, no frame transmitted outside its window |
| `latency_under_interference` | RT stream's p99.999 end-to-end latency with best-effort traffic saturating the link. **The headline number.** |
| `frer_zero_recovery` | Cut one path mid-stream; assert zero frames lost, zero gap |
| `admission_rejects_infeasible` | An unschedulable stream set is refused with a correct diagnosis |
| `holdover_degrades_gracefully` | Kill the grandmaster; assert degradation is detected and reported, not silently wrong |
| `no_allocation_rt_path` | Poison the allocator; run an RT flow at line rate |
| `chain_crosses_network` | End-to-end chain including network stages meets its deadline at p99.99 |

**Measure with external equipment where it matters.** Two NICs back to back with
hardware timestamps at both ends gets you most of the way; a hardware packet
capture with its own clock is better. An oscilloscope on the PHY is the ground
truth, and for a claim of "±200 ns" it's the only honest evidence.

---

## 9. Exercises

1. Get PTP hardware timestamping working between two machines with an i210 or
   i225. Plot the offset over 24 hours and tune the servo.
2. Implement `launch_time` on the transmit path. Measure accuracy from the
   receiver's hardware timestamps and plot the distribution.
3. Program a static gate control list on an i225 and verify with a capture that no
   frame ever escapes its window.
4. Build the network scheduler: given a topology and a stream set, produce gate
   lists. Start with a greedy heuristic; add an SMT-based version and compare
   schedulability.
5. Measure p99.999 latency of an RT stream with and without TSN enabled, under a
   saturating iperf-style load. This is the number that justifies the whole
   chapter.
6. Extend a Chapter 35 chain across two machines and verify the end-to-end
   deadline holds.
7. Implement EDF transmit scheduling in the driver (§6) and compare against strict
   class priority for mixed traffic.
8. Break PTP deliberately mid-experiment and confirm the system reports degraded
   determinism rather than continuing to claim guarantees.
9. **Argue the other side:** make the case that for most workloads, an
   overprovisioned best-effort network with good congestion control achieves
   better *practical* tail latency than a scheduled network running at 50%
   utilization. What measurement would settle it?

---

Next: [38 — NIC drivers: from e1000 to multi-queue](38-nic-drivers.md)
