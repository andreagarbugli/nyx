# 33 — Profiling and performance analysis

> Goal: find out where the cycles go, at the lowest overhead the hardware allows,
> with the kernel doing the minimum and an offline tool doing everything else —
> and with the results attributed to *requests* rather than only to threads, which
> a monolithic kernel cannot do.

---

## 1. The three questions, and the three tools

Don't conflate these. They need different mechanisms:

| Question | Tool | Mechanism |
|---|---|---|
| "What code is burning CPU?" | **Sampling profiler** | Periodic interrupt, record IP + stack |
| "Why is this *specific request* slow?" | **Tracing** (Chapter 32) | Timestamped events, causal chain |
| "Why is this thread not running?" | **Off-CPU analysis** | Scheduler events + block reasons |

Most performance problems in a microkernel are the second and third, not the
first. A component sitting idle waiting on an IPC reply shows up as *zero* CPU in
a sampling profiler while being entirely responsible for the latency. This is the
single most important thing to internalize: **CPU profiling answers throughput
questions; latency questions need tracing and off-CPU analysis.**

---

## 2. Sampling: the design

### 2.1 The mechanism

Periodic interrupt → record instruction pointer, stack, and context → append to a
ring → return. That's the entire hot path, and it must be a few hundred cycles.

Timer-based sampling has a fatal flaw for kernel profiling: it can't sample code
that runs with interrupts disabled, which is exactly your critical sections. Use a
**performance counter overflow delivered as an NMI**:

```c
/* Program a fixed counter (unhalted core cycles) to overflow every N cycles
   and deliver an NMI via the LAPIC PMI vector. */
wrmsr(IA32_FIXED_CTR0, -(int64_t)period);
wrmsr(IA32_FIXED_CTR_CTRL, FIXED0_ENABLE_ALL_RINGS | FIXED0_PMI);
wrmsr(IA32_PERF_GLOBAL_CTRL, FIXED0);
lapic_write(LAPIC_LVTPC, PMI_VECTOR);          /* delivered as NMI */
```

NMIs reach code with `cli` set. Note the hazards from Chapter 04: the NMI handler
runs on an IST stack, must be re-entrancy safe, must not take locks, and must
handle the swagger of arriving in the middle of `swapgs` (Chapter 10 §2 hazard 2).
Get this right or your profiler will be the thing that crashes the kernel.

**Sample period:** make it a *prime-ish* number of cycles, not a round one, or you
will alias with periodic activity in the system and produce beautifully wrong
results. 999983 cycles rather than 1000000.

### 2.2 What to record

```c
struct sample {
    uint64_t ip;
    uint64_t tsc;
    uint32_t tid;
    uint32_t cpu    : 8;
    uint32_t ctx    : 8;      /* kernel / user / irq */
    uint32_t nstack : 8;
    uint64_t trace_id;        /* Ch. 32 §5 — this is the good bit */
    uint64_t stack[MAX_DEPTH];
};
```

**No symbolization in the kernel.** Emit raw addresses plus, once, a map of
component load addresses. The offline tool resolves symbols from the ELF files and
DWARF. This keeps the handler tiny and means you can change your symbolization
strategy without touching the kernel.

### 2.3 Stack walking

Three options, in increasing order of quality and cost:

| Method | Cost | Works when |
|---|---|---|
| **Frame pointers** | ~10 cycles/frame | You compiled with `-fno-omit-frame-pointer` (Chapter 02 already says to). Simple, reliable. |
| **LBR** (Last Branch Records) | ~0 (hardware) | 16–32 entries; gives you call chains with no unwinding at all. Also gives branch mispredictions for free. |
| **DWARF CFI unwinding** | Expensive in-kernel | Best fidelity, no ABI cost. Do it *offline*: copy 8 KB of raw stack and unwind on the workstation. |

**Recommendation:** frame pointers now (you're already paying for them), LBR when
you want cheap accuracy, and consider the copy-stack-and-unwind-offline trick if
frame pointers ever become a measurable cost. Note that userspace components you
compile can also have frame pointers; that's a manifest-level build policy.

---

## 3. The PMU: beyond cycles

Cycle-based sampling tells you *where*. Performance counters tell you *why*:

| Counter | Diagnoses |
|---|---|
| Instructions retired | IPC (instructions/cycle) — the top-level health metric |
| L1D / L2 / LLC misses | Memory-bound code, false sharing, poor layout |
| **dTLB / iTLB misses** | Whether your huge-page direct map (Chapter 06) is working |
| Branch mispredictions | Unpredictable dispatch; the IPC fast path's branch structure |
| Stalled cycles frontend/backend | Whether you're instruction-fetch or data bound |
| `MEM_LOAD_RETIRED.*` with PEBS | The exact *data address* that missed |

**PEBS** (Precise Event Based Sampling) on Intel, and IBS on AMD, are worth real
attention: the hardware writes a record with the *precise* instruction pointer
(not skidded by pipeline depth) plus registers and, for memory events, the data
address and its latency. That turns "cache misses are hurting" into "this field of
`struct tcb` costs you 40 cycles per IPC" — which is directly actionable for the
cache-layout work in Chapter 07.

**Top-down analysis** (Yasin's methodology, and what `toplev` implements) is the
right framework: classify every cycle slot as retiring, bad speculation,
frontend-bound, or backend-bound, then drill down. It turns profiling from
guesswork into a decision tree. Implement the top-level four counters at minimum.

### 3.1 The `PerfCounter` capability

Profiling is a capability, for the same reason tracing is (Chapter 32 §6) — PMU
counters are a well-documented side channel, and letting any component measure any
other's cache behaviour is an information leak.

```
PerfCounter object:  a set of programmed counters, scoped to
                     (this thread | this component | this CPU | system-wide)
```

System-wide counting requires a capability one component holds. Self-counting
(a component measuring its own IPC) is safe and useful — hand it out freely.

This is a much cleaner model than `perf_event_paranoid`, which is a global integer
that everyone sets to the wrong value.

---

## 4. Request-attributed profiling — the thing Linux can't do

Combine §2 with Chapter 32 §5: every sample carries the `trace_id` of the request
the thread was working on.

Now you can ask questions that are simply unanswerable on a monolithic kernel:

- "For the class of requests that take > 10 ms, where are the cycles spent — and
  in *which components*?"
- "What fraction of the time in this request was on the critical path versus
  waiting?"
- "Which component's code is responsible for the p99, as opposed to the median?"

On Linux, a request crosses threads (a syscall, a kernel worker, a softirq, an
IRQ handler) and attribution is lost at every boundary. Here it survives, because
the boundary is IPC and the kernel is already mediating it.

**Critical-path analysis** falls out: given the causal chain of a slow request,
walk backwards from the response, and at each step ask whether the predecessor was
running or blocked. The chain of "blocked on X, which was running" segments is the
critical path. Everything else is parallel slack and optimizing it does nothing.

That analysis is a few hundred lines in the offline tool, and it is the single
most useful performance artifact you can produce. **This is the strongest
performance argument for the whole architecture** and it deserves to be
demonstrated rather than claimed.

---

## 5. Off-CPU analysis

A thread not running is invisible to a sampling profiler. Instrument the
transition instead — you already have the events (Chapter 32 §4.3):

```
sched_switch(prev=T, reason=BLOCKED_IPC_RECV, ep=E)   at t0
sched_switch(next=T)                                   at t1
→ T was off-CPU for (t1 - t0), blocked on endpoint E
```

Aggregate by *blocking reason and stack*, and you get an off-CPU flame graph: the
inverse of a CPU flame graph, showing where the waiting happens. Brendan Gregg's
work on this is the reference.

The categories you'll find, and what each means:

| Blocked on | Means |
|---|---|
| IPC receive (a server) | Idle — usually fine, this is a server waiting for work |
| IPC call (a client) | **On the critical path.** This is your latency. |
| Notification | An event you're waiting for; check the producer |
| Page fault → pager | Demand paging cost; measure the pager |
| Preempted (runnable, not running) | **Scheduling pressure — a red flag.** Someone is starving. |
| Timer | Intentional; verify it is |

That fifth row deserves an alarm: runnable-but-not-running time is the signal that
your priorities or budgets are wrong, and it's the one that connects to
Chapter 34's partitioning.

---

## 6. Microbenchmarking without lying to yourself

Chapter 08 asks for cycle counts on the IPC path. Getting them right is harder
than it looks:

```c
static inline uint64_t cycles_begin(void) {
    unsigned a, d;
    __asm__ __volatile__("lfence; rdtsc" : "=a"(a), "=d"(d) :: "memory");
    return ((uint64_t)d << 32) | a;
}
static inline uint64_t cycles_end(void) {
    unsigned a, d;
    __asm__ __volatile__("rdtscp" : "=a"(a), "=d"(d) :: "rcx", "memory");
    __asm__ __volatile__("lfence" ::: "memory");
    return ((uint64_t)d << 32) | a;
}
```

The discipline that separates a real number from a plausible one:

1. **Pin to a core** and disable migration.
2. **Lock the frequency** (disable turbo and P-state transitions), or your numbers
   drift with temperature. If you can't, report the frequency alongside.
3. **Warm up** — run the operation thousands of times before measuring; the first
   iterations are all cache and branch-predictor misses.
4. **Report the distribution**: min, p50, p99, max. **Never report only a mean.**
   The min is often the most informative number for a microbenchmark (it's the
   uncontended, cache-warm cost), and the p99 is what users feel.
5. **Run the baseline and the variant interleaved**, on the same day, on the same
   machine. Machine-to-machine and day-to-day variation exceeds most effects
   you're measuring.
6. **Beware layout noise.** Mytkowicz et al., "Producing Wrong Data Without Doing
   Anything Obviously Wrong!" (ASPLOS 2009) showed that changing an environment
   variable's length — which shifts stack alignment — can change measured
   performance by more than the optimization you're evaluating. Randomize link
   order across runs, or at minimum be suspicious of effects under ~5%.
7. **Measure the measurement.** Time an empty loop; subtract, or at least know
   the floor.

### 6.1 The CI performance harness

From Chapter 18, extended:

- A fixed set of microbenchmarks (IPC roundtrip same-core / cross-core, syscall
  entry/exit, context switch with and without address-space change, capability
  lookup, page fault, TLB shootdown, notification signal).
- Run on every commit on dedicated, quiesced hardware — **not** a shared CI
  runner, where variance will exceed every signal.
- Store results in the repo. Plot them. Fail the build on a regression beyond a
  threshold, *and* on an unexplained improvement (which usually means the
  benchmark broke).
- Because the results are per-commit, a regression is bisectable to the line.

The value of this compounds. Six months in, "when did IPC get 8% slower" is a
graph, not an investigation.

---

## 7. Hardware tracing

For control flow at a fidelity software can't reach:

**Intel Processor Trace (PT)** records every branch decision in a highly
compressed form (~1 bit per conditional branch) directly to memory, with
overhead typically under 5%. Decoded offline against the binary, it gives you the
**exact instruction-by-instruction execution history**. For a kernel this is
extraordinary: you can reconstruct exactly what happened in the microseconds
before a crash. `perf` uses it for `--call-graph` and for reverse debugging.

**ARM CoreSight ETM** is the equivalent.

Costs: the decoder is complex (Intel's `libipt` exists), the data rate is high
(hundreds of MB/s), and you need to correlate with the address-space map. Worth it
for: post-mortem "how did we get here", verifying that a fast path took the path
you think, and finding the rare-path bug that a sampling profiler will never catch.

Not a first-year project, but wire the buffer allocation in early, because
retrofitting is annoying.

---

## 8. Output formats and tooling

Same principle as Chapter 32: emit raw, convert offline.

| Format | Tool | Use |
|---|---|---|
| **Folded stacks** (`a;b;c 1234`) | `flamegraph.pl`, Speedscope | Flame graphs. Trivial to emit; start here. |
| **pprof** | `go tool pprof`, Speedscope | Aggregated profiles, diffing two profiles |
| **Chrome Trace JSON / Perfetto** | Perfetto UI | Timeline view combined with Chapter 32's spans |
| **Custom: critical path** | Your tool | §4's per-request analysis |

**Differential flame graphs** are worth calling out — render "profile B minus
profile A" with colour showing what got worse. That's how you evaluate an
optimization in one picture, and it catches the case where you sped up one thing
and slowed two others.

The single most valuable view for this system is the combined one: a Perfetto
timeline showing per-component spans (Chapter 32), with sampled stacks underneath,
filtered to one trace id. Everything else is a special case of that.

---

## 9. What to actually optimize in this kernel

Where the cycles are, roughly in order of return:

| Path | Target | Notes |
|---|---|---|
| IPC roundtrip | 300–600 cycles | Chapter 08. The headline number. |
| Syscall entry + exit | 80–200 | Chapter 10; mitigations dominate |
| Capability lookup | 5–20 | One bounds check + index in the common case |
| Context switch (same AS) | 100–300 | Chapter 07 |
| Context switch (+ CR3) | 500–1500 | PCID should cut this a lot — verify |
| Page fault → userspace pager | 2000–5000 | Expensive by design; measure it |
| TLB shootdown | 2000–20000 | Scales with CPU count; the optimization target for SMP |
| Notification signal | 50–150 | Should never allocate or block |

**The discipline:** each of these has a number in `docs/performance.md`, tracked
in CI, with a note on what dominates it. When someone (including future you)
proposes a change, the question "what does this do to the IPC number" has an
answer within a build.

---

## 10. Verification

| Test | Asserts |
|---|---|
| `pmi_handler_safe` | NMI-based sampler under stress; no crashes, no lost swapgs, correct on IST |
| `sampler_overhead` | < 1% at a 1 kHz sample rate; measured, not assumed |
| `no_allocation_in_sampler` | Poison the allocator during sampling |
| `stack_walk_correct` | Synthetic known call chain; assert the sampler recovers it exactly |
| `symbolization_roundtrip` | Offline symbolization matches a known map, including across component boundaries |
| `sample_attribution` | Samples taken during a traced request carry the right `trace_id` |
| `critical_path_correct` | A synthetic request with known blocking structure; assert the tool identifies the right critical path |
| `benchmark_variance` | Run the microbenchmark suite 100×; assert the run-to-run p99 spread is under threshold. **If this fails, every other performance number is noise.** |
| `counters_are_scoped` | A component without a system-wide `PerfCounter` capability cannot observe another's counters |

That variance test is the gate. Don't trust any performance result until it
passes.

---

## 11. Exercises

1. Implement PMU-overflow NMI sampling with frame-pointer stack walks. Emit folded
   stacks and produce your first flame graph of the kernel under an IPC benchmark.
2. Add `trace_id` to samples and build the per-request attribution view (§4).
3. Implement critical-path analysis and run it on the input-to-photon path from
   Chapter 23. Compare its answer to the latency waterfall's.
4. Implement off-CPU analysis and produce an off-CPU flame graph. Find one place
   where a thread is blocked longer than you expected.
5. Set up the CI performance harness on dedicated hardware. Run the variance test.
   Tune until it passes.
6. Use PEBS to find which cache line of `struct tcb` costs the most on the IPC
   path, then reorder the struct and measure the difference.
7. Do a top-down analysis of your IPC fast path. Determine whether it's frontend
   bound, backend bound, or retiring — and be surprised.
8. **Argue the other side:** a profiler with NMI handlers, PMU access, and stack
   walking is a large, privileged, security-sensitive mechanism inside a kernel
   whose entire thesis is minimality. Make the case that it belongs in userspace or
   nowhere, and design what a userspace-driven profiler would need from the kernel.

---

Next: [34 — Partitioning: resource isolation for real-time and mixed criticality](34-partitioning.md)
