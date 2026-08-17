# 00 — Operating system structure and the microkernel argument

> Read this before you write a line of code. Structure decisions made in week one
> are the ones you cannot undo in month six.

---

## 1. What an operating system actually is

Strip away everything familiar and an OS is a program that solves one problem:

> **Multiple mutually distrusting computations must share one machine, and the
> machine's interface is hostile to sharing.**

Hardware gives you exactly four primitives to work with:

1. **Privilege levels** — some instructions only execute in a privileged mode.
2. **Address translation** — an MMU maps virtual addresses to physical ones,
   per-context, with permission bits.
3. **Interrupts and exceptions** — the hardware can forcibly transfer control to
   a privileged handler.
4. **Timers** — a device that guarantees an interrupt will happen eventually, so
   no computation can hold the CPU forever.

Every OS abstraction — processes, files, sockets, containers, VMs — is built out
of those four things. A microkernel is the design position that says: *expose
those four things safely and get out of the way.*

### The three jobs

| Job | Meaning |
|---|---|
| **Multiplexing** | Share a scarce resource (CPU, RAM, disk) among clients. |
| **Abstraction** | Present something more usable than the raw resource (a file, not sectors). |
| **Protection** | Ensure one client cannot violate another's integrity or confidentiality. |

A key insight, from the exokernel work (Engler & Kaashoek, 1995): **multiplexing
and protection require privilege; abstraction does not.** Abstraction is a
library concern. That observation is the intellectual root of everything in this
book.

---

## 2. Structural taxonomy

### 2.1 Monolithic

All OS services run in the privileged address space: scheduler, VM, filesystems,
network stack, drivers. Linux, FreeBSD, Windows NT's kernel-mode portion.

- **Pro:** service-to-service calls are function calls. No IPC. Extremely fast.
  Shared data structures. Easy to add features.
- **Con:** one bug anywhere is a total-system compromise. A NIC driver has the
  same authority as the scheduler. The trusted computing base (TCB) is tens of
  millions of lines. No enforcement of internal interfaces, so the code becomes
  a graph, not a hierarchy.

Modern reality: Linux is ~30M lines, the vast majority drivers, and the majority
of CVEs are driver and filesystem bugs — code that *did not need* full privilege.

### 2.2 Microkernel

Only the irreducible minimum runs privileged. Everything else — filesystems,
network, drivers, paging *policy*, process management — is a user process,
communicating by message passing.

Liedtke's **minimality principle** (1995) makes "minimum" precise:

> A concept is tolerated inside the kernel only if moving it outside the kernel,
> i.e. permitting competing implementations, would prevent the implementation of
> the system's required functionality.

By that test the kernel needs: address spaces, threads/execution contexts, IPC,
and a way to route interrupts. Almost nothing else survives.

- **Pro:** TCB is ~10k lines and can be reasoned about (seL4 proved theirs
  correct). Failure isolation: a crashed driver is a crashed process. Servers
  can be restarted, upgraded live, replaced, or run in multiple competing
  versions. Interfaces are *enforced* by the hardware, so the architecture
  cannot rot.
- **Con:** every cross-component call is an IPC — a mode switch, a scheduling
  decision, cache and TLB pressure. Shared state becomes explicit protocol.
  Debugging spans processes. You must design an ABI, and you must live with it.

### 2.3 Hybrid / modular

XNU (Mach + BSD in one address space), Windows NT. Uses microkernel-ish
*structure* but co-locates servers in kernel space for performance. You get the
IPC costs *and* the shared-fate costs; often the worst of both, occasionally a
pragmatic win.

### 2.4 Exokernel

Kernel only multiplexes and protects; abstraction lives in unprivileged
"library OSes" linked into applications. Extremely fast for specialized apps,
extremely hostile to general-purpose sharing.

### 2.5 Unikernel

Single application + library OS, single address space, no protection boundary
internally, isolated by a hypervisor instead. The protection domain moved down
one level. Relevant to us because it shows the boundary's *placement* is a design
variable.

### 2.6 Where Nyx sits

Nyx is a **capability-based microkernel** in the seL4/L4 lineage, with MINIX 3's
system-structure sensibilities (userspace drivers, a reincarnation server,
recovery over prevention) and modern asynchronous I/O ideas grafted on. The
kernel provides:

```
threads · address spaces · capability spaces · IPC · notifications ·
interrupt-as-notification · untyped memory retyping · a minimal scheduler
```

and nothing else. Not even a filesystem interface. Not even `fork`.

---

## 3. The microkernel research program, honestly

You should know this history because it is the story of a hypothesis being
falsified, then rescued.

### Generation 1: Mach (CMU, late 1980s)

Mach introduced ports (capability-ish message endpoints), external pagers,
memory objects, and a clean IPC model. It was influential and **slow**. IPC cost
~100µs; systems built on it (OSF/1, early XNU) had to pull services back into the
kernel to be competitive. The community concluded microkernels were inherently
slow.

Why was it slow? Not because of message passing per se:

- IPC was optimized *late*, and the design had large, complex messages with
  in-kernel copy semantics and port-rights bookkeeping.
- The kernel was ~300 KB of code and data — it thrashed the (then tiny) caches.
- Cross-address-space calls did not preserve the cache/TLB working set.

### Generation 2: L4 (Liedtke, 1993–95)

Liedtke's response was essentially: *you measured my implementation, not my
idea.* L4 achieved IPC in ~5µs on a 486 — a 20× improvement — by:

- **Register-based messages.** Short messages never touch memory.
- **Minimality.** The kernel's cache footprint was kilobytes.
- **Direct process switch.** On a `call`, transfer directly to the receiver
  without going through the scheduler — the sender donates its remaining time
  slice. IPC becomes something very close to a protected function call.
- **Lazy scheduling.** Avoid touching scheduler queues on the fast path.
- **Architecture-specific implementation.** L4's *interface* is portable; its
  *implementation* is deliberately hand-tuned per architecture, including
  assembly fast paths.

The lesson: **IPC performance is not a structural property, it's an engineering
outcome.** Design your IPC path first and measure it obsessively.

### Generation 3: seL4 (NICTA/Data61, 2009→)

seL4 kept L4 performance and added:

- **Capabilities for everything**, including memory. There is no kernel heap;
  all kernel objects are created by *retyping* user-provided **untyped memory**.
  This makes kernel memory consumption fully accountable to a principal, which
  kills whole classes of DoS.
- **A machine-checked proof** of functional correctness (C implementation refines
  an abstract spec), plus integrity, confidentiality, and binary-correctness
  proofs. ~10k lines of C, ~200k lines of Isabelle/HOL proof.
- **MCS (mixed criticality) scheduling**: scheduling contexts as capabilities,
  so time is a first-class, delegatable, accountable resource.

### The parallel track: MINIX 3 (Tanenbaum et al., 2005→)

Different emphasis: not proof, not raw IPC speed, but **dependability by
recovery**.

- All drivers are unprivileged user processes with restricted access to I/O.
- A **reincarnation server** monitors them and restarts crashed or unresponsive
  ones. Drivers are designed to be restartable — the state needed to recover
  lives elsewhere.
- Simple, readable, synchronous message-passing kernel of a few thousand lines.
- Explicit **grants**: a process authorizes another to read/write a specific
  memory range, rather than handing over general access.

MINIX 3's contribution to your project is a *systems* mindset: assume components
fail; make failure survivable and cheap; prefer restart to correctness proofs
where proofs are unaffordable.

### The verdict

Microkernels lost the desktop/server market on ecosystem and inertia, not
merit — and they quietly won everywhere isolation is non-negotiable: seL4 in
avionics and defence, QNX in cars (>200M vehicles), L4 variants in billions of
phone basebands and secure enclaves, Google's Fuchsia/Zircon, Apple's Secure
Enclave. Your project sits in a live tradition, not a museum.

---

## 4. The design principles you will apply

### 4.1 Separate policy from mechanism

The kernel provides *mechanism* (this thread can run; this frame can be mapped);
userspace decides *policy* (which thread should run; which page to evict).

Concretely in Nyx: the kernel implements a fixed priority round-robin with a
timeslice, but priorities and timeslices are set through capabilities held by a
userspace scheduler server. Page faults are *delivered as IPC* to a userspace
pager, which decides what to do.

### 4.2 Principle of least authority (POLA)

Every component receives exactly the authority needed for its task, no more, and
that authority is **explicit and unforgeable**. This is why we use capabilities
instead of a global namespace with permission checks: with capabilities, the
*absence* of a reference is the enforcement, and there is no confused deputy.

### 4.3 The end-to-end argument

Don't implement a function at a low level if it must be reimplemented at a higher
level anyway. Reliability, encryption, and ordering usually belong at the
endpoints. The kernel should not do checksums.

### 4.4 Design the fast path first

Identify the operation that dominates (for us: `call`/`replyrecv` IPC between two
threads on one core) and design the entire data layout around making it fast.
Everything else can be a slow path in C.

### 4.5 Make the common case explicit, the rare case correct

Kernel code has a nasty property: the rare path is where the security bugs live
and where you have no test coverage. Write the rare path *first*, in the clearest
possible way, then add the fast path as an optimization that provably falls back.

### 4.6 Everything is an object with a capability

Uniformity buys you a lot: one revocation mechanism, one accounting mechanism,
one delegation mechanism. Resist adding a special case.

---

## 5. Architectural patterns you will implement

| Pattern | Where it shows up | Why |
|---|---|---|
| **Rendezvous / synchronous message passing** | Core IPC | No buffering ⇒ no kernel memory per message ⇒ no queue-overflow DoS. Sender blocks until receiver takes it. |
| **Client–server** | Every service | The universal microkernel structure. Servers are passive; they loop on `replyrecv`. |
| **Handoff / direct process switch** | IPC fast path | Turn a call into something close to a protected procedure call. |
| **Upcall** | Page faults, exceptions, interrupts | The kernel converts an event into a message to a userspace handler. Inverts control flow so *policy* can live outside. |
| **Capability + badge** | Server identifying its clients | The server receives an unforgeable per-client tag with each message, so no authentication protocol is needed. |
| **Grant / shared buffer** | Bulk data transfer | Avoid copying megabytes through registers. MINIX-style grants; modern shared rings. |
| **Reincarnation / supervisor tree** | Fault recovery | Erlang's idea, applied to drivers. |
| **Stateless-where-possible servers** | Restartability | State that can be reconstructed from clients is state you don't have to checkpoint. |
| **Retyping untyped memory** | Kernel object allocation | Removes the kernel heap; makes memory accountable. |
| **Multi-server layering** | init → pm → vfs → drivers | Explicit dependency ordering, resolvable at boot. |

---

## 6. The costs you are signing up for — and their mitigations

Be clear-eyed. These are real.

**1. IPC on every cross-component call.**
A `read()` in a monolithic kernel is one syscall. In a naive microkernel it is:
app → VFS → filesystem server → block driver → back, i.e. up to 8 mode switches
and 4 address-space switches.
*Mitigations:* fast-path IPC in assembly; direct process switch; batching via
shared rings so N operations amortize one switch; PCID/ASID tagging so address
space switches don't flush the TLB; server co-location where isolation isn't
needed.

**2. Address space switch cost.**
`mov cr3` flushes the TLB unless you use **PCID**. Post-Meltdown, kernel/user
separation (KPTI) adds more. On modern x86 with PCID and INVPCID this is
manageable; you will implement it in Chapter 06.

**3. Cache/TLB working set fragmentation.**
Splitting one process into five means five sets of hot cache lines.
*Mitigation:* keep the kernel tiny (it's a shared, always-hot working set) and
keep messages register-resident.

**4. Loss of shared data structures.**
The page cache can't be a global structure that everyone pokes at.
*Mitigation:* shared memory objects with explicit capabilities; a memory server
that hands out mappings. This is more work but also more honest.

**5. Protocol design burden.**
Every interface is now a wire format with versioning, error handling, and
capability-passing semantics.
*Mitigation:* an IDL and generated stubs (Chapter 10). Do not hand-write message
marshalling; you will get it wrong and it will be a security hole.

**6. Debugging across boundaries.**
*Mitigation:* build tracing into IPC from day one (Chapter 18). A message trace
with timestamps is worth more than any single-process debugger.

---

## 7. The Nyx object model (preview)

The kernel knows about exactly these object types. Everything else is userspace.

```
Untyped        A region of physical memory not yet used for anything.
               Can be retyped into any other object, or split.

CNode          A capability table (an array of capability slots).
               A thread's CSpace is a tree of CNodes — a guarded page table
               for capabilities.

TCB            Thread control block: registers, scheduling params, its CSpace
               root, its VSpace root, its fault endpoint.

VSpace         (arch: PML4) An address space: a tree of page tables.
Frame          A physical page that can be mapped into a VSpace.

Endpoint       A synchronous IPC rendezvous point.
Notification   An asynchronous binary-semaphore/bitmask signal object.

IRQHandler     Authority to receive a specific hardware interrupt as a
               Notification signal.
IOPort         Authority over a range of x86 I/O ports (for legacy drivers).

SchedContext   (MCS-style, Ch.13) A budget of CPU time, delegatable.
```

Every syscall is an *invocation of a capability*. There are only a handful of
actual syscall numbers:

```
send · recv · call · replyrecv · nbsend · nbrecv · signal · wait · yield ·
invoke (object-specific method, e.g. CNode_Copy, Untyped_Retype, Page_Map)
```

If you find yourself wanting to add syscall number 40, ask whether it's really an
invocation on some object you haven't named yet. Usually it is.

---

## 8. What "modern" means here

Nyx isn't a MINIX clone; it's MINIX's structure with the last twenty years of
systems research folded in. Specifically, we will build or scaffold:

- **Capability-based security** rather than UID/ACL ambient authority.
- **Untyped-memory accounting** so a process can't exhaust kernel memory.
- **x86-64 long mode**, PCID, SMEP/SMAP, W^X, NX, KASLR-ready design, and
  mitigation-aware entry/exit paths (Chapter 06, 10).
- **Asynchronous, batched IPC rings** alongside synchronous IPC (io_uring's
  lesson: syscall batching beats syscall optimization).
- **Userspace drivers with IOMMU-enforced DMA**, not "trusted" drivers.
- **MSI/MSI-X interrupts routed as capability-gated notifications.**
- **Live restart and upgrade** of servers (reincarnation, extended).
- **A design amenable to formal reasoning** — invariants written down, small
  kernel, no dynamic kernel allocation.
- **A test/trace/benchmark harness** as a first-class subsystem, not an
  afterthought.

Chapter 13 goes further, into the genuinely open research territory.

---

## 9. Exercises

1. Take a system call you know well (`read`, `mmap`, `poll`) and write out, on
   paper, the exact sequence of components and messages it would require in a
   multi-server microkernel. Count the mode switches. Then redesign it to reduce
   that count without collapsing components. This is the core skill.
2. Apply Liedtke's minimality principle to five features of Linux (e.g. cgroups,
   the page cache, `epoll`, signals, the ELF loader). For each: does it survive?
   If not, what kernel mechanism must exist for a userspace implementation to be
   possible?
3. Read the seL4 API reference's list of object types and compare to §7. What did
   they include that we omitted, and can you argue we need it?
4. Argue the *other side*: write 500 words defending the position that Linux's
   monolithic structure is correct given real-world constraints. If you can't,
   you don't understand the tradeoff yet.

---

Next: [01 — The x86-64 machine](01-x86-architecture.md)
