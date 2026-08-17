# 27 — Composability: one design from microcontroller to server

> Goal: make Nyx a *family* rather than a kernel. The same object model, the same
> ABI concepts, and as much of the same code as possible, running in 32 KB on a
> Cortex-M with no MMU and on a 128-core server with terabytes of RAM — with the
> configuration difference expressed as composition, not as `#ifdef`.
>
> This chapter argues that a capability microkernel is unusually well suited to
> this, for one specific structural reason developed in §3.

---

## 1. The thesis

Most systems that span this range do it by being *different systems that share a
name*: Linux on a microcontroller is not Linux, Windows IoT is a subset with its
own rules, and Zephyr and Linux share nothing but a foundation.

The claim here is stronger: **the capability object model degrades gracefully all
the way down, because everything that's dynamic at the large end can be
statically evaluated at the small end without changing the model.**

Concretely: on a server, the root task takes Untyped memory at runtime and retypes
it into TCBs, endpoints, and CNodes according to a manifest. On a microcontroller,
*a build-time tool* reads the same manifest and emits those same objects as
initialized data in flash, with the CSpaces already populated. The runtime model
is identical; only the moment of evaluation moves.

That's the whole idea, and it's why this is worth doing rather than writing a
separate small kernel:

| Property | Server | MCU |
|---|---|---|
| Capabilities | Runtime table lookups | The same table, in flash, built offline |
| Object creation | `Untyped_Retype` at runtime | The linker |
| Address spaces | Page tables | MPU regions, or none |
| The manifest | Interpreted by the root task | Evaluated by a build tool |
| Component boundaries | Hardware | MPU, or language, or nothing |
| IPC | Same code | Same code |

**The manifest is the invariant.** It describes the component graph and the
authority distribution, and the target decides how much of it is resolved before
boot. This is a genuinely nice property and I don't know of another system that
has it.

---

## 2. What the small end actually looks like

Be specific about the constraints, because they're more severe than people
remember:

| Constraint | Typical Cortex-M4 | Consequence |
|---|---|---|
| RAM | 32–256 KB | No dynamic allocation. Everything static. |
| Flash | 256 KB–2 MB | Execute in place (XIP); code doesn't consume RAM |
| MMU | **None** | No virtual memory, no address spaces, no demand paging |
| MPU | 8–16 regions, alignment-constrained | Coarse isolation only; region switching costs |
| Cores | 1, sometimes 2 | SMP mostly irrelevant, but not always |
| Interrupt latency | Must be < 1 µs | Every kernel critical section is a budget item |
| Cache | Often none | Timing is *more* predictable, and IPC is relatively cheaper |
| Power | The entire design constraint | Idle is the normal state (Appendix D §1) |

**The most important line is "no MMU."** Chapter 06 assumes page tables
everywhere. Without them:

- There is one address space. Every component sees every address.
- Isolation comes from the MPU: a small number of base/limit/permission regions,
  reprogrammed on context switch. Typically you can afford ~4–8 regions per
  component (code, data, stack, one or two device windows, one shared buffer).
- A pointer passed between components is *just valid*, which means the discipline
  of validating them (Chapter 10 §2) becomes more important, not less.
- Stack overflow is not caught by a guard page. Use an MPU region as a guard, or
  watermark the stacks and check.

The systems that do this well are worth studying, and they've converged on
similar answers:

| System | Approach |
|---|---|
| **Zephyr** | Kconfig + devicetree, everything statically configured, single binary, threads not processes, optional MPU-backed user mode |
| **Tock** | Rust; "capsules" are language-isolated and share one address space; *processes* are MPU-isolated with a grant mechanism for kernel-side per-process memory. The most relevant prior art for us. |
| **Hubris** (Oxide) | All tasks known at build time, no dynamic allocation anywhere, MPU isolation, IPC by syscall, a supervisor task that restarts failed ones. Essentially a static microkernel with a reincarnation server. |
| **FreeRTOS** | A scheduler, not an OS. Ubiquitous, minimal, no isolation by default. |
| **RIOT / Contiki-NG** | Networking-focused, tickless, energy-first |

**Hubris is the closest thing to "Nyx at the small end" that exists**, and its
design notes are the single best reading for this chapter. Note that it arrived at
static-everything and supervisor-restart independently, from reliability
requirements — which is evidence that the shape is right.

---

## 3. Static evaluation of the capability model

This is the load-bearing section. Here's how each dynamic mechanism collapses.

### 3.1 Objects

At the large end:
```
Untyped_Retype(untyped, TCB, size, dest_cnode, slot, count)
```
At the small end, a build tool emits:
```c
/* generated from the manifest — lives in flash, .rodata where possible */
static struct tcb tcbs[N_TASKS] = {
    [TASK_SENSOR] = { .prio = 200, .stack = sensor_stack,
                      .cspace = &cspace_sensor, ... },
    ...
};
```
Same `struct tcb`. Same scheduler code operating on it. The difference is who
filled it in.

### 3.2 CSpaces

A CSpace is a radix tree (Chapter 09 §2, Appendix C §4). At the small end, a
component typically holds 3–10 capabilities, so the tree collapses to **a flat
array of 8 or 16 entries, in flash, immutable**. `cap_lookup` becomes one bounds
check and one index — which is *exactly* the fast path the large end optimizes for
anyway.

An immutable CSpace also means: no `cap_copy`, no `cap_delete`, no revocation at
runtime. Authority is fixed at build time. For a device that ships and runs one
program forever, that's not a limitation, it's a feature — and it's the property
that lets you *prove* things about the system (Appendix E §E4) trivially, because
the graph is a constant.

### 3.3 Memory

No untyped, no allocation, no page tables. The manifest declares each component's
memory, the linker places it, and the MPU regions are computed offline. The
"memory server" (Chapter 11 §4) doesn't exist at this scale — its policy was
evaluated by the build.

### 3.4 IPC

**Unchanged**, and this is the point. The endpoint queue logic, the message
transfer, the badge semantics — same source file. On a single-core MCU with no
cache, the synchronous rendezvous is maybe 100–200 cycles, which is *relatively
cheaper* than on a server, because there's no cache footprint to lose.

Notifications map beautifully onto interrupt-driven MCU work, and rings
(Chapter 15) work fine in a shared address space — they just don't need mapping.

### 3.5 What's genuinely lost

Be honest about it:

- Dynamic component loading. (Usually fine; sometimes not — firmware update is
  then whole-image, which is what everyone does anyway.)
- Runtime revocation and delegation.
- Demand paging, COW, mmap.
- Strong isolation: an MPU with 8 regions is coarser than page tables, and
  language-level isolation (Tock's capsules) may be the only option for
  fine-grained separation.
- Multi-tenancy in any real sense.

So the small profile is a *statically-configured, single-tenant* system. That
describes essentially every embedded deployment.

---

## 4. Profiles, not `#ifdef`s

The failure mode here is well documented: Linux's `Kconfig` has thousands of
options, an astronomical configuration space, and most combinations have never
been compiled, let alone tested. Zephyr is heading the same way. Configurability
that isn't tested is a lie.

**The rule: a small number of named profiles, every one built and tested in CI.**

| Profile | Target | Kernel size | Isolation | Composition |
|---|---|---|---|---|
| **N0 — micro** | Cortex-M, RISC-V IMC, no MMU | ~16–32 KB | MPU + language | Fully static, link-time |
| **N1 — embedded** | MMU, single core, 8+ MB | ~64 KB | Page tables | Static manifest, runtime objects |
| **N2 — desktop** | SMP x86-64/ARM64 | ~100 KB | Full | Dynamic, root task |
| **N3 — server** | NUMA, many cores, IOMMU | ~120 KB | Full + IOMMU | Dynamic, multi-tenant |
| **N4 — node** | N3 + cluster membership | ~130 KB | Full + cross-node | Dynamic, distributed (Ch. 28) |

Rules that keep this honest:

1. **Every profile builds and passes its test suite on every commit.** If a
   profile can't be tested, it doesn't exist.
2. **Features are components, not compile flags.** "No IOMMU support" means the
   IOMMU component isn't in the manifest, not `#ifdef CONFIG_IOMMU`. Link-time
   removal (with `--gc-sections`) does the size work.
3. **The kernel itself has few options** — mostly architecture and the
   MMU/MPU/none axis. Everything else lives above it, which is the whole point of
   a microkernel.
4. **Size is a tracked CI metric.** Chapter 18's harness reports kernel `.text`
   and `.data` per profile per commit, and a regression fails the build. Without
   this, N0 will silently grow to 90 KB over a year.
5. **A profile is a manifest plus a target triple**, not a scattered set of
   defaults.

### 4.1 The one axis that genuinely forks the code

`MMU / MPU / none` is the real fork, because address-space management is
fundamentally different. Handle it with three implementations of one interface:

```c
struct aspace_ops {
    err_t (*create)(struct aspace *);
    err_t (*map)(struct aspace *, vaddr_t, paddr_t, size_t, uint32_t rights);
    err_t (*activate)(struct aspace *);     /* MMU: load CR3/TTBR. MPU: program regions. none: nop */
    void  (*destroy)(struct aspace *);
};
```

The MPU implementation's `map` records a region and fails if you exceed the
hardware's region count — at *build* time if the manifest is static, which is when
you want to find out. The `none` implementation is a set of no-ops.

Everything above this interface — the scheduler, IPC, capabilities — is shared.
That's the majority of the kernel.

---

## 5. Configuration and hardware description

You need to describe hardware and wiring. The options:

| Mechanism | Where | Verdict |
|---|---|---|
| **Devicetree** | Embedded, ARM, RISC-V | Compile it to a static table for N0/N1; parse the blob for N1+. Verbose, but it's the ecosystem standard and you get vendor-supplied files. |
| **ACPI** | x86 servers | Necessary, awful, keep it in a userspace server (Appendix D §4) |
| **Discovery** | PCIe, USB | Runtime, N2+ |
| **The manifest** | Everywhere | Yours. Components, capabilities, memory budgets. |

Keep the manifest and the hardware description **separate**: hardware description
says what exists, the manifest says who may use it. That separation is exactly the
mechanism/policy line, and conflating them (as devicetree sometimes does, by
encoding driver choices) is a mistake worth avoiding.

**Recommendation:** one manifest format (TOML or similar), a build tool that reads
it plus a devicetree, and emits either static tables (N0/N1) or a boot image with
a root-task manifest (N2+). One tool, two backends. This is a weekend of Python
and it's the keystone of the whole part.

---

## 6. Does the API survive?

The honest question: can an application written for N0 run on N3 and vice versa?

**Mostly yes for the kernel ABI**, because the syscalls are the same and the
capability semantics are the same. A component that does `nyx_call(ep, msg)`
doesn't care.

**Mostly no for the system services**, because N0 has no filesystem, no process
manager, and no dynamic anything. That's fine and expected — but it argues for
one specific discipline: **write components against IDL interfaces (Chapter 10
§7), not against a system**. A sensor driver that speaks the `sensor` interface
runs anywhere the interface is provided. That's the composability that actually
matters, and it's a property of the IDL, not the kernel.

The thing to avoid: a "small libc" and a "big libc" with different semantics.
Pick a subset, make it exact, and let N0 components use only the subset. Test it
by building the N0 components for N3 and running them there.

---

## 7. Verification

| Test | Asserts |
|---|---|
| `profile_matrix` | Every profile builds, boots, passes its suite. Non-negotiable. |
| `size_budget` | Per-profile `.text`/`.data` under a threshold, tracked over time |
| `static_manifest_equivalence` | The build-tool-generated object graph for a manifest is *identical* to what the root task builds at runtime from the same manifest. **This is the test that proves §3's thesis.** |
| `no_dynamic_allocation_n0` | Link with `malloc` poisoned; N0 must not reference it |
| `mpu_regions_fit` | Every component's mapping set fits the hardware's region count — checked at build time |
| `interrupt_latency_n0` | Worst-case latency from IRQ to handler, measured on hardware, under budget |
| `ipc_shared_source` | The IPC implementation compiled for N0 and N3 is the same source file (grep for arch guards) |
| `n0_component_runs_on_n3` | Portability, tested rather than asserted |

That third one deserves emphasis: writing a test that a build-time-evaluated
manifest and a runtime-evaluated manifest produce the same object graph is what
turns "the model degrades gracefully" from a claim into a property.

---

## 8. What this buys you, concretely

- **One codebase, one mental model, one set of tests** across a range that
  currently requires three separate operating systems.
- **A component written for a sensor node runs on a server** for testing and
  simulation. Development on a laptop, deployment to a microcontroller, with the
  *same binary semantics*.
- **The security story is uniform**: capabilities all the way down, and at the
  small end the graph is a compile-time constant you can exhaustively verify.
- **A path for real deployments**: an MCU running a motor controller, a gateway
  running N1, and a datacenter node running N4 — speaking the same IPC, with
  interfaces defined in the same IDL. Which is exactly the setup Chapter 28 needs.

---

## 9. Exercises

1. Write the manifest format and the build tool. Emit static tables for N0 and a
   boot image for N2. Then write the `static_manifest_equivalence` test.
2. Port the kernel to a Cortex-M or RISC-V MCU under QEMU with the `none` aspace
   backend. Measure the resulting `.text` size and the IPC cost in cycles.
3. Add the MPU backend. Find out how many regions your components actually need,
   and whether real hardware gives you enough.
4. Take one component from N3 (say, a driver) and build it for N0 unchanged.
   Document every place it failed and why.
5. Set up the size-tracking CI job. Look at the graph after a month.
6. Read Hubris's design documentation and write a page on where its choices
   differ from yours and who's right.
7. **Argue the other side:** make the case that scaling down is a distraction —
   that the constraints are different enough that a purpose-built RTOS is better
   at the small end, and that sharing code costs both ends. What evidence would
   settle it?

---

Next: [28 — Scaling up: the machine, the rack, the cluster](28-distributed.md)
