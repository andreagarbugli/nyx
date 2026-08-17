# 20 — Bibliography and primary sources

> Read the primary sources. Almost everything written *about* microkernels is a
> summary of a summary; the originals are short, clear, and frequently
> surprising. Liedtke's central paper is twelve pages and better than anything
> written since.
>
> Annotations say what each item is *for*, so you can choose. **★** marks the
> ones I'd read first.

---

## 1. If you read only five things

1. **★ Liedtke, "On µ-Kernel Construction"** (SOSP 1995). The founding argument
   for minimality, and the demonstration that Mach's poor performance was an
   implementation failure rather than an architectural one. Twelve pages.
2. **★ Elphinstone & Heiser, "From L3 to seL4: What Have We Learnt in 20 Years of
   L4 Microkernels?"** (SOSP 2013). An honest retrospective naming what worked
   and what didn't across two decades. The single best orientation to the field.
3. **★ Klein et al., "seL4: Formal Verification of an OS Kernel"** (SOSP 2009).
   What it took, what was proved, and — read carefully — what was assumed.
4. **★ Hardy, "The Confused Deputy"** (SIGOPS OSR, 1988). Two pages that explain
   why capabilities exist. Chapter 09 is an expansion of it.
5. **★ Engler, Kaashoek & O'Toole, "Exokernel: An Operating System Architecture
   for Application-Level Resource Management"** (SOSP 1995). The observation that
   abstraction and protection are separable — which is what Chapter 15's I/O
   model is quietly built on.

---

## 2. Microkernel foundations

- Brinch Hansen, "The Nucleus of a Multiprogramming System" (CACM 1970). The
  first microkernel, before the word existed.
- Accetta et al., "Mach: A New Kernel Foundation for UNIX Development" (USENIX
  1986). Read alongside the next item.
- Chen & Bershad, "The Impact of Operating System Structure on Memory System
  Performance" (SOSP 1993). *Why* Mach was slow — cache footprint, not IPC count.
  A model of careful measurement.
- Härtig et al., "The Performance of µ-Kernel-Based Systems" (SOSP 1997). L4Linux:
  a real workload on a microkernel, with real numbers.
- Liedtke, "Improving IPC by Kernel Design" (SOSP 1993). The techniques behind
  Chapter 08's fast path.
- Liedtke, "Toward Real Microkernels" (CACM 1996). The accessible version of the
  argument.
- Herder, Bos, Gras, Homburg & Tanenbaum, "MINIX 3: A Highly Reliable,
  Self-Repairing Operating System" (SIGOPS OSR 2006), and "Fault Isolation for
  Device Drivers" (DSN 2009). The reincarnation server and the dependability
  argument (Chapter 11).
- Tanenbaum & Woodhull, *Operating Systems: Design and Implementation*, 3rd ed.
  The MINIX book. Still the best code-first OS text.
- Heiser & Elphinstone, "L4 Microkernels: The Lessons from 20 Years of Research
  and Deployment" (TOCS 2016).
- Baumann et al., "The Multikernel: A New OS Architecture for Scalable Multicore
  Systems" (SOSP 2009). Barrelfish; the basis of Chapter 12's partitioned stance.

---

## 3. Capabilities and security

- Dennis & Van Horn, "Programming Semantics for Multiprogrammed Computations"
  (CACM 1966). Where capabilities come from.
- Levy, *Capability-Based Computer Systems* (1984). The historical survey;
  freely available online.
- Hardy, "KeyKOS Architecture" (SIGOPS OSR 1985). Capabilities plus orthogonal
  persistence, working, in production, in the 1980s (Chapter 13 §C4).
- Shapiro, Smith & Farber, "EROS: A Fast Capability System" (SOSP 1999).
  KeyKOS's successor; demonstrates that capabilities need not be slow.
- Shapiro & Hardy, "EROS: A Principle-Driven Operating System from the Ground
  Up" (IEEE Software 2002). The readable version.
- Miller, *Robust Composition: Towards a Unified Approach to Access Control and
  Concurrency Control* (PhD thesis, 2006). The definitive object-capability
  treatment. Long, and worth it.
- Miller, Yee & Shapiro, "Capability Myths Demolished" (2003). Short; directly
  refutes the standard objections to capabilities. Read before arguing with
  anyone about this.
- Watson et al., "Capsicum: Practical Capabilities for UNIX" (USENIX Security
  2010). Capabilities retrofitted onto a real UNIX; the compromises are
  instructive.
- Watson et al., *CHERI: An Instruction-Set Extension for Memory Safety* — the
  CHERI ISA specification and the associated papers (Chapter 13 §B2). The
  Cambridge technical reports are the authoritative source.
- Zeldovich et al., "Making Information Flow Explicit in HiStar" (OSDI 2006).
  DIFC in an OS with a capability-shaped kernel (Chapter 13 §B4).
- Elkaduwe, Derrin & Elphinstone, "Kernel Design for Isolation and Assurance of
  Physical Memory" (2008). The untyped-memory model of Chapter 09 §4.
- Saltzer & Schroeder, "The Protection of Information in Computer Systems"
  (Proc. IEEE 1975). Least privilege, complete mediation, economy of mechanism —
  still the best statement of the principles.

---

## 4. Scheduling and real-time (Chapter 14)

- Liu & Layland, "Scheduling Algorithms for Multiprogramming in a Hard-Real-Time
  Environment" (JACM 1973). RMS, EDF, and the utilization bounds. The foundation.
- Sha, Rajkumar & Lehoczky, "Priority Inheritance Protocols: An Approach to
  Real-Time Synchronization" (IEEE ToC 1990). Inheritance and priority ceiling.
- Lyons, McLeod, Almatary & Heiser, "Scheduling-Context Capabilities: A
  Principled, Light-Weight Operating-System Mechanism for Managing Time"
  (EuroSys 2018). seL4 MCS; the basis of Chapter 14's design.
- Blackham, Shi, Chattopadhyay, Roychoudhury & Heiser, "Timing Analysis of a
  Protected Operating System Kernel" (RTSS 2011). Actually computing a kernel's
  WCET — read before claiming you have a bound.
- Stoica et al., "A Proportional Share Resource Allocation Algorithm for
  Real-Time, Time-Shared Systems" (RTSS 1996). Earliest Eligible Virtual
  Deadline First — the ancestor of Linux's current scheduler.
- Baruah et al., "Proportionate Progress: A Notion of Fairness in Resource
  Allocation" (Algorithmica 1996). Pfair; useful for understanding what "fair"
  can even mean.
- Brandenburg, *Scheduling and Locking in Multiprocessor Real-Time Operating
  Systems* (PhD thesis, 2011). The definitive treatment of multiprocessor
  real-time locking. Exhaustive.
- Burns & Wellings, *Real-Time Systems and Programming Languages*. The standard
  textbook.
- Ge, Yarom, Cock & Heiser, "Time Protection: The Missing OS Abstraction"
  (EuroSys 2019). Timing channels as a resource-partitioning problem
  (Chapter 13 §B1).

---

## 5. I/O, networking, and storage (Chapter 15)

- Soares & Stumm, "FlexSC: Flexible System Call Scheduling with Exception-Less
  System Calls" (OSDI 2010). Demonstrated that the *indirect* cost of a mode
  switch exceeds the direct cost. The intellectual foundation of io_uring and of
  Chapter 15.
- Axboe, "Efficient IO with io_uring" (the design document) and the `liburing`
  sources. The best available description of a modern batched I/O interface.
- Rizzo, "netmap: A Novel Framework for Fast Packet I/O" (USENIX ATC 2012).
  Kernel-bypass networking done cleanly, with a good discussion of safety.
- The DPDK Programmer's Guide, and the SPDK documentation. Read the *design*
  chapters — poll-mode drivers, hugepages, memory registration, lockless rings —
  rather than the API reference.
- Høiland-Jørgensen et al., "The eXpress Data Path: Fast Programmable Packet
  Processing in the Operating System Kernel" (CoNEXT 2018). XDP; the
  "programmable hook in the kernel" alternative to bypass.
- Belay et al., "IX: A Protected Dataplane Operating System for High Throughput
  and Low Latency" (OSDI 2014), and Peter et al., "Arrakis: The Operating System
  is the Control Plane" (OSDI 2014). **Read both.** They independently arrive at
  Chapter 15's thesis — control plane in the kernel, data plane direct to the
  device — from a monolithic starting point.
- Marinos, Watson & Handley, "Network Stack Specialization for Performance"
  (SIGCOMM 2014). Why a general-purpose stack leaves so much on the table.
- The RDMA/InfiniBand verbs specification, and Kalia, Kaminsky & Andersen,
  "Design Guidelines for High Performance RDMA Systems" (USENIX ATC 2016).
  Memory registration and queue pairs — the model Chapter 15's `IoRegion` and
  `IoQueue` generalize.
- The NVMe Base Specification. The queue model is genuinely elegant and is worth
  reading directly; it's the reference design for hardware-consumed queues.
- The VIRTIO specification (OASIS). Your first real driver target, and a
  well-specified split-queue design.
- Intel, *Virtualization Technology for Directed I/O* (VT-d) specification, and
  the AMD I/O Virtualization Technology (IOMMU) specification. Required for
  Chapter 15 §6; there is no substitute.
- Gruss et al. and the Meltdown/Spectre papers (2018), plus Intel and AMD's
  mitigation guidance. Necessary background for any claim about syscall cost.
- Kaufmann et al., "High Performance Packet Processing with FlexNIC" (ASPLOS
  2016). Where device-offloaded dispatch is going.

---

## 6. Naming, objects, and system structure (Chapter 16)

- Pike, Presotto, Dorward, Flandrena, Thompson, Trickey & Winterbottom, "Plan 9
  from Bell Labs" (1995), and Pike et al., "The Use of Name Spaces in Plan 9"
  (SIGOPS OSR 1993). "Everything is a file" taken seriously, with per-process
  namespaces. **Essential reading for Chapter 16**, including where it strains.
- Pike, "Lexical File Names in Plan 9, or Getting Dot-Dot Right" (2000). A small
  paper that demonstrates how much complexity hides in naming.
- Ritchie & Thompson, "The UNIX Time-Sharing System" (CACM 1974). The original.
  Notice how much of the elegance is in what was left out.
- Russinovich, Solomon & Ionescu, *Windows Internals*. The NT Object Manager,
  handles, ALPC, I/O completion ports, and the security descriptor model — NT is
  a handle-based, kernel-object system and is the best-documented large-scale
  alternative to the UNIX model (Chapter 17 §3).
- Custer, *Inside Windows NT* (1993). Cutler's design intent, before two decades
  of compatibility accretion. Historically fascinating.
- The Fuchsia documentation, especially the Zircon kernel objects and handles
  reference. A modern, shipping, capability-ish microkernel with public design
  docs — the most direct point of comparison for Nyx.
- The Android Binder documentation and its object/reference model. Capability
  passing at scale, in production, on a billion devices.
- The D-Bus specification and the systemd `sd-bus` design notes — for what
  happens when a system needs typed IPC and doesn't have it in the kernel.
- The Linux `sysfs`, `procfs`, and `netlink` documentation. Read these as three
  successive admissions that a byte-stream file interface was insufficient for
  structured system state (Chapter 16 §2).
- Kubernetes' resource model and `kubectl explain`. Not an OS, but the clearest
  large-scale example of a typed, schema'd, discoverable object interface — which
  is exactly what Chapter 16 argues an OS should have.

---

## 7. System call and API design (Chapter 17)

- The POSIX / Single UNIX Specification (IEEE 1003.1). Skim the rationale
  volumes; they document the arguments, which is the interesting part.
- Baumann, Appavoo, Krieger & Roscoe, "A Fork() in the Road" (HotOS 2019). A
  devastating and correct critique. Read before deciding whether Nyx has `fork`.
- The seL4 Reference Manual. A complete, small, capability-based ABI, precisely
  specified. **The most useful single document for designing your own ABI** —
  study its structure as much as its content.
- The Fuchsia/Zircon syscall documentation. A second complete example, designed
  more recently and with different trade-offs.
- Bershad, Anderson, Lazowska & Levy, "Lightweight Remote Procedure Call" (TOCS
  1990). Where the fast-path design ideas of Chapter 08 begin.
- Chen et al., "Linux kernel vulnerabilities: state-of-the-art defenses and open
  problems" (APSys 2011), and the general CVE record for `ioctl`. Empirical
  evidence for the "narrow, typed interfaces" argument.
- Ousterhout, *A Philosophy of Software Design* (2018). Not OS-specific; the
  clearest modern writing on deep vs. shallow interfaces, which is Chapter 17's
  central criterion.
- Hoare, "Hints on Programming Language Design" (1973). Old, short, and most of
  it transfers directly to interface design.

---

## 8. Memory management, concurrency, and machine detail

- Bonwick, "The Slab Allocator: An Object-Caching Kernel Memory Allocator"
  (USENIX 1994), and Bonwick & Adams, "Magazines and Vmem" (USENIX 2001).
  Chapter 05's slab layer.
- Gorman, *Understanding the Linux Virtual Memory Manager* (2004). Dated in
  specifics, excellent on the concepts.
- McKenney, *Is Parallel Programming Hard, And, If So, What Can You Do About
  It?* (freely available, continuously updated). The best book on kernel-level
  concurrency, and the definitive treatment of RCU (Chapter 12 §7).
- Mellor-Crummey & Scott, "Algorithms for Scalable Synchronization on
  Shared-Memory Multiprocessors" (TOCS 1991). MCS locks.
- Sewell et al., "x86-TSO: A Rigorous and Usable Programmer's Model for x86
  Multiprocessors" (CACM 2010). What x86 memory ordering actually guarantees.
- Alglave, Maranget & Tautschnig, "Herding Cats" (TOPLAS 2014), and the herd7
  tool. For when you need to be *sure* about an ordering question.
- Drepper, "What Every Programmer Should Know About Memory" (2007). Long, and
  the best explanation of why cache layout dominates modern performance.
- Intel® 64 and IA-32 Architectures Software Developer's Manual, Volume 3
  (System Programming Guide). The authority. **AMD64 Architecture Programmer's
  Manual, Volume 2** is often clearer on paging and long mode — and §6.1.2 on
  `sysret` is the one you must read (Chapter 10 §2, CVE-2012-0217).
- The OSDev Wiki. Frequently the fastest way to find a hardware detail; verify
  anything load-bearing against the vendor manual.

---

## 9. Verification and testing

- Klein et al., "Comprehensive Formal Verification of an OS Microkernel" (TOCS
  2014). The full seL4 account, including the assumption list.
- Nelson et al., "Hyperkernel: Push-Button Verification of an OS Kernel" (SOSP
  2017). Verification made cheap by designing *for* it — the pragmatic middle
  path Chapter 13 §A4 recommends.
- Lamport, *Specifying Systems* (2002), for TLA+. Chapter 13 §A4 argues a week
  with this is the best formal-methods investment available.
- Clarke, Kroening & Lerda, on CBMC. Bounded model checking of real C.
- Serebryany et al., "AddressSanitizer: A Fast Address Sanity Checker" (USENIX
  ATC 2012), and the syzkaller project. Modern kernel fuzzing practice — read
  syzkaller's design notes before writing your own fuzzer.
- The QEMU documentation on record/replay and `-icount` (Chapter 18 §7.3).
  Underused and genuinely powerful.

---

## 9b. Graphics and window systems (Part VII, Chapters 21–26)

**The classic system designs.** Scheifler & Gettys, "The X Window System" (ACM
TOG, 1986) — read it for what they were solving, then read a modern critique of
the result. Gosling & Rosenthal on **NeWS** (1989), the display PostScript system
that tried Chapter 26 §5 forty years early and failed instructively. Petzold,
*Programming Windows* (5th ed.) — the best explanation of the Win32 window/message
model that exists, and the primary source for Chapter 21 §2.3 and Chapter 24; read
Chapters 1–5 even if you never write a Windows program. Pike, "Rio: Design of a
Concurrent Window System" (2000) — a usable window system in a few thousand lines.

**Modern compositing.** The Wayland protocol specification and Høgsberg's original
design rationale — short, and the "every frame is perfect" argument is stated
better there than anywhere. Fuchsia's **Scenic/Flatland** design documents, which
are the closest existing thing to a capability-native display system (Chapter 21
§3). Android's **SurfaceFlinger** and BufferQueue documentation for the
producer/consumer and fence model (Chapter 22 §3). Haiku's `app_server`
architecture notes — a clean modern take on the Win32-style model, and small enough
to read. **Arcan**'s design documents by Bjönfot, which contain more original
thinking about what a display server *is* than the rest of this list combined.

**Buffers, synchronization, and the GPU.** The Linux DRM/KMS documentation on
**atomic modesetting**, **planes**, and **format modifiers** (Chapter 22 §2.3,
§7) — the best available description of what display hardware actually offers.
The dma-buf and explicit-fence documentation, plus the discussions around the
move from implicit to explicit sync, which is Chapter 22 §3's argument made at
length by people who had to live with the alternative. The Vulkan specification's
chapters on timeline semaphores and presentation. `virtio-gpu` and `virgl`
documentation for Chapter 25 §7.1.

**Rasterization and text.** Levien's writing on font rasterization and the
signed-area/coverage approach used in `font-rs` (Chapter 25 §3.1). The
`stb_truetype` source — 2000 readable lines that demystify TrueType entirely.
FreeType's design documentation and the HarfBuzz shaping documentation; also
Esfahbod's talks on why shaping is hard, which will convince you of Chapter 25
§4.1's recommendation faster than the chapter does. Porter & Duff, "Compositing
Digital Images" (SIGGRAPH 1984) — four pages, still the foundation, and the source
of premultiplied alpha. Blinn's *Dirty Pixels* essays on why blending in sRGB is
wrong.

**Latency and interaction.** Card, Robertson & Mackinlay on interaction time
constants; Ng et al., "Designing for Low-Latency Direct-Touch Input" (UIST 2012),
which measured what latency people can actually perceive (much lower than assumed).
Microsoft's and Google's published work on input prediction. Anything on
`Choreographer`/`CVDisplayLink`/`requestAnimationFrame` frame pacing (Chapter 22
§6, Chapter 24 §4).

**UI security.** Roesner et al., "User-Driven Access Control" (Oakland 2012) — the
paper behind Chapter 23 §6.3's trusted-UI argument. Huang et al., "Clickjacking:
Attacks and Defenses" (USENIX Security 2012). The "shatter attack" writeups on
Win32 message-based privilege escalation (Chapter 21 §2.3). Yee's work on
user-interaction design for capability systems, which is the most direct
intellectual ancestor of Chapter 24 §7's clipboard design. Android's
`FLAG_WINDOW_IS_OBSCURED` and overlay-restriction history, as a case study in
retrofitting this.

---

## 9c. Composability, distribution, and deployment (Part VIII, Chapters 27–31)

**Scaling down.** The **Hubris** reference manual and Oxide's writing about it —
the closest existing thing to a statically-composed capability microkernel, and
the best reading for Chapter 27. **Tock**'s papers on capsules and grants
(Levy et al., SOSP 2017 and the TockOS design docs) for MPU-based isolation and
Rust-enforced separation in kilobytes. Zephyr's Kconfig/devicetree architecture,
read as a cautionary tale about configuration-space explosion as much as a model.

**Multikernel and distributed OS.** Baumann et al., "The Multikernel: A New OS
Architecture for Scalable Multicore Systems" (SOSP 2009) — the foundational
Barrelfish paper, and the source of both the "coherence is a message protocol"
argument and the System Knowledge Base. Schüpbach et al. on the SKB and
constraint-based system configuration, which is the under-cited part. Shan et al.,
"LegoOS: A Disseminated, Distributed OS for Hardware Resource Disaggregation"
(OSDI 2018). Waldo, Wyant, Wollrath & Kendall, "A Note on Distributed Computing"
(1994) — eight pages, and the reason single-system-image failed; read it before
designing any remote interface. Pike et al. on Plan 9's distributed namespaces,
for the one form of transparency that did work.

**Distributed capabilities.** Miller's thesis on object capabilities and the
E language's CapTP protocol; Cap'n Proto's RPC design notes, which are the most
practical modern treatment (promise pipelining, three-party introduction,
distributed refcounting). Birgisson et al., "Macaroons: Cookies with Contextual
Caveats" (NDSS 2014) — offline attenuation, and a much better fit for OS
capabilities than its web framing suggests. Hardy's KeyKOS papers for the
original persistent-capability system.

**Virtualization.** Steinberg & Kauer, "NOVA: A Microhypervisor-Based Secure
Virtualization Architecture" (EuroSys 2010) — the primary source for Chapter 29's
thesis. Popek & Goldberg (1974) for the formal requirements. The Firecracker paper
(NSDI 2020) on microVMs and cold-start engineering. Madhavapeddy et al.,
"Unikernels: Library Operating Systems for the Cloud" (ASPLOS 2013), and the
Unikraft papers for the modern version. AMD's SEV-SNP and Intel's TDX
specifications for confidential computing.

**Deployment and packaging.** Dolstra's thesis on **Nix** and the purely
functional deployment model — the clearest statement of why content-addressed
dependency closures solve what containers isolate. The Bazel remote-execution and
hermeticity documentation. **TUF** (The Update Framework) specification for
update security done properly. The **WASI** capability model, which is the closest
shipping thing to Chapter 30's argument. Burns et al. on Borg and the Kubernetes
design papers, read for what the control plane genuinely contributed, separately
from what the container did.

---

## 9d. Tracing, profiling, and partitioning (Part IX, Chapters 32–34)

**Tracing.** The **LTTng** papers and the **CTF** (Common Trace Format)
specification — the reference design for low-overhead, self-describing binary
tracing, and the source of Chapter 32's metadata-out-of-band approach. Linux's
ftrace ring-buffer design notes for the reserve/commit pattern. **Perfetto**'s
documentation, especially the trace-processor SQL layer, which is the best
available tooling for large traces. Sigelman et al., "Dapper, a Large-Scale
Distributed Systems Tracing Infrastructure" (Google, 2010) — the origin of
propagated trace ids and of making the sampling decision once at the request
origin, and the direct ancestor of Chapter 32 §5. OpenTelemetry's span model for
the vocabulary.

**Profiling.** Gregg, *Systems Performance* and *BPF Performance Tools* — the
practical reference for flame graphs, off-CPU analysis, and the discipline of
asking the right question first. Yasin, "A Top-Down Method for Performance
Analysis and Counters Architecture" (ISPASS 2014) for the PMU methodology in
Chapter 33 §3. Intel's SDM Volume 3 chapters on PEBS, LBR, and Processor Trace;
AMD's IBS documentation. Mytkowicz et al., "Producing Wrong Data Without Doing
Anything Obviously Wrong!" (ASPLOS 2009) — read this before publishing any
benchmark number. Curtsinger & Berger, "Coz: Finding Code that Counts with Causal
Profiling" (SOSP 2015), which is the right way to think about what optimization
would actually help.

**Partitioning and real-time.** **ARINC 653** for the partition model and APEX
API. **DO-178C** and DO-297 for integrated modular avionics; **ISO 26262** for
"freedom from interference", worth reading purely for how exactly it describes
what a capability system provides structurally. Rushby, "Design and Verification
of Secure Systems" (SOSP 1981) — the separation-kernel concept all of this
descends from. Shin & Lee, "Periodic Resource Model for Compositional Real-Time
Guarantees" (RTSS 2003) for the two-level analysis in Chapter 34 §5. Burns &
Davis, "Mixed Criticality Systems — A Review" for the state of that field.
Intel's Resource Director Technology (CAT/MBA/CMT) documentation and ARM's
**MPAM** specification for the hardware mechanisms. Lyons et al.,
"Scheduling-Context Capabilities" (EuroSys 2018) again, since it is the bridge
between Chapter 14 and this one.

**Real-time APIs (Chapter 35).** The **Ravenscar profile** for Ada and Burns &
Wellings, *Concurrency in Ada* / *Real-Time Systems and Programming Languages* —
the best existing example of a language and runtime restricted specifically to be
analyzable, and the direct ancestor of Chapter 35's philosophy. **ARINC 653**'s
APEX API, where period, capacity, and deadline are declared at process creation
and a deadline miss goes to the health monitor. Henzinger, Horowitz & Kirsch,
"Giotto: A Time-Triggered Language for Embedded Programming" (2003) for **Logical
Execution Time**, plus the more recent automotive LET literature. **RTIC** (Rust)
for compile-time ceiling-protocol enforcement with no locks — the closest thing to
Chapter 35 §4.1's checkable RT-safety. Kopetz on time-triggered architecture for
the determinism argument. Berry on Esterel and the synchronous-language family
(Lustre/SCADE) for the zero-time abstraction that certified avionics actually
uses. The RTSJ (Real-Time Specification for Java) as an instructive
over-complicated near-miss: scoped memory and cost enforcement were right, the
ergonomics were not. Feiertag et al. on **cause-effect chains** and the
inequivalent definitions of end-to-end latency (Chapter 35 §6). Davis & Burns,
"A Survey of Hard Real-Time Scheduling for Multiprocessor Systems", for what is
and isn't analyzable once you have more than one core.

## 9e. Networking (Part X, Chapters 36–38)

**Rethinking the API.** The IETF **TAPS** documents (RFC 9621/9622/9623) —
transport services declared as properties rather than protocols, and the direct
ancestor of Chapter 36 §2's D4. Ousterhout, "It's Time to Replace TCP in the
Datacenter" and the **Homa** papers (Montazeri et al., SIGCOMM 2018) for the
message-vs-stream argument. **Demikernel** (Zhang et al., SOSP 2021) for a
portable kernel-bypass API with zero-copy scatter-gather buffers. **Snap**
(Marty et al., SOSP 2019) and **TAS** (Kaufmann et al., EuroSys 2019) for the
control-plane/data-plane split in Chapter 36 §6. RDMA verbs and the queue-pair
model, worth studying even if you never use InfiniBand. **QUIC** (RFC 9000) for
connection IDs, stream multiplexing, and identity/address separation; **HIP**
(RFC 7401) for the fully separated version. Shenango and Caladan for µs-scale core
allocation. `AF_XDP` and netmap for the buffer-pool model, and DPDK's mbuf design
for headroom and chaining.

**Deterministic networking.** The IEEE 802.1 TSN standards themselves — start with
**802.1AS** (gPTP), **802.1Qbv** (time-aware shaper), **802.1Qbu**/802.3br (frame
preemption), **802.1Qci** (policing), **802.1CB** (replication/elimination), and
**802.1Qcc** (configuration and the CNC concept behind Chapter 37 §4). Kopetz,
*Real-Time Systems: Design Principles for Distributed Embedded Applications* for
the time-triggered architecture the whole field descends from. The IETF **DetNet**
working group for the routed-network extension. Linux's `taprio` and `etf` qdisc
documentation as a practical reference for what the hardware exposes, and the
Intel i210/i225 datasheets for how LaunchTime and the gate lists are actually
programmed.

**Drivers.** The **Intel 82540EM (e1000) Software Developer's Manual** — the
classic first NIC driver, and the QEMU model follows it closely. The **i210** and
**i225/i226** datasheets for multi-queue, RSS, MSI-X, PTP, and TSN. Rizzo's netmap
paper for why per-packet costs dominate and how batching fixes it. The `ixy`
project (Emmerich et al.) — a userspace driver in ~1000 lines, written to be read,
and the single best starting point for Chapter 38.

## 9f. Modularity and interface design (Chapter 39)

Parnas, "On the Criteria To Be Used in Decomposing Systems into Modules" (CACM
1972) — fifty years old, four pages, and still the best statement of why you
decompose around what is likely to *change* rather than around processing steps.
Parnas & Clements, "A Rational Design Process: How and Why to Fake It" for the
honest account of how design documents actually get written. Lampson, "Hints for
Computer System Design" (SOSP 1983) for the accumulated judgement on interfaces,
and specifically on when *not* to abstract. Ousterhout, *A Philosophy of Software
Design* on deep modules — narrow interface, substantial implementation — which is
the property Chapter 39 §4 is chasing. Baldwin & Clark, *Design Rules: The Power
of Modularity* for the economic framing: a modular boundary is an option to
substitute, and options have value that can be estimated. On narrow waists,
Beck's "Hourglass" framing and the retrospectives on IP's success are the useful
reading. For conformance suites as a practice, look at the Khronos CTS, the W3C
test suites, and the POSIX conformance suites — particularly at how each handles
underspecification, since that is where all the interesting cases live.

---

## 10. Modern systems worth reading the source of

| System | Why | Size |
|---|---|---|
| **seL4** | The reference capability microkernel; exceptionally clean C | ~10 kLOC |
| **Zircon** (Fuchsia) | Modern, shipping, C++, handle-based | large |
| **Hubris** (Oxide) | Rust, embedded, small, opinionated, beautifully documented | small |
| **Redox** | Full Rust microkernel OS with userland | large |
| **Theseus** | Intralingual design — the "do we need address spaces?" experiment | medium |
| **Barrelfish** | The multikernel, with the papers to match | large |
| **MINIX 3** | The dependability design; readable C | medium |
| **xv6** | Not a microkernel, but the clearest teaching kernel ever written | ~6 kLOC |
| **Xous** | Rust microkernel for secure hardware; interesting IPC design | small |
| **NOVA** | Microhypervisor; ~9 kLOC of C++ (Chapter 13 §C1) | small |

`xv6` deserves special mention: if any concept in Chapters 04–07 isn't landing,
read xv6's version of it. It is small enough to hold entirely in your head, and
its accompanying book is excellent.

---

## 11. How to read a systems paper

Since this chapter asks you to read a lot of them:

1. **Abstract, then introduction, then conclusion.** Decide in five minutes
   whether to continue.
2. **Find the claim.** Every good paper has one sentence claiming something is
   better than something else along some axis. Write it down. If you can't find
   it, the paper may not have one.
3. **Find the evaluation, and ask what it doesn't measure.** This is where the
   real information is. Microbenchmarks that avoid the expensive case are the
   most common form of systems dishonesty, and it is usually visible.
4. **Read the related-work section as a reading list**, not as prose.
5. **Ask what it would take to reproduce.** For most of the papers above, the
   answer is now "a weekend with Nyx" — which is the entire point of having built
   a workbench.

---

*End of the guide.*

You have a design, an implementation path, a measurement harness, a research
agenda, and a reading list. The remaining ingredient is the one nobody can supply
for you: several hundred hours, spent mostly on things that don't work yet.

Start with [M0](19-roadmap-and-gaps.md). Write the `NEXT` file. Boot something.

Appendices: [A — C ergonomics](A-c-ergonomics.md) ·
[B — Memory patterns](B-memory-patterns.md) ·
[C — Data structures](C-data-structures.md) ·
[D — Missing layers](D-missing-layers.md) ·
[E — Research agenda](E-research-agenda.md)

← [Back to the index](README.md)
