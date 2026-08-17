# Building **Nyx**: a modern microkernel from scratch

*A long-form, theory-first guide to writing a MINIX-inspired, capability-secured
microkernel in x86-64 assembly and C — and turning it into a research workbench.*

---

## What this is

This is not a "copy these 200 lines and you have a bootloader" tutorial. It is a
book-length engineering guide with three interleaved layers:

1. **Theory** — why operating systems are structured the way they are, what the
   microkernel research program actually discovered (including where it failed),
   and what the modern state of the art looks like.
2. **Mechanism** — the concrete x86-64 hardware facts you must know: paging,
   privilege rings, interrupt delivery, `syscall`/`sysret`, MSRs, memory
   ordering, IOMMU.
3. **Construction** — real, buildable code: linker scripts, boot stubs, IDT
   setup, page-frame allocator, context switch, IPC fast path, ELF loader,
   userspace servers.

Every chapter follows the same shape: **Theory → Design → Implementation →
Verification (how you test it) → Exercises / research hooks.**

## Who it's for

Someone who knows C well, is comfortable with pointers and bit manipulation, can
read x86 assembly (you'll learn the rest here), and wants both to *understand*
OS design and to *own* a codebase they can use to try new ideas.

You do **not** need prior OS development experience. You do need patience with
debugging things that produce no output.

## The target system

| Decision | Choice | Why |
|---|---|---|
| Architecture | **x86-64** (long mode), with a hand-written 32→64 bit transition | Best documented, best tooling, runs under QEMU with KVM. The 32-bit stub teaches you protected mode and paging enablement without trapping you in segmentation forever. |
| Boot protocol | **Multiboot2** (hand-rolled), Limine as the "fast path" alternative | Multiboot2 teaches the transition. Limine gets you to a higher-half 64-bit C function in ten minutes when you want to iterate on design instead of bootstrap. |
| Language | **C17 freestanding + NASM**, with an optional Rust userspace | C keeps the kernel small and auditable; Rust is where the interesting modern work is, and our ABI is language-agnostic. |
| Kernel model | **Microkernel**: threads, address spaces, IPC, capabilities, interrupt routing. Everything else is a user process. | This is the point of the project. |
| Security model | **Capabilities** (seL4-flavoured), not ambient authority | Modern, composable, and a genuinely better foundation for research than UNIX permissions. |
| IPC | Synchronous rendezvous fast path (L4/MINIX lineage) + asynchronous notifications + shared-memory rings for bulk | Covers both the classic design and the io_uring-era design so you can *measure* the difference. |
| Emulator | **QEMU** with `-s -S` + GDB, plus KVM for speed | Free, scriptable, deterministic enough, has a built-in GDB stub and tracing. |

The kernel is called **Nyx**. Rename it; it's yours.

## How to read this

Read Part I before writing code. It is the difference between building an OS and
retyping one.

Then go chapter by chapter — each one leaves you with a system that boots and
does something observable. Do not skip the "Verification" sections: in kernel
work, the ability to *see* what happened is the whole game.

### Part I — Foundations

- [00 — Operating system structure and the microkernel argument](00-theory-microkernels.md)
- [00.5 — Decisions to make before the first line](00.5-decisions-before-the-first-line.md)
  · *written after building it once; seven rules that are cheap on day one
  and expensive to retrofit*
- [01 — The x86-64 machine: what the hardware actually gives you](01-x86-architecture.md)
- [02 — Toolchain, build system, and the freestanding environment](02-toolchain-and-build.md)

### Part II — Bringing up the machine

- [03 — Boot: from firmware to a 64-bit higher-half C function](03-boot-and-long-mode.md)
- [04 — Interrupts, exceptions, and time](04-interrupts-and-exceptions.md)
- [05 — Physical memory: frames, zones, and allocators](05-physical-memory.md)
- [06 — Virtual memory: address spaces, mapping, and hardening](06-virtual-memory.md)

### Part III — The kernel proper

- [07 — Threads, context switching, and scheduling](07-tasks-and-scheduling.md)
- [08 — IPC: the heart of a microkernel](08-ipc.md)
- [09 — Capabilities: the security architecture](09-capabilities-and-security.md)
- [10 — Crossing the ring: syscalls, userspace, and the ELF loader](10-userspace-and-syscalls.md)

### Part IV — The system around the kernel

- [11 — Servers and userspace drivers](11-servers-and-drivers.md)
- [12 — SMP, concurrency, and memory ordering](12-smp-and-concurrency.md)

### Part V — Taking a position

These four chapters revisit the design with a specific agenda. This is where Nyx
stops being "a nice microkernel" and starts being an argument about how an OS
should be built.

- [13 — Modern and experimental directions](13-modern-and-research.md)
- [14 — Real-time: predictability as a first-class property](14-realtime.md)
- [15 — I/O architecture: zero-copy, asynchronous, direct to the device](15-io-architecture.md)
- [16 — Naming, objects, and system state: beyond "everything is a file"](16-naming-and-objects.md)
- [17 — System call and API design](17-syscall-design.md)

### Part VI — Making it a workbench

- [18 — Testing, debugging, tracing, benchmarking](18-testing-and-workbench.md)
- [19 — Roadmap, milestones, and the things people forget](19-roadmap-and-gaps.md)

### Part VII — The graphical system (extension)

This part is an extension, not a prerequisite: the system boots, runs, and is
fully usable with none of it started. The position taken here is that **Win32's
object-and-message model was right and its security model was wrong**, and that
those are separable.

- [21 — Display architecture: what a graphical system actually is](21-display-architecture.md)
- [22 — The compositor: buffers, frames, and presentation](22-compositor.md)
- [23 — Input: events, focus, and why input is a security boundary](23-input.md)
- [24 — The window system API](24-window-api.md)
- [25 — Rendering, text, and the GPU](25-rendering-and-gpu.md)
- [26 — Research directions in system graphics](26-graphics-research.md)

### Part VIII — From core to composable OS (extension)

The same object model from a 32 KB microcontroller to a datacenter cluster, with
clustering and virtualization as first-class concepts rather than layers — and an
argument that containers are three workarounds and two good ideas.

- [27 — Composability: one design from microcontroller to server](27-composability.md)
- [28 — Scaling up: the machine, the rack, the cluster](28-distributed.md)
- [29 — Virtualization as a first-class concept](29-virtualization.md)
- [30 — Deployment: what containers are actually for](30-deployment.md)
- [31 — Research directions: composability and scale](31-scale-research.md)

### Part IX — Observability and partitioning (extension)

Instrumentation, profiling, and resource isolation as designed subsystems rather
than afterthoughts. Chapters 32–33 are a pair: one records what happened, the
other where the cycles went, and they share a format and a toolchain.

- [32 — Tracing and instrumentation](32-tracing.md)
- [33 — Profiling and performance analysis](33-profiling.md)
- [34 — Partitioning: resource isolation for real-time and mixed criticality](34-partitioning.md)
- [35 — APIs for real-time programming](35-realtime-api.md)

### Part X — Networking (extension)

Sockets are a 1983 interface that conflates naming with addressing, mandates a
copy, reports readiness instead of completion, and cannot express a timing
requirement. Rather than bypass them, don't build them.

- [36 — Networking: beyond sockets](36-networking.md)
- [37 — Deterministic and real-time networking (TSN)](37-tsn.md)
- [38 — NIC drivers: from e1000 to multi-queue](38-nic-drivers.md)

### Part XI — Composability as a discipline (extension)

Making "you can swap any layer" true rather than aspirational: what belongs in the
narrow waist, which concerns can't be layers at all, and the practices —
conformance suites, reference and hostile implementations, performance contracts —
that separate a substitutable interface from a hopeful one.

- [39 — Composability as a discipline](39-composability-discipline.md)

### Appendices

- [A — C ergonomics: strings, slices, results, and internal style](A-c-ergonomics.md)
- [B — Memory ownership and allocation patterns](B-memory-patterns.md)
- [C — Kernel data structures](C-data-structures.md)
- [D — The layers nobody writes chapters about](D-missing-layers.md) — power, time, entropy, the device model, storage, networking, userland, debugging, heterogeneous cores, real hardware
- [E — A research agenda: open problems in OS design](E-research-agenda.md)
- [Bibliography and primary sources](20-bibliography.md)

## Repository layout used throughout

```
nyx/
├── arch/
│   └── x86_64/
│       ├── boot.asm            # multiboot2 header, 32-bit stub, long mode entry
│       ├── entry.asm           # ISR stubs, syscall entry, context switch
│       ├── cpu.c               # GDT/TSS/IDT, CPUID, MSRs
│       ├── paging.c            # page table manipulation
│       ├── apic.c              # LAPIC / IOAPIC / timers
│       └── link.ld             # linker script
├── kernel/
│   ├── main.c                  # kmain: arch-independent init
│   ├── mm/     pmm.c vmm.c slab.c
│   ├── obj/    cap.c cnode.c untyped.c   # capability system
│   ├── sched/  thread.c sched.c
│   ├── ipc/    ipc.c notify.c ring.c
│   ├── irq/    irq.c
│   └── klib/   printf.c string.c list.c assert.c
├── include/
│   ├── nyx/                    # kernel-internal headers
│   └── abi/                    # the *stable* kernel↔user ABI (shared)
├── user/
│   ├── libnyx/                 # syscall stubs, IPC helpers, minimal libc
│   ├── idl/                    # interface definitions + stub generator
│   └── srv/
│       ├── init/               # root task: bootstraps everything
│       ├── pm/                 # process manager
│       ├── vfs/                # virtual file system
│       ├── rd/                 # ramdisk driver
│       ├── con/                # console driver
│       ├── rs/                 # reincarnation server (fault recovery)
│       └── gfx/                # OPTIONAL (Part VII) — never started headless
│           ├── display/        #   display driver: modeset, scanout, planes
│           ├── input/          #   input server: devices, keymap, events
│           ├── comp/           #   compositor: scene graph, damage, present
│           └── shell/          #   policy: focus, placement, workspaces
├── tools/                      # build helpers, image builder, test runner
├── tests/                      # unit tests + in-kernel self tests + host tests
└── docs/                       # design docs, ABI spec, invariants
```

## Ground rules that will save you weeks

1. **Version control from commit zero.** Kernel bugs are time-travel bugs. `git
   bisect` is a debugger.
2. **Serial console before anything else.** VGA text mode is a dead end; serial
   is loggable, greppable, and works on real hardware and CI.
3. **Write the ABI spec before the code.** `docs/abi.md` is the contract. If it
   isn't written down, it isn't a design, it's an accident.
4. **Assume SMP from day one in your *locking discipline*,** even while running
   uniprocessor. Retrofitting concurrency is a rewrite.
5. **Every chapter ends with a test.** By chapter 18 you'll have a harness that
   boots QEMU headless, runs assertions, and exits with a status code. Build
   toward it.
6. **`-Werror` from the start.** Yes, really.
7. **When something doesn't work, look at the state, not at the code.** QEMU's
   `info registers`, `info mem`, `info tlb`, and GDB are your instruments.

---

Start with [00 — Operating system structure and the microkernel
argument](00-theory-microkernels.md), then read [00.5 — Decisions to make
before the first line](00.5-decisions-before-the-first-line.md) before you
write any. Chapter 00.5 exists because this book is ordered for learning and
a handful of decisions are ordered for building; it says which, and why each
one is expensive to change later.
