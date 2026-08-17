# 35 — APIs for real-time programming

> Goal: design the interface a real-time application actually writes against.
> POSIX's real-time extensions are thirty years old and encode a solution
> (priorities) rather than a requirement (deadlines), which is the root of almost
> everything wrong with them. This chapter proposes the inversion, and several
> things that follow from it.
>
> Chapter 14 built the mechanism and Chapter 34 built the isolation. This is the
> part the programmer touches.

---

## 1. What POSIX real-time gets wrong

Not sloppiness — these are consequences of a 1993 design that assumed a
single-kernel, uniprocessor, fixed-priority world.

| Problem | POSIX | Consequence |
|---|---|---|
| **Priority is a solution, not a requirement** | `SCHED_FIFO` + an integer | The system knows *what you want it to do* but not *what you need*. It cannot verify, admit, or reason. Every priority assignment is a human doing rate-monotonic analysis in their head, then not writing it down. |
| **No admission control** | None | You discover infeasibility in the field |
| **No overrun semantics** | None (`SCHED_DEADLINE` throttles, silently) | A task that exceeds its WCET either steals time or is starved, with no hook to degrade gracefully |
| **Priority is ambient and global** | `sched_setscheduler`, needs `CAP_SYS_NICE` | Any RT process can starve the machine; the fix is a privilege check, i.e. ambient authority |
| **Periodic tasks are hand-rolled** | `clock_nanosleep(TIMER_ABSTIME)` in a loop | Every project writes the same drift-accumulating bookkeeping, usually with a subtle bug, and no notification when a period is missed |
| **No timing contract on calls** | None | `malloc`, `printf`, a page fault, or any syscall may block unboundedly. Nothing declares or checks this. |
| **Memory is all-or-nothing** | `mlockall(MCL_FUTURE)` | And it still doesn't stop lazy PLT binding, stack growth, or COW faults |
| **Priority inheritance doesn't cross IPC** | Per-mutex only | Useless in a multi-server system where the "lock" is a server |
| **No composition** | None | Two independently-correct components may not be schedulable together, and nothing tells you |
| **The unit is a task, but the requirement is a chain** | None | Real requirements are sensor→actuator end-to-end; the API can only describe individual tasks |
| **No mode changes** | None | Startup / normal / degraded transitions are a well-studied problem with no API |
| **Signals** | `SIGRTMIN`+ | Asynchronous, unbounded, and unsafe in almost every context |

The single most important row is the first. **Priority is an encoding of a
scheduling decision that a human made from timing requirements they didn't write
down.** Everything downstream — no admission control, no verification, no
composition, no useful error message — follows from having discarded the
requirement and kept only the answer.

---

## 2. The inversion

> **Declare the requirement. Let the system derive the schedule, verify
> feasibility, and tell you precisely why if it can't.**

```c
struct rt_task_spec {
    uint32_t size;                  /* versioned, Chapter 17 */

    /* the requirement */
    nanos_t  period;                /* activation interval */
    nanos_t  deadline;              /* relative to activation; 0 = period */
    nanos_t  budget;                /* declared WCET */
    nanos_t  jitter_max;            /* tolerable release jitter; 0 = don't care */

    /* what to do when reality disagrees */
    uint8_t  criticality;           /* RT_HARD | RT_FIRM | RT_SOFT | RT_BEST_EFFORT */
    uint8_t  on_overrun;            /* NOTIFY | TRUNCATE | DEGRADE | SUSPEND */
    uint8_t  on_deadline_miss;      /* NOTIFY | SKIP_NEXT | MODE_CHANGE */

    /* placement constraints — see §11 */
    uint8_t  core_class;            /* ANY | PERFORMANCE | EFFICIENCY | pinned */
    uint32_t core_mask;
};

MUST_USE err_t rt_task_create(cptr_t partition, const struct rt_task_spec *,
                              void (*entry)(void *), void *arg, rt_task_t *out);
```

Priorities are **not in this struct**. The scheduler derives them (rate-monotonic,
deadline-monotonic, or EDF, per the partition's policy from Chapter 34 §6). If you
later change from fixed-priority to EDF, no application changes.

### 2.1 Admission control that explains itself

`rt_task_create` performs schedulability analysis against the partition's existing
task set and **can fail**:

```c
err_t e = rt_task_create(part, &spec, control_loop, NULL, &t);
if (e == ERR_INFEASIBLE) {
    struct rt_infeasibility why;
    rt_why_infeasible(part, &spec, &why);
    /* why.reason      = RT_UTILIZATION_EXCEEDED
       why.utilization = 1.13            (need <= 1.0 for EDF)
       why.blocking_task = "logger"      (the task whose blocking term dominates)
       why.suggest_budget = us(160)      (the largest budget that would fit)  */
}
```

That error message is the whole point. Compare the POSIX experience: you set
priority 80, it seems fine, and eight months later a customer sees a 4 ms spike.
Here the system refuses at startup and tells you the utilization is 1.13 and which
task is the problem.

**This is a genuine advance and it's not hard** — response-time analysis for
fixed-priority and utilization bounds for EDF are a few hundred lines of textbook
arithmetic. The reason no OS does it is that no OS has the requirements to analyze,
because the API discarded them.

### 2.2 Timing authority is a capability

`rt_task_create` takes a partition capability. The budget comes out of that
partition's `SchedContext` (Chapter 14), subdividing it. Consequences:

- There is no global priority space and no `CAP_SYS_NICE`. A component cannot
  raise its own urgency; it can only subdivide what it was given.
- Delegation is natural: a component hands a child a portion of its budget.
- Revocation works: take the capability back and the task stops being schedulable.
- The whole timing configuration of the system is visible in the manifest.

---

## 3. Activation: the periodic loop, done once, correctly

```c
static void control_loop(void *arg) {
    rt_task_t self = rt_self();
    for (;;) {
        struct rt_activation act;
        rt_wait_activation(self, &act);       /* drift-free, absolute, system-managed */

        if (act.missed_periods) {             /* you were late; how late, and why */
            handle_overrun(act.missed_periods, act.lateness_ns);
        }

        read_inputs();
        compute();
        write_outputs();

        rt_end_activation(self);              /* publishes LET outputs; §5 */
    }
}
```

What the system provides that a hand-rolled `clock_nanosleep` loop does not:

- **No drift.** The next release is `release_0 + n * period`, computed by the
  kernel in absolute time. There is no accumulating error and no way to write the
  bug.
- **Missed activations are reported**, not silently coalesced. `missed_periods`
  and `lateness_ns` are the data you need to decide whether to catch up or skip.
- **Release jitter is measured** against `jitter_max` and reported.
- **Actual execution time is measured** every activation, compared to the declared
  budget, and fed to §10's tooling. Your declared WCET is continuously validated
  against reality — in production, not just in a lab.

Non-periodic tasks get the same shape with a different release source:

| Release source | API | Analysis model |
|---|---|---|
| Periodic | `period` in the spec | Standard periodic task |
| Sporadic (event, with a minimum interarrival) | `rt_task_create_sporadic(..., min_interarrival)` | Sporadic task; the system **enforces** the minimum, which is what makes it analyzable |
| Aperiodic / best effort | Background budget | Served by a bandwidth-preserving server |
| Chained (triggered by another task's completion) | §6 | Part of an end-to-end chain |

That enforcement of minimum interarrival is important: a sporadic task's analysis
depends on an assumption about the environment, and the system *policing* that
assumption converts "we assume the sensor fires at most every 5 ms" from a comment
into a mechanism.

---

## 4. What must be forbidden, and how to check it

Every real-time programmer knows the list of things you must not do in an RT path.
No system checks it. That's the second big gap.

| Sin | Why | Mechanism that catches it |
|---|---|---|
| Dynamic allocation | Unbounded, may fault | `rt_safe` attribute + call-graph check |
| Page faults | Milliseconds | Pre-fault and pin at task creation; kernel refuses to start an RT task with unpinned pages |
| Unbounded loops | Obviously | Static analysis / review; loop bounds annotated |
| Priority-inverting locks | Unbounded blocking | Ceiling protocol enforced, or no shared locks (§7) |
| Blocking IPC to a lower-priority server | Unbounded | Passive servers (Chapter 14) make it structurally impossible |
| `printf` / logging | Locks, allocation, I/O | RT-safe logging only (§8) |
| Lazy symbol binding (PLT) | First call faults into the linker | Full RELRO / static linking, checked at load |
| Stack growth | Faults | Pre-committed stacks, checked size |
| Floating-point in a context that lazily saves FPU state | A fault | Eager FPU save (Chapter 07) — already done |

### 4.1 `rt_safe`: making it mechanical

Declare the property in the type system, verify it at link time:

```c
#define RT_SAFE __attribute__((annotate("rt_safe")))

RT_SAFE void   control_step(struct plant *p);
RT_SAFE void  *arena_alloc(arena *a, size_t n, size_t align);   /* bump: bounded */
/*  not RT_SAFE: */ void *kmalloc(size_t);
```

Then a build step walks the call graph:

> For every function marked `RT_SAFE`, every function it can transitively reach
> must also be `RT_SAFE`. Indirect calls must go through a function pointer whose
> type is `RT_SAFE`. Fail the build otherwise.

This is a few hundred lines over LLVM IR or over the linked binary's relocations.
And crucially, **the system ABI declares which of its own calls are RT-safe** —
your IDL (Chapter 10 §7) marks each method, and the generated stubs carry the
annotation through. So "is this system call safe to make from my control loop?"
becomes a compile error rather than a paragraph in a manual that nobody reads.

I don't know of an OS that does this. It's cheap, it's checkable, and it converts
the most common class of real-time bug — "something in this path blocked" — from a
field failure into a build failure. **If you build one novel thing from this
chapter, build this.**

---

## 5. Logical Execution Time

The subtle problem: even a task that always meets its deadline produces *jittery*
data flow, because it writes its outputs whenever it finishes — sometimes 100 µs
into the period, sometimes 900 µs. Downstream consumers see varying delay, and a
control loop's stability depends on the delay being constant, not merely bounded.

**Logical Execution Time** (from Giotto, and now widely used in automotive):

> Inputs are sampled at the *start* of the activation. Outputs become visible at
> the *end* of the activation interval, regardless of when the computation
> actually finished.

```c
rt_wait_activation(self, &act);     /* inputs snapshot here */
compute();                          /* takes 100 µs or 900 µs — doesn't matter */
rt_end_activation(self);            /* outputs published at the period boundary */
```

What this buys, and it's a lot:

- **Zero output jitter.** The observable timing is exactly the declared period.
- **Composition becomes timing-independent.** Two LET components connected have a
  data flow determined entirely by their declared periods, so you can reason about
  the chain without knowing execution times.
- **Determinism.** The same inputs produce the same outputs at the same logical
  times — on a faster CPU, on a different core, in simulation. This makes the
  system testable in the sense of Chapter 13 §C6.
- **Migration and re-mapping are safe.** Moving a task to a different core (or a
  different machine) doesn't change observable behaviour, as long as it still
  meets its deadline.

Cost: one period of latency, and double-buffered outputs. For control loops that
trade is almost always correct, and it's why the automotive industry adopted it.

Make it a per-task flag (`RT_LET`), not a mandate — a sensor-to-actuator path that
needs minimum latency may prefer immediate publication and accept the jitter.
**Offering both, with the tradeoff stated in the API, is the design.**

---

## 6. End-to-end chains as the unit of requirement

The actual requirement in a real system is never "task X runs every 1 ms." It's
"from the sensor sample to the actuator command, no more than 5 ms, with no more
than 500 µs of variation." Automotive calls these *cause-effect chains*, and the
gap between that requirement and per-task APIs is where a lot of real engineering
pain lives.

Declare the chain:

```c
struct rt_chain_spec {
    uint32_t size;
    nanos_t  end_to_end_deadline;
    nanos_t  max_variation;             /* jitter of the end-to-end latency */
    uint8_t  semantics;                 /* FIRST_TO_FIRST | LAST_TO_LAST | REACTION */
    uint16_t n_stages;
    struct { rt_task_t task; uint16_t next; } stages[];
};

MUST_USE err_t rt_chain_create(cptr_t partition, const struct rt_chain_spec *,
                               rt_chain_t *out);
```

Then the system can:

1. **Decompose the end-to-end budget** into per-stage budgets and deadlines,
   rather than making a human do it with a spreadsheet.
2. **Verify** that the composition meets the end-to-end requirement, including the
   sampling delays between stages (this arithmetic is error-prone and mechanical —
   exactly what a tool should do).
3. **Propagate deadlines** at runtime (Chapter 26 §3, Appendix E §E6): every stage
   inherits the chain's absolute deadline, so a stage that's running late gets
   scheduled accordingly rather than treated as an independent task.
4. **Measure end-to-end latency directly**, because the chain instance id is
   exactly Chapter 32 §5's trace id. **The tracing infrastructure and the real-time
   chain are the same mechanism.** You get a p99 end-to-end latency histogram per
   chain for free.

That last point is the nice convergence: causal tracing was built for debugging,
and it turns out to be the runtime representation of an end-to-end timing
requirement.

Note the `semantics` field — "end-to-end latency" has several inequivalent
definitions (first-to-first, last-to-last, reaction time, age) and confusing them
is a classic source of arguments between engineers. Make the API force the choice.

---

## 7. Sharing without inversion

The RT-safe way to share state between tasks, in preference order:

1. **Don't.** Message passing with bounded queues (Chapter 08 rings). No blocking,
   no inheritance needed, and the analysis is straightforward.
2. **LET double buffering** (§5). A writer publishes at period end; readers see a
   consistent snapshot. No lock at all.
3. **Wait-free single-writer patterns**: seqlock for small structures, or a
   triple-buffer for a producer/consumer with different rates. Readers never block;
   the writer never blocks.
4. **Passive servers** (Chapter 14): the shared state lives in a server with no
   scheduling context of its own; callers donate theirs. Priority inversion is
   structurally impossible because there's no server priority to invert. **This is
   the microkernel's best answer and it should be the default for anything
   complex.**
5. **Immediate ceiling priority protocol**, if you must have a lock: blocking is
   bounded by one critical section, deadlock is impossible, and the ceiling is
   computed by the build from the declared task set — not by a human.

Note that (4) makes POSIX's `PTHREAD_PRIO_INHERIT` largely unnecessary, and it
works *across* components, which POSIX mutexes cannot.

---

## 8. The RT-safe subset of the system

An RT API is only as good as what it lets you call. Declare, for every system
service, whether it's RT-safe and what its bound is:

| Service | RT-safe? | Bound |
|---|---|---|
| IPC call to a passive server | Yes | Server's declared WCET + transfer |
| IPC send (non-blocking) | Yes | O(1), no allocation (Chapter 08 §7) |
| Notification signal | Yes | O(1) |
| Ring enqueue/dequeue | Yes | O(1) |
| Arena allocation | Yes | O(1) bump (Appendix B §3) |
| `rt_log` (lock-free ring) | Yes | O(size); Chapter 32's tracing ring *is* RT-safe by construction |
| Reading the monotonic clock | Yes | vDSO-style page read, no syscall (Appendix D §2) |
| Capability invocation | Yes | O(depth), constant depth |
| `Untyped_Retype` | **No** | Zeroing is O(size) |
| Capability revoke | **No** | Preemptible but unbounded (Chapter 09 §3) |
| Page mapping | **No** | May need intermediate tables |
| Anything reaching a non-RT component | **No** | Unbounded by definition |

Publish this table in `docs/rt-abi.md`, generate the `RT_SAFE` annotations from
it, and let §4.1's checker enforce it. Now the boundary between RT and non-RT code
is a mechanically enforced property of the program rather than a convention.

The pleasant discovery here: **most of the system is already RT-safe**, because
Chapter 08 demanded that IPC never allocate, Chapter 09 removed the kernel heap,
and Chapter 32's tracing ring was designed for the same constraints. The
architecture converged on real-time safety without being asked to.

---

## 9. Modes

Real systems have modes — initialization, normal, degraded, shutdown — with
different task sets. Mode change is a well-studied real-time problem (the
transition itself must be schedulable) and has no API anywhere.

```c
rt_mode_t modes[] = { MODE_INIT, MODE_NORMAL, MODE_DEGRADED };
/* each mode declares its task set; the build verifies each is schedulable,
   and that every declared transition is feasible under a stated protocol */
rt_mode_request(partition, MODE_DEGRADED, RT_TRANSITION_AT_PERIOD_BOUNDARY);
```

Transition protocols to support: complete all in-flight activations first, abort
immediately, or a phased handover. The build verifies the *transition* — the
window where both task sets partially exist — which is the part everyone gets
wrong.

This pairs with `on_overrun = RT_DEGRADE`: a task exceeding its budget triggers a
mode change into a degraded configuration that is *known to be schedulable*,
rather than an ad-hoc scramble. That's the mixed-criticality story (Chapter 34 §4)
made concrete and usable.

---

## 10. Schedulability as a build artifact

Tie it to the manifest theme (Chapter 30 §5):

```
manifest (tasks, chains, budgets, modes)
   → build-time analysis
       ├─ response-time analysis per task
       ├─ end-to-end chain verification
       ├─ mode-transition feasibility
       ├─ RT_SAFE call-graph check
       └─ measured-WCET comparison against declared budgets
   → schedulability report, committed to the repo
   → CI fails if infeasible, or if a measured execution time exceeds 80% of budget
```

Properties worth having:

- **A timing regression fails the build**, the same way a test failure does.
- The report is a **diffable artifact**: a PR that adds 40 µs of work to a task
  shows up as a utilization change in the diff.
- **Measured vs declared** is tracked continuously (§3), so budgets that were
  guessed optimistically surface before deployment rather than after.
- For certification (Chapter 34 §8), this report *is* a large part of the timing
  evidence.

WCET itself remains hard — static analysis is pessimistic and unavailable for most
hardware, measurement is unsound. The pragmatic combination: measurement-based
estimation with the trace infrastructure, a safety margin, continuous validation
in production, and static analysis only for the genuinely certified paths.

---

## 11. Future-proofing

The things a 2026 design must anticipate that POSIX couldn't:

**Heterogeneous cores.** A WCET on a P-core is not a WCET on an E-core — often 2×
different. So a budget must be *per core class*, and the `core_class` field in the
spec is not an optimization hint but part of the timing contract. A task migrating
between core types without re-analysis is a bug the system should refuse.

**Accelerators in the chain.** A control loop that runs inference on a GPU or NPU
has a stage the CPU scheduler doesn't control (Chapter 25 §7.2). The chain API
should express it as a stage with a budget, even if the current enforcement is
only monitoring. Getting real guarantees through accelerator firmware is Appendix
E §E6 and remains open — but the *API* should be ready for the answer.

**Energy budgets.** Appendix E §E5: a task spec with a joule budget alongside its
time budget. On a battery-powered or thermally-limited device, thermal throttling
silently invalidates every WCET you measured — so the timing model and the energy
model are not separable. Leave room in the struct.

**Distributed real-time.** TSN (802.1Qbv time-aware shaping) and PTP give
bounded-latency networking. A chain crossing machines (Chapter 28) with a
synchronized clock is exactly the same model, with the network as a stage. The
chain abstraction extends without change, which is a good sign it's the right one.

**Variable-rate execution.** Engine-synchronous tasks (activated per crankshaft
revolution, not per millisecond) and adaptive-rate control loops. The activation
source should be pluggable, not hardcoded to a timer.

---

## 12. Verification

| Test | Asserts |
|---|---|
| `admission_rejects_infeasible` | A task set exceeding the bound is refused, with the correct diagnosis |
| `admission_accepts_feasible` | A set at 99% utilization under EDF is admitted and meets all deadlines |
| `no_drift` | A 1 ms task over 10⁷ activations: release times exactly `t0 + n·period`, cumulative error zero |
| `missed_activation_reported` | Deliberately overrun; assert `missed_periods` and `lateness_ns` are exact |
| `budget_overrun_delivers_exception` | Exceed the budget; assert the handler runs and the system doesn't die |
| `let_zero_jitter` | Under LET, output timestamps have zero variance regardless of compute time. **The headline LET test.** |
| `rt_safe_check` | A task calling `kmalloc` from an `RT_SAFE` path fails the build |
| `chain_end_to_end` | Measured end-to-end latency of a 4-stage chain is within the declared deadline at p99.99, under Chapter 34's adversaries |
| `no_priority_inversion` | A low-criticality task holding a shared resource never delays a high-criticality one beyond the ceiling bound |
| `mode_transition_meets_deadlines` | No deadline missed *during* a mode change |
| `measured_within_budget` | Production measurement never exceeds declared WCET; tracked in CI |
| `sporadic_enforced` | An event source firing faster than its declared minimum interarrival is policed, not permitted to break the analysis |

---

## 13. Exercises

1. Implement `rt_task_spec`, `rt_wait_activation`, and admission control with
   response-time analysis. Write the `no_drift` test and run it for an hour.
2. Implement `rt_why_infeasible`. Make its output good enough that a colleague
   could fix the problem from the message alone.
3. Implement the `RT_SAFE` call-graph checker. Run it on your existing components
   and report how many violations it finds.
4. Implement LET with double-buffered outputs. Measure output jitter with and
   without, under variable compute load. Plot both.
5. Build a 4-stage chain (simulated sensor → filter → control → actuator), declare
   an end-to-end deadline, and verify the system's budget decomposition against
   your own by hand.
6. Implement deadline propagation along the chain and measure the p99.9 improvement
   versus independent per-task scheduling.
7. Take a real POSIX real-time program (an audio callback, or a PREEMPT_RT control
   loop) and port it. Count the lines that disappeared and the assumptions that
   became explicit.
8. Wire the schedulability report into CI as a committed artifact. Make a PR that
   adds work to a task and look at the diff.
9. **Argue the other side:** priorities are simple, universally understood, and
   supported everywhere; declarative timing requires the system to be right about
   analysis, and an analysis bug becomes a system that refuses to run correct
   programs. Make the case for keeping priorities as the primary interface, with
   requirements as optional metadata. Then decide which you'd ship.

---

← [Back to the index](README.md)

Next: [36 — Networking: beyond sockets](36-networking.md)
