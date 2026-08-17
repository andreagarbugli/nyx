# 19 — Roadmap, milestones, and the things people forget

> Goal: turn eighteen chapters of design into an ordered plan you can actually
> execute, with honest effort estimates, explicit decision points, and a list of
> the unglamorous things that are missing from every hobby kernel — including the
> ones that will block you at the worst moment.

---

## 1. How to sequence a project like this

Three principles, learned the hard way by a lot of people:

**Always have a running system.** Never spend three weeks on a rewrite that
doesn't boot. Every milestone below ends in something observable. If a change is
too big to land in one step, land it behind a config flag with both paths
working, measure both, then delete the loser. (Chapter 12's "BKL first, then
remove it path by path" is this principle applied to SMP; Chapter 08's "C
slow-path before the assembly fast path" is the same thing applied to IPC.)

**Build the thing that unblocks the most other things.** Serial output unblocks
everything. The capability system unblocks every object type. The IDL generator
unblocks every server. Do these early even when they aren't exciting.

**Defer optimization until you can measure it, but not the *design* for it.**
The IPC fast path can wait. The decision that messages live in registers, that
the TCB holds the message buffer, and that endpoints never queue messages cannot
— those are architectural, and retrofitting them is a rewrite. The rule: defer
implementations, never defer the constraints that shape interfaces.

---

## 2. The milestone ladder

Estimates assume someone comfortable with C and systems programming, working
part-time (say 10–15 hours a week), and *include debugging*, which is most of the
time. Halve them if you're experienced and full-time; double them if x86 assembly
is new to you. Nobody hits these estimates on the first try, and that is normal —
they are for sequencing, not for guilt.

### Phase 0 — It boots (chapters 02–03)

| # | Milestone | Effort | Done when |
|---|---|---|---|
| M0 | Toolchain, linker script, Makefile, `make iso` | 2–4 d | `grub-file --is-x86-multiboot2 nyx.elf` passes |
| M1 | Multiboot2 stub → long mode → higher half → `kmain` | 1–2 wk | QEMU reaches `kmain` without a triple fault |
| M2 | Serial console + your own `printf` + `klog` ring | 2–3 d | `Nyx booting...` on `-serial stdio` |
| M3 | Parse the boot info into `struct bootinfo`; print the memory map | 2 d | Memory map printed and plausible |

> **Checkpoint.** M1 is the highest-attrition milestone in the whole project. A
> triple fault with no output is where most people quit. Chapter 03 §8's
> debugging checklist exists for exactly this; work through it in order rather
> than staring at the code. If you're stuck for more than two evenings, switch to
> Limine, get to `kmain`, and come back to the hand-written stub later as a
> self-contained exercise. Being stuck is not more educational than progress.

### Phase 1 — The machine is under control (chapters 04–06)

| # | Milestone | Effort | Done when |
|---|---|---|---|
| M4 | GDT, TSS, IST stacks, IDT, ISR stubs, exception dump | 1 wk | A deliberate `*(int*)0 = 1` prints a full register dump instead of rebooting |
| M5 | PMM: boot allocator → buddy → `struct page` database | 1 wk | Allocate/free 100 000 frames; KTESTs pass; frames are zeroed |
| M6 | VMM: page tables, map/unmap, `vmm_dump_walk`, address-space create/destroy | 1–2 wk | `vspace_destroy_frees_everything` leak test passes |
| M7 | LAPIC, IOAPIC, TSC calibration, TSC-deadline timer | 3–5 d | A periodic message at a measured, correct rate |
| M8 | Slab allocator, kernel heap, guard-page kernel stacks | 3 d | Red-zone/poison debug mode catches an injected overflow |

### Phase 2 — It is an operating system (chapters 07–10)

| # | Milestone | Effort | Done when |
|---|---|---|---|
| M9 | TCBs, `context_switch`, round-robin scheduler, idle thread | 1 wk | Three kernel threads interleave; cycle count in range |
| M10 | Capability system: CSpace, `cap_lookup`, copy/mint/move/delete | 1–2 wk | Host fuzzer runs clean for an hour |
| M11 | Untyped memory and Retype; remove `kmalloc` from object creation | 1 wk | `untyped_retype_zeroes_memory` passes; kernel has no heap for objects |
| M12 | Endpoints, notifications, synchronous IPC (C slow path) | 1–2 wk | 12 IPC KTESTs pass, including `ipc_no_kernel_allocation` |
| M13 | `syscall`/`sysret` entry, ABI, `cap_invoke` dispatch | 4–6 d | `syscall_roundtrip_cycles` in the 80–200 range under KVM |
| M14 | ELF loader, first user thread, `enter_userspace` | 4–6 d | A ring-3 program prints via IPC to a kernel-backed console |
| M15 | Root task: hand over capabilities, spawn a second process | 1 wk | Two user processes exchange a badged IPC round trip |

> **Checkpoint.** M15 is the real "I built an OS" moment — two independent
> user-mode processes communicating through your kernel using capabilities you
> designed. Everything before it is infrastructure; everything after it is
> building a system. Take a day off. Write a blog post.

### Phase 3 — It is a *system* (chapters 11–12, 15)

| # | Milestone | Effort | Done when |
|---|---|---|---|
| M16 | `libnyx` + the IDL stub generator | 4–6 d | Adding a server method means editing one `.idl` file |
| M17 | Console server, ramdisk server, `initrd` with real programs | 1 wk | A shell-like program reads a file from the ramdisk |
| M18 | Process manager: spawn, exit, wait, kill | 1 wk | `spawn` from userspace works and cleans up on exit |
| M19 | VFS as a name resolver; `open` returns a badged FS endpoint | 1–2 wk | Two filesystems mounted; reads bypass the VFS |
| M20 | IRQ delivery to userspace; a real userspace driver (serial, then PCI) | 1–2 wk | The console driver is a user process holding an `IRQHandler` |
| M21 | SMP: AP bringup, per-CPU data, ticket locks, TLB shootdown | 2–3 wk | 4 CPUs, stress test passes, lockdep clean |
| M22 | Reincarnation server + chaos test | 1 wk | Kill a driver in a loop for an hour; memory stays flat |

### Phase 4 — The positions from chapters 14–17

These are what makes the project *yours* rather than a re-implementation. They
are also where estimates become fiction, so treat these as relative sizes.

| # | Milestone | Effort | Done when |
|---|---|---|---|
| M23 | `IoRegion` + `IoQueue` objects; server-backed queue path | 2–3 wk | A read completes with zero syscalls on the data path |
| M24 | IOMMU (VT-d) contexts, default-deny, interrupt remapping | 2–3 wk | A userspace driver does DMA and a bad IOVA is *blocked*, provably |
| M25 | NVMe or virtio-net driver in userspace on the queue path | 2–4 wk | The benchmark table's `ioq_submit_complete_device` row has a number |
| M26 | `SchedContext` capabilities, budget enforcement, passive servers | 3–4 wk | Priority inversion test shows bounded blocking; WCET figures published |
| M27 | The object/naming model: typed properties, discovery, no `ioctl` | 2–3 wk | A `sysinfo`-equivalent walks the object graph with no new syscalls |
| M28 | POSIX personality (enough for a port of a real program) | 4–8 wk | Something you didn't write compiles and runs |
| M29 | Second architecture (RISC-V) | 4–8 wk | Same tests pass on both; the weak memory model found bugs |

### Phase 5 — Research

Pick from Chapter 13. By now you have a workbench, a measurement harness, and
opinions. The list in Chapter 13 §D is ordered roughly by "most valuable to the
field per unit of your effort".

---

## 3. The things people forget

This is the section I'd most want to have read at the start. None of these are
hard; all of them are invisible until they block you.

### 3.1 Time

Almost every hobby kernel has a broken notion of time, and it hurts later.

- **Three different clocks, and you need all three.** *Monotonic* (never goes
  backwards, no leaps — for timeouts and scheduling), *wall clock* (adjustable,
  for timestamps), and *CPU time* (per-thread accounting, for `SchedContext`
  budgets). Expose them as three separate things from day one. Conflating them is
  the bug that gives you a system which hangs for an hour when someone sets the
  clock backwards.
- **Read the RTC exactly once at boot**, then run wall clock as
  `boot_wall_time + monotonic_elapsed`. Never poll the RTC in a hot path; and
  handle the update-in-progress flag or you'll read a torn time twice a second.
- **TSC caveats**: check invariant TSC (`CPUID.80000007H:EDX[8]`); measure
  per-CPU offsets at boot; be aware that a VM migration can break all of it.
- **Timer wheels vs. sorted list.** Start with a sorted list of deadlines. When
  you have thousands of timers, switch to a hierarchical timer wheel — but not
  before, because the wheel's complexity buys nothing at ten timers.
- **NTP-style adjustment** eventually means slewing the wall clock rate rather
  than stepping it. Design the wall clock as `base + rate * monotonic` now and
  the change is a coefficient rather than a redesign.

### 3.2 Randomness

You need entropy before you think you do — for KASLR, for badge values you'd
rather not be guessable, for hash-table seeding, and later for anything
cryptographic.

- **`RDSEED`/`RDRAND` if available** (check `CPUID.07H:EBX[18]` and
  `CPUID.01H:ECX[30]`), and **retry properly**: `RDRAND` can legitimately fail,
  and code that ignores CF and uses whatever was in the register is a real,
  shipped bug class.
- **Don't trust it alone.** Mix hardware RNG with timing jitter (TSC deltas
  across interrupts) into a pool, and hash it with something like ChaCha20 or
  SHA-256. The reasoning: hardware RNGs are opaque and have been the subject of
  credible suspicion; a mix is strictly safer and costs nothing.
- **Expose it as a capability**, not as `/dev/urandom` — an `Entropy` object
  whose invocation fills a buffer. Then "which components can get randomness" is
  an answerable question.
- **Early boot is the hard case.** Before you have entropy, KASLR has nothing to
  work with. The honest options are the bootloader's RNG (Limine and UEFI both
  offer one), or accepting that the first boot's layout is weak.

### 3.3 Shutdown, reboot, and power

Everyone implements boot. Almost nobody implements the other end, and then
testing on real hardware is miserable.

- **Reboot**: try the keyboard controller (`0xFE` to port `0x64`), then the PCI
  reset register (`0xCF9`), then a triple fault as the last resort. Implement all
  three with fallback; the first one works on maybe half of real machines.
- **Shutdown** requires ACPI — specifically evaluating `\_S5` from AML, which
  means an AML interpreter. This is a strong argument for the userspace ACPI
  server (uACPI) from Chapter 04. Under QEMU you can cheat with the
  `isa-debug-exit` device or writing to the ACPI PM1a control port directly, but
  don't let the cheat hide the fact that you have no ACPI story.
- **Orderly shutdown is a protocol**, not a syscall: notify servers, let them
  flush, wait with a timeout, then kill. Design it as a notification broadcast on
  a well-known endpoint. If you don't, filesystem work will be lost and you'll
  build a fsck instead.
- **Idle power**: `hlt` in the idle thread is the minimum. `MWAIT` with C-states
  is a real improvement on laptops and a source of subtle wakeup-latency
  problems for Chapter 14's real-time claims. Say which you chose and why in
  `docs/`.
- **Suspend/resume (S3)** is a large project involving re-initializing every
  device. Defer it, but know it exists, and don't design device drivers that
  assume they are initialized exactly once.

### 3.4 Errors

- **Define the error space once, in `include/abi/errno.h`, before you have 50
  call sites.** Retrofitting error codes is miserable, and the temptation to
  return `-1` "for now" is how you get a kernel where failures are
  indistinguishable.
- **Do not copy POSIX `errno`.** It conflates unrelated failures (`EINVAL` means
  eleven different things) and lacks the ones a capability system needs. Nyx
  needs at least: `ENOCAP` (no such capability), `ERIGHTS` (capability lacks the
  right), `ETYPE` (wrong object type), `ENOSLOT` (destination slot occupied),
  `EREVOKED`, `EBUDGET` (scheduling budget exhausted), `EWOULDBLOCK`,
  `EPEERGONE` (the server on the other end died).
- **Errors that cross an IPC boundary need a stable numbering** — they are ABI.
  Generate the table from one file so kernel, `libnyx`, the IDL stubs and the
  human-readable strings can't drift.
- **`EPEERGONE` deserves special thought.** In a multi-server system, "the thing
  I was talking to died" is a normal event, not an exceptional one, and it must
  be in the generated stubs' contract from the beginning. This is the single
  biggest API difference between a multi-server OS and a monolith, and burying it
  is how you get a system that hangs instead of recovering.

### 3.5 Strings, text, and the console

- You will write `vsnprintf` (Chapter 03). Extend it early with `%p`, width and
  precision, and custom specifiers for your own types — `%pC` for a capability,
  `%pT` for a TCB. Ten lines that improve every log line you ever write.
- **Decide on UTF-8 and be done with it.** The console driver decodes UTF-8 to
  code points; everything internally is bytes. Do not invent a wide-char type.
- **Terminal emulation** is a swamp: a VT100/ANSI subset (cursor movement, SGR
  colours, erase) is a day of work and enough to run most programs. Full
  xterm compatibility is not a thing you should be building. Put it in a
  userspace console server so replacing it costs nothing.
- **The keyboard is worse than you think**: scancode sets, extended codes,
  modifier state, key repeat, layouts, dead keys. Userspace. Absolutely
  userspace.

### 3.6 Resource accounting and limits

Untyped memory (Chapter 09) solves kernel memory beautifully — and *only* kernel
memory. You still need answers for:

- **CPU time**: `SchedContext` budgets (Chapter 14) are the answer, if you build
  them. If you don't, a runaway thread at high priority is a hang.
- **Queue depth and backpressure**: bounded rings give this for free (Chapter
  15), which is a reason to prefer them over unbounded lists everywhere.
- **Per-client state in servers**: a server holding unbounded per-client state is
  a DoS regardless of what the kernel does. This must be a rule in your server
  guidelines, checked in review.
- **Who pays for a page fault?** The faulting thread's budget, or the pager's? If
  you have scheduling contexts, this is answerable; write the answer down.

### 3.7 The build and release machinery

- **Reproducible builds**: `-ffile-prefix-map`, `SOURCE_DATE_EPOCH`, sorted link
  order. Then two people can compare binaries, which is occasionally exactly the
  debugging tool you need.
- **Embed the version**: git describe + build date + config hash, printed in the
  boot banner and in every panic. You will otherwise waste an afternoon debugging
  a stale image.
- **Pick a licence on day one.** MIT/Apache-2.0 for maximum reuse, GPL if you
  want derivatives to stay open. Adding a licence later requires every
  contributor's agreement, which is a problem you can avoid by spending five
  minutes now.
- **Write `docs/security.md` with a threat model and a disclosure policy** before
  anyone else runs your code.

### 3.8 Real hardware

QEMU is forgiving in ways that will mislead you. Booting on a real machine is a
distinct milestone worth reaching once, early — say after M17 — because it
invalidates a whole class of assumptions cheaply.

What breaks first, roughly in order: firmware gives you a messier memory map
(overlapping, unsorted, reserved regions you must respect); serial is on a
different port or absent entirely (get a USB-serial adapter, or use the framebuffer);
the APIC configuration differs and Interrupt Source Overrides in the MADT
actually matter; CPU features you assumed (1 GiB pages, x2APIC, invariant TSC)
may be missing; timing is different enough to expose races QEMU hid; and some
firmware leaves devices in states QEMU never produces.

Practical route: a cheap old laptop or an Intel NUC, boot from USB via GRUB or
Limine, and a serial adapter. Budget a weekend. The list of things it teaches you
is worth more than the weekend.

### 3.9 Documentation you will regret not writing

Six files. Write them as you go; they take minutes each and save days.

| File | Contents | Why |
|---|---|---|
| `docs/abi.md` | The syscall and object interface | It's a contract; undocumented contracts get broken accidentally |
| `docs/invariants.md` | Every "this must always be true" | These are what tests check and what you'll violate at 1 a.m. |
| `docs/locking.md` | Lock rank order and rules | The only defence against deadlock that scales |
| `docs/security.md` | Threat model, what's in the TCB, known channels | Otherwise your security claims are vibes |
| `docs/performance.md` | The benchmark table over time | Chapter 18's whole point |
| `docs/decisions/` | One short ADR per significant choice: context, options, decision, consequences | In six months you will not remember why, and you will re-litigate it |

The ADR habit is the one I'd push hardest. Twenty lines when the decision is
fresh replaces an hour of archaeology later — and writing "consequences" forces
you to notice when you don't actually have an argument.

---

## 4. Traps specific to this design

Things that follow from *Nyx's* choices in particular, and that generic OSdev
advice won't warn you about:

1. **The capability system makes early bootstrapping awkward.** Before the root
   task runs, nothing has capabilities, so kernel-internal object creation needs
   a privileged path. Keep that path tiny, clearly marked, and unreachable after
   boot — it is a security hole with a timer on it.
2. **"No kernel heap" is easy to violate accidentally.** One `kmalloc` in an IPC
   path and you've lost the property that makes accounting exact. Add the KTEST
   from Chapter 08 that asserts allocation counts don't change across an IPC, and
   run it in CI.
3. **The direct map plus memory encryption (SME) breaks P2V/V2P.** If you ever
   run on an SME-enabled machine, the C-bit lives in the physical address and
   your macros are wrong. Centralize them so the fix is one place.
4. **Registered `IoRegion`s pin memory forever.** That's the feature (no
   `get_user_pages` dance) and the hazard: a process that registers everything
   and exits slowly holds the memory. Revocation must actually unmap from the
   IOMMU *and* wait for in-flight DMA, and "wait for in-flight DMA" is harder
   than it sounds.
5. **Passive servers change your debugger's mental model.** A server thread with
   no scheduling context looks *stopped* in `ps`. Make your debug output say
   "passive, awaiting donation" rather than "blocked" or you'll chase a ghost.
6. **Badges are not authentication if you mint carelessly.** A badge identifies
   *which capability* was used, not who used it. If two clients can obtain the
   same badged capability, your server's identity model is broken. The rule:
   badges are minted by the party that also decides who receives them, and that
   party is usually the root task or a broker.
7. **Restart-transparency requires the endpoint to outlive the server.**
   Chapter 11 makes this point; it's easy to lose in a refactor, and the symptom
   (clients hold dead capabilities after a restart that "worked") appears weeks
   later.

---

## 5. When to stop and refactor

Signals that you should stop adding features:

- The same bug class appears three times → the abstraction is wrong, not the
  code.
- You avoid touching a file → it needs to be split, today, while you still
  remember why.
- A test takes longer to write than the feature → the feature has bad seams.
- You can't explain a subsystem in five minutes on a whiteboard → neither can
  anyone else, including you in three months.
- The host-test shim (Chapter 18 §3.1) is growing → your kernel code is getting
  entangled with its environment.

And the counter-signal, which matters just as much: **don't refactor a subsystem
you haven't finished understanding.** Two weeks of use teaches you what the right
shape is; two hours of aesthetic discomfort does not.

---

## 6. Staying with it

The realistic failure mode for this project isn't a technical wall. It's a
three-week gap that becomes three months.

- **Keep a `NEXT` file** with the exact next action ("add `IoRegion_Unmap`,
  including the in-flight DMA wait"). Coming back after a gap costs an evening of
  re-orientation, and this reduces it to five minutes.
- **Commit small and often**, with messages that say *why*. `git log` becomes the
  project journal you won't otherwise keep.
- **Alternate hard and easy work.** After two weeks on TLB shootdown, spend a
  night making the panic output beautiful. Both are real progress; only one
  requires a full tank.
- **Demo things.** Show someone two processes exchanging IPC. The response is
  usually better than you expect, and momentum is a resource.
- **Write about it.** Explaining a subsystem to a reader is the most reliable way
  to discover you don't fully understand it — and it's how the useful parts of
  this project reach anyone else.

---

## 7. What "done" could mean

There is no finish line, so choose one deliberately:

- **The learning goal**: you can explain, from memory, exactly what happens
  between a user program's `syscall` instruction and its return. Reached around
  M15.
- **The systems goal**: a self-hosting-ish system — shell, filesystem, network,
  drivers, all in userspace, surviving driver crashes. Around M22–M25.
- **The research goal**: one measurement, honestly obtained, that tells the world
  something it didn't know. Chapter 13 §D, item 1 is the most valuable and most
  achievable.
- **The craft goal**: a codebase you're proud to show, with documented
  invariants, a real test suite, and design decisions you can defend.

They're compatible, but they imply different priorities, and pretending you're
pursuing all four is how projects stall. Pick the one you actually want.

---

## 8. Exercises

1. Write your own version of the milestone table with your own estimates. Track
   actuals. After five milestones, compute your personal estimation factor and
   multiply all future estimates by it. Everyone's is above 1.
2. Write `docs/decisions/0001-capabilities.md` as an ADR, retroactively, for the
   choice to use capabilities instead of ACLs. Include the consequences you've
   already felt.
3. Pick three items from §3 that your current code doesn't handle and fix the
   cheapest one today.
4. Boot on real hardware. Write down everything that broke. This list is more
   valuable than any chapter here.
5. Write the `NEXT` file. Do it now, before you close this document.

---

Next: [20 — Bibliography and primary sources](20-bibliography.md)
