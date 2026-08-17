# Appendix D — The layers nobody writes chapters about

> Goal: the topics that don't appear in OS textbooks, don't appear in
> microkernel papers, and will consume more of your time than IPC. Each section
> gives you: why it matters more than you think, what's genuinely hard about it,
> what the microkernel-specific angle is, and the minimum viable version.
>
> Read this before you plan your year. Several of these are load-bearing
> decisions that are painful to retrofit.

---

## 1. Power management — the single largest omission in this book

**Why it matters.** On anything with a battery, power management *is* the
operating system. It's also the reason "just use Linux" wins on laptops: the
power management is 20 years of vendor-specific empirical knowledge that nobody
can reproduce. And it's the topic hobby OS projects universally skip, which is why
they all report "my laptop gets 40 minutes of battery."

**What's actually involved:**

| Layer | Content |
|---|---|
| CPU idle | C-states: `hlt`, `mwait` with hints, package C-states. Deeper = more power saved, longer exit latency. Choosing correctly needs a prediction of idle duration. |
| CPU frequency | P-states, `HWP`/`CPPC` (hardware chooses, you give hints), energy-performance preference |
| Tickless operation | A timer interrupt every 1 ms prevents deep C-states entirely. Chapter 04's TSC-deadline design is a prerequisite. |
| Device power | Per-device D-states, runtime PM with reference counting, PCIe ASPM, link power management |
| Power domains | Devices share rails; turning one off requires all its users idle. A dependency graph. |
| Suspend/resume | S3, s2idle, hibernate. See §1.2. |
| Thermal | Sensors, throttling policy, fan control |
| Energy-aware scheduling | Which core, at which frequency, for this work? |

**The microkernel angle, and it's genuinely interesting:** in a monolithic
kernel, power management is centralized because one component sees everything. In
a multi-server system, **the information is distributed across processes that
don't trust each other**. "Can we enter a deep C-state?" requires knowing that no
driver has pending work and no timer will fire soon — facts held by a dozen
separate components.

This makes system-wide power management a **distributed consensus problem**, and
that framing is, as far as I know, unexplored. Options:

- A power manager server that all drivers report to (centralized policy,
  distributed information — the obvious design).
- Deadline-based: every component declares its next required wakeup; the power
  manager takes the minimum and picks a state whose exit latency fits. This
  composes beautifully with Chapter 14's scheduling contexts, since a component's
  next deadline is *already* known to the scheduler.
- Capability-scoped: holding a "prevent deep sleep" capability is how you express
  a wakelock, and it's revocable and auditable — which is a better answer than
  Android's wakelocks, where a buggy app drains your battery invisibly.

**The measurement problem:** you cannot optimize power without measuring it. RAPL
(Intel/AMD energy counters) gives you package energy in software, at ~1 ms
resolution. Wire it into Chapter 18's harness *early*: "joules per unit of work"
should be a tracked CI metric alongside cycles. Almost nobody does this, and it
turns power work from folklore into engineering.

### 1.1 Idle is the common case

A desktop system is idle >95% of the time. The metric that matters is **wakeups
per second at idle**, and the target is single digits. Every periodic poll, every
1 ms timer, every driver that wakes to check something, costs battery
continuously. `powertop`-style accounting — which component caused each wakeup —
should exist from early on, because in a multi-server system the answer is
attributable in a way it isn't on Linux (the wakeup came through a specific
notification from a specific component).

**This is a genuine microkernel advantage worth demonstrating.** Publish the
number.

### 1.2 Suspend/resume is the hardest thing in the system

Harder than SMP, harder than the IPC fast path. It requires *every* driver to
correctly save and restore its device's state, in the right order, with the
memory controller going away underneath them. On real hardware it involves ACPI
methods, firmware bugs, and devices that lie about their state.

The microkernel version has a structural advantage — each driver is a separate
process with explicit state, and the ordering is the dependency graph you already
have (Chapter 11 §2) — and a structural difficulty: the suspend protocol must
reach every component, and any one of them can hang. So: bounded timeouts,
per-component, with the reincarnation server as the fallback.

**Minimum viable version:** implement s2idle (freeze processes, put devices in
low power, enter deep C-states, wake on interrupt) before S3. It's mostly a
scheduling and driver-quiescence problem rather than a firmware problem, and it's
where the industry has moved anyway.

---

## 2. Time is much harder than a timer

Chapter 04 covers timer interrupts. That's the easy half. The rest:

- **Multiple clock domains.** Monotonic (never jumps, no leap seconds — for
  measuring intervals), realtime (wall clock, jumps when NTP corrects, has leap
  seconds — for timestamps), boot time (monotonic including suspend), and process
  CPU time. Applications constantly use the wrong one. Provide all of them, name
  them clearly, and make monotonic the default.
- **TSC is not always reliable**: check `invariant_tsc`, and know that on older
  or multi-socket systems it may not be synchronized across cores. Have a
  fallback and a validation test.
- **Clock synchronization across cores** at boot: measure the offset, or you'll
  see time go backwards on migration, which breaks everything subtly.
- **Suspend gaps.** Monotonic time must not include suspend; boot time must.
  Getting this wrong makes timeouts fire immediately on resume.
- **NTP/PTP** discipline: you need to *slew* the clock (adjust its rate) rather
  than step it, or you break every interval measurement in the system. PTP gets
  you sub-microsecond, which matters for distributed systems and for the
  measurement work in Chapter 18.
- **Time zones and leap seconds** are userspace data (tzdata) and a maintenance
  burden. Keep them entirely out of the kernel.
- **The timestamp on an event should come from the source** (Chapter 23 §3.1) and
  be comparable across components — which means one system-wide monotonic clock
  everyone can read cheaply. A `vDSO`-equivalent (a shared page with the TSC
  calibration, read without a syscall) is worth building; it's ~100 lines and
  removes a syscall from every timestamp.

---

## 3. Entropy and randomness — the bug you'll ship

**Why this bites:** the kernel needs cryptographic randomness before anything
else does — for ASLR, stack canaries, hash seeds (Appendix C §7), capability
badges if you make them unguessable, and the TLS in your first network
connection. At the moment you need it, you have almost no entropy: no user input,
no disk timing, no network.

This has produced *real, widespread, catastrophic* failures — the classic case
being embedded devices generating predictable SSH host keys because they seeded
their RNG at first boot with nothing.

**What to do:**

1. Use `RDSEED`/`RDRAND` if available, but **do not trust them alone** — mix them
   into a pool rather than using them directly, on the general principle that you
   cannot audit a hardware RNG.
2. Mix in everything at boot: TSC jitter, interrupt timings, firmware-provided
   entropy (UEFI has an RNG protocol), the boot loader's seed if it has one.
3. **Persist a seed file across reboots**, mixed with fresh entropy at shutdown.
   This is how most real systems actually get their entropy on a small device.
4. **Block, or fail loudly, if the pool isn't initialized.** Linux got this wrong
   for years (`/dev/urandom` returning predictable bytes early); the fix was
   `getrandom()` blocking. Do it right the first time.
5. **VM cloning breaks everything**: two VMs resumed from the same snapshot have
   the same RNG state and will generate the same keys. Detect it (VM generation
   ID) and reseed.
6. In a microkernel: is the RNG in the kernel or a server? The kernel needs it
   (ASLR, canaries) so it needs a small internal one; a userspace entropy server
   can feed it and serve everyone else. Write down the trust argument.

**Minimum viable version:** a ChaCha20-based CSPRNG, seeded from RDSEED + TSC
jitter + a persisted seed, with a hard "not yet initialized" state. ~200 lines.
Do it early — a lot of things depend on it, and retrofitting means auditing
everything that used the weak version.

---

## 4. The device model

Chapter 11 covers drivers. It does not cover the *framework*, which is most of
the work in a real system:

- **Enumeration**: PCIe (ECAM, covered), USB (an entire protocol stack), platform
  devices from ACPI or a device tree, I²C/SPI on embedded, virtio.
- **Binding**: matching a driver to a device by ID, class, or compatible string.
  Who decides? In a capability system, the answer is a *device manager* that holds
  the PCI configuration capability and hands out per-device capabilities — which
  makes "which driver is allowed to bind to this device" an explicit policy
  question rather than a match table.
- **Dependency ordering**: a driver needs its bus, its clocks, its power domain,
  and its regulators up first. This is a topological sort over a graph that ACPI
  or the device tree describes badly. Linux's answer (deferred probe: fail, retry
  later, repeat until stable) is an admission that the graph isn't knowable
  upfront. You can do better with explicit capability dependencies, and that's
  worth trying.
- **Hotplug and surprise removal.** A device disappearing while a driver holds
  MMIO mappings and in-flight DMA is a correctness and security problem. Reads
  return all-ones; drivers must detect it. Capability revocation gives you a clean
  mechanism the monolithic world lacks.
- **Resource arbitration**: who owns this IRQ, this memory range, this DMA
  channel? In Nyx, these are capabilities, so the arbitration is explicit and the
  conflict is impossible rather than detected.
- **Firmware loading** for devices that need it, from userspace, with signature
  verification.

**ACPI is the swamp.** Chapter 04 recommends putting AML interpretation in a
userspace server (uACPI) — that's right, and it's also a much bigger component
than it sounds: AML is a bytecode with its own object model, and the tables in the
wild are full of bugs that Linux works around by name. Budget accordingly, and
be ready for "works in QEMU, fails on this ThinkPad."

---

## 5. Storage and filesystems, properly

Chapter 11 has a VFS design and Chapter 15 has NVMe. The gap is everything in
between:

**The block layer.** Request merging, reordering, I/O scheduling, queue depth
management, barriers/flushes. With NVMe and per-core queues, much of the classic
block layer's job (merging and reordering to help a seeking disk) is obsolete —
which is an argument for a much thinner design than Linux's, and worth writing up
if you do it.

**Crash consistency — the hard part.** A filesystem must survive power loss at
any instant. The techniques:

| Technique | Used by | Cost |
|---|---|---|
| Journaling (metadata or full) | ext4, XFS, NTFS | Double writes for journaled data |
| Copy-on-write / shadow paging | ZFS, btrfs, APFS, bcachefs | Fragmentation, write amplification |
| Log-structured | F2FS, NILFS, and every SSD's FTL internally | Garbage collection |
| Soft updates | FFS | Extremely difficult to reason about |

**The `fsync` problem** deserves special mention because it's a genuine open
issue in shipping systems: what durability does an application actually get? The
answer differs per filesystem, per mount option, per drive (does it honor FLUSH?),
and applications get it wrong constantly. Pillai et al.'s "All File Systems Are
Not Equal" (OSDI 2014) documented that essentially every application had
crash-consistency bugs. **A capability system could do better** by making
durability an explicit property of a handle rather than a mode of a syscall — that
is a real research direction.

**Caching, and the microkernel question nobody answers well.** Where does the
page cache live? Options: in the filesystem server, in the memory server, or
distributed per-file. Monolithic kernels unify the page cache and the buffer cache
because it's the only way to make `mmap` and `read` coherent. In a multi-server
system, this is a hard design problem, and it's the one that most affects
performance. Write down your answer before you build the VFS.

**Minimum viable:** a read-only ramdisk (Chapter 11), then a simple log-structured
FS on virtio-blk, then NVMe. Don't write an ext4 implementation; write something
simple and *correct*, and test it with a crash-injection harness (write N sectors,
kill power, mount, verify invariants). That harness is more valuable than the
filesystem.

---

## 6. Networking

Chapter 15 covers the I/O architecture and mentions userspace stacks. The
missing chapter would cover:

- **A TCP/IP stack is a big, subtle, security-critical program.** Port one (lwIP
  for simple cases, smoltcp for a Rust option, or the NetBSD stack via rump
  kernels) rather than writing one. Writing your own TCP is a great learning
  project and a bad system component.
- **Where does it run?** One server for everyone (simple, a shared trust and
  failure domain, a bottleneck), or a library in each process with the NIC
  multiplexing by flow (fast, isolated, needs hardware flow steering, and each
  process needs its own IP or port range). The second is where the industry is
  going (Snap, TAS, Demikernel) and is a much better fit for a capability system.
  This is a genuinely open design question.
- **The socket API is not the only option.** It conflates naming, connection,
  and byte streams; it has no good story for zero-copy receive; and `select`-style
  readiness is worse than completion. Chapter 17's argument applies directly.
- **Offloads matter enormously**: checksum, TSO/LRO, RSS for multi-queue,
  hardware timestamps, and increasingly full protocol offload. Design for them or
  give up an order of magnitude.
- **Time synchronization** (§2) and network are coupled: PTP needs hardware
  timestamps in the NIC.

---

## 7. The userland you'll need anyway

Easy to defer, then suddenly blocking:

- **Init and service management.** Dependency-ordered startup, restart policies,
  socket/endpoint activation (start a server lazily on first use — which in a
  capability system is elegant: hand out a capability to a not-yet-running
  component), health checks. Chapter 11's root task is the seed of this.
- **Dynamic linking, or not.** A real fork in the road. Static linking gives
  simplicity, hermetic binaries, and no `LD_PRELOAD` attack surface; dynamic gives
  memory sharing (significant: one libc mapped once), smaller images, and security
  updates without relinking the world. **Decide early** — it affects your ELF
  loader, your ASLR design, and your update story. Recommendation: static first
  (it's genuinely simpler and the memory cost is smaller than folklore suggests),
  with the option later.
- **Logging.** Structured, with a stable schema, from every component, with
  bounded buffers and a rate limit. In a multi-server system this is your primary
  debugging tool; treat it as a designed subsystem, not `printf`.
- **Configuration.** In a capability system, most configuration *is* capability
  distribution, done by the root task from a manifest. That's a nice property.
  Everything else (timezone, hostname) is small.
- **The shell and core utilities.** Port BusyBox or write a minimal set. Boring
  and necessary.
- **Package management and updates**: atomic, verified, and rollback-capable.
  A/B partitions or a content-addressed store (Nix-style) are the modern answers;
  both are much easier to build correctly than a package database.
- **POSIX compatibility layer.** Chapter 13 §D5 makes this a research question,
  but practically: you need enough libc for ported software. musl over libnyx is
  the tractable path. Know that `fork` will be your worst day.

---

## 8. Debugging userspace, and debugging as authority

**A debugger is a program that reads and writes another program's memory and
controls its execution.** In a capability system, that's not a special kernel
feature (`ptrace`) — it's a set of capabilities: the target's VSpace, its TCB, and
its fault endpoint.

This is one of the places where the capability model is *obviously* better and
you should show it off:

- No `ptrace` syscall, no `PTRACE_ATTACH` permission model, no Yama LSM,
  no ambient "root can debug anything."
- Debugging authority is delegatable: a parent can hand a debugger the right to
  debug one specific child, and nothing else.
- It's revocable: end the debug session by deleting the capability.
- A process can be *born* debuggable or not, by whether the spawner keeps those
  capabilities.

**What you actually have to build:** a stub speaking the GDB remote protocol (you
already have one for the kernel via QEMU — now do it for userspace), breakpoint
insertion, single-step, register access, and symbol/DWARF handling. Plus core
dumps: a fault handler that writes the address space and register state somewhere
useful.

Related and equally missing: **a crash reporting path**. When a server dies, you
want the fault message, the registers, a backtrace, the last N log lines, and the
IPC history (Chapter 18). Automate it; you'll read hundreds of these.

---

## 9. Heterogeneous cores — this is now mandatory on x86

**What changed:** every recent Intel client CPU has P-cores and E-cores; Apple
and ARM have had big.LITTLE for a decade; AMD has cores with different cache and
frequency characteristics. Your scheduler's assumption that all CPUs are
interchangeable is **wrong on the hardware you own right now**.

What this requires:

- A model of core capability: relative performance, energy per instruction,
  cache topology, and which ISA features each core supports (early Alder Lake
  E-cores lacked AVX-512, which caused real, ugly problems — a thread that
  migrated would crash).
- Placement policy: latency-sensitive work on P-cores, background on E-cores. But
  *which* work? Intel's answer is Thread Director, a hardware feedback interface
  that tells the OS what kind of work a thread is doing.
- Energy-aware scheduling: the objective function is no longer "minimize latency"
  but "minimize energy subject to a deadline" — which is a genuinely different
  problem and a good research direction (§ Appendix E).
- The interaction with Chapter 14: a WCET on a P-core is not a WCET on an E-core.
  Real-time work needs core affinity or per-core budgets.

**In a microkernel this is more tractable than in Linux**, because placement is a
policy decision that can live in a userspace scheduler server with a capability
to set affinity. Which means you can experiment cheaply. Almost nobody has done
this on a research OS.

---

## 10. Real hardware, which is not QEMU

A partial list of what changes the day you boot on metal:

- **Firmware lies.** Memory maps overlap, are unsorted, and mark things wrong.
  ACPI tables have bugs Linux works around *by machine name*. Assume nothing.
- **SMM exists**, runs at a higher privilege than your kernel, can preempt you at
  any time for hundreds of microseconds, and you cannot see or control it. It is
  a hard floor under your real-time guarantees (Chapter 14 should say so) and a
  security hole you cannot close.
- **Timers drift, and differ.** The HPET may be broken. The TSC may not be
  invariant. The LAPIC timer frequency varies with C-states on older parts.
- **Errata.** Every CPU has an errata document with dozens of entries, some of
  which require software workarounds. Read yours.
- **Microarchitectural mitigations** (Spectre, MDS, Retbleed, and successors) have
  real costs and are required for security. Know which apply, which are enabled by
  microcode, and what they cost you — and measure it.
- **PCIe enumeration is weird**: bridges, bus renumbering, devices behind
  switches, resizable BARs, and devices that need quirks.
- **Peripherals need firmware blobs**, and the licensing is a project decision.

**Recommendation:** stay on QEMU until Chapter 19's M-something milestone, then
buy one specific, well-supported, boring machine and target only it. Breadth is a
distraction; a ThinkPad or a NUC with good Linux support means the ACPI works and
someone has documented the quirks.

---

## 11. Identity, sessions, and what replaces `uid`

A capability system has no ambient identity — which is the point, and also leaves
a gap. Real systems need to answer: whose files are these, who is logged in,
what happens at logout, what is a "session", and how does a login program hand
authority to a shell?

The capability answer is clean and worth working out explicitly: **a user is not
an identity, it's a bundle of capabilities.** Logging in means a trusted login
component authenticates you and then instantiates a subtree of components holding
the capabilities associated with your data. Logging out means revoking that
subtree. There is no `setuid`, no `uid` check anywhere, and no confused deputy.

The parts that need design: authentication itself (where do password hashes live,
and who can read them?), the mapping from a person to a capability bundle
(persisted how — see §12), and multi-seat/multi-session. Also: what does a
*service account* mean when there are no accounts? (Answer: it's just a component
with capabilities, which is much simpler — but say so in the docs.)

---

## 12. Persistence of the capability graph

Related to §11 and to Chapter 13 §C4, but needed even without full orthogonal
persistence: **capabilities don't survive a reboot**, so every boot the root task
must reconstruct the entire authority distribution from a manifest.

That's fine and even desirable — it means the system's security policy is a file
you can read, diff, and verify (Chapter 13 §D6). But it needs design:

- The manifest format and its verification.
- How persistent data (files, databases) is associated with the capabilities that
  should reach it — you need a *stable* name for storage that survives reboot,
  even though capabilities don't.
- What happens to a capability a user granted at runtime ("this app may use the
  camera") — does it persist? Where? Who can edit that store? This is the
  permission-persistence problem, and getting it wrong reintroduces ambient
  authority through the back door.

---

## 13. Observability beyond testing

Chapter 18 covers testing. Production observability is different:

- **Always-on tracing** with a ring buffer you can dump after a fault (a flight
  recorder). In a multi-server system, the IPC trace *is* the execution trace, and
  it's more informative than anything a monolithic kernel can produce — you can
  reconstruct the causal chain across components. Build the visualizer.
- **Sampling profiler**: periodic NMI, walk the stack, aggregate. Needs frame
  pointers (Chapter 02 already recommends `-fno-omit-frame-pointer`) and symbol
  resolution.
- **Metrics**: counters and histograms per component, cheaply readable. Chapter
  16's object model gives you a natural way to expose them.
- **Distributed tracing across components** — attach a trace id to an IPC and
  propagate it. This is exactly what OpenTelemetry does for microservices, and a
  multi-server OS has the same shape. Nobody has built it for an OS, and it would
  be genuinely useful.

---

## 14. Project sustainability

Not technical, and it determines whether any of this survives:

- **Documentation is a deliverable.** The `docs/` directory this book keeps
  demanding is the actual product; the code is an implementation of it.
- **License choice** shapes who contributes and what can be reused (seL4 is
  GPL/BSD mixed; a permissive license eases hardware-vendor adoption).
- **Reproducible builds** — same source, same binary, verifiable by anyone. Much
  easier to establish now than to retrofit.
- **A `NEXT` file and a decision log.** Every non-obvious choice, with its date
  and reasoning. In two years you will not remember why, and neither will a
  contributor.
- **Make the first hour good.** `git clone && make run` should boot in under a
  minute on a fresh machine, or you will have no contributors.

---

## 15. A ranked list of what to fix first

If you do nothing else from this appendix:

1. **Entropy** (§3) — security-critical, cheap, and painful to retrofit.
2. **Monotonic vs realtime clocks and a vDSO-style time page** (§2) — everything
   timestamps things, and fixing the model later touches every component.
3. **The device model's dependency and binding design** (§4) — it's the shape of
   your whole driver ecosystem.
4. **Static vs dynamic linking** (§7) — affects the loader, ASLR, and updates.
5. **Where the page cache lives** (§5) — the single biggest performance decision
   in a multi-server system.
6. **Wakeup accounting and RAPL energy measurement** (§1) — cheap to add, and you
   cannot do power work later without it.
7. **A crash-report path** (§8) — you'll read hundreds; automate it now.

---

Next: [Appendix E — A research agenda](E-research-agenda.md)
