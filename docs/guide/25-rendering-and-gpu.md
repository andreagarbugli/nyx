# 25 — Rendering, text, and the GPU

> Goal: put pixels in a buffer. 2D rasterization, the surprisingly hard problem of
> text, colour correctness, and an honest account of what a GPU stack costs — plus
> the staged plan that lets you have a working graphical system long before you
> have a GPU driver.

---

## 1. Where rendering happens, and why it's not in the compositor

Chapter 21 D3: clients render, the compositor composites. Restating why, because
this is where the temptation to add "just a few drawing calls to the protocol"
appears:

- Server-side drawing APIs age badly (X11's core drawing is dead; GDI survived
  only by being reimplemented on top of Direct2D).
- The drawing API is where you need the most iteration, and putting it in a
  protocol freezes it.
- A rendering bug in a client is a client bug. A rendering bug in the compositor
  takes down the session.
- Clients want different renderers: a text editor wants a CPU rasterizer, a game
  wants Vulkan, a terminal wants a glyph atlas blitter. One API serves none of
  them well.

**The compositor's only drawing operations are: blit with transform, blend,
solid fill, and clip.** That's it. Everything else is a client-side library.

---

## 2. The staged plan

Do not start with a GPU. The staging that gets you a usable system fastest:

| Stage | Renderer | Compositor backend | You can |
|---|---|---|---|
| **0** | Software, `memcpy` of solid colours | virtual (Ch. 22 §7) | Test the whole stack in CI, no hardware |
| **1** | Software rasterizer (§3) | bootfb | Real windows on real hardware |
| **2** | Software + glyph atlas (§4) | virtio-gpu, software composition | A usable desktop under QEMU |
| **3** | Software clients, GPU composition | virtio-gpu with 3D | Smooth compositing, hardware planes |
| **4** | GPU clients (Vulkan via virgl/venus) | virtio-gpu | Games, accelerated toolkits |
| **5** | Native GPU driver | real hardware | The multi-year project |

**Stages 0–2 give you a real, working, usable graphical system.** A 2D software
rasterizer on a modern CPU fills something like a gigapixel per second; a 1080p
full-screen fill is under 2 ms single-threaded. The bottleneck for a desktop UI
is text and blending, not fill rate. People underestimate this badly — Haiku ran a
full desktop on software rendering for years and it felt fine.

So: **do not let the GPU be on the critical path to having a window system.**

---

## 3. Software 2D rasterization

You need less than you'd think. The full set of operations a UI toolkit needs:

1. Fill a rectangle (solid, gradient).
2. Blit a rectangle (with alpha blending, optionally scaled).
3. Fill an arbitrary path (rounded rectangles, icons, vector art).
4. Stroke a path.
5. Draw glyphs (§4 — actually just #2 with a mask).
6. Clip everything to a region.

Items 1, 2, 5, and 6 are 90% of a UI and are all straightforward memory
operations. Only 3 and 4 need real rasterization.

### 3.1 The path rasterizer

The best modern approach for a from-scratch implementation is **signed-area
coverage accumulation** (the "font-rs"/`cell` approach, also how `tiny-skia` and
FreeType's smooth rasterizer work in spirit):

1. Flatten curves to line segments with an adaptive tolerance.
2. For each segment, accumulate signed area and cover contributions into a
   sparse scanline structure.
3. Prefix-sum along each scanline to get coverage in [0,1].
4. Apply the fill rule (non-zero or even-odd), then blend.

Why this rather than scanline-with-active-edge-tables: it produces analytic
antialiasing for free, it's branch-light and vectorizes well, and it's about 300
lines. The classical active-edge-table approach needs supersampling for
antialiasing, which is 4–16× the work for a worse result.

### 3.2 Blending, and the mistake everyone makes

Compositing must happen in **linear light**, not in sRGB-encoded values. Blending
two sRGB values by averaging their encoded bytes is mathematically wrong and
produces the characteristic dark fringes around antialiased edges and the muddy
midpoint in gradients.

Options, in order of cost:

- Premultiplied alpha in linear space, 16-bit per channel. Correct, 2× memory.
- Premultiplied alpha with an sRGB↔linear lookup table for 8-bit. Correct enough,
  cheap, standard.
- Blend in sRGB space directly. Wrong, but it's what most systems do, and matching
  everyone else's wrongness is sometimes the pragmatic choice for text (see §4.4).

Decide deliberately and write it in `docs/color.md`. Also: **always use
premultiplied alpha** in buffers. Straight alpha requires a division per blend and
makes filtering incorrect at edges. Every serious system uses premultiplied; make
it the only format you accept.

### 3.3 Optimization, when you get there

- SIMD the blend loops (SSE2/AVX2). This is the single biggest win and it's
  mechanical.
- Special-case the common paths: fully opaque source (a copy), fully transparent
  (skip), source-over with constant alpha.
- Tile the rasterizer (32×32) for cache locality and easy parallelism.
- Skip work outside the damage region — the rasterizer should take a clip region
  and never touch pixels outside it. This is the biggest win of all and it's free
  if you wire damage through properly (Chapter 22 §5).

---

## 4. Text, which is the hard part

Every underestimation of the difficulty of a graphical system is really an
underestimation of text. The pipeline:

```
string (UTF-8)
  → Unicode processing: normalization, bidi, line/word breaking, grapheme clusters
  → itemization: split into runs of one script, direction, and font
  → font selection and fallback (the glyph isn't in your font. Now what?)
  → shaping: characters → positioned glyph ids (ligatures, kerning, marks, Indic reordering)
  → rasterization: glyph id → coverage bitmap, at a size, with hinting
  → glyph cache / atlas
  → blit with subpixel positioning
  → line layout, justification, and the caret/selection geometry that must match
```

Nine stages. Each has real complexity. Text is the reason a "simple" GUI stack
takes years.

### 4.1 The honest recommendation

**Port, don't write:** HarfBuzz for shaping, FreeType (or a Rust equivalent) for
rasterization, ICU or a smaller library for Unicode segmentation and bidi. These
are decades of accumulated correctness for scripts you cannot test and do not
read. Writing your own shaper means your OS cannot display Arabic, Devanagari, or
Thai correctly, and you will not find out for years.

They're freestanding-friendly: HarfBuzz and FreeType need only `malloc`, `free`,
and a file/memory source. Given Chapter 10's libnyx and Appendix B's arena, that's
a day of glue.

**Write yourself:** the glyph cache, the atlas, the line layout, and the API. The
parts that touch your design.

**Write your own only as a learning exercise, in a corner, for Latin only:** a
TrueType parser and a glyph rasterizer are a genuinely enjoyable weekend project
(`stb_truetype` is 2000 lines and readable). Just don't ship it as the system's
text engine.

### 4.2 The glyph atlas

The one piece you must build well, because it's on every frame's hot path:

- A texture (or plain buffer) holding rasterized glyphs, packed with a simple
  shelf or skyline allocator.
- Keyed by `(font, size, subpixel_x_offset, hinting_mode, glyph_id)`. Note the
  subpixel offset: caching at 4 horizontal subpixel positions is what makes text
  positioning smooth without re-rasterizing.
- LRU eviction with a generation counter so evicting doesn't invalidate in-flight
  frames.
- Rendering a run of text is then: one lookup per glyph, one blit each. Trivial.

### 4.3 The alternative: GPU vector text

Newer systems (Slug, and various SDF/compute approaches) rasterize glyph outlines
directly on the GPU, avoiding the atlas entirely. Advantages: arbitrary scale, no
cache management, works well with transforms. Disadvantages: needs a GPU, quality
tuning is subtle, and hinting is essentially impossible.

Not for stage 0–2. Worth knowing about for Chapter 26.

### 4.4 Subpixel antialiasing (RGB stripes)

Note that the industry has been *removing* it: macOS dropped it entirely, and it
fails on rotated displays, non-RGB-stripe panels, and any surface that gets
transformed or composited with alpha. At 2×-scale displays, grayscale
antialiasing looks fine.

Recommendation: grayscale antialiasing, with gamma-corrected blending tuned so
text weight looks right. Skip subpixel. If you want it later, note that it
constrains your compositor (subpixel-antialiased buffers can't be freely rotated,
scaled, or blended), which is a real architectural cost.

---

## 5. Colour

Worth doing correctly from the start, because retrofitting colour management is
one of the most painful changes a graphical system can undergo (see: every system
that has tried).

The minimum viable design:

- Every buffer declares a colour space (sRGB, Display P3, Rec.2020, scRGB linear).
- Every output has a colour profile and a target.
- The compositor converts as needed during composition.
- If everything is sRGB and the output is sRGB, the conversion is the identity and
  costs nothing — so the correct design is free in the common case.

That last point is the argument: putting the colour space *field* in the buffer
descriptor now costs 4 bytes and no cycles, and makes HDR and wide-gamut support a
compositor change later rather than an ABI break. Chapter 22's `buffer_desc` has
room; use it.

HDR additionally needs: a per-buffer content-brightness metadata, a tone-mapping
policy for mixing SDR and HDR content on one screen, and a decision about
reference white. It's genuinely hard and worth deferring — but only if the
plumbing exists.

---

## 6. The toolkit layer

Above the window API (Chapter 24) sits the thing applications actually use. Keep
it *out* of the OS core — but design one, because the API's quality can only be
judged by writing real applications against it.

The pieces:

| Piece | Notes |
|---|---|
| Widget model | Retained tree, or immediate mode (§6.1) |
| Layout | Flexbox-like constraint solving is the pragmatic modern answer; box model, then flex, then maybe a real constraint solver |
| Styling | Keep it data-driven from the start or theming becomes impossible later |
| Text editing | Far harder than it looks: bidi caret movement, IME preedit, selection across shaped runs, undo. Build it once, well, and share it. |
| Accessibility | An automation tree exported from the widget tree. **Design it in.** Retrofitting accessibility is a multi-year project on every platform that has tried. |
| Animation | Property animation driven by `EV_FRAME` target times (Chapter 24 §4) |

### 6.1 Immediate vs retained mode

| | Immediate (Dear ImGui style) | Retained (Win32/DOM style) |
|---|---|---|
| Code | Simplest possible — UI is a function of state | More ceremony, explicit widget objects |
| Damage | Redraws everything, every frame | Damage-driven, can idle at 0% CPU |
| Accessibility | Very hard — no persistent tree to expose | Natural |
| Power | Bad on battery | Good |
| Verdict | Excellent for tools and debug UI | Right for the system toolkit |

Recommendation: **retained for the system toolkit, and ship an immediate-mode
library too** for debug overlays, the compositor's own diagnostics, and internal
tools. They coexist happily; the immediate-mode one draws into a buffer like any
other client.

---

## 7. The GPU, honestly

This is the part where a hobby OS meets an industrial wall. Be clear-eyed:

### 7.1 What a GPU driver actually requires

| Piece | Effort |
|---|---|
| Display engine: modeset, planes, vblank, hotplug, DP/HDMI link training | Months. Mostly documented for Intel; partially for AMD. |
| Memory manager: VRAM allocation, GTT/GART, migration, eviction | Months |
| Command submission: rings, doorbells, fences, preemption, hang recovery | Months |
| Shader compiler: your IR → the GPU's ISA, with an optimizer | **Years.** This is the wall. |
| API implementation: Vulkan is ~1000 entry points with a conformance suite | Years |
| Power management, clocks, thermals | Months, and it's why your GPU runs at 300 MHz |

Nobody writes this from scratch anymore. The realistic paths:

**Path A — virtio-gpu (do this).** QEMU's paravirtual GPU. `virgl` translates
OpenGL to the host; `venus` does Vulkan. You implement a comparatively simple
ring-based protocol and get real acceleration. This is where you should live for
years, and it's the same interface you'd use if Nyx ran as a guest in production.

**Path B — port Mesa.** Mesa contains the shader compilers and driver backends
for Intel, AMD, and others. Porting it means providing a `winsys` layer (memory
allocation, command submission, fences) plus a kernel-side driver for the
hardware bits. Large but tractable — this is what every non-Linux system that has
real GPU support has done. It's also a genuinely interesting exercise in the
capability model: Mesa's winsys assumptions are Linux-shaped and mapping them to
capabilities will teach you a lot about both.

**Path C — display-only, no 3D.** Modeset + planes + scanout, no rendering
acceleration. This is `simpledrm`/`efifb` territory extended with real modesetting.
Weeks to months per vendor, and it gets you multi-monitor, correct resolutions,
hotplug, and hardware cursor/overlay planes — which is most of what a *desktop*
needs, since composition of a few windows is cheap on the CPU.

**Recommendation: A now, C when you want real hardware, B if the project ever
justifies it.**

### 7.2 The GPU in a capability system

This part *is* novel and worth doing carefully, because the security model of GPU
access is a genuine open problem everywhere:

- **A GPU context is a capability.** It bundles: a VRAM allocation budget, a
  submission ring, an IOMMU/GPU-page-table context, and a fence timeline.
- **GPU page tables are a second MMU** and must be treated with the same rigor as
  Chapter 06's. A process's GPU context must only be able to address its own
  buffers. Most drivers get this right *now*; historically many did not, and
  "GPU can DMA anywhere" was standard.
- **Untrusted shader code** is arbitrary code on a device with DMA. Infinite loops
  hang the GPU (needs preemption or a reset watchdog); out-of-bounds access needs
  hardware bounds checking; and timing channels between contexts are wide open.
- **The scheduler question**: GPU work is scheduled by the GPU's own firmware,
  which knows nothing about your priorities. Chapter 14's deadline reasoning stops
  at the GPU boundary. Making a real-time guarantee that includes GPU work is an
  open problem and a strong research direction.

Chapter 15 §5 already established that a userspace driver without an IOMMU
provides no isolation. For GPUs this is doubled: you need both the system IOMMU
*and* correct GPU page table isolation.

---

## 8. Verification

| Test | Asserts |
|---|---|
| `rasterizer_reference` | Render a suite of paths, compare against stored PNGs with a small tolerance |
| `blend_math` | Property test: `over(a, transparent) == a`, `over(opaque, b) == opaque`, associativity of source-over |
| `premultiplied_invariant` | No pixel ever has a channel value exceeding its alpha |
| `clip_is_respected` | Fuzz: render with a random clip, assert no pixel outside it changed. **Run this constantly** — clip bugs are the most common rasterizer bug. |
| `glyph_cache_correct` | Cached glyph == freshly rasterized glyph, at every subpixel offset |
| `text_shaping_snapshots` | Store shaped output (glyph ids + positions) for a corpus including Arabic, Hindi, Thai, emoji, and combining marks. Diff on change. |
| `atlas_eviction_safe` | Evict aggressively under load; assert no in-flight frame reads a reused slot |
| `linear_blending` | A 50% gradient between black and white has the expected linear-light value |

Host-side testing applies to almost all of this (Chapter 18): a rasterizer is pure
computation. Compile it for the host, fuzz it under ASan, property-test it. You
should be able to run your entire 2D rendering test suite in under a second on a
laptop with no emulator involved.

The text shaping snapshot test deserves emphasis: it's the only practical way to
know whether a change broke a script you can't read.

---

## 9. Exercises

1. Implement the signed-area path rasterizer. Render a few hundred random paths
   and diff against a reference (Cairo or Skia on the host makes a good oracle).
2. Implement the clip fuzz test and run it for an hour. Report what it finds.
3. Port `stb_truetype` and render "Hello" at 12pt. Then port FreeType and
   HarfBuzz and render Arabic. Note how long each took.
4. Build the glyph atlas and measure text throughput in glyphs/second. Then find
   the actual bottleneck (it will not be rasterization).
5. Implement sRGB↔linear conversion and compare a gradient rendered both ways.
   Look at them side by side; the difference is not subtle.
6. Bring up `virtio-gpu` in 2D mode and get the compositor scanning out through
   it, with a hardware cursor plane.
7. Measure full-screen software composition time at 1080p and 4K. Decide, with
   numbers, at what resolution you actually need GPU composition.
8. **Argue the other side:** make the case for putting a drawing API back in the
   display server (as X11 and GDI did). Under what circumstances — thin clients,
   remoting, memory-constrained devices — would that be the right call again?

---

Next: [26 — Research directions in system graphics](26-graphics-research.md)
