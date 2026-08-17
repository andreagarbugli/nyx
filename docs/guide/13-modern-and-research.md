# 13 — Modern and experimental directions

> This is the chapter that turns a learning project into a workbench. Everything
> here is either state of the art, actively researched, or genuinely open. Each
> section gives you: the idea, why it matters, what it costs, and a concrete
> first step in Nyx.

Pick two or three. Don't try to do all of them — the value is in going deep
enough to produce a *measurement* or a *design document* someone else could
learn from.

---

## 1. Asynchronous, batched system calls

**The idea.** The cost of crossing the kernel boundary is roughly fixed
(~100–500 cycles) and hasn't improved much in a decade, while per-operation work
has gotten cheaper. So the ratio has gotten worse. The answer isn't a faster
syscall; it's *fewer* syscalls per unit of work.

Lineage: FlexSC (2010, "exception-less system calls"), Barrelfish's message
passing, Windows I/O completion ports, and — the one that made it mainstream —
**io_uring** (2019).

**Why it matters for you.** A microkernel's structural weakness is boundary
crossings. Batching directly attacks it. This is arguably the most important
"modern feature" you can add, because it changes the performance argument against
microkernels.

**Cost.** Shared memory means untrusted input; every descriptor must be validated
(carefully — see the TOCTOU note in Chapter 08). Completion-based APIs are harder
to program against than blocking ones. Buffer lifetime becomes the caller's
problem.

**First step in Nyx.** You already have rings (Chapter 08 §6). Extend them from
"a data plane between two userspace processes" to "a submission channel for
*capability invocations*":

```
struct sqe {                       /* submission queue entry */
    uint8_t  opcode;               /* SYS_CALL, SYS_INVOKE, ... */
    uint8_t  flags;                /* LINK: don't start until previous done */
    uint16_t ncaps;
    uint32_t user_data;            /* echoed in the completion */
    uint64_t cap;                  /* CPtr */
    uint64_t args[4];
};
```

The kernel drains the ring when signalled, or a dedicated kernel thread polls it
(io_uring's `SQPOLL` mode: zero syscalls in steady state).

**The experiment to run.** Measure a workload — say 100k IPC operations — three
ways: one syscall each, batched in groups of 32, and fully polled. Plot
throughput and latency. You'll get a curve that tells you exactly where the
crossover is, and that curve is a genuinely interesting result for a microkernel.

**Open question worth exploring.** Batching and synchronous rendezvous IPC are in
tension: a `call` blocks by definition. Can you design a batched interface where
*dependent* calls (A's reply feeds B's argument) are expressed as a linked chain
executed entirely in the kernel? io_uring's `IOSQE_IO_LINK` does this for I/O.
Doing it for arbitrary IPC chains would be new.

---

## 2. Passive servers and scheduling contexts (seL4 MCS)

**The idea.** Time is a resource, so it should be a capability. A
**SchedContext** object holds a budget and a period. A thread runs only when it
has a scheduling context. A **passive server** has *no* scheduling context of its
own — when a client calls it, the client's scheduling context is *donated* for
the duration of the call.

**Why it matters.**

- **Priority inversion vanishes structurally.** There is no server priority to
  invert; the server runs at whatever the caller has.
- **Accounting is correct.** The client is charged for the work its request
  causes. In a conventional design, a server doing work on behalf of a client is
  charged to the server, which is both unfair and exploitable.
- **Mixed criticality** becomes expressible: a low-criticality client cannot
  starve a high-criticality one via a shared server.

**Cost.** Every server must be restructured. Donation must be tracked through
call chains. The kernel needs a timeout/budget-exhaustion path (what happens when
the budget runs out mid-call? seL4 delivers a timeout fault to a handler). This
is real complexity, and getting it right is a project.

**First step in Nyx.** Add a `SchedContext` object with `budget_ns` and
`period_ns`; make `TCB_SetSchedContext` an invocation. Implement donation only
for the direct-switch IPC fast path first (the client's remaining timeslice
transfers, which you're already doing informally — make it explicit and
accounted). Then add budget replenishment on a timer.

**The measurement.** Build a three-thread priority-inversion scenario (low
priority client, medium priority spinner, high priority client, shared server).
Show the inversion with fixed-priority servers, then show it eliminated with
passive servers. That's a compelling demo.

---

## 3. Rust in the kernel and in userspace

**The idea.** Memory safety without garbage collection. The overwhelming majority
of kernel CVEs are memory-safety bugs; a language that eliminates them by
construction removes them.

**Where it fits, in decreasing order of value:**

1. **Userspace drivers and servers.** Highest value, lowest friction. A driver
   parsing attacker-controlled packets is exactly where you want Rust, and your
   ABI is language-agnostic so it's a drop-in. **Start here.**
2. **The root task and system initialization.** Complex logic, security-critical,
   no hard real-time constraint.
3. **Kernel subsystems.** Possible, but a microkernel's C is only ~10k lines and
   much of it is `unsafe` by nature (page tables, register state). The
   cost/benefit is weaker than in Linux.

**Cost.** A second toolchain, FFI boundaries, `no_std` limitations, and the fact
that the interesting parts of kernel code are `unsafe` anyway — Rust doesn't
verify your page table logic, it just contains the damage elsewhere.

**First step.** Write the ramdisk or console driver in Rust:

```rust
#![no_std]
#![no_main]

use libnyx::{Endpoint, Message, CPtr};

#[no_mangle]
pub extern "C" fn _start() -> ! {
    let ep = Endpoint::from_cptr(CPtr(CAP_SERVICE_EP));
    let mut msg = Message::default();
    let mut badge = ep.recv(&mut msg);
    loop {
        handle(badge, &mut msg);
        badge = ep.reply_recv(&mut msg);
    }
}
```

Build with `--target x86_64-unknown-none`, `panic = "abort"`, link against your
`libnyx` shim.

**The interesting research direction.** Can the *type system* encode capability
discipline? A `Capability<Endpoint, Rights::WRITE>` type that cannot be forged,
where `mint()` returns `Capability<Endpoint, R2>` with `R2: SubsetOf<R>` checked
at compile time. Then capability-safety errors become compile errors in your
servers. This is a real, publishable direction and it composes beautifully with
the OS design.

---

## 4. Formal verification

**The idea.** Prove, mechanically, that your implementation satisfies a
specification.

**The reality of seL4's effort:** ~10k lines of C, ~500k lines of Isabelle/HOL
proof, ~20 person-years for the initial functional correctness proof. That is not
a weekend project.

**But there is an enormous amount of value at lower cost.** In increasing order
of effort:

| Technique | Effort | What you get |
|---|---|---|
| **Write down invariants** | Hours | The single highest-value activity in this list. Most bugs are invariant violations nobody named. |
| **Runtime invariant checking** | Days | `KASSERT` the invariants at every subsystem entry/exit under a debug build. Cheap, finds real bugs. |
| **Property-based testing** (host) | Days | Generate random operation sequences against your allocator/CDT/CSpace, check invariants. |
| **Bounded model checking (CBMC)** | Weeks | Prove a specific function has no UB, no overflow, no assertion failure, for all inputs up to a bound. Works well on self-contained algorithms: buddy allocator, capability lookup, ring buffers. |
| **Symbolic execution (KLEE)** | Weeks | Automatic test generation with high coverage on parsers and decoders. |
| **Refinement proof (Isabelle/Coq)** | Years | seL4-level assurance. |
| **Rust + verification (Verus, Prusti, Kani)** | Months | Rapidly maturing; much better effort/assurance ratio than Isabelle. **Probably the right modern choice.** |

**First step.** Write `docs/invariants.md`. For each subsystem, list the
properties that must always hold. Examples:

```
CSPACE
  I1. Every capability's rights are a subset of its CDT parent's rights.
  I2. The CDT is a forest: no cycles, every node's parent precedes it.
  I3. An object's refcount equals the number of capabilities pointing to it.
  I4. A CNode slot is either CAP_NULL or a well-formed capability.

IPC
  I5. An endpoint's queue contains threads all in the same blocked state.
  I6. A thread is on at most one endpoint queue.
  I7. thread.blocked_on != NULL ⟺ thread.state ∈ {BLOCKED_SEND, BLOCKED_RECV}
  I8. No IPC operation allocates memory.

MEMORY
  I9. Every frame is either free, or reachable from exactly one Untyped's
      allocated range.
  I10. No page is simultaneously writable and executable.
```

Then `#ifdef CONFIG_CHECK_INVARIANTS` a function per subsystem that verifies them,
and call it at every syscall boundary in debug builds. This is 90% of the value
of verification for 1% of the cost.

**Then:** take *one* self-contained function — `cap_lookup` is ideal — and prove
it with CBMC. It's tractable in a weekend and it teaches you what verification
actually feels like.

---

## 5. Safe kernel extensions (the eBPF question)

**The idea.** Sometimes you need code to run *in* a privileged, latency-critical
context (packet filtering, tracing, scheduling hints) without a boundary crossing.
eBPF's answer: a restricted bytecode, statically verified for termination and
memory safety, then JIT'd.

**The microkernel tension.** eBPF exists because Linux's boundaries are
expensive and in the wrong places. If your IPC is 300 cycles, do you need it?

**Where it's still interesting:**

- **Tracing and observability.** Attaching a filter to every IPC without
  recompiling the kernel is genuinely useful. This is the strongest case.
- **Interrupt-context work.** A driver that must respond in <1 µs might want a
  small verified program in the interrupt path.
- **Policy in the fast path**: a scheduling hint, an admission control decision.

**Alternative worth exploring: WebAssembly.** WASM is a better-designed sandbox
than eBPF — real types, a memory model, mature toolchains, and a
capability-shaped import model (a module can only call what it's given, which is
*exactly* your OS's security model). A WASM runtime as a Nyx component, where
WASM imports map 1:1 onto capability invocations, is a clean and genuinely novel
design.

**First step.** Add a tracing hook: a table of (event, filter program) that the
IPC path consults. Implement the filter as a tiny interpreted bytecode first;
JIT later if you care. Then ask whether it earned its keep.

---

## 6. Virtualization: Nyx as a hypervisor

**The idea.** A microkernel is already most of a hypervisor: it has address
spaces, scheduling, and interrupt routing. Add VMX/SVM support and each VM becomes
another object type. NOVA, seL4, Fiasco.OC, and Bareflank all do this.

**Why it matters.** It's the pragmatic path to a usable system: run Linux as a
guest for the ecosystem while your native components handle the security-critical
parts. This is exactly the architecture of most deployed seL4 systems.

**Design in Nyx:**

```
VCPU        A new object type: VMCS/VMCB state, guest register file.
            Invocations: VCPU_Run, VCPU_ReadRegs, VCPU_WriteRegs.
VSpace      Extended with an EPT/NPT mode: the guest's physical memory is a
            second-level page table the VMM constructs from Frame caps.
```

The VM exit path becomes an **upcall**: the kernel exits the guest, packages the
exit reason into a message, and sends it to the VMM's endpoint. A userspace VMM
handles MMIO emulation, virtio devices, and interrupt injection. The kernel's
role stays tiny.

**First step.** Get `vmxon` working and run a guest that does nothing but `hlt`.
That alone is a substantial milestone and teaches you the VMCS. QEMU with nested
virtualization (`-cpu host,+vmx` with KVM) supports this.

---

## 7. Heterogeneous and non-x86 targets

**Why port.** Nothing exposes leaky abstractions like a second architecture. Your
`arch/` boundary is theoretical until you test it.

**RISC-V (rv64gc)** is the best second target:

- Clean, small, well-documented spec. Sv39/Sv48 paging is the same shape as x86-64.
- Three privilege modes (M/S/U); you write S-mode code, SBI handles M-mode.
- QEMU `virt` machine is excellent and well-supported.
- The `ecall` instruction is a much simpler syscall than `syscall`/`sysret`.
- **Genuinely open research space**: RISC-V's extensibility (custom instructions,
  the PMP for physical memory protection, upcoming CHERI-RISC-V) means you can
  explore hardware/OS co-design in a way you cannot on x86.

**ARM64** is the pragmatic second target (real hardware everywhere), with the
interesting wrinkle of ASIDs, EL0/EL1/EL2, and GIC interrupt controllers.

**The exercise that pays.** Before porting, list every file in `kernel/` that
mentions x86. Every one is an abstraction leak. Fix them first; the port becomes
mechanical.

---

## 8. CHERI: capabilities in hardware

**The idea.** CHERI extends pointers into 128-bit **capabilities** carrying
bounds, permissions, and a hardware validity tag that ordinary stores cannot
forge. Every memory access is bounds-checked by hardware.

**Why this is the most interesting long-term direction in this chapter.** Your OS
has capabilities at *object* granularity (endpoints, frames, TCBs). CHERI has them
at *memory* granularity. Composing them gives you:

- Spatial memory safety for free in C — buffer overflows become traps.
- Capabilities that can live safely in *user* memory (the tag makes them
  unforgeable), which removes the CSpace indirection and could make IPC faster.
- Compartmentalization *within* a process, at near-zero cost, which changes the
  decomposition calculus: you'd split things you currently wouldn't because the
  IPC cost is too high.

**A capability microkernel on CHERI hardware, where OS capabilities and hardware
capabilities are the same thing, is an open and interesting design.** CheriBSD
exists; a from-scratch CHERI microkernel with unified capabilities does not, in
any mature form.

**First step.** Get CheriBSD's QEMU (`qemu-system-riscv64cheri` or Morello) and
run a hello-world. Then write a design doc: what would Nyx's CSpace become if
capabilities could live in user memory?

---

## 9. Persistence and single-level store

**The idea.** KeyKOS and EROS made the *entire system state* persistent:
periodic transparent checkpoints meant a power failure lost at most a few
seconds, and there was no distinction between memory and disk. No files, no
`save`, no serialization — objects just exist.

**Why it's newly relevant.** Byte-addressable persistent memory (Optane's
demise notwithstanding, CXL-attached memory and battery-backed DRAM continue) and
enormous RAM make the "one address space, always persistent" model practical
again. And the idea was never refuted — it was just ahead of the hardware.

**The hard problems** (which are what makes it interesting):

- **Consistency**: a checkpoint must be a consistent cut of all state, including
  in-flight IPC. In a synchronous rendezvous system this is *easier* than in an
  asynchronous one — there are no messages in flight, only blocked threads. That's
  a real advantage worth writing about.
- **Device state**: hardware can't be checkpointed. Drivers must be able to
  reconstruct device state after a restore. This is the same property that makes
  them restartable (Chapter 11), so the work compounds.
- **Capability persistence**: capabilities point at kernel objects; a checkpoint
  must serialize the object graph.

**First step.** Implement checkpoint/restore for a *single* component: suspend
its threads, serialize its VSpace contents and CSpace, write to the ramdisk,
restore into a fresh process. You'll immediately hit the device-state problem and
learn why it's the crux.

---

## 10. Timing channels and real isolation

**The idea.** Capabilities control explicit information flow. They do nothing
about the cache, the TLB, the memory bus, DVFS, or branch predictors.

**What's known:**

- seL4 has a verified *time protection* mechanism: cache colouring to partition
  the L2/L3 between domains, plus flushing everything switchable on domain
  switches, plus padding the switch to a constant duration.
- It requires hardware support that mostly doesn't exist as documented
  behaviour — the seL4 team has published on the fact that current hardware
  cannot support verified time protection, and what ISA extensions would be
  needed.

**Why it's a good workbench project.** You can *measure* channels. Build a
covert-channel benchmark (a sender modulating cache sets, a receiver measuring
access times), report the bandwidth in bits/second, then implement a mitigation
and re-measure. That's a complete, self-contained research contribution and it's
achievable.

**First step.** Implement page colouring in your physical memory allocator:
`pmm_alloc_colored(color)` returns frames whose physical address maps to a
specific L2 cache set range. Give each security domain a disjoint colour set.
Measure the channel bandwidth before and after.

---

## 11. Automatic component placement and adaptive structure

**The idea.** In a multi-server system, *where* components run (which core, which
NUMA node) and *how* they're grouped dramatically affects performance. Currently
this is set by hand.

**The opportunity.** Your kernel already sees every IPC. It can build the
communication graph at runtime: who talks to whom, how often, with what message
sizes. From that you can:

- Co-locate heavily-communicating components on the same core (better cache
  locality) or on the same NUMA node.
- Detect that two components exchange 10M messages/sec with 8-word messages and
  suggest they should share a ring instead.
- Automatically decide when a component should be *merged* into another's address
  space (trading isolation for speed) — with the isolation decision made
  explicitly and reversibly.

**This is genuinely underexplored** and your architecture makes it natural:
the IPC graph is a first-class, observable object.

**First step.** Add per-endpoint counters (message count, total words, latency
histogram). Dump the graph as Graphviz. Look at it. You will immediately see
something you didn't expect.

---

## 12. A shortlist of other directions

- **Deterministic execution.** Make the system reproducible given the same
  inputs — no timing-dependent scheduling. Enables record/replay debugging,
  deterministic testing, and closes timing channels. Requires a logical clock
  instead of a physical one.
- **Live kernel update.** You already restart servers. Can you replace the
  *kernel*? (Suspend everything, save the object graph, load a new kernel, restore.
  Feasible precisely because the kernel is small and the object graph is explicit.)
- **A capability-native network protocol.** Extend capability invocation across
  machines. This is what Amoeba and Mach did badly and what Cap'n Proto's RPC
  does well. A distributed capability system with a real OS underneath is
  interesting.
- **GPU / accelerator as a first-class object.** Everyone's compute is
  heterogeneous now and nobody's OS model reflects it. What does a capability to
  a GPU queue look like?
- **Confidential computing.** SEV-SNP / TDX put the hypervisor outside the TCB.
  A microkernel *inside* a confidential VM, with a minimal attested TCB, is a
  practical and current problem.
- **Energy-aware scheduling as a capability.** MCS makes time a capability; make
  *energy* one too. Relevant for battery devices and increasingly for datacenters.
- **Formally specified ABI.** Write your syscall interface in a spec language and
  generate the stubs, the dispatcher, the documentation, and the test cases from
  it. Removes an entire class of client/server mismatch.

---

## 13. How to actually do research with this

1. **Pick a question with a measurable answer.** "Is batched IPC faster?" is
   answerable. "Is my OS good?" is not.
2. **Build the measurement infrastructure first** (Chapter 18). If you can't
   measure the baseline, you can't evaluate the change.
3. **Get a baseline number and write it down**, with the exact configuration.
4. **Change one thing.**
5. **Write it up** — even just a `docs/experiments/2026-08-batched-ipc.md` with
   the hypothesis, method, numbers, and conclusion. This is the difference
   between a hobby and a workbench. Six months later, the write-ups are what you
   still have.
6. **Compare against the literature.** seL4 publishes IPC numbers; Linux
   publishes lmbench numbers. If yours are 10× off, that's information.

---

## 14. Exercises

1. Pick one direction from this chapter. Write a two-page design document: the
   problem, the design, the invariants it must preserve, what you'll measure, and
   what result would falsify your hypothesis. Do this *before* coding.
2. For your chosen direction, find the three most relevant papers (Chapter 20 has
   starting points) and write one paragraph each on what they did and where they
   stopped.
3. Build the IPC communication graph visualizer (§11). Run your full system boot
   and look at the graph. Write down three things that surprised you.

---

Next: [14 — Real-time: predictability as a first-class property](14-realtime.md)
