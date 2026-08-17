# Verticals

How B, C, and D happen later without destroying the workbench.
ADR-0002 chose A and left “on this kernel” as a sentence. This file
is the how. The decision with alternatives is
[`decisions/0006-verticals-are-manifests.md`](decisions/0006-verticals-are-manifests.md)
(proposed).

**Rule: one kernel, one ABI, one object model. A vertical is a
manifest plus an initrd.**

---

## Why not a fork, a branch, or a version

The waist (guide 39) is object types, IPC, capabilities, the
manifest format, the trace model, the IDL. Fork that and a finding
on A does not apply to B. Merge day is a rewrite.

| Approach | Use? |
|---|---|
| Long-lived `vertical/graphics` kernel branch | **No.** Waist diverges. |
| `Nyx-Desktop` / a second repo | **No**, unless B requires breaking an invariant — in which case B is a different thesis and should have a different name. |
| Kernel soname (`nyx 1` / `nyx 2`) | **No** for a vertical. B does not need a new `SYS_*`. |
| `#ifdef CONFIG_GFX` in `ipc.c` | **No.** Profiles are composition, not ifdefs in the waist. |
| Spike branch (`spike/NNNN-…`, never merges) | **Yes**, for one compositor or TSN question. |
| Userspace-only branch of `user/srv/gfx` | **Yes**, after the ABI and the needed objects exist on `master`. |
| Manifest profile, same `nyx.elf` | **Yes. This is the mechanism.** |

A “different version of the kernel” is the most tempting wrong
answer. It sounds like discipline. It is how you get two systems
that share a brand (guide 27’s anti-pattern). Graphics is a
large-end composition of the same object model.

---

## Profiles

```
make                 → one nyx.elf
make test            → headless initrd, always
manifests/headless   → CI, core servers
manifests/rt         → track A
manifests/workstation → headless + B-thin servers
```

`user/srv/gfx/` stays empty until B-thin is scheduled. The
directories under `user/srv/` are a map, not a start.

---

## B — Graphics

Guide 21: the stack is optional; only display arbitration touches
hardware; input, window policy, and the app API are userspace.
Win32 put those last two in `win32k.sys`. We do not.

Almost every kernel object B wants is an object A wants:

| B needs | Also needed by |
|---|---|
| `IRQHandler` + Notification | A’s NIC, M3.2’s first driver |
| Frame mapping from userspace | everyone |
| IOMMU | any userspace DMA, including A |
| Endpoints, badges | already there |

Build those on `master` for A or M3.2. Do not build them on a
graphics branch.

### Two slices, never one milestone

**B-thin (the finding).** Virtio-gpu or a linear framebuffer, virtio-input
or PS/2, a compositor that is a capability boundary, a hostile
client. The result is Appendix E4: a manifest in, a machine-checked
list of what can observe keystrokes out. No GPU driver, no toolkit,
no workspaces.

**B-full (the product).** Modeset, planes, GPU submission, damage, a
shell, a toolkit (guides 22–25). Only if B-thin produced a document
someone else can use.

Starting B-full because chapter 25 exists is how the workbench dies.

### When to start B-thin

All three, not “two of three”:

1. Track A has *a* number — not the final 1 ms loop, but M3.3’s
   variance test plus at least one A-blocker beyond the priority
   check. Otherwise B becomes what you do instead of measuring.
2. `IRQHandler`, user-mappable Frames, and a written IOMMU answer
   (or a written reason it can wait) are on `master`.
3. The ABI is boring: `SYS_INVOKE` works, `libnyx` and the IDL
   exist, a second server has been written without inventing a
   marshalling convention.

### Parallel work

Two people do not branch the kernel. One continues A on `master`.
The other implements B-thin against the published ABI in
`user/srv/gfx` and is broken by kernel changes the same way any
out-of-tree server would be. That breakage is information.

---

## C — Virtualization

A kernel *object* (`VCPU`, perhaps a VM address space), not a
kernel fork, and not a P5 vertical. ADR-0002 kept it as an
**instrument** for E1: same hardware, Linux in a VM versus a native
Nyx workload. Add the object on `master` when A needs the
comparison. A “Nyx hypervisor edition” is C becoming the goal,
which is the alternative ADR-0002 rejected.

---

## D — Distributed

The claim is that a capability and a message do not change meaning
when the other end is a different box. That claim is false the
moment on-the-wire IPC is a different code path with a different
object model.

Construction: a userspace transport (or a thin kernel datagram
object if measurement demands it) that moves bytes; endpoints and
CSpaces stay local; a proxy exports a *local* endpoint that
forwards. If D needs a “distributed kernel,” D’s thesis is already
dead.

D depends on the failure model (Appendix E3) more than B does.
M3.0.5 is the local half of “the other end went away.” Do not start
D until `E_PEERGONE` is also the answer when the other end is a
machine that rebooted, and that answer is written down.

---

## When a second kernel would be justified

Only if a vertical cannot be expressed without breaking an
invariant in [`invariants.md`](invariants.md):

- the kernel would have to dereference a user pointer (GPU command
  buffers parsed in ring 0)
- IPC would have to allocate (in-kernel surface queue)
- a string would have to cross the syscall boundary (window titles
  as `char *`)
- frames given to userspace would not be zeroed

If B seems to need any of those, the graphical design is wrong, not
the repo layout. The spike is “can this be a ring plus a Frame
capability instead.” Guide 21 already predicts that answer.

---

## Sentence for the B milestone, when it exists

> Same `nyx.elf` as track A. New manifest. No new syscall.
> Finding is E4, not a screenshot. GPU is out of scope until
> E4 is a document.

If a future milestone cannot accept that paragraph, it is not a
vertical on this workbench. It is a different project, and it
should have a different name.
