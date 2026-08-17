# Appendix E — A research agenda for operating system design

> Goal: the open problems. Not "features Nyx could have" — Chapter 13 has those —
> but questions the field has not answered, framed so that a workbench like this
> one could actually attack them.
>
> Each entry: **the question**, why it's still open, what makes it tractable
> *now*, and what result would count as an answer. The last part is the one that
> matters; a project without a falsifiable claim is a hobby.

---

## Part I — Questions the field has been avoiding

### E1. What does a microkernel actually cost in 2026?

**The question.** Every argument about OS structure cites numbers from the 1990s
(Mach: catastrophic) or seL4 microbenchmarks (IPC: 300 cycles). Nobody has a
careful, modern, *application-level* comparison on current hardware with current
techniques: PCID, huge pages, MSI-X, IOMMU, batched rings, io_uring-style
submission, and 100+ Gb NICs.

**Why it's still open.** Doing it properly requires a microkernel system complete
enough to run a real workload, which almost nobody has, and an honest
methodology, which is harder than it sounds — the confounds (different
filesystems, different allocators, different NIC drivers) usually swamp the
structural difference.

**What makes it tractable now.** Chapter 13 §C2's trick: build *both* structures
in one codebase, sharing everything except the boundary. Then the only variable is
the boundary.

**What counts as an answer.** A table: for N real workloads, the cost of
componentization, decomposed into mode switches, cache/TLB effects, scheduling,
and copying. Plus the conditions under which it goes to zero (batching, direct
device access) and where it's irreducible.

**This is the most valuable and most achievable item in this appendix.** The
field would use the number for twenty years.

---

### E2. Is the syscall the right boundary at all?

**The question.** The trap-based syscall has been the kernel boundary since the
1960s. But: io_uring shows that batched shared-memory submission beats it;
FlexSC showed exception-less syscalls win by preserving cache locality; and on
current hardware the mode switch costs 100–500 cycles with mitigations.

So is the right interface (a) a trap, (b) a ring, (c) a call into a
same-address-space verified extension (eBPF's answer), (d) a message to a core
dedicated to kernel work (the multikernel answer), or (e) chosen per-operation?

**What makes it tractable now.** Nyx's capability model makes the ring version
*safe* in a way Linux's isn't (Chapter 13 §A2): a ring entry can only invoke
capabilities the process holds, so there's no credential re-derivation and no
confused deputy.

**What counts as an answer.** An implementation of at least three of those five,
measured across latency-sensitive and throughput-sensitive workloads, with an
analysis of where each wins. Plus a security analysis: the ring version's attack
surface versus the trap's.

---

### E3. What is the correct failure model for a multi-server OS?

**The question.** A multi-server OS is a distributed system on one machine. But
distributed systems have a precise vocabulary — crash-stop, crash-recovery,
omission, Byzantine — and formal results about what's achievable under each.
Multi-server OS work mostly says "the reincarnation server restarts it" and moves
on.

Unanswered: what consistency guarantee does a client get across a server restart?
What does "the filesystem restarted mid-write" mean for durability? Is
exactly-once IPC achievable, or do all protocols need idempotency? What's the
right analogue of a transaction?

**What makes it tractable now.** The failure domains are explicit (they're
components), the communication is explicit (it's IPC), and you can inject faults
precisely (Chapter 11 §6's chaos testing).

**What counts as an answer.** A formal model of the failure semantics, a mapping
from component structure to guarantees, and an implementation whose recovery
properties are *stated* rather than hoped for. Bonus: a checker that flags
protocols that aren't restart-safe.

---

### E4. Can a system's security policy be verified from its structure?

**The question.** In a capability system, the authority distribution is a finite
graph, established at boot from a manifest. So: given the manifest, can you
decide properties like "component A can never influence component B", "no
component can both read the private key and write to the network", or "the
following components can observe keystrokes"?

**Why it's still open.** It's a reachability problem, so it should be decidable —
but the semantics of each object type matter (an Endpoint transfers authority; a
Frame doesn't; a CNode with GRANT does), and the graph changes at runtime.
Existing work (CAmkES, seL4's access-control model, KeyKOS's factory) gestures at
this without producing a usable tool.

**What counts as an answer.** A tool that takes a manifest and produces a report
of information-flow properties, sound with respect to a stated model. Then apply
it to the graphical stack (Chapter 26 §1) and produce a document no shipping
system can produce: an exhaustive, machine-checked list of what can observe your
keystrokes.

**Difficulty: moderate. Value: very high.** This is the strongest practical
argument for the whole capability approach and it's currently unsubstantiated.

---

## Part II — Time, energy, and the resources nobody schedules

### E5. Energy as a first-class schedulable resource

**The question.** Schedulers allocate *time*. Nothing allocates *joules*. But on
a battery device, energy is the scarce resource, and on a datacenter machine it's
the dominant cost. What would an OS look like if the scheduler's currency were
energy?

Concretely: a scheduling context with a *joule* budget, not a time budget. A
component that exhausts its energy budget stops. Frequency and core selection
become part of the scheduling decision rather than a separate governor.

**What makes it tractable now.** RAPL gives per-package energy at ~1 ms
resolution; per-core estimates are derivable. Heterogeneous cores (Appendix D §9)
make the placement decision meaningful. Chapter 14's scheduling contexts already
provide the accounting mechanism — it's a change of unit.

**What counts as an answer.** An implementation of energy-budgeted scheduling,
plus a demonstration that it does something time-based scheduling cannot: e.g.,
guaranteeing a background task uses no more than X% of battery per hour, provably,
regardless of what it does.

**Nobody has built this.** It's a clean idea with a clear evaluation and it fits
this architecture unusually well.

---

### E6. End-to-end deadlines across components — and across the GPU

**The question.** Real-time theory handles a task on a CPU. It does not handle a
deadline that flows through five components, a shared-memory ring, a GPU queue
scheduled by device firmware, and a display controller.

Chapter 26 §3 poses the graphical version; it generalizes: **can a deadline be a
propagating property of a request, inherited by everything that works on it?**
This is priority inheritance generalized from locks to entire request chains.

**Why it's hard.** The GPU (and the NIC, and the storage controller) schedules
its own work with no notion of your deadlines. The firmware is closed. This is
partly a hardware/software co-design problem (§E11).

**What counts as an answer.** Deadline propagation implemented through IPC and
fences, with measured tail-latency improvement, and an honest characterization of
where the guarantee breaks (SMM, GPU firmware, device queues) — because the
boundary of what's schedulable is itself a useful result.

---

### E7. Time protection at acceptable cost

**The question.** Ge/Yarom/Heiser (Chapter 13 §B1) argued the OS should partition
time as it partitions memory, and showed it's partly achievable and partly
blocked by hardware that provides no way to reset microarchitectural state.

Open: what's the minimum-cost implementation on *current* x86 and ARM? What
channel bandwidth can you actually achieve (bits/second, measured, not asserted)?
How does it compose with a passive-server IPC model where domains switch
thousands of times a second? And what hardware support would make it cheap —
which is a concrete ask to put to CPU vendors.

**What counts as an answer.** Measured residual channel bandwidth versus measured
performance cost, across a range of mitigation strengths, on current silicon. A
Pareto curve, not a single point.

---

## Part III — Structure and hardware

### E8. What is the right OS for disaggregated and heterogeneous hardware?

**The question.** A modern machine is several computers: CPUs, GPUs, DPUs,
accelerators, CXL memory pools with different latencies, and SmartNICs running
their own OS. Coherence is partial. The shared-memory kernel model doesn't
describe this.

Barrelfish's multikernel and LegoOS's disaggregation each answered part. Nobody
has a design that handles *both* heterogeneity of compute and disaggregation of
memory, with a coherent programming model.

**What makes it tractable now.** CXL hardware exists. QEMU can emulate multi-node
setups. A message-passing microkernel is already the right shape — extending IPC
across a link is a transport change, not an architecture change (Chapter 13 §C5).

**What counts as an answer.** A system where a component's *placement* (which
core type, which node, which device) is a scheduling decision the OS makes, with
measured benefit, and a programming model that doesn't require the application to
know.

---

### E9. Automatic component placement from observed communication

**The question.** In a multi-server OS, performance depends heavily on which
components share a core, a cache, or a NUMA node. Currently a human guesses.

The IPC graph is *observable* — you already trace it (Chapter 18). So: can
placement be derived automatically? It's a graph partitioning problem with a clear
objective (minimize cross-domain communication cost subject to load balance), and
it's the kind of problem where a simple algorithm probably captures most of the
benefit.

**What counts as an answer.** Measured improvement over hand placement on a real
workload, plus a characterization of how stable the optimum is (does it need to
adapt continuously, or is it a boot-time decision?).

**Low difficulty, clear evaluation, no one has done it.** Good first project.

---

### E10. Does language-based isolation obsolete hardware isolation?

**The question.** Theseus and Singularity argue that if the language guarantees
memory safety, you don't need address spaces — and then "IPC" is a function call,
which removes the microkernel's entire cost.

Open: what's the *actual* performance difference, measured in one system with
identical semantics on both sides? What does the language-isolated version lose
(unsafe code, compiler trust, no defense against hardware faults or malicious
compilers)? Can you mix them per-component based on trust?

**What makes it tractable now.** Rust is mature; you can build both isolation
mechanisms behind one component interface and switch per-deployment.

**What counts as an answer.** The measurement, done honestly, in one codebase —
which no existing comparison has, because they always compare two different
systems and confound everything.

---

### E11. What should hardware provide for a microkernel?

**The question.** CPUs are designed for monolithic kernels. What would you ask
for if you designed the ISA for a message-passing, capability-based system?

Candidates: hardware capability registers (CHERI does part of this), a fast
protection-domain switch that doesn't flush predictors, tagged memory, a message
send/receive instruction pair, hardware-assisted scheduling context switching,
per-domain microarchitectural state reset (§E7), and asynchronous notification
delivery without an interrupt.

Some of this has been tried (Mondrian memory protection, CODOMs, the Mill's
portals, ARM's memory tagging). None has been evaluated in the context of a
complete capability OS.

**What makes it tractable now.** RISC-V. You can add instructions, simulate them
in QEMU or gem5, port Nyx, and measure. That path did not exist ten years ago.

**What counts as an answer.** A proposed ISA extension with a measured benefit on
a real system and a plausible implementation cost estimate. This is the kind of
result that changes hardware.

---

## Part IV — Correctness

### E12. Verification at a useful cost

**The question.** seL4 proved a kernel correct in ~20 person-years. That's not
reproducible for every system. What's the *best* correctness-per-effort curve?

Open sub-questions: how much does modern automation (CBMC, SMT solvers, Rust's
type system, refinement types) reduce the cost? Can you verify *properties*
(no buffer overflow, no deadlock, information flow) rather than full functional
correctness, at a small fraction of the cost? What about verifying *drivers*,
which are where the bugs actually are and which nobody has verified?

**What counts as an answer.** A documented effort/assurance curve: "these
properties, this technique, this many hours, this much of the codebase covered."
Concrete and immediately useful to every systems project.

---

### E13. Can drivers be synthesized or verified from device specifications?

**The question.** Drivers are the majority of kernel code and the majority of
kernel bugs. They're also mostly mechanical: a state machine over a register
interface. Devil, NDL, and Termite attempted synthesis from formal device
specifications in the 2000s and the work largely stopped.

Why revisit: hardware descriptions are more machine-readable now; formal methods
are cheaper; and in a microkernel, a driver is an isolated userspace process, so a
*partially* correct synthesized driver is safe to try — the failure is contained.
That containment is what makes the idea practical in a way it wasn't for a
monolithic kernel.

**What counts as an answer.** A synthesized driver for a real device that works,
plus an account of what fraction of the driver the specification captured and what
had to be written by hand. Even "60% synthesized" would be a significant result.

---

### E14. Deterministic execution as a system property

**The question.** Can a whole OS be made deterministic — same inputs, same
execution, bit for bit — at acceptable cost? Chapter 13 §C6 sketches it.

Why it matters beyond debugging: deterministic replay gives you fault tolerance
(replay on a spare), security forensics (replay the intrusion), and testing
(replay a fuzzer's finding forever). It also makes the multi-server failure model
(§E3) empirically checkable.

**What makes it tractable.** The nondeterminism sources in a microkernel are
enumerable and few. In a partitioned design (Chapter 12), the worst one —
arbitrary SMP interleaving — largely disappears.

**What counts as an answer.** Measured overhead of full-system deterministic
record/replay, and the list of nondeterminism sources you couldn't eliminate.

---

## Part V — Things nobody is working on

A shorter list of ideas I think are genuinely under-attacked:

**E15. Distributed tracing for an OS.** Attach a trace id to every IPC, propagate
it, and reconstruct the causal chain of any user-visible action across every
component. Microservices have this; operating systems don't, because monolithic
kernels can't produce it. A multi-server OS can. "Why did this keystroke take
80 ms?" would have an answer, in a waterfall, automatically. **Low difficulty,
high value, obviously useful.**

**E16. Durability as a typed property.** The `fsync` problem (Appendix D §5): no
application knows what durability it has. What if a handle's type declared it —
`Durable<Ordered>` versus `Volatile` — and the compiler checked it? Crash
consistency becomes a type system problem.

**E17. Capabilities across machines.** What is a capability to an object on
another host? You need unforgeability over a network (cryptographic), revocation
(hard — the classic problem), and a failure model. Solving this well would unify
OS and distributed security, which are currently separate fields with separate
vocabularies.

**E18. The OS as a target for program synthesis and ML policy.** Not "ML in the
kernel" as a buzzword: specifically, policies that are currently hand-tuned
heuristics with decades of accumulated magic numbers (readahead, page reclaim,
frequency governors, placement). Each is a small prediction problem with an
abundant training signal. The obstacle is that ML policies are non-reproducible
and unbounded, which conflicts with everything Chapter 14 wants — so the real
research question is: **what's the right way to use a learned policy inside a
system that must remain predictable and debuggable?** That framing is more
interesting than the application.

**E19. Post-quantum in the boot chain.** Secure boot, attestation, and firmware
signing all use signatures with 20-year deployment lifetimes. The migration is a
systems problem (larger keys, larger signatures, firmware flash constraints) that
nobody has worked through end to end for an OS.

**E20. What replaces the process?** The UNIX process bundles: an address space, a
thread, a security identity, a resource budget, a file descriptor table, and a
unit of failure. Nyx already unbundles most of it (Chapter 07). Taken further:
what *should* the units be, given that modern software wants isolation
granularities from a WASM module to a VM? A defensible answer with an
implementation would be a real contribution — the process has gone unexamined for
fifty years.

---

## How to pick one

Some practical filtering, since this list is long and a person is finite:

1. **Prefer a question with a measurement.** If the outcome is a number, you'll
   know when you're done and others can check you. §E1, §E5, §E7, §E9, §E10, §E14
   all have this shape.
2. **Prefer one where Nyx has a structural advantage.** §E4 (capabilities make
   the graph analyzable), §E15 (IPC makes causality observable), §E13
   (containment makes synthesis safe) are things a monolithic kernel *cannot*
   easily do. That's where your work is not replaceable.
3. **Prefer one where the negative result is also publishable.** "I built energy
   budgeting and it doesn't help because X dominates" is useful. "I built a faster
   IPC path and it wasn't faster" is useful. Both save someone else a year.
4. **Check the size.** §E1, §E9, §E15 are months. §E4, §E5, §E13 are a year.
   §E8, §E11, §E12 are theses. §E17 is a career.
5. **Write the evaluation plan first.** Before any code: what will I measure,
   against what baseline, and what result would tell me I'm wrong? If you can't
   write that page, the question isn't ready.

---

## The meta-point

The reason this list is long is that operating systems research went quiet for
about fifteen years while the industry consolidated on Linux, and the assumptions
underneath that consolidation — uniform cores, coherent shared memory, a trusted
kernel, a trap-based syscall, time as the only scheduled resource, drivers written
by hand — have *all* changed since. Most of the questions above are open not
because they're intractable but because the field stopped asking.

A workbench that can boot, measure honestly, and be modified in an afternoon is
the tool for asking them. That's what you've been building.

---

← [Back to the index](README.md) · [Bibliography](20-bibliography.md)
