# Retrospective — the kernel at the end of P4

Written 2026-08-15, after M4.3. Nothing here is a plan; `ROADMAP.md` is
the plan. This is an assessment of what the design bought, what it cost,
what a second version should do differently, and what the measured
numbers say about the two verticals that motivated the whole thing.

Every number below is measured on this machine (i5-1145G7E, 2.6 GHz,
KVM) and is in `docs/performance.md` with its method. Where something is
an estimate rather than a measurement it says **estimate** and shows the
arithmetic.

---

## 1. What exists

| | |
|---|---|
| Kernel + userspace + tests + tools | ~26 100 lines |
| Tests | 164, 0 failing (SMP=4, KVM); 2 skipped |
| ADRs | 10, all accepted |
| Invariants tracked | 19, each with the test that checks it |
| Userspace components | 9 resident (con, uart, rd, ramfs, vfs, mem, pm, sh, rs) |
| Processors | 4, booted one at a time, running under one lock |

The system boots, starts nine components from a manifest, resolves a
path through a VFS to a file object that is a badged endpoint, spawns a
process from an ELF read through that endpoint, runs a shell that
executes a typed command, and survives a chaos loop that kills and
rebuilds a random server 32 times without leaking memory.

**The kernel contains no ELF parser, no filesystem, no driver, and no
graphics.** That is worth stating plainly because it is the property
everything else was traded for.

---

## 2. What the design got right

### 2.1 Capabilities made the security argument short

There is no ambient authority anywhere in the system. The manifest *is*
the architecture: `component rd untyped=256K serves=3 initrd=1` is the
complete statement of what the ramdisk driver may ever do, and the
absence of a line is the enforcement. When `hello` reads the boot
archive, it holds no mapping of it — every byte crosses an endpoint.

This paid off in a way I did not anticipate: it made *whole classes of
test* trivial to write. "A driver cannot map another driver's MMIO" is
not a policy check, it is `E_BADCAP` falling out of a lookup. The M3.2
I/O-port work gave the UART driver `0x2f8..0x2ff` and nothing else, and
the test that it cannot touch COM1 is three lines.

### 2.2 The guide-as-spec loop found bugs in the guide

Three guide corrections are owed (`ROADMAP.md`), each found by an
implementation that could not work:

- **12 §2** — INIT level de-assert is invalid in x2APIC mode; the ICR
  write hangs with no output.
- **05 §3** — `boot_alloc` over the largest free region overwrites the
  kernel, because GRUB loads at 1 MiB and that region *is* the largest.
- **02 §4 / 03 §3** — `__kernel_start` is physical and `__kernel_end` is
  virtual, so any size computed from the pair is wrong by `KERNEL_VMA`.

A workbench that only confirmed the book would have been worth much
less than one that contradicts it three times.

### 2.3 Test-first, and never inferring a pass

Two of the more serious bugs were found by writing the test first and
watching it fail against code that looked right:

- **A killed caller left the server holding a pointer to it** and the
  server's next reply resumed a destroyed thread. `user/child/main.c` is
  exactly that shape, and the chaos loop kills servers only, so nothing
  had ever exercised it.
- **A TCB slot was recycled while a capability still named it**, so
  `root_task_tcb()` came back as a thread called `dump-server`. Only
  visible under KVM, where the extra thread churn reached root's slot.

Neither presented as a failure before the test existed. Both were
one-line consequences of a rule already written down (ADR-0003) and not
enforced in one direction.

### 2.4 Measurement discipline caught the measurement

`make bench` hardcoded `taskset -c 0`, and core 0 is the busiest core on
this realtime-kernel host: `syscall_null` p50 was 221/282 pinned against
197/198 unpinned. The pin meant to remove noise *was* the noise, and
`benchmark_variance` did not catch it because context switches stay
inside the guest. Numbers as a deliverable means auditing the harness,
not only the kernel.

### 2.5 Restartability is real, not aspirational

The reincarnation server kills `{con, rd, ramfs, vfs}` eight times each,
rebuilds them, proves the session still works, and reclaims the Untyped
so the loop does not leak. That works because a component's entire state
is capabilities in a CNode plus frames in a VSpace, and both are
reclaimable by whoever created them. This is the microkernel claim, and
it is the one the project can demonstrate rather than assert.

---

## 3. What it cost

### 3.1 The numbers are two to five times the targets

| Operation | Guide target | Measured | Ratio |
|---|---|---|---|
| Context switch, same AS | 100–300 cy | 116 | inside |
| Notification signal | 50–150 cy | 37 | better |
| Syscall entry+exit | 80–200 cy | 198 | at the edge |
| Capability lookup | 5–20 cy | 43 | 2× over |
| IPC roundtrip, same core | 300–600 cy (fast path) | 1635 | 2.7–5.5× over |
| IPC roundtrip, cross core | 3000–8000 cy | 24617 | 3–8× over |

The IPC gap is explained and not mysterious: there is no fast path. The
slow path is two context switches, a capability lookup, endpoint queue
bookkeeping, a badge, and the big kernel lock, written in C on purpose
because guide 08 §4 says to write that first. The 1635 is the honest
baseline the fast path will be compared against — but it is *today's*
number, and every design conclusion below has to use it rather than the
one we hope for.

Capability lookup at 43 cy against 5–20 is the more interesting miss: it
is a guarded radix walk with a bounds check per level and no packing.
The guide's figure assumes 16-byte packed capabilities, which are parked.

### 3.2 The big kernel lock is a global priority inversion

Two independent client/server pairs on four CPUs get **1.20× the
throughput of one pair**, not 2×. A second pair adds a fifth of a core.
The shared line is the BKL, and every syscall and every interrupt entry
takes it.

For a general-purpose kernel that is a performance problem to be
attacked incrementally, which is exactly what guide 12 §1 prescribes and
what M4.3 started (the runqueue is off the lock; IPC is next). For a
*real-time* kernel it is worse than a performance problem, and §5 says
why.

### 3.3 Four register words shaped the protocols

Every protocol in the system moves ≤ 32 bytes per call, so the ramdisk
serves a 4 KiB page in **128 round trips**. `rd_read_fully` exists to
loop the short reads. That is defensible for a correctness milestone and
indefensible for anything that moves data, and it means no protocol in
the tree has been designed against a realistic transport.

### 3.4 Static ceilings everywhere

`TCB_MAX`, `NCPU = 4`, `MAX_PROC = 4`, `MAX_COMPONENTS = 8`,
`ROOT_UNTYPED_COUNT = 9`, `LOCKDEP_MAX_HELD = 8`. Each is defensible
alone; together they mean the system has never been run at a size where
an allocator's behaviour matters. `pmm_alloc` is still live, so "no
kernel heap after the untyped migration" is **not held** and
`docs/invariants.md` says so.

### 3.5 A thread cannot be stopped

There is no way to stop a thread except to stop naming it. `pm` cannot
end a child on `pm_exit`, because guide 11 §4.2 has spawn hand the
*parent* a process capability and that copy keeps the refcount up. So
`user/child/main.c` exits by returning into a ring-3 `hlt` and letting
the `#GP` kill it, and `root` kills a component by deleting 64 CNode
slots one at a time. Both work. Neither is nameable. `TCB_SUSPEND` is
decided and unbuilt.

### 3.6 The bug taxonomy is the most useful artifact

Of the bugs that cost more than an hour, almost all fall into three
classes:

**Per-CPU state that looked like machine state.** Three in one commit:
an AP had no `EFER.SCE` (so `syscall` was `#UD`), no `CR0.WP`/SMEP/SMAP/
UMIP, no `CR4.PGE`. The BSP got all three from the boot stub. The
symptom was user threads faulting at their own entry points, which reads
as memory corruption and is not.

**Two copies of one fact.** `SYS_DEBUG` renumbered in the ABI but not in
the blob's copy; `percpu.inc` offsets against `struct cpu`; `BI_SLOT_*`
constants against the run they describe; the enum that was inserted
mid-list. Every one was caught by a `_Static_assert` or by a test that
read a value written through the other copy — where one existed.

**An invariant written down and enforced in one direction only.**
`blocked_on` vs queue membership; the reply obligation; the TCB refcount
vs slot recycling. The rule was right in all three cases, and half
implemented.

A V2 does not get to avoid these by being careful. It gets to avoid them
by making the second copy impossible and the invariant symmetric by
construction.

---

## 4. What a V2 would change

Ordered by how hard they are to retrofit, hardest first. These are the
things that are *not* patches.

### 4.1 Design partitioned from the first line

Guide 12 §1 says: design as if partitioned, add a BKL to make progress,
remove it path by path. We did the second and third. The first is not
something you can do later — it is a property of every data structure
you have already written. The TCB pool, the PMM, the trace ring, the IRQ
counters and (until M4.3) the runqueue are all global because they were
written when "the CPU" was a definite article.

**V2:** every kernel structure is per-CPU or explicitly shared with a
stated owner, from the first commit. There is no `static struct foo
foos[N]` without a CPU index or a lock rank next to it. A single
`cpu_init()` runs on every processor including the BSP, so no piece of
per-CPU state can be BSP-only by accident — that alone would have
prevented §3.6's first class outright.

### 4.2 The IPC transport, designed once

The current transport is four register words, with capability transfer
bolted into RAX's high bits (ADR-0009) because there was nowhere else to
put it. It works and it is tested from ring 3, but it is a compromise
that every protocol above it inherited.

**V2:** decide the message shape against a workload, not against a
register budget. A per-thread IPC buffer from day one (seL4's shape, and
guide 08 §6a's) makes capability transfer, long messages and bulk
descriptors one mechanism instead of three. The register fast path is
then an *optimisation of* that shape rather than the shape itself.

### 4.3 Reply objects instead of a TCB pointer

`reply_to` is a raw pointer from server to caller, and the caller-side
back pointer (`reply_from`) had to be added when a killed caller left the
server holding it. That is the bug that motivates seL4's Reply object,
discovered independently and patched rather than fixed.

**V2:** a reply capability is an object. It can be held, transferred to
a worker, and revoked; its lifetime is the CDT's problem, not a pair of
pointers that must be kept symmetric by hand.

### 4.4 Revocation that is preemptible and recursive

`cap_revoke` is neither. The consequence is visible in userspace: root
sweeps 64 CNode slots by hand to kill a component, because deleting a
CNode capability does not delete what is inside it. And an unbounded
revoke is a real-time hazard (§5).

**V2:** the preemptible, restartable shape (guide 09 §3, the `-ERESTART`
convention) from the start, for revoke, for `vspace_destroy`, and for
Untyped zeroing. It is much harder to add once callers assume these are
atomic.

### 4.5 Untyped from the first allocation

The kernel still has `pmm_alloc`. The migration to "every free frame is
an Untyped and the kernel allocates nothing" is track A's blocker 6 and
has been deferred four times. Each deferral was correct locally; the
aggregate is a kernel that cannot honestly claim its own headline
property.

**V2:** no kernel allocator at all, ever, including during boot. Boot
memory is a pre-carved Untyped like everything else.

### 4.6 Packed capabilities

43 cycles per lookup against a 5–20 target, on the path taken by every
IPC and every invoke. The representation is `struct cap` with pointers
for the CDT ring; guide 09's 16-byte packed form is parked behind "the
fast-path trigger". A V2 should start packed, because unpacking later is
free and packing later touches every file that names a field.

### 4.7 KVM-first, SMP-first testing

TCG hid a real bug for several milestones (the recycled TCB slot), and
five tests carried uniprocessor assumptions that only surfaced when APs
started scheduling — `tr == SEL_TSS`, `!interrupts_enabled()`,
"only the BSP is online", and two allocation-counting tests that assume
a quiet machine.

**V2:** the suite runs `SMP=4` under KVM by default from M0.2, and a
test that needs quiescence says so explicitly rather than assuming it.

---

## 5. Real-time (track A): what the numbers allow

The target that justifies the architecture is a **1 ms control loop
provably meeting its deadline** while an adversary saturates cache,
memory bandwidth and network from another partition.

### 5.1 The constant part of the latency chain is fine

Guide 14 §6.1's chain, with this system's measured constants:

| Step | Guide | Measured here |
|---|---|---|
| IOAPIC/MSI delivery | ~0.1 µs | not measured |
| **non-preemptible region** | **your number** | **unbounded — see below** |
| CPU interrupt entry | ~100 cy | not isolated |
| ISR: mask + signal notification | ~200 cy | `notify_signal` 37 cy |
| Scheduler decision + switch | 0.3–1 µs | 116 cy ≈ 45 ns |
| Driver thread first instruction | | |

Everything that is a constant is at or better than the guide's figure. A
device interrupt reaching a userspace driver thread should be well under
a microsecond of *constant* cost. **Estimate:** 0.2–0.5 µs, from
37 + 116 cycles of measured work plus entry and EOI, at 2.6 GHz.

That is not the number that matters.

### 5.2 The number that matters is unbounded today

Guide 14 §6.2 asks for a table of kernel operations with analytical
bounds next to measured numbers. Here is the honest version:

| Operation | Bound | State here |
|---|---|---|
| IPC (slow path) | O(1) | Holds. 1635 cy same-core. |
| Capability lookup | O(depth ≤ 4) | Holds by construction. |
| `cap_revoke` | unbounded | **Not preemptible.** |
| `Untyped_Retype` zeroing | O(size) | **No preemption points.** 256 KiB = 64 pages ≈ 20–40 µs (guide's figure). |
| `vspace_destroy` | O(mappings) | Does not exist; teardown is a userspace sweep. |
| TLB shootdown | O(cores) + remote ack | Implemented, ack is mandatory, **not measured**. |
| Scheduler pick | O(1) | Holds — bitmap. |
| **BKL hold time** | **unbounded** | **The dominant term, and it is new.** |

The last row is the finding. The big kernel lock means the worst-case
delay before a high-priority thread runs is *the longest time any other
processor can spend inside the kernel*, and that includes an unbounded
revoke on a low-priority thread. This is priority inversion at kernel
scope, and no amount of scheduler work fixes it.

The measurement that shows it is already in the tree:
`ipc_roundtrip_cost_cross_core` p99 is **56 819 cy ≈ 21.9 µs**, against a
p50 of 24 617. A control loop that does one IPC per period would see
that p99. A 1 ms period with a 100 µs jitter budget survives it; a 100 µs
period does not.

### 5.3 What track A actually requires

In dependency order, and none of these are optional for a *provable*
deadline:

1. **IPC off the BKL** — the next path, already identified.
2. **A partitioned RT core.** For hard real-time the guarantee has to be
   that the RT core shares no lock with any non-RT core. That is guide
   12 §1's option (c), and it is the honest end state rather than "fewer
   locks". Everything else is best-effort.
3. **SchedContext + timeslice accounting** (ADR-0004, guide 14 §4).
   Today a thread's budget is not tracked at all; "provably" is not
   available without it.
4. **Preemptible revoke and retype**, per §4.4.
5. **A measured bound on every `IF=0` region**, with the measurement in
   CI — which here means `make test`, since there is no CI.
6. **Priority inheritance or donation** for the passive-server case.
   Today a high-priority client calling a low-priority server inherits
   nothing, and the direct-switch priority check (fixed at M3.2) is only
   the local half of that problem.

**Estimate, stated as an estimate:** with (1)–(6) done and an isolated
core, a 1 ms loop holding p99 jitter in the low tens of microseconds
looks reachable on this hardware — the constants support it. Without
(2), the honest claim is *soft* real-time: the mean will look excellent
and the tail will be owned by whatever another core was doing inside the
kernel. The current p99/p50 ratio of 2.3× on cross-core IPC is that tail,
measured, today.

### 5.4 What would falsify the design

If, after (1)–(6), the p99 of an end-to-end sensor→actuator chain on an
isolated core is still dominated by kernel-internal variance rather than
by the device, then the microkernel structure is costing more than it
returns for this workload, and the honest response is to say so in an
ADR rather than to keep optimising.

---

## 6. The GUI vertical (track B): what the numbers allow

Track B is not chosen (ADR-0002 picked A), but the design owes an answer
about whether it is *possible* on this kernel, because guide 21 §3
commits to a compositor built from ordinary components.

### 6.1 IPC is not the problem

A 60 Hz frame is 16.67 ms; 120 Hz is 8.33 ms. Same-core IPC is 1635 cy ≈
**0.63 µs**; cross-core is 24 617 cy ≈ **9.5 µs**.

**Estimate,** 20 surfaces, one round trip per surface per frame:

| | per frame | share of 16.67 ms | share of 8.33 ms |
|---|---|---|---|
| 20 × same-core IPC | 12.6 µs | 0.08% | 0.15% |
| 20 × cross-core IPC | 190 µs | 1.1% | 2.3% |

Even at today's slow-path numbers, and even if every client sits on a
different core, the *message* cost of compositing is one to two percent
of a frame. The Wayland-shaped model in guide 21 §3 (D3: clients render
into buffers they own, damage is explicit, no drawing commands cross the
protocol) is affordable here with room to spare.

Vsync is also already expressible: an IRQ becomes a Notification signal
(37 cy) bound to the compositor's thread, which is exactly guide 21 §4's
requirement.

### 6.2 Pixels are the problem, and none of that exists

What a compositor needs from the kernel, against what exists:

| Need | State |
|---|---|
| Share a buffer between client and compositor | **Exists.** A Frame capability mapped into two VSpaces; `mem` already does this for the pager. |
| Transfer a buffer capability at runtime | **Exists** (ADR-0009), one capability per message. |
| A ring for damage/present events without a syscall per message | **Missing.** Guide 08 §6c; parked. |
| DMA-capable memory with a device's own address | **Missing.** `dma_addr_t` is named in `types.h` and not implemented. |
| IOMMU / device isolation | **Missing.** A GPU driver without it can DMA over the kernel. |
| MMIO capability (BARs) | **Missing.** Only I/O ports exist (`CAP_IOPORT`). |
| Modeset / scanout | **Missing.** No display driver of any kind. |

So: the *architecture* of the graphics stack is affordable on this
kernel and the *plumbing* underneath it is roughly four milestones of
work that has never been started — MMIO capabilities, DMA with a device
address type, an IOMMU story, and a bulk transport. Guide 21 §5's claim
that headless is the default is true today in the strongest possible
sense: there is no alternative.

**The honest summary for track B:** nothing measured here argues against
it, and nothing here supports a claim that it works. The IPC budget has
two orders of magnitude of headroom for a 60 Hz compositor; the risk is
entirely in the device plumbing, which is exactly the part this project
has deliberately never touched (`ROADMAP.md`: "real hardware until P4").

---

## 7. The three things I would fix first

Not a roadmap — a ranking, if the goal is that the next milestone's
numbers mean something.

1. **IPC off the BKL.** It is the single number that gates both
   verticals, it is the guide's own next step, and the 1.20× scaling
   measurement makes the case without argument.
2. **A bound on every kernel region that runs with interrupts off or the
   lock held**, published next to its measurement. Guide 14 §6.2 asks for
   the table; producing it will find things, in the way that writing
   `docs/locking.md` found that the logger deadlocks against itself.
3. **The Untyped migration.** Not for performance — for the ability to
   say the headline property out loud.

Everything else on the deferred list is genuinely deferrable. These
three are load-bearing.
