# 30 — Deployment: what containers are actually for

> Goal: take seriously the claim that containers solve a problem that shouldn't
> exist. Decompose what a container actually delivers into its five separate
> functions, show which are workarounds for defects in the underlying OS and which
> are genuinely valuable, and design the replacement — while being honest about
> why the workaround won.

---

## 1. What a container is, decomposed

A container bundles five unrelated things that arrived together for historical
reasons:

| # | Function | Mechanism (Linux) |
|---|---|---|
| 1 | **Dependency isolation** — "my libc, not yours" | Mount namespace + a whole userland in the image |
| 2 | **Resource limits** | cgroups |
| 3 | **Isolation from other workloads** | Namespaces + seccomp + capabilities(7) + LSM |
| 4 | **A distribution format** | Layered image, content-addressed, a registry |
| 5 | **A deployment/lifecycle API** | The runtime + orchestrator |

Now the assessment, which is the argument of this chapter:

| # | Verdict |
|---|---|
| 1 | **A workaround.** For dynamic linking against a global `/usr/lib`, a global filesystem namespace, and implicit dependencies. Fix those and it evaporates. |
| 2 | **Legitimate**, and Chapter 09's untyped memory does it better — exactly, by construction, with no accounting heuristics. |
| 3 | **A workaround.** For ambient authority. A process starts with access to everything and you subtract; namespaces are the subtraction mechanism. Capabilities start at zero and you add. |
| 4 | **Genuinely valuable and orthogonal to the OS.** Content-addressed, verifiable, cacheable distribution is a good idea independent of containers. |
| 5 | **Genuinely valuable and orthogonal.** Declarative desired-state deployment is a real advance. |

So: **two of the five are real; three are compensation for defects.** And the two
real ones are not OS features at all — they're a package format and a control
plane, both of which work fine over anything.

That's the case, stated. The rest of the chapter makes it concrete and then
argues against itself in §7.

---

## 2. The evidence that (1) and (3) are workarounds

Not just an argument — the industry has repeatedly built things that skip them:

- **Static linking** removes (1) entirely. Go's ecosystem shipped static binaries
  and largely stopped caring about "dependency hell" as a deployment problem.
- **Nix / Guix** remove (1) by content-addressing the dependency closure instead
  of isolating it. Two applications can use different libc versions *in the same
  filesystem namespace*, because the path contains the hash. No namespace needed.
- **Unikernels** remove (1) by having no shared userland to conflict with.
- **gVisor, Firecracker, Kata** exist because (3) **didn't work**. Namespace
  isolation was judged insufficient for hostile multi-tenancy, so the industry
  went *back to VMs*. That's the clearest possible admission that (3) was a
  workaround that didn't hold.
- **WASM/WASI** does both properly: a module imports exactly the functions it may
  call (capabilities), and has no filesystem namespace at all. It's the closest
  thing to "containers done right" currently shipping, and notably it's
  capability-based.
- **seccomp filters, LSM policies, and `capabilities(7)`** are all "subtract
  authority after the fact" mechanisms, and all are famously hard to get right —
  because subtracting from ambient authority requires you to enumerate everything,
  which is impossible.

The pattern is consistent: every attempt to fix containers moves toward
content-addressed dependencies and capability-based authority.

---

## 3. What Nyx already has

Walk through the five, assuming the architecture built in this book:

**(1) Dependency isolation.** There is no global filesystem namespace (Chapter 16;
Chapter 11 §3: naming is per-component ABI slots, and "the absence of a capability
*is* the policy"). A component reaches only the objects it holds capabilities for.
There is no `/usr/lib` for it to conflict over. If you also build hermetically
(§4), the problem is gone, not isolated.

**(2) Resource limits.** Untyped memory (Chapter 09 §4) gives exact memory
accounting with no over-commit and no OOM killer. Scheduling contexts (Chapter 14)
give exact CPU budgets, with the passive-server property that a client pays for
work done on its behalf — which cgroups famously cannot do (work done by a kernel
thread on your behalf is charged to nobody).

**(3) Isolation.** This is the entire book. A component starts with *no* authority
and receives exactly what the manifest grants.

**(4) Distribution format.** Doesn't exist yet. **Build it** (§4).

**(5) Deployment API.** Chapter 28 §5's node agent + control plane. Also needs
building, and it's the same mechanism as local component startup, which is the
nice part.

So the conclusion isn't "Nyx doesn't need containers." It's: **three of the five
functions are already provided structurally, and the remaining two are worth
building properly because they were always the good parts.**

---

## 4. The replacement: a component artifact

Define the deployment unit. It is not an image of an operating system; it is a
component plus its authority requirements.

```toml
# nyx.component — the deployable artifact's manifest
[component]
name    = "sensor-aggregator"
version = "2.3.1"
# content hash of the binary; the artifact's true identity
binary  = "sha256:9f2c..."

[requires.interfaces]           # what it needs to be given
storage  = { interface = "nyx.storage.v1", optional = false }
metrics  = { interface = "nyx.metrics.v2", optional = true  }
clock    = { interface = "nyx.time.v1" }

[provides.interfaces]
aggregate = { interface = "nyx.sensor.aggregate.v1" }

[resources]
memory_max   = "16MiB"          # becomes an Untyped budget
cpu_budget   = { period = "10ms", budget = "2ms" }   # a SchedContext
threads_max  = 4

[isolation]
mechanism = "address-space"     # or wasm | mpu | vm | vm-confidential (Ch. 29 §3.1)

[build]
toolchain = "sha256:1a4e..."    # hermetic: the compiler is part of the identity
inputs    = ["sha256:...", "sha256:..."]
```

Properties that follow:

- **Identity is a content hash**, not a name and a tag. `latest` is not a version;
  a hash is. Two builds of the same source with the same toolchain produce the same
  hash (reproducible builds), so identity is verifiable rather than asserted.
- **Dependencies are interfaces, not files.** The component doesn't need "libjpeg
  6.2 at this path"; it needs "something speaking `nyx.image.decode.v1`." Binding
  happens at deployment. This is the difference between depending on an
  *implementation* and depending on a *contract*, and it's the actual fix for
  dependency hell.
- **The manifest is the security policy** (Chapter 10 §8, Appendix E §E4). It's
  auditable, diffable, and machine-checkable. You can answer "what can this thing
  reach?" by reading a file — which no container image permits.
- **The artifact is kilobytes to a few megabytes**, not hundreds of megabytes,
  because it contains a program and not a distribution of Linux.
- **The resource limits are in the same file as the authority**, because they're
  the same kind of thing: what this component is allowed to consume.

### 4.1 Hermetic builds

The dependency problem is *created at build time* and containers paper over it at
run time. Fix it at the source:

- Every input to a build is content-addressed, including the compiler.
- The build has no network access and no access to the host filesystem.
- Same inputs → same output bytes, byte for byte, verifiable by a third party.

Nix, Bazel, and Guix all demonstrate this works. The payoff: "works on my machine"
becomes meaningless, because there is no "my machine" in the build. Combined with
interface-based dependencies, the entire class of problem that containers were
invented to contain does not arise.

### 4.2 Distribution and trust

Keep what container registries got right, drop what they got wrong:

| Keep | Drop |
|---|---|
| Content addressing | Mutable tags (`:latest` is a bug) |
| Layer/chunk deduplication | Layers as an *ordering* of filesystem mutations |
| A simple HTTP fetch protocol | A single centralized registry as a norm |
| Caching everywhere | Trusting the registry to tell you what a name means |

For trust, use **TUF** (The Update Framework): signed metadata, role separation,
key rotation, freeze and rollback attack protection, threshold signing. It's the
mature answer and it exists precisely because naive signing schemes failed.
Include an SBOM derived from the build closure — which, with hermetic builds, is
*exact* rather than an estimate, which is a genuinely better answer than the SBOM
tooling currently deployed.

### 4.3 Updates

Atomic, verified, rollback-capable:

1. Fetch and verify the new artifact.
2. Start the new component alongside the old (both exist; only one is bound).
3. Migrate state if needed (Chapter 11 §6's live-update machinery).
4. Rebind clients — the reincarnation server already keeps the endpoint object
   alive, so client capabilities remain valid (Chapter 11 §6). **This means a
   component upgrade is nearly transparent to clients**, which containers cannot
   offer at all.
5. On failure, rebind to the old one. Rollback is instant because nothing was
   destroyed.

Compare A/B partition updates (whole-system, coarse, requires reboot) and
container rolling updates (per-service, but clients must reconnect and the
orchestrator must handle the churn). Per-component atomic rebinding is strictly
better and falls out of the architecture.

---

## 5. Deployment as capability distribution

The elegant part, and the thing that ties the whole book together:

**Deploying a system is instantiating components and distributing capabilities
according to a manifest. That is exactly what the root task does at boot
(Chapter 10 §8), what the build tool does at compile time on an MCU (Chapter 27
§3), and what the cluster control plane does across machines (Chapter 28 §5).**

One mechanism, three scales:

| Scale | Who evaluates the manifest | When |
|---|---|---|
| MCU (N0) | The build tool | Compile time |
| Machine (N2/N3) | The root task | Boot |
| Cluster (N4) | The control plane → node agents | Deploy time |

The manifest format is the same. The semantics are the same. **A "deployment" and
a "boot" and a "link" become the same operation evaluated at different times.**

This is the sort of unification that suggests the abstraction is right, and it's
worth stating loudly, because it means:

- The security policy of a cluster is a set of files, checkable by the same tool
  that checks a single machine's (Appendix E §E4).
- A component's environment is identical in development, test, and production,
  because it's the same manifest with different bindings.
- There is no separate "container runtime," "init system," "service manager," and
  "orchestrator" — there is one thing at four scales.

---

## 6. What about the software that already exists?

The honest problem. Two answers, and you need both:

**Run Linux in a VM** (Chapter 29). Existing containers run inside it. This is
what Fuchsia does with Starnix, what macOS does with its Linux VM, and what
Windows does with WSL2. It's not elegant, it works, and it decouples "does my OS
run existing software" from "is my OS's native model good."

**Support OCI images as a compatibility artifact.** A tool that takes an OCI image
and runs it under a Linux guest, presenting it as a Nyx component to the rest of
the system. Ugly, pragmatic, and it means adoption doesn't require rewriting the
world.

The strategy is the standard one for a new platform: be excellent natively, be
adequate for legacy, and make the boundary explicit rather than letting legacy
semantics leak into the native design. Windows NT's original subsystem model was
right about this; its failure was letting Win32 become privileged.

---

## 7. The strongest argument against this chapter

Take it seriously, because the workaround won and there were reasons.

**Containers won because they required changing nothing.** You could take an
existing application, an existing distro, an existing build, and get isolation and
reproducible deployment without modifying any of it. That is an enormous practical
advantage and it beat every technically superior alternative — including several
that look a lot like §4.

The design in this chapter requires: a new OS, a new build system, components
written against interfaces rather than files, and a new distribution format. The
adoption cost is not comparable.

**Second objection:** interface-based dependencies push the compatibility problem
into interface versioning, which is not obviously easier than library versioning.
Chapter 17's versioning discipline had better be very good, and the failure mode
(an interface that must be supported forever, or a flag day) is real. COM and
D-Bus both have scar tissue here.

**Third:** "the manifest is the security policy" is only true if the manifest is
*correct*. Writing a correct capability manifest for a complex application is real
work, and the failure mode — granting too much because it's easier — reproduces
ambient authority with extra steps. Container practice shows exactly this: people
run as root with `--privileged` because it's Friday.

**The response to all three:** don't claim containers were a mistake. Claim they
were the right answer *given Linux*, that their five functions were always
separable, and that a system designed from scratch should provide three of them
structurally and build the other two properly. Then demonstrate it with numbers —
artifact size, startup time, memory overhead, and the auditability of the security
policy — rather than by asserting elegance.

---

## 8. Verification

| Test | Asserts |
|---|---|
| `reproducible_build` | Two builds from the same inputs produce identical bytes. Run in CI, on different machines. |
| `manifest_is_complete` | A component denied any capability not in its manifest still starts and runs its test suite — i.e. the manifest isn't lying |
| `no_ambient_authority` | A component with an empty manifest can do *nothing*: no clock, no log, no memory beyond its budget |
| `artifact_size` | Track the deployment artifact size per component in CI. Compare to the equivalent container image; the ratio is your headline number. |
| `startup_latency` | Time from deploy command to serving requests. Compare to a container and a Firecracker microVM. |
| `atomic_rollback` | Deploy a broken version; assert automatic rollback with no dropped client requests |
| `upgrade_transparent` | Upgrade a component under load; assert client capabilities remain valid and no request fails |
| `signature_verification` | A tampered artifact is rejected; a rollback attack (serving an old signed version) is detected |
| `same_manifest_all_scales` | The same component manifest deploys on N0 (build time), N2 (boot), and N4 (cluster). **The thesis test of §5.** |

That artifact-size and startup-latency comparison is the number that will
persuade people. A component that deploys in 1 ms from a 200 KB artifact, against
a container that takes 500 ms from 200 MB, is an argument that doesn't need
explaining.

---

## 9. Exercises

1. Write the manifest schema and the deployment tool. Deploy one component
   locally, then to a second node, with the same manifest.
2. Make one component's build hermetic and reproducible. Verify by building it on
   two different machines and diffing the hashes.
3. Implement the `no_ambient_authority` test. Find everything your components were
   quietly assuming.
4. Take a real containerized service (something small — a static file server) and
   express it as a Nyx component. Compare artifact size, startup time, memory, and
   the length of the security policy you can actually read.
5. Implement atomic upgrade with client-capability preservation, and measure the
   request failure count during an upgrade under load. Target: zero.
6. Write the capability-graph checker (Appendix E §E4) over a multi-component
   manifest and produce the report.
7. **Argue the other side:** write the strongest possible defense of containers,
   including the adoption argument in §7, and then state precisely what evidence
   would be needed to justify the alternative. Decide whether you can produce that
   evidence.

---

Next: [31 — Research directions: composability and scale](31-scale-research.md)
