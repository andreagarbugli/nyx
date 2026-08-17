# 22 — The compositor: buffers, frames, and presentation

> Goal: build the component that owns the screen. Buffer allocation and sharing
> as capabilities, the retained scene graph, damage tracking, explicit
> synchronization, frame pacing, and the presentation path — plus a virtual
> backend so all of it is testable before you own a single line of GPU code.

---

## 1. Theory: what compositing actually is

A compositor answers one question, sixty times a second: **given a set of
client-produced buffers and a scene description, what should the display
controller scan out at the next vblank?**

There are exactly three ways to answer it:

| Strategy | Mechanism | Cost |
|---|---|---|
| **Direct scanout** | Point the display controller at the client's buffer | Zero. No copy, no GPU. |
| **Plane composition** | Give each buffer a hardware overlay plane; the display controller blends during scanout | Zero GPU, zero memory bandwidth beyond scanout |
| **Render composition** | Draw all buffers into a new buffer, scan that out | A full-screen read + write per frame |

Most compositors do the third for everything. The first two are *free* and the
hardware has supported them for fifteen years. A serious design tries hard to use
them:

- Fullscreen video or a fullscreen game → direct scanout. No composition at all.
- Cursor → its own plane, always. This is why the cursor moves smoothly even when
  the machine is loaded, when it's done right.
- A few non-overlapping windows → planes, if the hardware has enough.
- Everything else → render composition, **but only the damaged region**.

Write this as a rule for the design doc: *composition is the fallback, not the
default*. Chapter 26 develops what it would take to make it the fallback more
often than anyone currently manages.

### 1.1 Why "every frame is perfect" matters

The invariant, from Wayland and worth stealing verbatim:

> The display never shows a partially-updated frame. A client's buffer is either
> fully presented or not presented at all.

This gets you no tearing, no flickering during resize, and — more importantly —
a *definition of correctness* you can test. A frame is a value. Given a scene
description, the output is a pure function of it. That is what makes the
reference-image testing in §8 possible, and it's a property most graphical
systems cannot state.

---

## 2. Buffers: allocation, sharing, and ownership

### 2.1 The buffer is a capability

A buffer is one or more Frame capabilities (Chapter 09) plus metadata:

```c
/* include/abi/gfx.h — the stable ABI */
struct buffer_desc {
    uint32_t size;              /* versioned struct, Appendix A §5 */
    uint32_t width, height;
    uint32_t format;            /* FOURCC-style: 'XR24', 'AR24', 'NV12' ... */
    uint32_t modifier_hi, modifier_lo;  /* tiling/compression, see §2.3 */
    uint32_t n_planes;
    struct { uint32_t offset, stride; } plane[4];
};
```

The capability *is* the sharing mechanism. To show a buffer, a client sends the
Frame capability to the compositor over IPC (Chapter 09 §5). Consequences worth
appreciating:

- **Zero copy, structurally.** The compositor maps the same physical frames.
- **Revocation works.** Delete the capability and the compositor loses access —
  which is how you implement "this buffer is gone" without a protocol message.
- **No global buffer namespace.** No `wl_buffer` id, no GEM handle, no dma-buf fd
  table. The authority to touch the pixels *is* the reference to them. This
  removes a whole class of bugs where a stale id refers to a recycled buffer
  (compare Appendix B §4.2 — capabilities give you the generation-counter
  property for free).
- **Read-only sharing is expressible**: mint the capability without
  `RIGHT_WRITE`. A client can hand the compositor a buffer the compositor
  provably cannot modify, and vice versa.

### 2.2 Who allocates?

Three options, and the answer is "it depends", which is why you need an explicit
allocator interface:

| Allocator | When | Why |
|---|---|---|
| Client (from its own untyped) | Software rendering, simple cases | Simplest; charged to the client's memory budget, which is correct |
| GPU/display driver | GPU rendering, scanout-capable buffers | Only it knows alignment, tiling, and which memory is scanout-capable |
| A dedicated buffer allocator component | Heterogeneous cases: camera → GPU → display | Only it can find constraints satisfying *all* consumers |

The third case is the one everyone gets wrong and then bolts on later (Android's
`gralloc`, Linux's `dma-buf heaps`, the never-quite-finished unified allocator).
**Define the constraint-negotiation interface now, even if the first
implementation just returns "plain memory, 4096-byte aligned".**

```
alloc_buffer(width, height, format, usage_mask, constraints[]) -> buffer
```

where each consumer contributes constraints (alignment, stride granularity,
acceptable modifiers, memory placement) and the allocator intersects them. If the
intersection is empty, the answer is "you will need a copy" — said explicitly,
once, at allocation time, rather than discovered as a mysterious slowdown.

### 2.3 Format modifiers, and why you need them from day one

A buffer's *format* (`XR24`) says what a pixel is. A buffer's *modifier* says how
pixels are arranged in memory: linear, tiled in one of a dozen vendor-specific
patterns, or compressed. GPUs render into tiled/compressed layouts and scan out
from them; if the compositor doesn't understand the modifier, it must ask for a
linear copy, which costs a full-frame blit *and* loses compression bandwidth
savings.

Linux took years to retrofit modifiers into dma-buf. Put the field in the struct
now, even if the only value you ever use is `LINEAR`. It costs 8 bytes and saves
an ABI break.

### 2.4 The buffer lifecycle

```
client: allocate → render → submit(buffer, damage, fence) → [wait for release]
                     ↑                                              │
                     └──────────────────────────────────────────────┘
```

Rules:

1. A client must not touch a submitted buffer until the compositor releases it.
2. The compositor must release a buffer as soon as it's no longer needed for
   presentation — which is *not* when it's finished compositing, if the buffer is
   being directly scanned out. Getting this wrong causes tearing that appears only
   in the direct-scanout path.
3. Therefore clients need at least **two** buffers, usually **three**: one being
   scanned out, one being composited, one being rendered.
4. The compositor must handle a client dying with a buffer in the scanout path.
   With capabilities this is automatic — the frames stay alive as long as the
   compositor holds its capability. That is a genuinely nice property; on Linux
   this needs explicit reference counting through dma-buf.

---

## 3. Synchronization: explicit fences only

The buffer's *contents* are not ready when the buffer arrives. GPU rendering is
asynchronous, so the compositor must know when it can read.

**Never use implicit synchronization** (where the kernel tracks buffer
dependencies and stalls automatically). Linux did this, discovered it causes
unpredictable stalls and prevents useful reordering, and has spent years moving
to explicit sync. Skip that decade.

```c
/* A fence is a capability to a signalable object. */
submit(buffer_cap, damage, acquire_fence_cap) -> release_fence_cap
```

- **Acquire fence**: the compositor waits on this before reading the buffer.
- **Release fence**: the client waits on this before re-rendering into the buffer.

Implementation in Nyx: a fence is a **Notification** (Chapter 08 §5) plus a
64-bit timeline value. Signalling is `notification_signal`, which never blocks
and never allocates. Waiting is the ordinary wait primitive — so fences need no
new kernel machinery at all, which is the sort of thing that indicates the IPC
primitives were chosen correctly.

Prefer **timeline semantics** (a monotonically increasing counter, wait for
`>= N`) over binary fences: it composes better, avoids the "fence not yet
created" race that binary fences have, and matches Vulkan's timeline semaphores
and modern hardware.

**Deadline propagation** is where this gets interesting for Chapter 14: if the
compositor knows it must present at time T, and it's waiting on a client's
acquire fence, the client's rendering should inherit that deadline. Almost no
system does this. It's a natural fit with scheduling contexts and is a strong
research direction (Chapter 26 §4).

---

## 4. The scene graph

Chapter 21 D4 chose a retained scene. Here it is:

```c
struct node {
    node_id       id;
    node_id       parent;
    struct list_head siblings, children;

    /* geometry */
    struct rect   bounds;         /* in parent coordinates */
    struct mat3   transform;      /* 2D affine; keep it 2D until you need 3D */
    int32_t       z;

    /* content — exactly one of: */
    enum { NODE_CONTAINER, NODE_BUFFER, NODE_SOLID } kind;
    struct buffer *buffer;        /* NODE_BUFFER */
    uint32_t       color;         /* NODE_SOLID  */

    /* compositing */
    uint8_t        opacity;
    bool           opaque;        /* content has no alpha: enables occlusion culling */
    struct region  input_region;  /* where this node accepts input; see Ch. 23 */
    struct region  opaque_region; /* client's promise about opacity, per-region */

    /* ownership */
    cptr_t         owner;         /* which client contributed this subtree */
};
```

Why retained rather than "a list of surfaces, redrawn each frame":

- **Occlusion culling.** A fullscreen opaque window means everything under it is
  skipped. This is the single largest compositing optimization and it needs
  structure to compute.
- **Hit testing** (Chapter 23) is a tree walk, not a heuristic over a flat list.
- **Plane assignment** (§1) needs to know which nodes are independent and
  rectangular.
- **Damage propagation** is a tree operation.
- **Accessibility and automation** need to know the structure, and getting it
  from a retained scene rather than by screen-scraping is a very large
  improvement (Chapter 26 §6).
- **The compositor can be restarted** if the scene is reconstructible from client
  state (Chapter 11 §6, and §9 below).

The critical rule: **a client may only modify the subtree it owns.** This is
enforced by capability: a client holds a capability to its own root node, and node
operations are invocations on it. There is no "modify node by id" API. That single
decision is what prevents the entire class of X11 window-manipulation attacks.

### 4.1 Atomic updates

Clients batch changes and commit them:

```
begin() → set_buffer(node, buf, fence) → move(node, rect) → ... → commit()
```

Nothing is visible until `commit`, and a commit is applied entirely or not at all.
This is what makes resize-without-flicker possible: move the window and swap to
the new-sized buffer in one commit. X11's inability to do this is the reason
resizing X applications looks the way it does.

Extend it to **synchronized commits across clients** (Wayland's subsurface sync
problem, Android's transactions): a parent and child must be able to commit
together, or a window and its shadow tear apart during resize. Design the API as
"a transaction may include nodes from multiple clients, all of whom must have
consented" — a transaction object that clients contribute to and that applies when
all contributors have committed.

---

## 5. Damage tracking

Redrawing the whole screen every frame at 4K is ~33 MB of write bandwidth per
frame, 2 GB/s at 60Hz, before reading any sources. On a laptop that is a
measurable fraction of battery life. Damage tracking is not an optimization; it's
table stakes.

Three levels, in order of implementation:

1. **Client damage.** The client says which part of its buffer changed. This is
   Win32's `InvalidateRect` and it's the right API — the *application* knows what
   changed and nothing else can find out cheaply.
2. **Scene damage.** The compositor accumulates: nodes that moved (damage old +
   new bounds), nodes whose buffer changed (damage the client's region,
   transformed), nodes added/removed.
3. **Output damage.** Intersect scene damage with each output, subtract regions
   covered by opaque nodes above, and composite only the result.

You need a **region** type — a list of disjoint rectangles with union,
intersection, subtraction, and a simplification step that merges the list back to
a bounded number of rectangles (say 16) by taking the bounding box when it grows
too complex. This is a few hundred lines and is the most-used data structure in
the compositor. `pixman`'s region code is the canonical reference implementation
and its algorithm is worth understanding rather than copying.

**Damage plus double buffering has a subtlety** that catches everyone: the
compositor's back buffer is *two frames old*, not one. So you must composite the
union of this frame's damage and last frame's damage. Keep a small ring of
per-buffer damage histories. Getting this wrong produces artifacts that appear
only when something moves and stops — which is exactly the kind of bug that
survives to release.

---

## 6. Frame pacing

The naive loop — composite as fast as possible — burns power and adds latency.
The correct loop is deadline-driven:

```
vblank at T. Presenting at T requires:
    scanout flip submitted by       T - t_flip
    composition finished by         T - t_flip - t_compose
    client buffers ready by         T - t_flip - t_compose - t_slack
    therefore: wake clients at      T - t_flip - t_compose - t_slack - t_render
```

Each term is measurable. Measure them, keep a running estimate (a p95, not a
mean), and **wake clients as late as safely possible**. This is the difference
between 1-frame and 3-frame input latency, and it's the single most noticeable
quality difference between graphical systems.

This is a real-time scheduling problem, which is why Chapter 14 exists. The
compositor should:

- run with a scheduling context whose period matches the refresh interval,
- have a budget sized from measured composition time,
- and be the highest-priority non-driver component, because missing its deadline
  drops a frame for everyone.

**Do not use a timer at 16.67 ms.** Use the display's actual vblank interrupt as
the clock; refresh rates are never exactly what they claim, they drift with
temperature, and variable refresh rate makes the interval a variable. The vblank
event is the ground truth.

### 6.1 Variable refresh rate

If the panel supports VRR, the deadline model inverts: instead of "present at the
next vblank", it's "present when ready, and the panel adapts". This is strictly
better for latency and worth supporting early, because it simplifies the pacing
logic rather than complicating it. The constraint is a minimum and maximum
refresh interval you must stay within.

---

## 7. Backends

One interface, several implementations. Define it before writing any of them:

```c
struct display_backend {
    err_t (*enumerate_outputs)(struct output **, size_t *);
    err_t (*set_mode)(struct output *, const struct mode *);
    err_t (*alloc_buffer)(const struct buffer_desc *, struct buffer **);
    err_t (*commit)(struct output *, const struct plane_state *, size_t n,
                    cptr_t fence_out);      /* atomic: all planes or none */
    err_t (*wait_vblank)(struct output *, uint64_t *seq, uint64_t *time_ns);
    uint32_t caps;                          /* planes, VRR, modifiers ... */
};
```

| Backend | Purpose | Build it |
|---|---|---|
| **`virtual`** | Renders to memory, writes PNGs, fake vblank on a timer | **First.** Everything else depends on this existing. |
| **`bootfb`** | The bootloader-provided linear framebuffer | Second. No modesetting, no acceleration, but it's real pixels on real hardware in a day. |
| **`virtio-gpu`** | QEMU's paravirtual GPU | Third. Gets you modesetting, multiple outputs, and (with `virgl`) real acceleration under QEMU. This is where you should live for a long time. |
| **`simpledrm`-equivalent for real hardware** | Intel/AMD display engines | Much later. This is a large project (Chapter 25 §7). |
| **`remote`** | Encode and stream (Chapter 21 §6) | Whenever you want it; it's just a backend. |

The `commit` being atomic across all planes matters: partial plane updates cause
visible artifacts, and every modern display engine supports atomic commit. Design
to it even if the first backend fakes it.

---

## 8. Verification

The virtual backend makes the compositor *unusually* testable for a graphical
system. Exploit that hard.

**Reference image tests.** Build a scene from a script, render one frame, compare
to a stored PNG, fail on any pixel difference. Store references in the repo.

```
tests/gfx/scenes/two-overlapping-windows.scene
tests/gfx/refs/two-overlapping-windows.png
```

Cover: alpha blending, clipping to parent bounds, transforms, z-order,
occlusion, subpixel positioning, and every format you support.

**Damage correctness — the most valuable test in the whole subsystem:**

```
1. Render the scene fully → image A.
2. Reset, apply the same scene incrementally with damage tracking → image B.
3. Assert A == B, pixel for pixel.
```

Run this after every scene mutation in a randomized stress test. Damage bugs are
otherwise found by users noticing a smear on the screen weeks later, and are
nearly impossible to reproduce.

**Other tests worth naming:**

| Test | Asserts |
|---|---|
| `no_buffer_use_after_release` | Compositor never reads a released buffer (poison released buffers in debug) |
| `commit_is_atomic` | A frame never shows half of a transaction |
| `occlusion_culling_correct` | Culled render == non-culled render |
| `fence_waited_before_read` | Instrument the backend; assert ordering |
| `client_cannot_touch_foreign_node` | Attempt it; assert `ERR_PERM` |
| `compositor_survives_client_death` | Kill a client mid-frame; assert no crash, no leak |
| `region_ops` | Property-test union/intersect/subtract against a naive bitmap implementation on the host |

That last one is a case for host-side testing (Chapter 18): region arithmetic is
pure logic, so compile it for the host, property-test it against a bitmap
reference, and fuzz it under ASan. An afternoon, and it'll find bugs.

**Latency measurement**, from day one: timestamp at input event, at client
render start, at commit, at composition, at flip, at vblank. Log the histogram.
Chapter 26 §4 argues this should be a budget, not a metric; you can't budget what
you don't measure.

---

## 9. Making the compositor restartable

Chapter 11's reincarnation server should cover the compositor, and it's an
excellent test case because the failure is so visible.

What it takes:

1. **Scene state must be reconstructible.** Clients keep their own scene
   description (they built it) and buffers (they own the capabilities). On
   restart, the new compositor announces itself and clients re-submit. Total state
   loss: none.
2. **The endpoint object must outlive the compositor** (Chapter 11 §6) so client
   capabilities stay valid across the restart.
3. **Clients must handle a restart notification.** Bake it into the generated
   stubs (Chapter 10 §7) so no application author has to think about it.
4. **The display driver is a separate component**, so the mode stays set and the
   screen doesn't blank.

Result: a compositor crash is a dropped frame or two. Compare with the current
state of the art, where it's a lost session. This is a small, concrete, genuinely
novel-in-practice win, and it's a good early demonstration of why the
architecture is worth the trouble.

---

## 10. Exercises

1. Implement the region type and property-test it on the host against a bitmap
   reference. Fuzz it.
2. Build the virtual backend and the reference-image harness before anything
   else. Get one solid-colour node rendering and diffed in CI.
3. Implement the damage-equivalence test (§8) and run it under a randomized scene
   mutator for a million iterations. Report what it finds.
4. Measure your composition time as a function of the number of windows and the
   damage area. Plot it. Determine which one actually dominates.
5. Implement occlusion culling and measure the improvement with 20 stacked
   fullscreen windows. Then measure it with 20 *slightly transparent* windows and
   explain the difference.
6. Kill the compositor while a client is animating. Make it recover. Time it.
7. **Argue the other side:** make the case for immediate-mode (no retained scene)
   compositing. What does the compositor lose, and is there a design where the
   scene lives somewhere else entirely?

---

Next: [23 — Input: events, focus, and why input is a security boundary](23-input.md)
