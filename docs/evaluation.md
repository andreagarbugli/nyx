# Evaluation: ideas, design, and implementation

- first written: 2026-08-13 (pre-M3.0; §1–§12)
- addendum: 2026-08-13 evening, after M3.0 / kernel W^X / M3.0.5
  (§13–§14)
- scope of §1–§12: `master` at M2.2 plus the then-uncommitted M3.0
  work. Left as a historical reading — several of its findings were
  acted on in the next three commits, and rewriting them would hide
  that.
- scope of §13–§14: committed HEAD `62c401f` (M3.0.5), plus how to
  take the other P5 verticals later without forking the workbench.
- not: a code-review of every function, and not a plan for the next
  milestone. Those belong in `ROADMAP.md` and a review file.

This is a reading of three things that are easy to conflate: what Nyx
claims to be, what the guide specifies, and what the kernel actually
does. Where they agree, that is a finding. Where they disagree, that is
the more useful finding.

**Current one-sentence view** (after §13): the design is better than
§1 described, because the project chose a vertical and then built the
consequences. Track A stays the product. Other verticals — especially
graphics — are the same kernel plus a different manifest, not a
different kernel, not a long-lived branch.

The living versions of what this file argued for are now:

- [`architecture.md`](architecture.md) — the system as it is
- [`abi.md`](abi.md) / [`abi-policy.md`](abi-policy.md) — the contract
- [`invariants.md`](invariants.md) — never-violate, with status
- [`open-questions.md`](open-questions.md) — decisions still owed
- [`verticals.md`](verticals.md) — how B/C/D happen later
- [ADR-0006](decisions/0006-verticals-are-manifests.md) — proposed

§14 is the argument that produced `verticals.md`; if they disagree,
the dedicated file wins.

---

## 1. Verdict

Nyx is a strong workbench with a sharper idea than most from-scratch
kernels, and the code through M2.2 is unusually honest. The risk is not
the quality of what has been built. The risk is that the *written*
system is three architectures at once, M3.0 is the first point at which
those pieces have to compose, and that work is unfinished while already
drifting from the spec.

The project is doing the rare thing well: measuring, refusing to
stub-and-declare, and arguing with its own guide in public. It will
stop doing that the moment “the guide has a chapter on X” becomes a
reason to implement X.

**One sentence.** Treat P5 track A (real-time + TSN) as the product,
finish M3.0 as specified rather than as “the files exist,” and freeze
the ABI before `libnyx` exists. Everything else is a later system.

---

## 2. What the project is claiming

`README.md` and `CLAUDE.md` agree on the role of this tree: it is not
the product. It is the place where the design is forced to meet a
machine, so that findings can flow back as ADRs and guide corrections
before a main-repo implementation. That framing is load-bearing. A
hobby kernel that aspires to be seL4 is a trap. A workbench that can
answer “does this invariant survive contact with `syscall`?” is a
tool.

The intended kernel, from guide 00 §2.6:

```
threads · address spaces · capability spaces · IPC · notifications ·
interrupt-as-notification · untyped memory retyping · a minimal scheduler
```

and nothing else. Not a filesystem interface. Not `fork`. The
intellectual sources are named and, unusually, not flattened into one
slogan:

| Source | What is being taken |
|---|---|
| L4 / seL4 | minimality, register messages, direct process switch, capabilities including memory, no IPC timeouts |
| MINIX 3 | userspace drivers, reincarnation, restart over proof, grants |
| Exokernel | multiplexing and protection require privilege; abstraction does not |
| io_uring / FlexSC / Barrelfish | the mode switch is a fixed cost; amortize it |

Appendix E then names the result that would justify the architecture.
The most valuable item is E1: *what does a microkernel actually cost in
2026*, on current hardware, with PCID, huge pages, MSI-X, IOMMU,
batched rings, and 100+ Gb NICs, decomposed into mode switches,
cache/TLB, scheduling, and copies. That is a falsifiable claim. The
rest of the project should be judged by whether it is aimed at a claim
of that shape.

`ROADMAP.md` already knows the failure mode. P5 says pick **one**
vertical by M3.0 and record it as an ADR. The current milestone *is*
M3.0. There is no such ADR.

---

## 3. The idea

### 3.1 What is good about it

The idea is not “a capability microkernel.” Those exist. The idea is:

1. A kernel small enough to keep the always-hot working set in cache.
2. Authority that is enumerable (a CSpace can be printed) and
   revocable (a CDT walk, not a hope).
3. Failure as a normal event (`EPEERGONE`, reincarnation), not an
   exception.
4. A measurement harness that exists *before* the interesting
   experiments, so those experiments produce numbers rather than
   anecdotes.
5. A written invariant list that is allowed to veto features
   (no user pointers, no IPC allocation, no strings across the
   boundary, frames given to userspace are zeroed).

That last point is the one that makes the workbench trustworthy.
Features can be added. Invariants, once broken “just this once,”
cannot be restored by a later milestone.

The shallow syscall boundary (guide 10 §1) is the single best
design idea in the tree. Arguments are register values or capability
indices. A capability index is bounds-checked against a kernel-owned
table; it is not dereferenced. That deletes the `copy_from_user` /
user-pointer class rather than mitigating it. Hold this line. If it
is ever broken for an IPC buffer, that is an ADR, not a comment.

### 3.2 The three-lineage problem

The combination is coherent as a *thesis*. It is not coherent as a
*first system*. The three lineages fight, and the fights are already
visible in the code and in ADR-0001.

| Tradition | Wants | Already in tension with |
|---|---|---|
| seL4 | no kernel heap, no IPC timeouts, MCS / donated time, revoke as the security workhorse | `pmm_alloc` is still the live allocator; no `SchedContext`; `cap_revoke` is unbounded recursion |
| MINIX 3 | restartable drivers, a reincarnation server, grants | ADR-0001: a dead server hangs its callers until a userspace watchdog acts; object finalization does not exist, so “kill and restart” has no defined kernel meaning |
| io_uring-era I/O | rings, completion, batching, zero syscalls on the data path | synchronous rendezvous is *the* control plane; a `call` blocks by definition; Chapter 13’s batched invocation ring has no story for dependent calls |

None of these fights is a reason to abandon the idea. They are a
reason to pick which fight you are having. A workbench that tries to
win all three in year one will produce a kernel that is seL4-shaped
in the comments, MINIX-shaped in the server tree, and io_uring-shaped
in the unwritten chapters.

### 3.3 The P5 tracks, judged as ideas

`ROADMAP.md` P5 offers four verticals and says do not go horizontal.
Evaluated as research bets, not as features:

**A — Real-time + TSN (recommended).** Least breadth. The result is a
number: a 1 ms control loop meeting its deadline while an adversary
saturates cache, memory bandwidth, and network from another
partition, sensor→actuator across a TSN link, fully traced. Linux is
genuinely bad at this; a microkernel can be genuinely better; almost
nobody has published the partitioned-adversary number on current
hardware. It also matches what is *already* in the kernel: bounded
operations as a goal, no-alloc IPC, tracing, ADR-0001. The cost is
that several “deliberate simplifications” become correctness bugs
the moment a priority-diverse, budgeted workload exists (see §6.4
and §8).

**B — Graphics.** Highest demo value, largest breadth (guides 21–26:
display, compositor, input as a security boundary, window API, GPU).
A capability window system with a machine-checked “what can observe
keystrokes” report (Appendix E4 applied to the graphical stack) would
be a real result. It is also a second operating system. Starting it
before M4.0 is how the workbench dies.

**C — Virtualization.** Boot Linux; buy software and a comparison
baseline. Useful as a *tool* for E1 (same hardware, two structures).
Dangerous as the *goal*: the project becomes a hypervisor with a
research story, and the capability system is then justified by
guest isolation that hardware already provides.

**D — Distributed.** Transport equivalence across machines (guide
28). The interesting claim is that a capability and a message do not
change meaning when the other end is a different box. That is a
research OS in the Barrelfish / Barrelfish-derived sense. It needs
a working local system first, including the failure model (E3) that
is currently undesigned.

**Recommendation, as an idea, not as a schedule:** A is the product.
C is a later instrument for measuring A against Linux. B and D are
other projects that can share this kernel if A works.

The decision is late. The roadmap said “by M3.0.” Making it after
the first user thread is still cheaper than making it after the
first driver.

### 3.4 The research agenda versus the construction agenda

Appendix E is better than most “future work” chapters because each
entry says what would count as an answer. The construction agenda
(`ROADMAP.md` P3–P4) is a MINIX-3 userland: init, PM, VFS, ramdisk,
console, reincarnation, a shell.

Those agendas only meet if the userland is built *in order to
measure something*. A VFS that exists so that `open`/`read` work is
a hobby kernel. A VFS that exists so that E1 can run a real
workload, or so that E3 can state recovery semantics, is a
workbench. The difference is whether the milestone’s `done-when`
includes a number or a stated guarantee.

E2 (is the syscall the right boundary?) is the one Appendix E item
that M3.0 itself can start to arm. Once `SYS_DEBUG_NOOP` has a
cycle count, the trap cost is a known input to “ring vs trap vs
dedicated core.” Do not build three of those five interfaces until
the trap number is recorded. Building the trap *without* recording
the number would waste the only cheap measurement in that list.

### 3.5 What the idea is not

It is not a POSIX OS, and the guide is right to defer POSIX to a
personality. It is not a verified kernel; there is no Isabelle
story and there should not be one until the C is boring. It is not
a from-day-one SMP kernel in implementation, only in locking
discipline — and even that discipline is not yet in the code (no
lock ranks, because there are almost no locks).

It is also not, yet, a capability system in the seL4 sense. A
capability system whose objects have no finalization, whose
endpoints cannot be retyped from Untyped, and whose memory is still
handed out by `pmm_alloc`, is a capability *bookkeeping* layer on
top of a conventional kernel. That is the correct intermediate
state. Calling it the seL4 model in prose, while `pmm_alloc` is
live, is how the workbench starts lying to itself.

---

## 4. The design

### 4.1 What the guide is

`docs/guide/` is a book-length engineering guide: theory, x86-64
mechanism, construction, verification, research hooks. Forty-six
chapters and appendices. The working agreement is that the guide is
the specification, and a disagreement is a bug in one of the two,
logged rather than silently resolved.

That agreement is the project’s main quality control, and it has
already paid for itself. Three guide 03 bugs (`.bss` zeroed after
CR3 pointed into it; 32-bit `lgdt` given a higher-half base; `align`
in a `nobits` section) were found by booting, written into the
guide, and kept as a record. The tracing budget was rewritten from
“< 2% of IPC” to “< 50 cycles per enabled event” because the old
form was unreachable in principle: one `rdtsc` is 37 cycles, 2% of
the slow-path roundtrip is 22. That correction is a better artifact
than a passing test would have been.

The guide is also *too much specification*. Chapters 13–39 take
positions (real-time, I/O, naming, graphics, composability,
networking, TSN) that the construction agenda has not committed to.
A chapter that is a position is not a constraint until P5 chooses
it. Treating every chapter as load-bearing is how a 10 kLOC kernel
grows a compositor.

### 4.2 Design principles, as they stand up

Guide 00 §4 lists six principles. Evaluated against the current
kernel and the current roadmap:

| Principle | Status in the design | Status in the code |
|---|---|---|
| Separate policy from mechanism | Firm. Pagers, userspace scheduler, IRQ handlers as notifications. | Mechanism only. No pager, no userspace scheduler, priorities are just TCB fields. Correct for now. |
| POLA / capabilities | Firm. No ambient authority. | CSpaces exist. Ring 3 is not yet the only caller. `ipc_*` still takes a raw `struct endpoint *` for kernel threads. The `ipc_*_cap` split (M3.0) is the right shape. |
| End-to-end argument | Firm. Kernel does not checksum. | Held, vacuously: there is no I/O. |
| Design the fast path first | The *data layout* was designed first (message in the TCB, endpoints do not queue messages). The *code* is the C slow path, per the guide’s own sequencing. | Correct sequencing. The layout is the part that cannot be retrofitted. |
| Rare path first, then fast path | Stated. | Followed for IPC. Not yet followed for revoke (recursive, not restartable) or for user faults (panic). |
| Everything is an object with a capability | Stated. | `CAP_ENDPOINT` and `CAP_TCB` exist as enum values. Untyped can only retype into `CAP_FRAME` and `CAP_UNTYPED`. Endpoints are still caller-owned C structs wrapped after the fact. |

The principles are sound. The code is allowed to lag them. The
danger is claiming the principle is in force when only the enum is.

### 4.3 Invariants

`CLAUDE.md` and `docs/CLAUDE-instructor.md` list the same
never-violate set. They are the right set.

| Invariant | Held today? | Notes |
|---|---|---|
| Kernel never dereferences a user pointer | Yes, vacuously until M3.0’s syscall path, and then yes by construction: arguments are registers / `cptr_t`. | The first threat is an IPC buffer. Do not add one “for convenience.” |
| IPC allocates no kernel memory | Yes, by construction. Endpoint queues are TCB links. `ipc_no_kernel_allocation` is a real test (100 000 round trips, `pmm_free_bytes()` unchanged). | Notifications and rings must preserve this. A kernel-buffered mailbox would be a different OS. |
| No string crosses a syscall boundary | Yes. `include/abi/` has no `char *`. | The CI grep named in M0.2 should land with this ABI header, as the roadmap already said. |
| Every frame given to userspace is zeroed | Yes for `pmm_alloc` (tested) and for `untyped_retype` (tested on reuse of the same page). `user_proc_create` relies on `pmm_alloc`. | Hold this when the ELF loader arrives. Partial pages at segment tails are the classic leak. |
| `paddr_t` / `vaddr_t` / `dma_addr_t` are distinct | `paddr_t` and `vaddr_t` are one-word structs. `dma_addr_t` is correctly absent until M3.2. | `cap.obj` is a `uint64_t` that sometimes holds a `paddr_t.v` and sometimes a kernel pointer. That is the one place the type discipline is bypassed. Acceptable if every reader of `obj` is a typed wrapper. Dangerous if `SYS_INVOKE` starts switching on type and casting. |
| Every fallible function `MUST_USE` | Mostly. The public allocators and cap operations are marked. | `syscall_dispatch` returns a `long` that is sometimes an error and sometimes a message label. That collision is intentional (one register) and means `MUST_USE` cannot distinguish them. Fine; do not “fix” it by adding an out-parameter. |
| Every lock has a rank | Vacuous. There are no locks. | M4.3. Do not add a lock before the rank table exists. |
| Every ABI struct has size/offset `_Static_assert`s | `message_t` yes. `struct ublob` yes. `struct syscall` has no ABI struct, only enums. | `message_t`’s bitfields have implementation-defined layout; the file says so. That is honest. It also means the in-memory `message_t` is *not* a wire format. The wire format is the register mapping. Keep those separate in your head. |

ADR-0001 (IPC has no timeouts) is the only accepted decision, and it
is the right one. A timeout is per-thread kernel state with a
lifetime independent of the IPC, which breaks the no-allocation
invariant and lengthens the fast path. Liveness is a userspace
watchdog holding TCB capabilities. The revisit condition is written
down: if P5-A produces a case where detection latency itself breaks
a deadline. That is an argument for picking A *soon*, not for
putting a timeout in the kernel “just in case.”

### 4.4 Design tensions that are not yet ADRs

These are the places where the guide contains two answers, or an
answer and a later chapter that undoes it. Each will need an ADR
the first time code has to pick.

**1. Who is the spec, the guide or `include/abi/`?**

Guide 10 §3 and guide 08 §2 describe ~13 syscalls (`CALL`, `SEND`,
`RECV`, `REPLYRECV`, `NBSEND`, `SIGNAL`, `WAIT`, `POLL`, `YIELD`,
`INVOKE`, `DEBUG`) and six message words in `RDX/R10/R8/R9/R12/R13`.
`include/abi/syscall.h` has six numbers, four words, and a comment
that words 4–5 are not wired because they are SysV callee-saved.
Both cannot be authoritative. The ABI directory is the only one
that can be, because it is what a user stub will include. The guide
must be patched to match, or the ABI grown *before* anyone depends
on four words.

Guide 19 and appendix D also ask for `docs/abi.md`,
`docs/abi-policy.md`, and `docs/architecture.md`. None of those
files exist. The ABI is currently a header comment. That is enough
for a kernel with no userspace. It is not enough the day `libnyx`
is written, because the stub author will read the guide.

**2. Error space.**

Guide 19 §3.4: define the error space once, in
`include/abi/errno.h`, before there are 50 call sites. Needed at
least: `ENOCAP`, `ERIGHTS`, `ETYPE`, `ENOSLOT`, `EREVOKED`,
`EBUDGET`, `EWOULDBLOCK`, `EPEERGONE`. The file does not exist.
`enum syscall_err` has `E_NOSYS`, `E_BADCAP`, `E_PERM`, `E_INVAL`,
`E_TYPE`. `enum cap_err` is a parallel, kernel-internal space
(`CAP_ERR_LOOKUP`, `CAP_ERR_PERM`, …). IPC capability failures
translate into the syscall space; cap operations used from
`SYS_INVOKE` will have to do the same.

`EPEERGONE` is the one that cannot wait for convenience. In a
multi-server system, “the thing I was talking to died” is a normal
event. It has no encoding today, and no producer, because endpoint
teardown does not exist.

**3. Synchronous `call` versus batched invocation.**

Chapter 13 §1’s most important modern idea is a submission ring of
capability invocations, drained by the kernel or polled. Chapter
08’s control plane is a blocking rendezvous. A batched interface
where call *A*’s reply is call *B*’s argument, executed entirely
in the kernel (`IOSQE_IO_LINK` for IPC), would be new and
genuinely interesting. It is also a different IPC. Building rings
as “shared memory plus a Notification” (the data plane) does not
commit you to kernel-executed call chains. Decide which you are
doing before `IoQueue` exists.

**4. No kernel heap, stated as a property, implemented as an
aspiration.**

Guide 09 §4’s migration is: convert every buddy-free block into a
boot-time root Untyped, delete `pmm_alloc` / `kstack_alloc` as
anyone else’s allocator. What landed at M2.1 is
`untyped_from_pmm`, one `pmm_alloc_order` at a time, plus
`untyped_retype` that can produce frames and smaller Untypeds.
`tcb_pool` and `vspace_pool` are still fixed arrays. Kernel stacks
still come from `kstack_alloc`. Track A’s table in guide 14
(“dynamic allocation → kernel never allocates”) is therefore a
claim about a kernel that does not exist yet.

There is also an internal inconsistency: `include/nyx/untyped.h`
says `struct untyped` comes from a fixed pool; `kernel/cap/untyped.c`
says it lives inside the physical memory it describes, header
reserved at the front. The `.c` is what the machine does. The
header comment is stale. Small, but exactly the class of drift
the working agreement is supposed to prevent.

**5. Direct switch versus priority.**

Guide 07 §7: switch directly only if the receiver’s priority is ≥
the highest-priority ready thread. `ipc_call` always
`sched_switch_to`s. Every IPC test is same-priority, so the missing
check is inert. The first priority-diverse IPC workload — which
track A *is* — makes this a correctness bug: a low-priority server
can displace a high-priority ready thread for the rest of a
timeslice the caller did not even account.

**6. Policy/mechanism and the userspace scheduler.**

Guide 00 §4.1 says the kernel implements fixed-priority
round-robin with a timeslice, and priorities and timeslices are
set through capabilities held by a userspace scheduler. Guide 14
then replaces a large part of that with `SchedContext` capabilities
and passive servers. Those are compatible (the userspace scheduler
holds the `SchedContext` caps), but they are not the same design,
and M1.3 implemented neither timeslices nor a way to set priority
from anywhere but the creator. Pick the M1.3 shape as the
mechanism and the MCS shape as the P5-A addition, and write that
down, or the scheduler will be rewritten twice.

**7. Page-fault policy.**

Guide 06: user faults become IPC to a fault endpoint. Guide 10’s
`user_thread_create` takes a `fault_ep`. The TCB in this tree has
a comment that `fault_ep` joins at Ch.09/M2.1, and then does not
grow the field. `exception_handler` still says “no userspace yet,
so every exception is a kernel bug” and panics. That was right
until the first `user_thread_create`. It is now a design hole in
the path M3.0 is opening.

**8. Two working agreements.**

`CLAUDE.md` (the file the workbench agent is told to follow): this
repo is where you write the code. `docs/CLAUDE-instructor.md`: you
do not write production code; spikes only. A workbench whose
working agreement is two-valued will produce silent deviations.
Pick one and delete the other, or write the exception in one place
(“instructor mode vs workbench mode”) so it is a switch, not a
contradiction.

### 4.5 The object model, judged as a design

The kernel object list in guide 00 §7 is the right list for a first
system: Untyped, CNode, TCB, VSpace, Frame, PageTable, Endpoint,
Notification, Reply, IRQControl, IRQHandler, IOPort, SchedContext
(later), ASID pool (arch). The design rule “everything else is
userspace” is the Liedtke test applied to the object set.

What is easy to underestimate, and what the current code has not
faced:

- **Reply capabilities.** seL4’s one-shot reply cap is how you
  stop a server from replying twice and how you revoke the right
  to reply if the caller dies. Nyx currently stores `reply_to` as
  a TCB pointer on the server. That is a kernel-internal
  equivalent of a reply cap with no representation in the CSpace,
  so it cannot be transferred, revoked, or audited. Fine for the
  slow path. Wrong the moment a server wants to hand a reply to a
  worker thread.
- **Notification vs Endpoint.** Keeping them distinct is correct.
  Notifications coalesce, never block the signaller, carry a
  bitmask, not a message. They are also how IRQs become
  userspace-visible (M3.2) and how rings wake a waiter. There is
  no `CAP_NOTIFICATION`, no `notify.c`, and no milestone in P2
  that assigns them. The M2.0 write-up already flagged this and
  said ask before scheduling. That question is now on the
  critical path for M3.2, not a curiosity.
- **CNode-as-object.** `struct cnode` exists. `CAP_CNODE` exists
  so a CSpace can be deep. There is no invoke path to
  copy/mint/move/delete from userspace. The root task cannot
  build anyone else’s CSpace until `SYS_INVOKE` dispatches on
  `CAP_CNODE` and `CAP_UNTYPED`. That is M3.1’s real work, not
  the ELF loader.
- **Packed 16-byte caps.** Guide 09 §2 wants
  `_Static_assert(sizeof(struct cap) == 16)`. The implementation
  is an explicit CDT (parent, child, sibling ring) and is
  larger. The guide itself says “first implementation, optimize
  later.” The trigger to pack is the IPC fast path, which will
  touch a cap on every call. Not now.

### 4.6 System structure above the kernel

Guide 11’s level rule — a component may only `call` strictly lower
levels; upward traffic is reply or notification — is the design
that makes ADR-0001 survivable. Deadlock is structurally
impossible if the manifest cannot hand out an up-call capability.
That rule belongs in `docs/architecture.md` the day the first two
servers exist, and in the manifest generator the day the third
exists. The empty directories under `user/srv/` (`init`, `pm`,
`vfs`, `rd`, `con`, `rs`) are a reminder, not a start.

The open questions the roadmap already listed are still the right
ones, and they have dates:

| Question | Decide before | Why it cannot wait |
|---|---|---|
| Where the page cache lives | M4.0 | Determines VFS, memory server, and `mmap`/`read` coherence. Appendix D §5; guide 39 grades VFS B− because of this. |
| Static vs dynamic linking | M3.1 | The root task’s loader and the initrd layout. |
| Device binding and dependency model | M3.2 | Who holds the PCI capability, who may bind, what happens on restart. |
| P5 vertical | M3.0 (overdue) | Which of the above even happen. |

### 4.7 Composability as a design, not a slogan

Guide 39’s useful move is to split three things called
composability: configurability (profiles), substitutability
(conformance suites), extensibility (delegation + versioning). The
narrow waist it proposes — kernel object types, IPC and capability
semantics, manifest format, trace event model, IDL wire format —
is the right waist. The implication is uncomfortable and should be
taken seriously:

> The kernel is the part of the interface you are committing to
> for thirty years. Minimality is a bound on how much you have
> to be right about, forever.

That is a reason to keep `SYS_INVOKE` as the escape hatch that
stops the syscall table from growing, and a reason *not* to add
`SYS_OPEN` later “because a shell would be nicer.” It is also a
reason to stop adding object types until the existing ones have
death semantics.

The same chapter’s “escape-hatch smell” (`ioctl`, `void *opaque`,
vendor command ranges) applies to `SYS_DEBUG`. The implementation
correctly compiles it out of release builds. Keep that. A debug
syscall that survives into production is a serial console and an
exit primitive handed to every process — the file comment already
says so.

### 4.8 Style and language, as design

Appendix A (no `strlen`/`strcpy`/`sprintf`/`alloca`, `str` not
`char *`, arenas not per-object malloc, initialize at declaration)
is a kernel style that will age well. The tree follows it in the
places that exist. `str` itself has not arrived; `kprintf` still
takes `const char *` for kernel-internal format strings, which is
fine. The ABI rule is the one that matters and is held.

C17 + NASM for the kernel, language-agnostic ABI, optional Rust
userspace later: right split. Do not introduce a kernel Rust
dependency. Do not port musl.

---

## 5. The implementation, milestone by milestone

What is committed is M0.0 through M2.2, dated 2026-08-11 through
2026-08-13, in twelve kernel commits plus guide corrections. That
is very fast. The quality is high *for that speed* because the
process (tests, measurements, recorded deferrals, guide
corrections) was followed. Speed is also how integration debt
accumulates: many “not done, deliberately” items, `NEXT` two
milestones behind, M3.0 started without its tests.

### 5.1 P0 — It boots (M0.0–M0.2)

Done, and done in the right order. Serial before anything else.
`make test` before more kernel. Host tests under ASan/UBSan.
Size printed on every link. Multiboot2 verified with `grub-file`.

The boot stub is the part of a kernel that is allowed to be ugly
and is not allowed to be wrong. Finding that `.bss` zeroing wiped
the live page tables, and that a 32-bit `lgdt` truncated a
higher-half base, is exactly the work a workbench is for. Those
are now in “Guide corrections applied,” which is the correct
home.

Carried and still reasonable: Limine as a second boot path (not
scheduled; ask first); symbolized backtraces via Multiboot2 tag
9; gcc cross-build in CI.

### 5.2 M1.0 — Interrupts

GDT + TSS with IST for `#DF` / NMI / `#MC`, 256-vector IDT,
`struct regs` offsets `_Static_assert`ed against `entry.asm`,
deliberate `#PF` decoded, PIC remapped and masked, x2APIC EOI
verified under KVM. The x2APIC test self-skips under TCG, loudly.
That is the right way to have a hardware-dependent test.

The IST proof is better than a comment: `int $2` records an RSP
inside the NMI IST stack. Software `int` goes through the same
gate, including the stack switch.

Deliberately not done, and the deferrals were right *then*:
`swapgs` on entry (needs per-CPU GS and a ring-3 entry), LAPIC
timer (needs a scheduler), IOAPIC/MADT (needs a device), userspace
IRQ delivery (needs capabilities and notifications). Two of those
are now M3.0’s problem (`swapgs` on the interrupt path is still
missing; see §6).

### 5.3 M1.1 — Physical memory

Buddy allocator, frame database, zones, zero-on-alloc, host build
under ASan/UBSan, 200 k-iteration stress with a shadow map.
Multiboot2 mmap parsing. `paddr_t` / `vaddr_t` as structs.

Two bugs in the guide’s sketches, both found by running: 
`boot_alloc` from “the largest free region” overwrites the kernel
on every PC (GRUB loads the kernel at 1 MiB, which *is* that
region); `__kernel_start` is physical and `__kernel_end` is
virtual, so the reserve range was empty and the kernel’s own
frames were in the free pool. Both have regression tests. The
first is still in “Guide corrections owed,” waiting on approval
to edit the guide. The code is right; the guide is not. That
debt is small and should be closed so the next reader of
chapter 05 does not rebuild the hang.

No lock, no slab, no `pmm_alloc_contig`, no per-CPU cache, no
NUMA. All correctly deferred. The one to remember for track A:
M1.3 must not allocate from an interrupt handler, and currently
does not.

### 5.4 M1.2 — Virtual memory

Address spaces, map/unmap, `vspace_destroy_frees_everything` (1000
pages, `pmm_free_bytes()` returns exactly), a companion that
destroys 8 spaces while a kernel mapping stays live, `vmm_dump_walk`
wired into the `#PF` dump, SMEP/SMAP/UMIP/WP on and
behaviour-verified (not just bit-verified), W^X refused *before*
any page table is allocated, guard pages on kernel stacks, direct
map made NX.

The SMAP test using a real user address in a real address space,
with a CR3 switch, is the actual scenario SMAP exists for. A
`PTE_U` leaf under a supervisor-only PML4 slot is not a user
page; effective permissions are the AND of the walk. That bug
was found in a test, which is where it belongs.

Still open, and now on the M3.0 doorstep: the kernel image is
mapped RWX by the boot stub’s 2 MiB pages. W^X applies to
`vspace_map`, which never touched it. Remapping `.text` RX,
`.rodata` R+NX, `.data` RW+NX needs a 4 KiB remap of the kernel
half. ROADMAP says ask before M3.0. Ask. Doing it after ring 3
exists means a user mapping bug and a kernel W^X hole have to be
debugged in the same week.

PCID is not present. `vspace_switch` is a `mov cr3`. The first
cross-address-space IPC will pay a full TLB flush. Measure that
the same day it exists; it is the row sitting empty in
`docs/performance.md`.

### 5.5 M1.3 — Threads and scheduling

Two kernel threads, 10⁶ alternations without corruption, an
isolated asm `context_switch` selftest with magic values in
callee-saved registers, O(1) bitmap runqueue with a real pop
(the guide’s `rq_pick` sketch peeked and would have livelocked),
idle thread with `sti;hlt` as one asm block, TSC-deadline timer,
preemption checkpoint at interrupt return.

Cycle count: p50 104 / p99 144 under KVM, inside the guide’s
100–300 band. Max 7753 on one sample, diagnosed as the partner’s
last iteration going through `thread_exit`. That diagnosis is
written down. Good.

Simplifications that were right for M1.3 and are now M3.0 or
track-A problems:

- No timeslice accounting. Every tick requests a reschedule.
  Round-robin still happens; a quantum is not bounded.
- `switch_to` did not switch address spaces, `TSS.rsp0`, or FPU.
  The first two are in the uncommitted M3.0 `switch_to`. FPU is
  still absent (`-mno-sse`, blob does not touch it). When the
  first user program does, save/restore must be eager
  (CVE-2018-3665), as the comment already says.
- TCB pool of 64, leaked on `thread_exit` (cannot free the stack
  you stand on). Fine until something creates and destroys
  threads at a rate that matters. The root task will.
- `#DF`-on-stack-overflow still not tested. The reason is now
  specific and correct: the ktest diversion resumes on the
  faulting RSP, which is the overflowed stack.
- `current` and the runqueue are globals. Single CPU.
- `kmain` still `qemu_exit`s. Nothing has handed off to idle
  permanently. `make run`’s clean-exit contract is preserved on
  purpose. The first user thread that should *keep running* will
  have to change this; do it deliberately, not by deleting
  `qemu_exit` in a hurry.

### 5.6 M2.0 — IPC slow path

The state machine is the part that matters, and it is right.

- Endpoint is a meeting point. Queue holds senders *or*
  receivers. Message lives in the TCB.
- `ipc_call` / `ipc_recv` / `ipc_reply` / `ipc_replyrecv` as C
  functions between kernel threads. No syscall yet, on purpose.
- Badge overwritten in `msg_transfer` from `send_badge`, never
  from the sender’s message. `ipc_badge_correct` is the actual
  unforgeability test.
- `ipc_no_kernel_allocation` as a construction test, not a luck
  test.
- FIFO among multiple senders; second `ipc_reply` is a silent
  no-op (one-shot).
- Direct switch on rendezvous via `sched_switch_to`.

Slow-path cost: p50 1127 / p99 1231 cycles. The guide’s 300–600
is the *fast path* target. The write-up says so, and is right.
1127 cycles for two direct switches plus queue bookkeeping is a
plausible C baseline. The fast path’s job is to get from here to
there without changing semantics; `ipc_fastpath_matches_slowpath`
cannot exist until both paths exist.

Not done, and the list is still the right list: asm fast path
(needs a syscall boundary — that is now), plain send / non-blocking
send, notifications, bulk transfer, `ipc_rights_enforced` (needs
caps — that is now, via `ipc_*_cap`), endpoint destroy unblocks
all (design question, not a one-liner), deadlock detection,
priority check on direct switch.

The ordering question — IPC before capabilities, even though the
guide’s `ipc_call` is written in terms of `cap_lookup` — was asked
and answered: keep ROADMAP order, take an endpoint pointer plus an
explicit badge, refactor call sites at M2.1. That refactor did
**not** happen at M2.1. It is happening in the M3.0 diff, as
`ipc_*_cap`. That is a reasonable home. It is also a missed
“mechanical refactor” that sat for a milestone.

### 5.7 M2.1 — Capabilities

This is the best-shaped subsystem in the tree.

`kernel/cap/cap.c` has no hardware dependency. The same object
builds in the kernel and on the host. `cap_lookup` was fuzzed
under libFuzzer + ASan + UBSan; the first crash was a harness
bug (a fuzzed leaf typed `CAP_CNODE` with a garbage `obj`),
which produced a useful comment about the trust model: `walk()`
dereferences a `CAP_CNODE`’s `obj` unconditionally because no
legitimate operation can produce a `CAP_CNODE` with a bad
pointer. Userspace never writes raw capability bytes. That
trust boundary is real and now written down.

A second, real, fix: an iteration bound, because a CNode with
`radix == guard_bits == 0` consumes zero bits per level, and a
chain (or cycle) of those does not terminate on `bits_left`
alone. Host and ktest coverage for the degenerate chain.

`cap_lookup` copies the capability *by value* into an out
parameter rather than returning a pointer into the table. The
mutable form (`cap_lookup_slot`) is a separate function. IPC
reads should stay on the by-value form.

`untyped_retype_zeroes_memory` retypes, writes a pattern,
reclaims, retypes the *same* page, and checks zeros. That is
the test that actually tests retype’s `memset`, not PMM’s
zero-on-alloc.

`revoke_is_transitive`: a → b (minted) → c (copied from b);
`cap_revoke(a)` removes b and c, leaves a.

CSpace dump exists and is non-destructive.

What this is not:

- Packed 16-byte caps.
- `struct kobject` refcount and finalization. Delete/revoke is
  CDT bookkeeping only. An Endpoint does not wake blocked
  threads. A TCB’s stack is not freed. A Frame’s mappings are
  not tracked.
- Preemptible/restartable revoke. A deep CDT can blow the
  kernel stack and violate bounded syscall time. Fine for
  every tree the tests build.
- `cap_mint` restricted to endpoints/notifications — nothing
  else existed to make the restriction meaningful. `CAP_ENDPOINT`
  has since appeared as a type; the restriction still is not
  enforced.
- Capability transfer over IPC. `msg_transfer` no-ops on
  nonzero `ncaps`.
- The full untyped migration (see §4.4).
- Partial reclaim of an Untyped.

The last four are correctly deferred. Finalization is the one
that is now on the critical path: M3.0 wraps caller-owned
endpoints in `CAP_ENDPOINT` capabilities, and M3.2 wants to
kill a driver. Without death semantics, “kill” is `thread_exit`
plus a leak plus every waiter hung forever.

### 5.8 M2.2 — Tracing

Built early, which is what guide 32 asked for, and measured
properly.

- Per-CPU *shape*, one ring, 64 KiB static, no allocation.
- Five tracepoints: `ipc_send`, `ipc_recv`, `sched_switch`,
  `irq_enter`, `fault`.
- Trace id on the TCB, adopted by the receiver, restored on
  reply. Tested in both directions.
- Converter emits Chrome Trace JSON; schema travels in the
  stream rather than being hardcoded. Format-verified against
  the spec. **Not** opened in the Perfetto UI. The write-up
  says so.
- Overhead 27 cycles/event against a 50-cycle budget. The
  original `< 2%` target was corrected in the guide rather
  than fudged in the test.

The one optimization taken (reuse `switch_to`’s TSC) is the
legitimate one. Sharing a timestamp between `ipc_send` and
`ipc_recv` was correctly refused.

Not done: generated events from a `.def`, spans, sampling
origins, the trace server and its capabilities, panic dump of
the flight recorder, patched-nop disable. All reasonable. Wiring
`trace_dump()` into `panic()` is the one that is cheap and will
be wanted the first time a user fault is not a clean ktest
diversion.

### 5.9 Numbers

From `docs/performance.md` and `docs/tracing.md`, all under
KVM except where noted:

| Operation | Guide | Measured p50 | p99 |
|---|---|---|---|
| Context switch, same AS | 100–300 cy | 104 | 144 |
| Context switch, + CR3 | 500–1500 | — | — |
| Syscall entry+exit | 80–200 | — (M3.0, not recorded) | — |
| Capability lookup | 5–20 | — | — |
| IPC roundtrip, same core | 300–600 (fast path) | 1127 (slow path) | 1231 |
| Enabled tracepoint | < 50 cy/event | 27 | — |

Release `.text` grew 9.0 KiB (M0.2) → 36.4 KiB (M2.2). That is
still a small kernel. ktest `.bss` is dominated by sample arrays
in the benchmarks, not by the kernel. The trace ring is a real
64 KiB of release `.bss`, paid for in the open.

`benchmark_variance` does not exist. Guide 33 §6 and M3.3 say
that if it fails, every other number is noise. The numbers above
are one-machine, one-run, well-disciplined (warmup, percentiles,
interleaved on/off for tracing). They are not yet a CI series.
Do not add more microbenchmarks until M3.3’s variance test
exists, or the table will become a graveyard of incomparable
rows.

---

## 6. M3.0 as it actually sits

M3.0’s `done-when`: `syscall`/`sysret` with canonicality check;
registers scrubbed on exit, verified by a ktest reading them
from userspace; roundtrip cycles recorded.

The tree has the machinery. It does not have the milestone.

### 6.1 What is in good shape

**MSRs and selectors.** `syscall_init` programs `STAR`, `LSTAR`,
`FMASK`. `STAR` arithmetic is `_Static_assert`ed against the GDT
layout that `sysret` actually performs (`SS = base+8`,
`CS = base+16`). `FMASK` clears `IF`, `DF`, `AC`, `TF`, `NT`,
and also `CF` (stricter than the guide’s list; harmless).
`EFER.SCE` is checked rather than assumed, though a clear SCE
currently logs and returns instead of panicking — a boot that
continued past that log would `#UD` on the first `syscall`.

**Entry stub.** `swapgs`, stash user RSP, load `kernel_rsp` from
GS, save the callee-saved set plus the CPU’s RCX/R11, `cld`,
marshal into SysV order, call `syscall_dispatch`. Single
`.exit` label on the success path. Canonical RIP check *before*
the user stack is loaded, `iretq` fallback that builds its
frame on the kernel stack. Scratch registers zeroed on both
exits. This is the CVE-2012-0217 shape done correctly, and the
info-leak shape done correctly.

**First entry.** `user_thread_create` stacks an `iret` frame and
a switch frame whose return address is `enter_userspace`. The
trampoline scrubs every GPR, `swapgs`, `iretq`. No special case
in the scheduler. That is the right construction.

**Per-CPU GS.** `struct cpu` has `kernel_rsp`, `user_rsp`,
`current`, with offsets `_Static_assert`ed and duplicated in
`percpu.inc` so the stub cannot drift. `percpu_init` sets
`KERNEL_GS_BASE`, not `GS_BASE` — the comment records why
getting that backwards would make the first `swapgs` take the
stub to a null base. Makefile lists `percpu.inc` as a
prerequisite of every asm object. These are the details that
usually become a week of triple faults.

**`switch_to` grew up.** Address-space switch when `vspace`
differs, `gdt_set_kernel_stack` (TSS.rsp0, for interrupts),
`percpu_set_current` (for `syscall`). The comment correctly
distinguishes the two mechanisms. FPU still deferred, with the
eager-save CVE cited.

**Authority split.** `ipc_call` / `ipc_recv` / `ipc_reply` remain
the mechanism and take a `struct endpoint *`. `ipc_*_cap`
resolve a `cptr_t` through the caller’s own CSpace, require
`CAP_ENDPOINT` and the matching right (`RIGHT_WRITE` to send,
`RIGHT_READ` to receive), and take the badge from the
capability. Everything reachable from ring 3 goes through the
latter. Kernel threads with a `NULL` `cspace_root` fail closed
(`E_BADCAP`). A freshly created `user_proc` starts with an
empty CSpace. That is POLA made concrete, not decorative.

**User blob.** Assembled into `.rodata`, copied into a user
frame, never executed from the kernel image. Commands exist for
exactly the tests the milestone needs: record GPRs, `SYS_DEBUG_NOOP`
loop with `rdtsc` in ring 3, `putc`, `cli`, read a kernel
address, write own text, `SYS_CALL`. ELF loading is correctly
refused as M3.1 / root-task work.

**W^X on the blob.** Text is mapped without `PTE_W` (so it may
be executable); data and stack are `PTE_W | PTE_NX`.
`vspace_map` would refuse the other combination.

### 6.2 What will fail the milestone if you declare it done

**There are no M3.0 tests.** `tests/ktest/` has no `t_user.c` /
`t_syscall.c`. The blob is a test oracle without an assertion.
The working loop is: write the `done-when` tests first. That did
not happen. `ROADMAP.md` still says M3.0 is `todo`. `NEXT` still
describes M1.3. The code is ahead of the process, which is how
untested entry stubs ship.

**Reply words never return to ring 3.**
`syscall_dispatch`’s `SYS_CALL` / `SYS_REPLYRECV` rebuild a
`message_t` from registers, call `ipc_*_cap` (which writes the
reply into that stack-local `message_t`), and return only the
label in `RAX`. The entry stub then zeros `RDX/RSI/RDI/R8/R9/R10`
on purpose. Guide 10 §6’s `nyx_call` expects:

```
RAX = label
RSI = badge
RDX, R10, R8, R9 = reply words
```

A test that only checks `RAX` will pass. A protocol that returns
anything in a word will not. This is the first ABI bug. Fix it
before any stub generator exists, by reloading the reply from
`current->msg` in the stub (or by having dispatch return a
structure the stub knows how to scatter). The scrub is still
required; it has to happen *after* the reply is in the registers
that are allowed to carry it, and *of the registers that are
not*.

`SYS_RECV` is worse: the received message is discarded entirely
except for the label.

**User faults still panic.** `exception_handler` dumps and
`qemu_exit(EXIT_PANIC)` on any undiverted exception, including
from ring 3. The blob’s `cli` / kernel-read / write-text cases
are written as if “the kernel’s fault handler records what
happened.” Nothing records it unless a ktest arms the diversion
hook, and that hook rewrites RIP and `iretq`s — usable for those
three cases if the tests remember to arm it, unusable as the
permanent user-fault path. Guide 10 wants a fault endpoint on
the TCB. The TCB does not have one.

**Interrupt `swapgs` is still the M1.0 comment.**
`arch/x86_64/entry.asm` line 8: “No swapgs here yet. It belongs
at M3.0.” Syscall uses `swapgs`; interrupts do not. This is
internally consistent only while:

1. no handler uses GS, and
2. syscalls never re-enable `IF` (they currently do not: FMASK
   cleared it and nothing `sti`s).

A timer tick in ring 3 will enter on `TSS.rsp0` (now maintained),
run `isr_dispatch` with user GS still loaded, and may
`sched_preempt_check` → `switch_to`. That probably works today.
It is also the exact class of bug that should not be “probably.”
The first handler that reads `this_cpu()` from an interrupt
taken in userspace will use a user GS base of zero and fault or,
worse, not fault. M3.0 is when this comment was supposed to die.
Either add the paranoid user-GS check on the interrupt path, or
write down that GS is unused in handlers *and* that the kernel
is non-preemptible on the syscall path, and put a test on (1).

**`SYS_INVOKE` is `E_NOSYS`.** Acceptable for M3.0 if the
`done-when` stays as written (it does not mention invoke).
M3.1’s root task cannot retype, copy, or mint without it. Do
not let M3.1 start by growing an ELF loader on top of a
non-functional invoke.

**Words 4 and 5.** `MSG_MAX_WORDS` is 6. The syscall transport
carries 4. `msg_from_regs` hard-codes the fifth argument as 0
and never reads a fifth register. Document this as a transport
limit in the ABI header (it is, partially) *and* in guide 08
§2, or the first person to put a length in `w[4]` will debug
a zero.

**Error codes are ad hoc.** See §4.4. Freeze
`include/abi/errno.h` now, while there are five call sites, not
at M3.1 when there are fifty.

**Kernel image still RWX.** See §5.4.

**`kmain` still exits.** A `make run` that creates a user
thread and then `qemu_exit`s will never let that thread run,
unless a ktest yields to it first. The tests, when they exist,
must `thread_resume` and `yield` (or `schedule`) until
`SYS_DEBUG_EXIT`. That is a test-harness design question, not
a one-liner: the boot thread has `kstack_top = 0`, so
`switch_to` *skips* updating TSS.rsp0 and `kernel_rsp` when
returning to boot. After a user thread has run, those still
point at the user thread’s kernel stack. Fine if boot never
takes a syscall or a user-targeted interrupt. Record it;
do not discover it as stack corruption.

### 6.3 Smaller M3.0 nits

- `cap.obj` for `CAP_ENDPOINT` is a kernel pointer stuffed into
  a `uint64_t`. `ep_from_cap` casts it back. This is the typed-
  object hole in §4.3. A helper `endpoint_of(const struct cap *)`
  that asserts the type would make the next invoke path less
  likely to cast a frame address to an endpoint.
- `untyped.h` / `untyped.c` comment mismatch (§4.4).
- `sched.h`’s file comment still says authority fields “join at
  Ch.09/M2.1, when struct cnode exists” and “adding them now
  would be pointers to nothing.” They have joined. The comment
  is a fossil.
- `include/abi/message.h` still says “there is no syscall
  boundary yet to marshal across.” There is.
- Release builds compile `SYS_DEBUG` to `E_NOSYS` for the whole
  syscall. Good. The blob used by `user_proc_create` is linked
  into release objects too (`user_blob.asm` is not excluded).
  Harmless (it is data) but it means a release kernel carries
  a ring-3 test program. Exclude it the way ktests are excluded,
  or accept the bytes in the open.
- `user_proc_create` failure path `vspace_destroy`s but does
  not need to free a TCB if `user_thread_create` failed after
  allocating one… currently `user_thread_create` either returns
  a complete TCB or fails before publishing it, so this is
  fine. If anyone adds a step between TCB alloc and return,
  it will not be.

### 6.4 What M3.0 does *not* owe, and should not grow

Notifications. Capability transfer. The asm fast path. ELF.
Initrd. `libnyx`. A console server. FPU. PCID. Timeslices.
Object finalization. Preemptible revoke.

The temptation, with half of M3.0 already typed, is to “just
add” invoke methods or a pager so the user thread can do
something visible. That is how the milestone stops being
mechanically verifiable. The `done-when` is three bullets. Meet
them. Then stop.

---

## 7. Guide versus code: a matrix

A condensed view of the load-bearing design versus the machine.
“Held” means the code implements the rule, not that the
surrounding system exists.

| Topic | Guide | Code | Action |
|---|---|---|---|
| Rendezvous endpoints, no queued messages | 08 §2 | Held | Keep |
| IPC allocates nothing | 08 §7 | Held, tested | Keep |
| No IPC timeouts | 08 §7, ADR-0001 | Held | Keep; revisit only under P5-A evidence |
| Badge unforgeable | 08 §2 | Held in `msg_transfer`; `ipc_*_cap` sources it | Hostile ring-3 test still missing |
| Direct switch | 07 §7, 08 §4 | Always, no priority check | Schedule the check with the first mixed-priority IPC |
| Notifications | 08 §5 | Absent | Ask; needed for M3.2 |
| Rings / bulk | 08 §6 | Absent | After a control-plane ABI exists |
| Fast path | 08 §4 | Absent (correct) | After slow path is reachable from ring 3 *and* reply words return |
| CSpace walk + guards | 09 §2 | Held, fuzzed | Keep |
| CDT revoke transitive | 09 §3 | Held | Preemptible form is a later milestone |
| Object finalization | 09 §3 | Absent | Before M3.2 / any destroy-from-userspace |
| Untyped as the only allocator | 09 §4 | Partial: retype exists, PMM is live | Do not claim the property yet |
| 16-byte packed cap | 09 §2 | Explicit CDT, larger | Fast-path trigger |
| Cap transfer in IPC | 09 §5 | `ncaps` ignored | With invoke + two CSpaces |
| ~13 syscalls, 6 words | 08 §2, 10 §3 | 6 syscalls, 4 words | ABI is spec; patch the guide |
| No user pointers | 10 §1 | Held | Hold |
| `sysret` canonicality | 10 §2 | Held | Keep |
| Register scrub | 10 §2, §4 | Held on the way *out*; reply words not restored | Fix scatter, then re-scrub |
| Fault as IPC | 06 §4, 10 §4 | Panic | M3.0 or immediately after; needs `fault_ep` |
| Interrupt `swapgs` | 04 §4 | Comment says later; later is now | M3.0 |
| W^X including kernel image | 06 | `vspace_map` only | Ask, then remap |
| SMEP/SMAP/UMIP/WP | 06 | Held, behaviour-tested | Keep |
| Error space frozen | 19 §3.4 | Ad hoc enums | `include/abi/errno.h` now |
| `docs/abi.md` / policy / architecture | several | Absent | Before `libnyx` |
| Levels / acyclic call graph | 11 §1 | No servers | Write down with the first two |
| `SchedContext` / passive servers | 14 | Absent | P5-A, not a sneak into M3.x |
| Lock ranks | 12 §4 | No locks | Before the first lock |
| Page cache home | D §5, 39 | Undecided | Before M4.0, as already noted |

---

## 8. Risks

Ranked by “how much they cost if ignored until they bite.”

**R1. P5 is undecided at the moment the roadmap required a
decision.** Every chapter from 13 onward is available as a
distraction. Cost: a year of horizontal work and no number.
Mitigation: an ADR this week. Track A unless there is a written
reason otherwise.

**R2. Object death is undefined.** The first `cap_delete` on an
endpoint with waiters, or the first `thread_exit` of a server,
hangs callers with no `EPEERGONE`. M3.2’s “survives being killed
and restarted” is then a fiction. Mitigation: define teardown
before any destroy is reachable from ring 3. This is a design
exercise (what happens to a TCB mid-`ep_link`?) and deserves an
ADR, not a one-line `list_for_each` in `cap_delete`.

**R3. The ABI is being invented in two places.** Guide 10, guide
08, `include/abi/syscall.h`, and the entry stub already disagree
about word count and the return register map. Cost: `libnyx` and
the IDL generator fossilize the wrong one. Mitigation: one file
is the spec (`include/abi/`), the guide is updated in the same
commit as any ABI change, `docs/abi.md` restates it in prose
before the first user stub.

**R4. M3.0 entry path is untested.** Canonical `sysret`, scrub,
user `#PF`, timer-during-ring-3, CR3 switch, TSS.rsp0, GS
imbalance: all are CVE classes, all are currently “the code
looks right.” Mitigation: the tests the blob was written for,
plus one interrupt-from-userspace test, before any commit
message that says M3.0.

**R5. Track A is incompatible with several current
simplifications.** Non-preemptible syscalls (`IF` stays 0),
unbounded `cap_revoke`, direct switch without a priority check,
no timeslice, no `SchedContext`, PMM still allocating. None of
these are M3.0 work. All of them are silent if A is chosen and
then forgotten until M4.x. Mitigation: if the ADR is A, put
these on the P3/P4 backlog *as A-blockers*, not as “nice.”

**R6. Process documents have drifted.** `NEXT` is M1.3. ROADMAP
says M3.0 `todo`. Two CLAUDE files disagree about who types.
Guide corrections owed (05 §3, 02/03 linker symbols) are still
owed. Cost: the next session starts from the wrong place, or
“corrects” a guide that was already fixed in code. Mitigation:
the last hour of every milestone is `ROADMAP` / `NEXT` / guide,
not another function.

**R7. The empty `user/srv/*` directories look like a start.**
They are not. Building `con` because the folder exists is how
M3.1 becomes five milestones. Mitigation: the directories can
stay as a map; nothing goes in them until M3.1’s `done-when`
names the binary.

**R8. Verification theatre.** Tracing’s JSON is format-checked
and has not been opened in Perfetto. The fuzz done-when asked
for 1 h and got 55 min of a flat coverage plateau. Both write-ups
are honest. The failure mode is the next milestone reporting
“verified” for something similarly almost-done. Mitigation: the
existing honesty is the standard; do not raise it by fudging,
do not lower it by omitting the caveat.

---

## 9. What the implementation culture is getting right

This is the part that should not be lost in the gap list.

- **Tests name the property**, not the function:
  `pmm_never_hands_out_the_kernel_or_low_memory`,
  `ipc_no_kernel_allocation`, `revoke_is_transitive`,
  `w_xor_x_is_enforced`, `smap_stops_the_kernel_reading_a_user_page`.
- **Guide sketches are not treated as code.** `rq_pick`’s peek,
  `boot_alloc`’s region choice, the phys/virt linker symbols,
  the tracing percentage: all found, all recorded.
- **Deferral lists are specific.** Not “TODO later,” but “not
  this milestone, here is why, here is the home.” That is how a
  workbench stays small.
- **Measurements use the discipline the guide asked for.**
  Warmup, percentiles, KVM vs TCG called out, interleaved
  on/off for tracing, max outliers diagnosed rather than
  averaged away.
- **Host tests and fuzz sit on the same source** as the kernel
  for the parts that have no hardware reason not to.
- **Release and ktest are separate object trees.** Switching
  `CONFIG_KTEST` cannot leave a stale object behind.
- **Comments explain constraints, not the author’s morning.**
  The `syscall_entry.asm` hazard labels, the `untyped.c` header,
  the `switch_to` CR3/TSS/GS distinction: these are the comments
  that prevent the next edit from being a CVE.

The culture *is* the product of a workbench. The kernel can be
rewritten. The habit of measuring and of refusing to silently
disagree with the spec cannot be bolted on later.

---

## 10. Recommendations

Ordered. The first three are the ones that protect the rest.

1. **Write ADR-0002: P5 is track A**, or write the ADR that
   rejects A and says why. Until that file exists, do not start
   notifications-as-a-research-toy, IoQueues, graphics, or
   anything from chapters 21–38. Notifications *as the M3.2 IRQ
   mechanism* are still in scope; that is construction, not a
   vertical.

2. **Finish M3.0 as specified.** Tests first, in something like
   `tests/ktest/t_user.c`:
   - registers scrubbed on first entry and on `sysret`
   - `cli` is `#GP`, kernel-address read is `#PF`, text write is
     `#PF`, none of them a panic if the test armed a diversion
   - `SYS_DEBUG_NOOP` cycle count into `docs/performance.md`
   - one `SYS_CALL` through a real `CAP_ENDPOINT` whose *reply
     words and badge* come back in the registers guide 10 §6
     names
   - at least one interrupt taken in ring 3 that returns (timer
     is enough)
   Then interrupt-path `swapgs` (or a written, tested argument
   that GS is unused). Then record the number. Then mark the
   milestone done. Then stop.

3. **Freeze the ABI.** `include/abi/syscall.h` and
   `include/abi/message.h` are the spec. Patch guide 08 §2 and
   guide 10 to match (four words, six syscall numbers, return
   scatter). Add `include/abi/errno.h` with the guide 19 set,
   including `EPEERGONE` even though nothing produces it yet.
   Add the `char *` grep the M0.2 write-up promised. Write
   `docs/abi.md` as a restatement, not a second source of
   truth.

4. **Do not grow the object model until death is defined.**
   ADR for endpoint/TCB/frame teardown. `EPEERGONE` as the
   waiter’s result. This unblocks M3.2 and M4.2; it does not
   belong *in* M3.0, but it belongs *before* M3.2, and the
   question is already late.

5. **Close process debt in the same commit that closes M3.0.**
   `NEXT` describes the next thing, not M1.3. ROADMAP status
   matches the tree. Guide corrections owed (05 §3, linker
   symbols) are either applied or explicitly rejected. One
   CLAUDE file, or one file that says which mode is on.

6. **Ask the ROADMAP’s own M3.0 question about kernel W^X**,
   then remap or write the reason. Do not take ring 3 and a
   RWX kernel image into M3.1 together.

7. **If the ADR is track A, promote these from “carried” to
   scheduled:** priority check on direct switch; timeslice or
   `SchedContext` (decide which); preemptible revoke; user
   fault IPC; a bound on kernel `IF=0` regions (today: the
   entire syscall). None of these are M3.0. All of them are
   A, and A was supposed to be chosen now.

8. **Do not start `libnyx`, the IDL, or `user/srv/*` until
   M3.1’s `done-when` names them.** The loader lives in the
   root task. The kernel does not grow an ELF parser “just for
   bring-up” if the guide already said to put it in userspace
   and the blob already proved the ring transition.

---

## 11. What would change this evaluation

This document is a reading on 2026-08-13. It should be wrong in
specific, checkable ways after the next milestones:

- After M3.0: if the tests above exist and pass, §6.2 is
  historical. If `SYS_CALL` still drops reply words, §6.2 is
  a regression.
- After ADR-0002: §3.3 becomes a decision, not a
  recommendation. The rejected tracks can move to “out of
  scope” rather than “tempting.”
- After object teardown: R2 drops. Until then, “capability
  system” in prose should stay qualified.
- After M3.3: the performance table is a series, not a set of
  one-run rows. If `benchmark_variance` never lands, treat
  every new number as anecdotal.

If the guide and the code disagree and the disagreement is not
in ROADMAP’s correction lists, this evaluation is stale: that
disagreement is the more important document.

---

## 12. Sources

Primary, in the tree:

- `CLAUDE.md`, `docs/CLAUDE-instructor.md`, `README.md`,
  `ROADMAP.md`, `NEXT`
- `docs/guide/00`, `08`, `09`, `10`, `11`, `13`, `14`, `17`,
  `19`, `32`, `39`, appendices D and E
- `docs/decisions/0001-ipc-no-timeouts.md`
- `docs/performance.md`, `docs/tracing.md`
- Implementation read in full or in the load-bearing parts:
  `kernel/ipc/ipc.c`, `kernel/cap/cap.c`, `kernel/cap/untyped.c`,
  `kernel/sched/sched.c`, `kernel/sched/thread.c`,
  `kernel/syscall/dispatch.c`, `kernel/user/user.c`,
  `kernel/irq/dispatch.c`, `kernel/main.c`,
  `arch/x86_64/syscall_entry.asm`, `arch/x86_64/syscall.c`,
  `arch/x86_64/user_blob.asm`, `arch/x86_64/entry.asm`,
  `include/abi/syscall.h`, `include/abi/message.h`,
  `include/nyx/{ipc,cap,sched,user,percpu,syscall,types}.h`

Uncommitted at time of writing §1–§12: the M3.0 syscall / per-CPU /
user-blob / `ipc_*_cap` work listed in `git status`. Committed
HEAD was M2.2 (`1b39ef2`) plus a follow-up guide correction
(`295a373`). That work is now committed; see §13.

---

## 13. Addendum: after M3.0, W^X, and M3.0.5

- date: 2026-08-13 (evening)
- commits: `212b7eb` M3.0 · `e279171` kernel image W^X + proposed
  ADRs · `62c401f` M3.0.5 object lifetime and notifications
- HEAD: `62c401f`

§11 said this document should be wrong in specific, checkable ways
after the next milestones. It is. This section records what changed
in the *design*, not only what landed in the tree.

### 13.1 Verdict, revised

The last three commits improved the design, not just the checklist.
Before them, Nyx was a well-built L4-shaped kernel with a book of
optional futures. Now it has picked its fight, defined what death
means for the objects that matter for restart, frozen the ABI, and
written down how the scheduler will grow without a rewrite.

I would trust this tree more than I did when §1 was written. The
next design test is whether M3.1 stays “invoke, then a loader in
the root task” or becomes five servers because the directories
exist. The ADRs say the first thing. `NEXT` says the first thing.
That is the design holding, if the next commit does too.

### 13.2 What §1–§10 asked for, and what happened

| Finding | Outcome |
|---|---|
| Pick P5 by M3.0 (R1) | **ADR-0002 accepted:** track A. B and D out of scope for P5; C is an instrument, not the goal. |
| Finish M3.0 as specified, tests first (R4, §6.2) | **Done.** 82 ktests, then 87, then 97. Three `done-when` lines met. Null syscall **199 cy** from ring 3, in band. |
| Reply words dropped (§6.2) | **Fixed** before the milestone was declared, with a per-CPU return block so scrub and reply are the same operation. Caught by this file, not by a test — then tested. |
| User faults panic | **Defined path:** record + kill the thread. Not yet guide 06 §4’s fault-IPC. Honest about the gap. |
| Interrupt `swapgs` missing | **Landed.** Conditional on saved CS RPL, symmetric on exit. |
| Freeze the ABI (R3) | `include/abi/` is the spec; guide 08 §2 and 10 §3 say so. `errno.h` frozen at five call sites. `make abi-check`. Syscall numbers **append-only** after inserting `SYS_SIGNAL` in the middle silently hung the blob. |
| Object death undefined (R2) | **ADR-0003 accepted and implemented** as M3.0.5, *before* M3.1, which is the correct order. `E_PEERGONE` has a producer. |
| Dual scheduler (guide 00 vs 14) | **ADR-0004:** fixed-priority is the mechanism; MCS layers on top. Prevents writing the scheduler twice. |
| Static vs dynamic before M3.1 | **ADR-0005:** static, revisit at M4.0 against a measured duplication threshold. |
| Kernel image RWX | **Done.** The real hole was not `.text`: the boot stub mapped physical 0–1 GiB into the higher half RWX. Direct map was NX since M1.2; this second view was not. |
| CSpace without a 64-bit guard | **Found by a test that passed for the wrong reason**, then fixed. Guide 09 §2’s single-level shape is radix + guard = 64. |
| `NEXT` / ROADMAP drift (R6) | **Closed** for this slice. `NEXT` describes M3.1. ROADMAP current is M3.0.5. |

Three bugs in M3.0 were found by running the machine, which is the
workbench working. The `swapgs` inversion is the one worth
remembering: `percpu_init` set `KERNEL_GS_BASE` (correct *while
ring 3 runs*) and the first transition is `enter_userspace` going
the other way, so the per-CPU pointer was handed *to* userspace
and the first `syscall` stored to linear address 8, `#PF` under
SMAP, `#DF`. Diagnosed from `-d int` under TCG: `IP=syscall_entry+3,
CR2=0x8`.

### 13.3 Why M3.0.5 is a design commit, not a feature commit

ADR-0001 (no IPC timeouts) was a wish until endpoint death existed.
A watchdog that restarts a server does not unblock clients queued
on the old endpoint. M3.0.5 is the missing half of that decision:

- objects carry a capability-refcount and a finalizer
- last delete runs the finalizer
- endpoint finalization wakes every queued thread with `E_PEERGONE`
  as an ordinary return, not a fault
- revoke of derived caps that leaves the root does **not** destroy
  the object (tested both directions)

`kernel/cap/cap.c` still does not know object types. Retain/release
are boot-installed hooks, so the host fuzzer still runs the exact
walk the kernel runs. That inversion is the same shape as
`pmm_arch_ops` and is the right one.

Notifications riding along is a sequencing argument, not
feature-creep. A Notification is a kernel object with a capability,
so it needs a finalizer; adding a seventh type *after* the
framework costs more than designing it in. It is also small: one
word of bits, at most one waiter, no queue, no allocation — both
“never blocks the signaller” and “allocates nothing” are tested.

Inserting the milestone as **M3.0.5 before M3.1** is the load-bearing
ordering. `SYS_INVOKE` is what lets userspace retype Endpoints and
TCBs. Death semantics after that would be a retrofit onto objects
userspace already holds.

### 13.4 What is still not a better design

Honesty about remaining holes is still good. The design is not
finished.

- **`reply_to` is still a TCB pointer.** Destroying an endpoint
  does not save a client already in `TS_BLOCKED_REPLY`. Killing
  the *server* would, and that is TCB teardown, split out for the
  real reason (you cannot free the stack you stand on). Until that
  exists, “peer died” is only half-defined.
- **Track A’s first latent bug is still in the code.** Direct
  switch still ignores priority. ADR-0002 calls it a correctness
  bug; `NEXT` calls it a ten-line opportunistic fix. It has not
  landed.
- **`E_REVOKED` still has no producer.** Frame / Untyped / CNode
  finalizers are absent. A Frame is raw memory with nowhere to
  put a header — that is a real design question, not laziness.
- **User faults are still “kill the thread,”** not IPC to a pager.
  Fine for M3.0; M3.1’s root task will care.
- **Comments have already drifted.** `include/abi/errno.h` still
  says `E_PEERGONE` has no producer. `docs/decisions/README.md`
  still lists only ADR-0001. Small, but it is the class of drift
  the process is supposed to prevent.
- **M3.1 is already leaking into the working tree**
  (`include/abi/invoke.h`, `kernel/cap/invoke.c`). The CNode ABI
  is intentionally asymmetric (invoked cap = destination; source
  is always the caller’s own root). Right for the root task. Not
  a general CSpace operation. The header says the general triple
  can be added later without renumbering. Hold that line.
- **`benchmark_variance` still does not exist.** Every number in
  `docs/performance.md` is still one-run.
- **The six A-blockers** are written down and not scheduled as
  milestones. Writing them down was the design improvement.
  Leaving them as a list in `NEXT` until A actually needs them
  is correct *except* for the priority check, which is already a
  bug.

### 13.5 Numbers added since §5.9

| Operation | Guide | Measured | Commit |
|---|---|---|---|
| Syscall entry+exit (null, from ring 3) | 80–200 cy | 199 cy p50 | M3.0 |

Still empty, and more interesting after M3.0 than before: context
switch + CR3, capability lookup, notification signal, page fault
to a pager. Do not fill them from TCG. Do not add rows until
M3.3’s variance test exists, except when a milestone’s
`done-when` names a number (M3.0 did).

### 13.6 Sources for this addendum

`docs/decisions/0002`–`0005`, `ROADMAP.md` M3.0 and M3.0.5
write-ups, `NEXT`, `include/abi/errno.h`, `include/nyx/kobject.h`,
`kernel/ipc/notify.c`, `kernel/syscall/dispatch.c` (committed and
the in-progress invoke wiring), `docs/performance.md`.

---

## 14. Other verticals later — especially graphics

Canonical, maintained form: [`verticals.md`](verticals.md).
Proposed decision: [ADR-0006](decisions/0006-verticals-are-manifests.md).
What follows is the argument that produced them.

ADR-0002 already says B and D remain possible on *this* kernel,
and that C is a later instrument for measuring A. That is the
right conclusion. This section is the how: what “on this kernel”
must mean, so a future session does not open `vertical/graphics`
and fork the waist.

### 14.1 The rule

**One kernel, one ABI, one object model. A vertical is a
manifest plus an initrd, not a kernel.**

Guide 39’s narrow waist is exactly the list you must not fork:

- kernel object types and their semantics
- IPC and capability semantics
- the manifest format
- the trace event model
- the IDL and its wire format

Graphics (guide 21) already states the same rule from the other
end: the whole graphical stack must be *optional*. Only display
arbitration touches hardware. Input routing, window policy, and
the application API are ordinary userspace programs. Win32 put
(3) and (5) in `win32k.sys` and produced a generation of
privilege-escalation CVEs. A microkernel gets “not that” for
free, but only if those programs stay programs.

If you fork the kernel to “do graphics properly,” you have
recreated `win32k.sys` in slow motion: a second waist, a second
ABI, and no way for a finding on A to apply to B.

### 14.2 What each option actually buys

| Approach | What it is | When it is right | Why it is wrong for B |
|---|---|---|---|
| **Long-lived kernel branch** (`vertical/graphics`) | A second history of `arch/` and `kernel/` | Never, for a vertical | The waist diverges. Merge becomes a rewrite. A’s `SchedContext` and B’s `Frame`/`IRQHandler` stop being the same types. |
| **Fork / “Nyx-Desktop”** | A different kernel that shares a name | Only if B requires breaking an invariant (user pointers, in-kernel compositor, kernel heap for command buffers) | That would not be Nyx. It would be a different thesis. If B needs those things, the design is wrong, not the repo layout. |
| **Kernel version / soname** (`nyx 1` vs `nyx 2`) | A breaking ABI rev | When the waist itself must change | Too early, and the wrong lever. B does not need a new `SYS_*`. It needs Frames, IRQHandlers, and a compositor process. |
| **Compile-time `#ifdef CONFIG_GFX`** | Two kernels from one tree | MCU-vs-server profiles (guide 27), or stripping a 32 KB target | Graphics is not a `#ifdef` in `ipc.c`. It is servers you do not put in the initrd. `#ifdef` in the waist is how the waist stops being one. |
| **Spike branch** (`spike/NNNN-…`) | Throwaway, never merges | Compositor algorithms, damage tracking, “does virtio-gpu even work under our VMM” | Right for *questions*. Wrong as the home of the vertical. |
| **Userspace-only branch** | `user/srv/gfx/**` on a branch; kernel untouched | Parallel work after the ABI and the needed object types exist on `master` | This is the one kind of long-lived branch that does not fork the waist. |
| **Manifest profile** (the one to use) | Same `nyx.elf`, different initrd + manifest | Always | Headless / RT / workstation are compositions, not products. Guide 27’s whole claim. |

**Use the last two. Do not use the first four.**

A “different version of the kernel” is the most tempting wrong
answer, because it sounds like engineering discipline. It is
how you get Linux-the-name on a microcontroller: a different
system that shares a brand. Guide 27’s thesis is the opposite —
same object model, same ABI concepts, the configuration
difference expressed as composition, not as `#ifdef`. Graphics
is a large-end composition. It is not a second kernel.

### 14.3 Graphics, specifically

Part VII splits five responsibilities. Map them onto Nyx as it
actually is:

| Responsibility | Where it lives | Kernel objects it needs |
|---|---|---|
| 1. Display arbitration | `user/srv/gfx/display` — a driver | `IRQHandler`, `Notification`, Frames (scanout, dumb or imported), later IOMMU / `IoRegion` if the device DMAs |
| 2. Input routing | `user/srv/gfx/input` | Same IRQ/Notification pair; capabilities to recipients, not a global evdev |
| 3. Window state | `user/srv/gfx/shell` (policy) | Endpoints, badges. No new kernel type. |
| 4. Drawing | Client-side, always | Shared Frames. Not a kernel drawing API. |
| 5. App-facing API | `libnyx` + IDL, or a toolkit on top | Capability to a window / surface, not an `HWND` |

Nothing in that table is a kernel fork. Almost nothing in it is
even a new kernel object. Frames, IRQHandlers, Notifications,
and IOMMU contexts are what **track A also needs** for a TSN
NIC and a partitioned device. Building them for A *enables* B.
That is the strongest argument against a graphics kernel
branch: the kernel work B wants is not graphics work.

The research result that would justify doing any graphics at
all is not a compositor demo. It is Appendix E4 applied to the
stack: a manifest in, a machine-checked list of what can
observe keystrokes out. That result needs:

1. The capability graph to be the authority graph (already the
   thesis).
2. An input server that delivers events only through
   capabilities it was given.
3. A compositor that cannot be talked into reading another
   client’s buffer without a cap.
4. A tool that walks the manifest.

It does **not** need a GPU driver, text shaping, or a toolkit.
A virtio-gpu or linear framebuffer, a PS/2 or virtio-input
device, a compositor that composites rectangles, and a hostile
client in the chaos tests are enough to make E4 true or false.

So the graphics vertical, when it is time, is two slices, and
they must not be started as one milestone:

- **B-thin (the finding):** display + input + a compositor that
  is a capability boundary, plus the E4 checker. This is the
  only graphics work the workbench owes anyone.
- **B-full (the product):** modeset, planes, GPU command
  submission, damage, a shell with workspaces, a toolkit.
  Guide 22–25. Do this only if B-thin produced a number or a
  document someone else can use, and only as userspace.

Starting B-full because chapter 25 exists is how the workbench
dies. ADR-0002 already said that. It is still true.

### 14.4 When to start, and how to isolate the work

**When.** After three things exist on `master`, not before:

1. Track A has *a* number — not the final 1 ms TSN loop, but
   enough that the kernel’s temporal claims are being measured
   (M3.3’s variance test, plus at least one A-blocker beyond
   the priority check). Otherwise B becomes the thing you do
   instead of measuring.
2. The object types B-thin needs are already on `master`
   because A or M3.2 needed them: `IRQHandler`, `Notification`
   (done), Frame mapping from userspace, IOMMU or a written
   reason it can wait.
3. The ABI is boring. `SYS_INVOKE` works. `libnyx` and the IDL
   exist. A second server has been written without inventing
   a marshalling convention.

**How, in repo terms:**

```
master                  the one kernel, the one ABI
user/srv/gfx/           empty until B-thin is scheduled
manifests/headless.nyx  what CI boots today
manifests/rt.nyx        track A (sensors, TSN, adversary)
manifests/workstation.nyx
                        headless + display + input + comp + shell

spike/NNNN-damage       throwaway; answers one compositor question
user-gfx/B-thin         optional: userspace-only branch, rebase
                        onto master, never contains arch/ or kernel/
```

`make` produces one `nyx.elf`. `make test` stays headless.
`make test GRAPHICS=1` (or a second initrd) boots the
workstation manifest. Guide 21’s “never started headless” is
a CI constraint, not a code-layout constraint.

If two people work in parallel: they do not branch the kernel.
One continues A on `master`. The other implements B-thin
against the published ABI, in `user/srv/gfx`, and is broken
by kernel changes the same way any out-of-tree server would
be. That breakage is information. A kernel branch would hide
it until merge day.

### 14.5 The other two verticals, briefly

**C — virtualization** is a kernel *object* (`VCPU`, perhaps a
VM address space), not a kernel fork, and not a vertical in
the P5 sense. ADR-0002 already kept it as a tool for E1: same
hardware, Linux in a VM vs a native Nyx workload. Add the
object when A needs the comparison, on `master`, behind the
same capability model. A “Nyx hypervisor edition” is C
becoming the goal, which is the alternative ADR-0002 rejected.

**D — distributed** is the one that *feels* like a different
kernel and must not become one. The claim is that a capability
and a message do not change meaning when the other end is a
different box. That claim is false the moment IPC on the wire
is a different code path with a different object model. The
construction is: a transport server in userspace (or a thin
kernel datagram object if measurement demands it) that moves
bytes; endpoints and CSpaces stay local; a userspace proxy
exports a *local* endpoint that forwards. If you need a
“distributed kernel” to make D work, D’s thesis is already
dead.

D also depends on E3 (failure model) more than B does. M3.0.5
is the local half of “the other end went away.” Do not start
D until `E_PEERGONE` is also the answer when the other end is
a machine that rebooted, and that answer is written down.

### 14.6 What would justify a second kernel

Write this down so the question has an off-ramp, not a vibe.

Fork the kernel only if a vertical cannot be expressed without
breaking an invariant in `CLAUDE.md`:

- the kernel would have to dereference a user pointer (GPU
  command buffers parsed in ring 0)
- IPC would have to allocate (in-kernel surface queue)
- a string would have to cross the syscall boundary (window
  titles as `char *`)
- frames given to userspace would not be zeroed (scanout of
  stale data as a “feature”)

If B seems to need any of those, the answer is not a branch.
The answer is: the graphical design is wrong, and the spike
is “can this be a ring plus a Frame capability instead.”
Guide 21 already predicts that answer. Believe it before the
first `ioctl`.

### 14.7 A sentence to put on the B milestone, when it exists

> Same `nyx.elf` as track A. New manifest. No new syscall.
> Finding is E4, not a screenshot. GPU is out of scope until
> E4 is a document.

If a future milestone cannot accept that paragraph, it is not
a vertical on this workbench. It is a different project, and
it should have a different name.
