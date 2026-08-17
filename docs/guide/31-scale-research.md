# 31 — Research directions: composability and scale

> Goal: the open questions specific to Part VIII, and a milestone plan. Appendix E
> has the field-wide agenda; this chapter is what's newly askable *because* the
> same system spans a microcontroller and a cluster.

---

## 1. Why spanning the range is itself the research instrument

Most claims in systems research are untestable because the comparison is between
two different systems built by two different teams with two different sets of
unrelated decisions. The confounds swamp the effect.

A single codebase that runs at every scale removes the confound. It lets you ask
questions of the form "**does this abstraction survive a 10⁶× change in
resources?**" — and an abstraction that does is telling you something real about
the problem, while one that doesn't is telling you where the actual boundaries
are.

That framing generates the following questions.

---

## 2. Is one abstraction really enough? ★★★

**The question.** Chapter 27 claims the capability/IPC model degrades gracefully
from 32 KB to a datacenter. Is that *true*, or does it hold only because the small
end is a stripped-down subset that shares a name and little else?

**How to test it, precisely.** Measure the degree of sharing:

- What fraction of kernel source lines are compiled into *every* profile?
- What fraction of the IPC, capability, and scheduler code is identical?
- How many `#ifdef`s or `arch_ops` indirections separate them, and what do they
  cost at each end?
- Can a component built for N0 run on N4 unmodified, and vice versa where the
  resource envelope permits?

**What counts as an answer.** A quantified report. "84% of kernel code is shared
across all five profiles; the divergence is entirely in address-space management;
the N0 IPC path is 140 cycles versus 190 on N3." Nobody has published that for any
system, and the number is interesting whether it's high or low.

**Why it matters beyond this project:** if it's high, it's an argument that the
embedded/server split in operating systems is historical rather than necessary,
which would be a genuinely significant claim.

---

## 3. Distributed capabilities with revocation and partition tolerance ★★★★★

Appendix E §E17, sharpened by Chapter 28 §2.

**The question.** Local capabilities give you unforgeability, delegation,
attenuation, and *prompt revocation*. Cryptographic bearer tokens give you the
first three across a network and lose the fourth. Proxies give you all four and
lose partition tolerance and add latency. Is there a design with all of it?

**Sub-questions that are individually tractable:**

- What does revocation *mean* during a partition? (Probably: "revoked as of epoch
  N", with the guarantee being about ordering rather than timing — which is a
  weaker but honest property, and one you can state formally.)
- Can macaroon-style offline attenuation be combined with an epoch-based
  revocation check that's cheap on the fast path?
- Does promise pipelining (Cap'n Proto) change the cost analysis enough to make
  proxies acceptable?
- What's the right failure semantics for an invocation on a capability whose
  object may have been revoked, destroyed, or partitioned away? (Three distinct
  errors, and most systems conflate them.)

**What counts as an answer.** A protocol with stated guarantees under an explicit
network model, an implementation, and a Jepsen-style evaluation. This is a thesis,
and it would matter to both the OS and the distributed-systems communities, which
is rare.

---

## 4. Isolation as a deployment-time parameter ★★★

Chapter 29 §3.1 proposes: one component model, six isolation mechanisms (language,
MPU, address space, address space + side-channel hardening, VM, confidential VM),
chosen at deployment rather than design time.

**The question.** Is that actually achievable, or does each mechanism leak into
the component's programming model?

**What to measure.** For one non-trivial component, under each mechanism:
per-invocation latency, memory overhead, startup time, and — the interesting one —
**how much of the component's source had to change**. If the answer is zero for
all six, the claim holds. If it's nonzero, *what* had to change is the actual
result: it tells you what each isolation mechanism fundamentally demands.

**Why it's worth doing.** Today, the choice of isolation mechanism is made once,
early, and permanently: you decide you're writing a Linux process, or a WASM
module, or a VM image, and everything follows. Making it a late-bound deployment
parameter would change how systems are built — and it's the natural answer to
"what replaces the process?" (Appendix E §E20).

---

## 5. Do components dominate unikernels? ★★

Chapter 29 §3's claim: a unikernel is a component with a worse interface and a
fatter boot path, and unikernels exist only because the VM was the only isolation
primitive available in the cloud.

**The experiment.** The same service — an HTTP endpoint, a key-value store —
implemented as: a Linux container, a Firecracker microVM, a unikernel, and a Nyx
component. Measure cold start, memory footprint, per-request latency and tail,
density (instances per GB), and artifact size.

**What would make it interesting.** If the component wins by a large factor on
cold start and density while matching on latency, that's a concrete argument about
serverless infrastructure, which is an area with real commercial attention and a
well-defined objective function. If it doesn't win, finding out *why* (probably:
the isolation isn't the cost, the language runtime is) is equally useful.

**Low difficulty, clear evaluation, and the result is legible to people outside
OS research** — which matters for whether the work gets read.

---

## 6. Cluster-wide resource allocation with real accounting ★★★★

**The question.** Untyped memory (Chapter 09) gives exact memory accounting.
Scheduling contexts (Chapter 14) give exact CPU accounting, including work done on
a client's behalf. Energy could be a budget too (Appendix E §E5). What happens if
you extend *exact* accounting across a cluster?

Today, cluster schedulers (Kubernetes, Borg, Mesos) allocate based on *requests
and limits that are guesses*, with over-commit, eviction, and noisy neighbours as
the consequence. Nobody has exact accounting because Linux can't provide it.

**The research question:** with exact per-component resource accounting, can a
cluster scheduler achieve substantially better utilization at the same tail
latency? That's the central economic question of datacenter computing and the
answer is currently "we don't know, because we can't measure precisely enough."

**What counts as an answer.** A cluster (even a small one, even emulated) with
exact accounting, a placement solver over the knowledge base (Chapter 28 §1.2), and
a utilization/tail-latency curve compared against a request-and-limit baseline.

---

## 7. Deployment as a verifiable artifact ★★★

Chapter 30 §5's unification: linking, booting, and deploying are the same
operation at different times.

**The questions that follow:**

- Can you *prove* properties of a deployment from its manifest — not just
  information flow (Appendix E §E4), but liveness ("every required interface is
  bound"), resource feasibility ("the sum of budgets fits the node"), and
  compatibility ("every binding's interface versions are compatible")?
- Can a deployment be *type-checked*? An interface is a type; a binding is an
  application; a manifest is a program. This suggests the whole thing should have a
  proper type system rather than a schema.
- Can you compute a **minimal** capability set from a component's code, rather
  than trusting the author's manifest? (Static analysis of which interfaces are
  actually invoked. This defeats the §7-objection in Chapter 30 — that people
  over-grant because it's easier — by making the correct manifest the *default*.)

That last one is the highest-value item here. "The build system computes your
security policy from your code, and the deployment refuses anything more
permissive" would be a real advance over every permission model currently
deployed, and it's tractable.

---

## 8. Partition-tolerant edge-to-cloud as one system ★★★★

The scenario Part VIII actually enables: a fleet of N0 sensor nodes, N1 gateways,
and N4 datacenter nodes, all speaking the same IPC, all described by the same
manifest, all analyzable by the same tools.

**The open questions:**

- What computation moves where, and can placement be automatic across a
  three-orders-of-magnitude heterogeneous fleet? (Chapter 28 §1.2's solver, at
  scale.)
- How does an interface behave when the link is intermittent by design? A sensor
  node that's asleep 99.9% of the time is *partitioned on purpose*, and the failure
  model (Chapter 28 §4) needs a vocabulary for that.
- Can a component be developed on a laptop, tested in a cluster, and deployed to a
  microcontroller with the same binary semantics — and can you *verify* that its
  resource envelope fits before deploying?
- What does over-the-air update look like when the artifact is 200 KB, atomic, and
  rollback-capable (Chapter 30 §4.3), on a device with 256 KB of flash?

**Why it's interesting:** the edge/cloud split is currently two entirely separate
software worlds glued with MQTT and hope. One system spanning it, with one
security model and one deployment mechanism, is a plausible and valuable outcome —
and it's the most likely *practical* application of everything in this book.

---

## 9. Reviving the system knowledge base ★★

Chapter 28 §1.2. Barrelfish's SKB — a queryable, constraint-solved store of
everything the system knows about itself — was one of the better ideas of the last
twenty years of OS research and has been almost completely ignored.

**Why revisit now:** hardware heterogeneity has gotten much worse (P/E cores, CXL
tiers, accelerators, SmartNICs), so the number of configuration decisions that
depend on topology has exploded. Hand-written heuristics scale badly; a solver
over declared facts scales fine.

**Concrete project:** implement the knowledge base, feed it topology plus measured
latencies, and use it for three decisions — thread placement, IRQ affinity, and
buffer allocation (NUMA/CXL tier). Compare against hand-tuned heuristics. Report
both the performance and the *code size* difference, because "600 lines of solver
replaced 4000 lines of heuristics" is its own result.

---

## 10. Milestones for Part VIII

Assuming Parts I–IV exist:

| Milestone | Content | Effort |
|---|---|---|
| **S0** | The manifest format + build tool; the root task consumes it | 2 weeks |
| **S1** | N0 profile: MCU port, `none` aspace backend, static object generation, `static_manifest_equivalence` test | 4–6 weeks |
| **S2** | MPU backend; the size-tracking CI job; profile matrix in CI | 2 weeks |
| **S3** | Nyx as a KVM guest: virtio drivers, PV clock, CI job | 3 weeks |
| **S4** | `VCPU`/guest `VSpace`; a trivial guest; then Linux booting | 6–8 weeks |
| **S5** | Proxy transport (Ch. 28 §2a); `transport_equivalence` test across two machines | 3 weeks |
| **S6** | Node agent + minimal control plane; deploy a component to a remote node from a manifest | 4 weeks |
| **S7** | Hermetic reproducible builds; content-addressed artifacts; signing | 3 weeks |
| **S8** | Atomic upgrade with capability preservation; measure zero-failure upgrade under load | 2 weeks |
| **S9** | The Chapter 30 §8 comparison: artifact size and startup vs container and microVM | 1 week |
| **S10** | Pick one question from §2–§9 | — |

S0–S3 are the high-value core: a manifest, a tiny profile, and being deployable as
a guest. S9 is the milestone that produces the number people will remember.

---

## 11. A closing observation

Part VIII's four chapters make one argument in four places:

- **Chapter 27**: the difference between an MCU OS and a server OS is *when the
  manifest is evaluated*.
- **Chapter 28**: the difference between a local and a remote call is *the failure
  model*, and everything else can be uniform.
- **Chapter 29**: the difference between a process and a VM is *the ABI*, and
  isolation strength should be a deployment parameter.
- **Chapter 30**: the difference between linking, booting, and deploying is *the
  time of evaluation*, and containers are three workarounds and two good ideas.

In each case, something the industry treats as a fundamental category distinction
turns out to be a parameter. That's what a good abstraction does, and it's the best
available evidence that the capability microkernel model is the right foundation —
better evidence, honestly, than any benchmark.

Whether it survives contact with implementation is the thing you'd be finding out.

---

← [Back to the index](README.md)

Next: [32 — Tracing and instrumentation](32-tracing.md)
