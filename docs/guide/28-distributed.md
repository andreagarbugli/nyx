# 28 — Scaling up: the machine, the rack, the cluster

> Goal: take the message-passing model past the boundary of one machine. What a
> capability means across a network, what a cluster-wide OS can and cannot
> transparently provide, why single-system-image attempts failed, and what
> Barrelfish got right that everyone forgot.

---

## 1. The continuum, and where the lies start

There is no sharp boundary between "one machine" and "a distributed system."
There's a gradient of communication cost and failure independence:

| Scope | Latency | Coherent? | Fails independently? |
|---|---|---|---|
| Same core | ~1 ns | Yes | No |
| Same socket | ~20–40 ns | Yes (by protocol) | No |
| Cross-socket | ~100–200 ns | Yes (expensively) | Rarely |
| CXL-attached memory | ~200–500 ns | Yes or no, by type | Sometimes |
| Same rack, RDMA | ~1–2 µs | **No** | **Yes** |
| Same datacenter | ~50–500 µs | No | Yes |
| Cross-region | ~10–100 ms | No | Yes |

Two thresholds matter, and they're in different places:

- **Coherence ends** somewhere around CXL. Past it, shared memory is a lie you
  implement in software.
- **Independent failure begins** at the machine boundary. Past it, "the other side
  didn't reply" is a *normal* condition with no timeout that distinguishes slow
  from dead.

The second is the harder one. Everything below it can pretend; nothing above it
can. **Every failed attempt at a distributed OS failed by pretending anyway.**

### 1.1 The Barrelfish observation

Barrelfish's central insight (Baumann et al., SOSP 2009) is worth restating
because it reframes the whole problem: **cache coherence is already a message
protocol**, implemented in hardware, and pretending it's shared memory costs you
the ability to reason about it. A many-core machine is already a distributed
system; it just has an unusually fast, unusually reliable network.

So instead of "shared memory kernel, extended to a network," design as
"message-passing everywhere, with the transport chosen per link." Chapter 12 §1
already took this position for SMP ("design as if partitioned"). This chapter is
the same decision, extended.

The practical consequence: **a component doesn't know whether its peer is on the
same core, another core, another socket, or another machine.** What changes is
latency, bandwidth, and failure semantics — and the last one it *must* know about,
which is why §4 exists.

### 1.2 The other Barrelfish idea nobody stole

Barrelfish's **System Knowledge Base**: a datalog-style store of everything the
system knows about itself — topology, cache hierarchy, device locations, measured
latencies, NUMA distances — queried by a constraint solver to make configuration
and placement decisions.

Instead of hardcoding "spread threads across sockets," you *ask*: "give me 4 cores
sharing an L3, with an attached NIC, not currently running a latency-sensitive
component." This is a much better answer to placement (Appendix E §E9) than
heuristics, and it generalizes cleanly to a cluster.

It has been almost entirely ignored by subsequent work. It's a good project.

---

## 2. What a capability means off-machine

This is the crux. A local capability is unforgeable because the kernel mediates
every access. Across a network there is no shared kernel.

Three mechanisms, in increasing order of goodness:

**(a) Proxy objects.** A local capability to a *proxy* component that forwards
invocations over the network. The remote side has a matching proxy holding the
real capability. Unforgeability is local at both ends; the network is just a
transport.

- Simple, works today, preserves all local semantics.
- Revocation works: delete the proxy.
- The proxies must authenticate each other (TLS, or a pre-shared key from the
  manifest).
- Cost: an extra hop, and the proxy is a trusted component on both sides.

**(b) Cryptographic bearer tokens.** The capability is a signed token naming the
object and its rights. Possession is authority, exactly as locally.

- No proxy needed; a token can be passed through untrusted intermediaries.
- **Revocation is the classic hard problem.** Solutions: short expiry plus
  renewal, or an epoch/generation the server checks (which is Appendix B §4.2
  again), or a revocation list. All have costs.
- Attenuation is elegant: **macaroons** (Birgisson et al., 2014) let a holder
  add caveats without talking to the issuer, producing a strictly weaker token.
  That's capability attenuation, cryptographically, offline. It maps onto
  `cap_mint` remarkably well and is under-used in systems work.

**(c) A distributed capability protocol** — CapTP/Cap'n Proto's RPC layer, the
descendant of the E language's work. Handles three-party introductions (A can
give B a capability to C without B and C having met), promise pipelining (send
follow-up calls before the first reply arrives — a huge latency win), and
distributed reference counting.

**Recommendation:** (a) to start, because it's implementable in a week and
preserves semantics exactly; (b) for anything crossing a trust boundary or passing
through intermediaries; study (c) seriously, because promise pipelining is exactly
the batching argument from Chapter 15 applied to RPC, and Cap'n Proto's design
notes are excellent.

**The research question** (Appendix E §E17): none of these gives you local
capability semantics *with* revocation, *with* partition tolerance, *with*
acceptable latency. Solving it well would unify OS and distributed security, which
are currently separate fields.

---

## 3. Why single system image failed

A cluster that looks like one big machine has been attempted many times: MOSIX,
OpenSSI, Kerrighed, OpenMosix, Plan 9's distributed namespaces, and in a sense
every DSM system. All are dead or niche. Understanding why is the most useful
thing in this chapter, because the temptation to try again is strong.

| What was made transparent | Why it broke |
|---|---|
| **Process migration** | Migration is easy; migrating the *references* — open files, sockets, shared memory, device state — is not. Residual dependencies on the home node defeat the purpose. |
| **Shared memory across nodes (DSM)** | The performance model is invisible. A pointer dereference costs 1 ns or 100 µs and nothing in the language tells you which. Programs written for one cost model run catastrophically under the other. |
| **A single filesystem namespace** | Works (NFS, 9P) — this is the one that *did* succeed, and notably it's the one where the API already had explicit failure and latency. |
| **A single process table / PID space** | Requires consensus for a trivial benefit |
| **Failure** | Cannot be hidden. Partial failure is the defining property of a distributed system and no abstraction makes it go away. |

**The lesson, stated as a design rule:** *make naming and authority uniform;
never make latency or failure invisible.*

You can have one namespace, one identity model, one IPC API, and one set of
interfaces across the cluster. You cannot have "this call might take 100 µs and
might never return" hidden behind the same syntax as a function call — that's what
Waldo et al.'s "A Note on Distributed Computing" (1994) said, and thirty years of
RPC frameworks re-learning it have not refuted it.

**So: the API for a remote invocation should be visibly different from a local
one** — or at minimum, must return the failure modes a local one can't have, and
must be `MUST_USE` (Appendix A §4). Chapter 11 already introduced `ERR_DEAD` for
a dead server; remote adds `ERR_UNREACHABLE`, `ERR_TIMEOUT`, and the worst one,
`ERR_UNKNOWN` — the call may or may not have executed.

That last error is the one that forces idempotency into your interface design
(Chapter 11 §6), and it's why a multi-server OS is already a distributed system
even on one machine.

---

## 4. The failure model, made explicit

Write this into `docs/distributed.md` before writing code:

1. **Every remote interface declares its idempotency.** Idempotent operations can
   be retried on `ERR_UNKNOWN`. Non-idempotent ones need a request id and
   server-side deduplication, or they need to be redesigned. The IDL should have
   an annotation and the generated stubs should enforce it.
2. **Timeouts are a policy, set by the caller, always bounded.** No infinite waits
   across a machine boundary, ever.
3. **Failure detection is a component**, not a kernel feature. Use a phi-accrual
   detector (a *suspicion level*, not a boolean) rather than a fixed timeout —
   fixed timeouts are always either too slow or too trigger-happy.
4. **Decide your partition behaviour per service.** CAP is not a system-wide
   choice; it's per-data-item. Write down, for each service: does it stay
   available and diverge, or refuse and stay consistent?
5. **Fencing.** When you decide a node is dead and fail over, the "dead" node may
   be alive and still writing. You need fencing tokens (monotonic epoch numbers
   checked by the resource) or you will corrupt data. This is the single most
   commonly omitted piece of failover design.

---

## 5. Cluster architecture

What actually runs where:

```
┌───────────────────────── cluster control plane ─────────────────────────┐
│  membership · placement · configuration · identity · attestation        │
│  (replicated, consensus-backed, a few nodes)                            │
└─────────────────────────────────────────────────────────────────────────┘
        │ capabilities + manifests, pushed to nodes
        ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│  node (N4)    │   │  node (N4)    │   │  node (N4)    │
│  ┌─────────┐  │   │               │   │               │
│  │ kernel  │  │   │   ...         │   │   ...         │
│  ├─────────┤  │   │               │   │               │
│  │ node    │  │   │               │   │               │
│  │ agent   │◄─┼───┼───────────────┼───┼──►            │
│  ├─────────┤  │   │  RDMA / TCP / CXL fabric          │
│  │components│ │   │               │   │               │
│  └─────────┘  │   │               │   │               │
└───────────────┘   └───────────────┘   └───────────────┘
```

Design points:

- **Consensus is a component, not a kernel feature.** Raft in userspace, holding
  the cluster's authoritative state. The kernel knows nothing about clusters. If
  you find yourself adding a cluster concept to the kernel, you've made a mistake.
- **The node agent is the local root task** (Chapter 10 §8), extended: it receives
  a manifest from the control plane and instantiates components accordingly.
  **Which means cluster deployment and local component startup are the same
  mechanism** — a genuinely elegant consequence, and the foundation of Chapter 30.
- **Placement is a solver problem** (§1.2 and Appendix E §E9), fed by the
  knowledge base: latency measurements, topology, current load, energy, and
  affinity constraints from the manifest.
- **The control plane is itself components**, running on nodes, subject to the
  same rules. No special infrastructure.

### 5.1 Transport

One IPC interface, several transports, chosen by the transport layer, not the
application:

| Transport | Latency | Use |
|---|---|---|
| Same-core rendezvous | ~100 ns | Chapter 08 |
| Cross-core MPSC + IPI | ~1 µs | Chapter 12 §8 |
| Shared memory over CXL | ~0.5 µs | Same rack, coherent or not |
| RDMA (one-sided read/write) | ~1–2 µs | Rings in remote memory; the ring model from Chapter 15 works *unchanged*, which is a strong sign it was the right abstraction |
| TCP / QUIC | ~50 µs+ | Anything else |

That RDMA row is worth dwelling on: an SPSC ring in remote memory, with the
producer doing one-sided writes and a doorbell, is *the same data structure* as
the local ring. The abstraction genuinely survives the network, and this is the
main reason to have built I/O on rings rather than on syscalls.

---

## 6. Migration and replication

With components as the unit and capabilities as the references, both become
tractable in a way process migration never was:

**Migration.** A component's state is: its memory, its thread state, and its
capabilities. Memory and threads are straightforward to serialize. Capabilities
are the hard part — but if they're proxies (§2a), migration means re-pointing the
proxies, which is a control-plane operation. Compare UNIX process migration, where
the "capabilities" are file descriptors into kernel state you cannot name.

**Replication.** Run N copies, feed them the same input sequence, compare outputs.
This is straightforward *if* the component is deterministic — which connects to
Chapter 13 §C6 and Appendix E §E14, and which is much more achievable for a small
single-purpose component than for a whole OS. N-version programming (Chapter 11
§6) becomes a deployment option rather than a research exercise.

**Checkpointing.** A component's checkpoint is its memory plus its capability
graph. With the persistence work from Chapter 13 §C4, this is the same machinery.

The general observation: **the microkernel decomposition makes distribution
easier for the same reason it makes fault recovery easier** — the units are small,
their state is explicit, and their references are enumerable. That's a claim worth
demonstrating rather than asserting; §8 says how.

---

## 7. What is actually shared cluster-wide?

Be precise, because "distributed OS" is otherwise a mood:

| Shared | Not shared |
|---|---|
| The interface definitions (IDL) | Memory (except explicitly, over a fabric) |
| The naming/object model (Ch. 16) | Scheduling (each node schedules itself; placement is cluster-level) |
| Identity and authority (capabilities, §2) | The kernel — each node runs its own |
| The manifest / deployment model (Ch. 30) | Time, except as a synchronized estimate (PTP; Appendix D §2) |
| Observability: tracing, metrics, logs | Failure |

The claim "one OS across the cluster" means the top-left column, and nothing more.
Say so explicitly, because the failed attempts in §3 all claimed more.

---

## 8. Verification

| Test | Asserts |
|---|---|
| `transport_equivalence` | The same component test suite passes with local, cross-core, and TCP transports. **The headline test:** it proves the abstraction holds. |
| `remote_cap_revocation` | Revoke a proxied capability; assert the remote side loses access promptly and observably |
| `partition_behavior` | Introduce a partition with a network simulator; assert each service behaves as its declared CAP position says |
| `fencing_prevents_split_brain` | Fail over while the "dead" node is alive; assert no double-write |
| `idempotency_annotations` | Every non-idempotent remote method has dedup; checked by the IDL compiler |
| `migration_preserves_state` | Migrate a component under load; assert no lost or duplicated requests |
| `latency_matrix` | Measure IPC cost on every transport; track in CI |
| `jepsen_style` | Randomized partitions, clock skew, and node kills against a stated consistency model. Adopt Jepsen's methodology; it finds things nothing else does. |

The first one is the most important. If your component tests pass unchanged over
a TCP transport, the distribution story is real. If they need modification, find
out exactly what leaked and either fix it or document it as a boundary.

---

## 9. Exercises

1. Implement the proxy transport (§2a) and run an existing component pair across
   two QEMU instances. Then run the `transport_equivalence` test.
2. Implement an SPSC ring over RDMA (or over a socket simulating one-sided writes)
   and confirm the ring code is unchanged.
3. Build the knowledge base (§1.2): collect topology and measured latencies, and
   write one placement query against it. Compare its answer to your intuition.
4. Implement phi-accrual failure detection and tune it. Measure false-positive
   rate under load.
5. Add `ERR_UNREACHABLE`/`ERR_UNKNOWN` to your generated stubs and fix every
   call site the compiler now flags. Count them; that number is how much of your
   code was assuming local semantics.
6. Read Waldo et al. (1994) and Barrelfish (2009). Write a page on whether
   Barrelfish's "one machine is a distributed system" and Waldo's "don't hide the
   network" are the same claim.
7. **Argue the other side:** make the case that a cluster should be built out of
   ordinary networked machines running independent OSes, and that "distributed OS"
   is a category error — that the control plane is the OS and the node OS should
   stay dumb. (This is essentially Kubernetes's position, and it won.)

---

Next: [29 — Virtualization as a first-class concept](29-virtualization.md)
