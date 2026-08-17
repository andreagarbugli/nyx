# 39 — Composability as a discipline

> Goal: make "you can swap any layer" true rather than aspirational. That
> requires deciding what is deliberately *not* swappable, recognizing which
> concerns cannot be layers at all, writing conformance suites before second
> implementations exist, and confronting the failure mode nobody talks about —
> interfaces that preserve every semantic guarantee and still break their clients
> because the *timing* changed.
>
> Chapter 27 was about scale. This is about substitutability, which is a
> different property with different requirements.

---

## 1. Three things called composability

They get conflated, and they need different mechanisms:

| Kind | Question | Mechanism |
|---|---|---|
| **Configurability** | Which parts do I include? | Profiles + manifest (Chapter 27 §4) |
| **Substitutability** | Can I replace this part with a different one? | Interfaces + conformance suites (this chapter) |
| **Extensibility** | Can I add something the designers didn't anticipate? | Capability delegation + interface versioning |

Zephyr does the first well and the second barely — everything links into one
binary, so "swapping" a subsystem means a recompile, and the substitute must fit
the same internal API that was shaped by the original. That's not a criticism of
Zephyr; it's the correct design for a 32 KB target where a call must be a call.

Here the components are already separate, already behind capability-mediated
interfaces, already restartable. **The mechanism for substitutability is
free — what isn't free is the discipline that makes an interface actually
substitutable.** That discipline is the subject.

---

## 2. The narrow waist: what must not be swappable

Every composable system has a layer that is fixed so everything above and below
can vary. IP for the internet. The syscall table for Unix. If nothing is fixed,
nothing composes.

| Fixed forever | Swappable |
|---|---|
| Kernel object types and their semantics | Scheduler policy, memory policy, pager |
| IPC and capability semantics | Filesystem, VFS design, block layer |
| The manifest format (Chapter 30 §4) | Network stack — library *or* server (Chapter 36 §6.1) |
| Trace event model and the clock (Chapter 32) | Every driver |
| The `str`/`RESULT`/versioned-struct conventions (Appendix A) | Compositor, shell, toolkit (split deliberately, Chapter 21 §3) |
| Interface-definition language and its wire format | Init/root-task policy — it *is* a manifest |
| RT-safety annotations (Chapter 35 §4.1) | Congestion control, TSN scheduler, allocator |

This reframes Liedtke's minimality principle. The usual argument for a small
kernel is performance and TCB size. The stronger argument, visible only once you
care about composability, is:

> **The kernel is the part of the interface you are committing to for thirty
> years. Minimality is a bound on how much you have to be right about, forever.**

Criteria for anything you put in the waist:

1. **Small.** You will not be able to remove it.
2. **Semantically complete** — everything above can be expressed in terms of it.
   If implementations keep needing an escape hatch, the waist is wrong.
3. **Performance-neutral** — it must not make any reasonable implementation
   above it impossible. (This is where "everything is a file" failed: it made
   zero-copy and completion-based I/O awkward for thirty years.)
4. **Versioned from day one**, even at version 1 with no version 2 planned.

### 2.1 The escape-hatch smell

If your interface has an `ioctl`, a `void *opaque`, a "vendor-specific command"
range, or a `setsockopt`-shaped generic setter, the abstraction is incomplete and
those hatches are where substitutability goes to die — because implementations
diverge through them and clients start depending on the divergence.

Not "never do it," but: **every escape hatch is a debt with a due date.** Track
them in `docs/escape-hatches.md`, with what would be needed to close each one.

---

## 3. Layers, protocols, and cross-cutting concerns

Not everything can be a swappable layer, and pretending otherwise produces the
worst designs.

| Concern | Shape | Why |
|---|---|---|
| Filesystem, network stack, scheduler policy, driver | **Layer** | Well-defined boundary, one provider, clients don't care how |
| Power management | **Protocol** | Requires facts held by every component (Appendix D §1) |
| Time | **Protocol + waist** | Everyone must share one clock or nothing composes |
| Tracing | **Protocol + waist** | A trace with two event models is not a trace |
| Security policy | **Structure** | It's the shape of the capability graph, not a component |
| Naming | **Both** | The *mechanism* is a waist; the *namespace* is per-component policy |
| Resource accounting | **Structure** | Untyped memory makes it a property of the graph, not a service |

The test: **can one component provide this to all others through an interface, or
must every component participate?** If the latter, it's a protocol, and the right
design is a coordinator plus an obligation on every component — not a swappable
box.

Getting this wrong is expensive in both directions. Making power management a
"layer" gives you a component that has to infer what everyone else is doing.
Making the trace event model "swappable" gives you traces that can't be joined.

---

## 4. Designing an interface that is actually swappable

A checklist. Apply it when writing the `.idl`, not afterwards.

1. **Specify semantics, not mechanism.** "Returns the bytes previously written at
   this offset" — not "reads from the block device."
2. **Enumerate every failure**, including the ones specific to being a separate
   component: `ERR_DEAD` (provider restarted), `ERR_UNKNOWN` (may or may not have
   executed, Chapter 28 §3). If clients don't handle these, you don't have a
   swappable component, you have a library with extra latency.
3. **Annotate idempotency** per method, and let the generator enforce dedup for
   the ones that need it.
4. **State the resource and timing contract** — §6. This is the step everyone
   skips.
5. **No implementation-shaped leaks.** The recurring examples:
   - a filesystem interface that exposes *block* size (leaks the storage layout)
   - a memory interface that exposes *page* size (blocks huge-page or MPU
     implementations)
   - a network interface with connection setup/teardown semantics (blocks
     connectionless implementations — Chapter 36's whole complaint)
   - a display interface exposing a framebuffer pointer (blocks GPU composition —
     the mistake X11 made)
   - any interface exposing an index into the provider's internal table
6. **No ambient state.** No "current directory", no "default device", no implicit
   session. Every call carries what it needs, or the capability does.
7. **Version it** (Chapter 17): versioned attribute structs, interface version in
   the message label, append-only evolution.
8. **Decide the capability shape**: who holds what, what a client can delegate,
   what revocation means. Two implementations that differ in this are not
   substitutable regardless of their method signatures.

---

## 5. The two-implementation rule

> **No interface is considered designed until two implementations exist.**

Not because you need two filesystems. Because **an interface with exactly one
implementation is invariably shaped like that implementation**, and you cannot
see the leaks from inside. The second one — even a deliberately trivial one — is
what exposes them.

Cheap second implementations that pay for themselves:

| Interface | Reference / second implementation | Finds |
|---|---|---|
| Filesystem | In-memory ramfs | Leaked block-device assumptions |
| Memory server | Fixed-partition allocator (no policy at all) | Leaked policy assumptions |
| Pager | Null pager (fault = kill) | Whether faults are really optional |
| Network | Loopback-only stack | Leaked connection/addressing assumptions |
| Display backend | Virtual/PNG backend (Chapter 22 §7) | Leaked hardware assumptions — and it did |
| Scheduler | Round-robin, single priority | Whether "priority" leaked into clients |
| NIC driver | virtio-net alongside e1000 | Leaked descriptor-model assumptions |
| Storage | File-backed, in a file | Leaked latency and ordering assumptions |

The trivial implementation doubles as **executable specification** — when a
conformance test fails on the real implementation but passes on the reference, the
reference tells you what the intended behaviour was.

And a third variety worth building: the **hostile implementation**. One that is
technically conformant but maximally unhelpful — always returns the minimum
allowed, reorders whatever it may reorder, restarts constantly, takes the longest
permitted time. Clients that survive it depend on the *contract* rather than on
the incumbent's behaviour. This is the single most effective way to find
accidental coupling, and almost nobody does it.

---

## 6. The performance contract — the real failure mode

Here is the failure that makes "swappable" a lie in practice:

> You replace a component. Every semantic guarantee is preserved. Every
> conformance test passes. And a real-time client misses its deadline, because
> the new implementation's p99 latency is 3× the old one's.

Semantic conformance is necessary and nowhere near sufficient. The fix is to make
the performance contract part of the interface:

```
interface storage.v1 {
    method read(u64 offset, u32 len) -> (bytes data);

    contract {
        read.latency_p50   <= 100us;
        read.latency_p99   <= 2ms;
        read.rt_safe       = false;
        read.idempotent    = true;
        read.max_inflight  >= 32;      /* clients may rely on this concurrency */
        read.allocates     = false;    /* Chapter 35 §8 */
    }
}
```

Then:

- **A conformance run measures the contract**, not just the semantics. An
  implementation that's semantically perfect and 5× slower *fails*.
- Clients declare what they need; a mismatch is caught at deployment, by the
  manifest checker, rather than in production.
- Chapter 34 §5's compositional timing analysis has real inputs: a component's
  timing interface is published, so the analysis composes across substitutions.

This also gives you a principled answer to the "swapping costs a boundary
crossing" objection: the contract states the boundary's cost, and Chapter 29 §3.1's
isolation spectrum lets you *choose* the enforcement mechanism to meet it. Same
interface, direct call at N0, IPC at N2, network hop at N4 — with the contract
naming the cost in each case.

---

## 7. Conformance suites

**Write the suite with the interface, before the second implementation exists.**
It lives next to the `.idl`, not in any implementation's directory:

```
idl/storage.v1.idl
idl/storage.v1.conformance/     ← runs against ANY implementation
    semantics/                  ← behavioural tests
    properties/                 ← property-based: read-after-write, ordering
    failures/                   ← restart mid-operation, revoke mid-call, ERR_DEAD handling
    contract/                   ← the §6 measurements
    hostile/                    ← the client-side suite: run clients against the hostile impl
```

Properties that make a suite worth having:

- **Property-based, not example-based**, where possible. "For any sequence of
  writes, a read returns the last written value at that offset" catches more than
  fifty hand-written cases.
- **Tests the failure paths hardest.** Restart the provider mid-call. Revoke a
  capability mid-operation. Return `ERR_DEAD`. These are the paths that
  distinguish a component from a library and the ones clients never exercise.
- **Runs against every implementation on every commit**, in a matrix.
- **Failure is the interface's problem, not the implementation's.** If two
  reasonable implementations disagree and the spec doesn't say who's right, the
  spec is underspecified — fix the spec, then add the test.

The conformance matrix is the artifact that makes substitutability *true*:

```
                      ramfs   logfs   nvmefs   hostile
semantics               ✓       ✓       ✓         ✓
properties              ✓       ✓       ✓         ✓
failures                ✓       ✓       ✓         ✓
contract (p99 ≤ 2ms)    ✓       ✓       ✓         —
```

---

## 8. Configuration without combinatorial explosion

Chapter 27 §4 said it: a small number of named profiles, each built and tested.
The general rule, worth stating plainly:

> **The number of supported configurations is the number of *tested*
> configurations. Everything else is a possibility, not a feature.**

Techniques when the space is genuinely large:

- **Profiles first.** Cover the deployments you actually intend.
- **Pairwise (combinatorial) testing** for the rest: a small suite covering every
  *pair* of feature values catches the large majority of interaction bugs at a
  fraction of the cost of exhaustive testing.
- **Constrain the space in the manifest schema.** If two features are
  incompatible, the schema should say so and the deployment tool should refuse —
  not discover it at runtime.
- **Delete configurations.** An option nobody uses is a tested configuration you
  are paying for. Track usage; remove the unused.

---

## 9. Substitution at runtime

Chapters 11 §6 and 30 §4.3 already built the mechanism. Composability makes a
stronger use of it:

| Mode | Use |
|---|---|
| Restart same version | Fault recovery |
| Restart new version | Upgrade |
| **Run both, route to one** | Canary — new implementation gets 5% of traffic |
| **Run both, compare outputs** | **Shadow mode** — the new implementation receives every request, its results are discarded, and divergence is logged |

Shadow mode is the strongest possible validation of a swap and it's almost free
here: the interface is already a message, so tee it. Divergence between the
incumbent and the candidate on real production traffic finds the things
conformance tests didn't think of, and finds them *before* the swap.

It also composes with Chapter 32's tracing: shadow requests carry the same trace
id, so a divergence report includes both execution paths side by side.

---

## 10. Anti-patterns

| Anti-pattern | Symptom | Fix |
|---|---|---|
| **The god interface** | 60 methods, no implementation uses more than 15 | Split by client, not by provider |
| **Premature abstraction** | One implementation, elaborate interface | Write the second implementation *or* delete the abstraction |
| **The escape hatch** | `ioctl`, `void *`, vendor ranges | §2.1 |
| **Config flag that's really two components** | `if (mode == FAST)` branching through the implementation | Two implementations of one interface |
| **The leaky default** | Clients rely on undocumented behaviour of the incumbent | Hostile implementation (§5) |
| **Interface follows implementation** | Method names match the provider's internal functions | Design from the client's need |
| **Untested composition** | Each component tested alone; the combination never | Profile matrix, §8 |
| **Swappable in principle** | No second implementation has ever been built | The two-implementation rule |

---

## 11. Case studies from this book

Honest assessment of how well each boundary in the preceding chapters actually
composes:

| Boundary | Grade | Notes |
|---|---|---|
| **Memory server** (Ch. 11 §4) | **A** | Untyped memory means policy is entirely above the interface. Two policies genuinely coexist. |
| **Network stack** (Ch. 36 §6.1) | **A** | Same interface, library *or* server deployment. The model case: the substitution axis is deployment, not source. |
| **Display backend** (Ch. 22 §7) | **A** | Virtual/bootfb/virtio-gpu behind one interface, and the virtual backend found real leaks. |
| **Compositor / shell split** (Ch. 21 §3) | **A−** | Mechanism/policy split that Wayland merged. Costs an extra hop; worth it. |
| **Scheduler policy** (Ch. 07 §5, Ch. 14) | **B+** | Policy is swappable, but Chapter 35's declarative API is what stops "priority" leaking into clients. Without it, B−. |
| **VFS / filesystem** (Ch. 11 §4) | **B−** | The page-cache-ownership question (Appendix D §5) is an unresolved leak. Where the cache lives will constrain every filesystem implementation. |
| **Driver framework** (Ch. 11 §5) | **B** | Good per-device; the dependency and binding model (Appendix D §4) is under-specified. |
| **Toolkit** (Ch. 25 §6) | **B** | Deliberately outside the OS, which is right, but the accessibility tree makes it more coupled than it looks. |
| **Real-time API** (Ch. 35) | **A−** | Declaring requirements instead of priorities is precisely what makes the scheduler substitutable. |

The B− on VFS is the one to fix, and it's fixable now, before implementations
exist. That's the value of doing this assessment early.

---

## 12. Verification

| Test | Asserts |
|---|---|
| `conformance_matrix` | Every implementation × every suite, on every commit |
| `two_implementations_exist` | CI fails if any interface in `idl/` has fewer than two conformant implementations (a reference counts) |
| `hostile_impl_survived` | Every client passes against the hostile implementation |
| `contract_measured` | The §6 performance contract is measured, not asserted, per implementation |
| `no_escape_hatch_growth` | Count generic/opaque parameters in `idl/`; fail if it increases |
| `profile_matrix` | Every named profile builds, boots, passes (Chapter 27 §7) |
| `pairwise_features` | Every pair of feature values is exercised somewhere |
| `shadow_divergence` | For a candidate swap, divergence rate on real traffic is zero |
| `manifest_rejects_incompatible` | A deployment binding a client to an implementation that fails its declared contract is refused at deploy time |

That second one is aggressive and worth it. An interface with one implementation
is a claim, not a capability.

---

## 13. Exercises

1. Pick the three interfaces you consider most important and write their
   conformance suites — before writing a second implementation of any of them.
2. Build the null/reference implementation for each. Report every leak it found.
3. Build one hostile implementation and run your existing clients against it.
   Report how many broke, and why.
4. Add performance contracts to one interface and measure two implementations
   against it. Find out whether your incumbent would pass its own contract.
5. Do the §11 assessment for your own boundaries. Be harsh. Fix the worst one
   while it's still cheap.
6. Implement shadow mode for one component and run a candidate swap against
   production-like traffic.
7. Count your escape hatches. Write down what it would take to close each.
8. **Argue the other side:** conformance suites, reference implementations,
   hostile implementations, and performance contracts are a large tax on every
   interface — plausibly more work than the implementations themselves. Make the
   case for designing interfaces informally and fixing them when a second
   implementation appears. When is that the right call?

---

← [Back to the index](README.md) · Next: [Appendix A — C ergonomics](A-c-ergonomics.md)
