# ADR-0006 — Verticals are manifests, not kernels

- date: 2026-08-13
- status: accepted (2026-08-13)
- guide: 21 §1, 27, 39 §2; ADR-0002; `docs/verticals.md`

## Context

ADR-0002 chose track A and said B and D “remain possible on this
kernel.” It did not say what “on this kernel” forbids. The obvious
ways to start graphics later — a `vertical/graphics` branch, a
`Nyx-Desktop` fork, `CONFIG_GFX`, a kernel soname — all split the
waist (object types, IPC, capabilities). After that split, a
finding on A does not apply to B, which is the failure mode the
workbench exists to avoid.

Guide 21 already requires the graphical stack to be optional.
Guide 27’s thesis is one object model, composition rather than
#ifdef. Guide 39 names the waist as the thing that must not be
swappable. This ADR is those three chapters applied to repo layout.

## Decision

There is one kernel, one ABI, one object model, on `master`. A
vertical is a **manifest plus an initrd**. `make` produces one
`nyx.elf`. `make test` stays headless. Graphics, when it happens,
is `user/srv/gfx/*` under a workstation manifest.

Kernel objects a later vertical needs are added on `master` when
*any* scheduled work needs them, because they are almost never
vertical-specific (`IRQHandler`, Frames, IOMMU serve A and B
alike).

Long-lived kernel branches, kernel forks, and waist `#ifdef`s are
not how a vertical is started. Spike branches remain the way to
answer a question; they never merge. A userspace-only branch of
`user/srv/gfx` is allowed after the ABI is boring.

## Alternatives rejected

- **Long-lived `vertical/graphics` kernel branch.** The waist
  diverges. Merge is a rewrite. A’s `SchedContext` and B’s Frame
  stop being the same type.
- **Fork / “Nyx-Desktop.”** Two systems that share a name (guide
  27’s anti-pattern). Justified only if B requires breaking an
  invariant; then it is a different thesis and should have a
  different name, not a hyphen.
- **Kernel major version as the lever.** B does not need a new
  `SYS_*`. It needs Frames and a compositor process.
- **`#ifdef CONFIG_GFX` in the waist.** Profiles are composition.
  Ifdefs in `ipc.c` are how the waist stops being one.
- **Wait and see.** Rejected because “how do we do graphics” is
  being asked now, and an unwritten answer will be a branch.

## Consequences

Makes easy:

- A finding on A (a number, a bounded path, an IOMMU default-deny)
  applies to B without a port.
- Two people can work in parallel without forking: one on `master`
  (A), one in userspace against the published ABI.
- CI stays one image.

Makes hard:

- B cannot land a kernel shortcut that A would refuse (in-kernel
  compositor, user pointers for command buffers). That is the
  intended hardness.
- A userspace graphics branch is broken by kernel changes the same
  way an out-of-tree server is. That breakage is information.

Forecloses: a world in which “the graphics kernel” and “the
real-time kernel” are different binaries with different object
semantics. That foreclosure is the point.

## Revisit when

A vertical cannot be expressed without breaking an invariant in
`docs/invariants.md` (kernel dereferences a user pointer, IPC
allocates, a string crosses the syscall, a frame given to
userspace is not zeroed). Then the vertical’s *design* is wrong,
and the next step is a spike showing the feature as a ring plus a
capability — not a fork. If the spike fails, the vertical is a
different project.
