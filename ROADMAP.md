# ROADMAP — Nyx V2

One milestone at a time. A milestone is **done** only when its `done-when`
is *run* and passes. Never inferred from reading code.

Sequencing is chapter 19 §2's ladder, **reordered by chapter 00.5 and
`docs/retrospective.md` §4**: the things V1 could not retrofit are pulled
to the front, even where the guide teaches them later. Where this
disagrees with chapter 19's ordering, 00.5 wins and the milestone says so.

Status: `todo` · `wip` · `done (date)` · `blocked`

---

## The seven rules, as acceptance criteria

Every milestone below is reviewed against these, not just its own
done-when. They are chapter 00.5's checklist turned into a standing gate.

| # | Rule | Mechanical check |
|---|---|---|
| R1 | No kernel structure without a CPU index or a lock rank | grep review: no bare `static struct foo` mutable global |
| R2 | One `cpu_init()`, BSP calls it too | one definition, one call site per CPU |
| R3 | A fact has one representation; a forced copy is `_Static_assert`ed or read back by a test | build fails on drift |
| R4 | Enums crossing the ABI are append-only | `make abi-check` |
| R5 | Both teardown paths of an obligation land in the same commit, with a test each | review |
| R6 | Long operations return a restart code from the first one written | review + a restart test |
| R7 | Numbers are a deliverable: p50/p99/max, instrument audited | `make bench` output |

---

## Phase 0 — Structure before machine

V1's lesson: the harness and the shape are chapter 2 work, not chapter 18
work. Nothing in Phase 0 needs the kernel to do anything interesting.

| # | Milestone | Done when |
|---|---|---|
| M0.0 | `git init`, commit zero, `-Werror` freestanding toolchain, linker script, build | `make` produces `nyx.elf`; `grub-file --is-x86-multiboot2 nyx.elf` passes |
| M0.1 | Doc reset: `docs/` describes V2's *actual* state, not V1's | no claim in `docs/invariants.md` without a test that exists here |
| M0.2 | Test harness + bench runner wired to `make`, headless, exit code is the result | `make test` passes with one trivial ktest; `make bench` emits p50/p99/max JSON |

Status: all `todo`.

### ADRs are written when the decision is made

Not before. An ADR written in advance of the evidence is fiction, and
00.5 §6 does not ask for one — it says these two decisions are *expensive
to change*, which is a different claim from *decide them first*.

What it does ask for is that the decision be **noticed when it happens**,
because the real failure mode is not a missing document. It is code that
encodes an answer before anyone realised a question was being asked.

| Decision | ADR due at | Why there, and not later |
|---|---|---|
| Build system | after M0.0 | cheap to reverse; discovered by doing |
| Boot protocol | after M1.0 | same |
| **Capability representation** | **M2.1** | Retype creates objects. Whatever `struct cap` is typed that day *is* the decision. |
| **IPC message shape** | **M3.3** | Needs a workload to size against, and that is the first milestone that has one. |

The two in bold are the ones where "we'll see what makes sense" has a
deadline that arrives earlier than it looks.

> **M0.2 before M1.** V1 built the harness at chapter 18 and spent four
> milestones not knowing its own numbers were wrong (00.5 §5 — the core-0
> pin *was* the noise). The bench runner must also be able to say
> "instrument not trustworthy here" and skip: a `rdtsc` under TCG is not a
> cycle.

## Phase 1 — It boots

| # | Milestone | Done when |
|---|---|---|
| M1.0 | Boot stub → long mode → higher half → `kmain` | QEMU reaches `kmain` without a triple fault |
| M1.1 | Serial console, own `printf`, `klog` ring (the ring is per-CPU — R1) | `Nyx booting...` on `-serial stdio` |
| M1.2 | `cpu_init()` written now, with its one caller (00.5 §2) | BSP goes through `cpu_init`; every control-register bit set there and nowhere else |
| M1.3 | Boot info parsed into `struct bootinfo`; memory map printed | map printed and plausible against QEMU's `-m` |

> **M1.0 is the highest-attrition milestone in the project** (chapter 19).
> Chapter 03 §8 has the checklist. Artifacts before theories: `-d
> int,cpu_reset,guest_errors` and `info registers`.

> **M1.2 is out of guide order on purpose.** Chapter 3 introduces this;
> chapter 12 is where V1 discovered it mattered. Writing it now, with one
> caller, is what makes AP bringup a one-line change later instead of an
> afternoon of hunting missing `EFER.SCE`.

## Phase 2 — The machine is under control

| # | Milestone | Done when |
|---|---|---|
| M2.0 | GDT, TSS, IST stacks, IDT, ISR stubs, exception dump | a deliberate `*(int *)0 = 1` prints a full register dump with the right CR2 and vector |
| M2.1 | Untyped memory as the *only* allocator, including boot memory (retrospective §4.5) | there is no `kmalloc`/`pmm_alloc` in the tree; `untyped_retype_zeroes_memory` passes |
| M2.2 | Retype zeroing is preemptible from the first version (00.5 §7) | a retype of a large untyped returns a restart code and completes across re-invocations |
| M2.3 | VMM: page tables, map/unmap, W^X refused before any table is allocated, `vmm_dump_walk` | `w_xor_x_is_enforced` and `vspace_destroy_frees_everything` pass |
| M2.4 | `vspace_destroy` is preemptible and restartable | destroy of a large vspace restarts and finishes; leak test still clean |
| M2.5 | LAPIC, TSC calibration, TSC-deadline timer | a periodic message at a measured, correct rate |

> **M2.1 is chapter 19's M11 moved ahead of its M5.** V1 shipped
> `pmm_alloc` "temporarily" and deferred the untyped migration four times,
> which is why it cannot honestly claim its headline property. There is no
> temporary allocator in V2.

## Phase 3 — It is an operating system

| # | Milestone | Done when |
|---|---|---|
| M3.0 | Capability system, **packed representation** (retrospective §4.6) | `sizeof(struct cap)` is the number ADR-M0.1 committed to; lookup benched, p50 recorded |
| M3.1 | Preemptible, *recursive* revoke (retrospective §4.4) | deleting a CNode capability deletes what is inside it; revoke of a deep subtree restarts |
| M3.2 | TCBs, `context_switch`, per-CPU runqueue from the first version (00.5 §1) | three kernel threads interleave; `this_rq()` exists and `NCPU` is an array bound, not a comment |
| M3.3 | Per-thread IPC buffer, endpoints, notifications, synchronous IPC | `ipc_no_kernel_allocation` passes; capability transfer, long messages and bulk use *one* mechanism |
| M3.4 | Reply is an object, not a TCB pointer (retrospective §4.3) | killing either end cancels the obligation, with a test in each direction (R5) |
| M3.5 | `syscall`/`sysret`, ABI, `cap_invoke` dispatch | `syscall_roundtrip_cycles` recorded under KVM; skipped, not passed, under TCG |
| M3.6 | ELF loader, first ring-3 thread | a ring-3 program prints via IPC; every frame it got was zeroed |
| M3.7 | Root task hands over capabilities, spawns a second process | two user processes exchange a badged IPC round trip |

> **M3.3's register fast path is an optimisation of the buffer shape, not
> the shape itself.** If the fast path is written first, the buffer will
> never happen — that is exactly how V1 ended up serving a 4 KiB page in
> 128 round trips.

## Phase 4 — It is a system

Chapter 19's Phase 3, minus what moved earlier. Detailed when Phase 3 lands.

`libnyx` + IDL · console and ramdisk servers · process manager · VFS as a
name resolver · IRQ to userspace, real userspace driver · **SMP: the
second `cpu_init()` caller** · reincarnation server + chaos test that
kills *clients* as well as servers.

> **Testing runs `SMP=4` under KVM by default from M0.2** (retrospective
> §4.7), not from the SMP milestone. TCG hid a real bug in V1 for several
> milestones. A test that needs a quiet machine says so explicitly.

## Phase 5 — Taking a position

Chapter 19's Phase 4. `IoRegion`/`IoQueue` · IOMMU · a real device on the
queue path · `SchedContext` capabilities and budget enforcement · the
object/naming model. Not planned in detail until Phase 4 lands; V1's
retrospective §5 says what the numbers must allow for track A.

---

## Where this roadmap disagrees with chapter 19

Log the disagreements rather than silently reordering.

| Moved | From | To | Why |
|---|---|---|---|
| Test + bench harness | M-late (ch. 18) | M0.2 | 00.5 §5 |
| `cpu_init()` as a named function | implicit in ch. 3 | M1.2 | 00.5 §2 |
| Untyped / no kernel allocator | M11, after PMM | M2.1, *instead of* a PMM | retrospective §4.5 |
| Preemptible long operations | ch. 14, after the fact | M2.2, M2.4, M3.1 | 00.5 §7 |
| Packed capabilities | "behind the fast-path trigger" | M3.0 | retrospective §4.6 |
| Per-thread IPC buffer | ch. 8 §6a, optional | M3.3, mandatory | retrospective §4.2 |
| Reply object | not in V1 | M3.4 | 00.5 §6, retrospective §4.3 |
| SMP=4 under KVM in CI | M21 | M0.2 | retrospective §4.7 |
