# 26 — Research directions in system graphics

> Goal: the open questions. The graphical stack is, per unit of user-visible
> impact, the least-researched layer of a modern OS — it's mostly forty years of
> accretion with a compositing rewrite in the middle. Here is where a workbench
> could produce something new.
>
> As in Chapter 13: difficulty ★ (a weekend) to ★★★★★ (a thesis). Each entry
> states the idea, the state of the art, the Nyx-specific angle, and what result
> would make it interesting.

---

## 1. Provable input and display isolation ★★

**The idea.** Chapter 23 built input routing on capabilities. Turn "we think
client A can't observe client B's keystrokes" into a statement you can prove from
the capability graph.

**Why it's tractable here:** the property is a reachability question over a finite
graph. Given the set of capabilities each component holds, and the semantics of
each object type, is there any path by which A learns about input directed at B?
This is decidable, and it's the same tool as Chapter 13 §D6.

**What would be interesting:** a checker that consumes the root task's manifest
and outputs a report — "the following components can observe global input: `shell`,
`screenreader`. The following can capture the screen: `screenshot-tool` (granted
2026-08-01, revocable)." No shipping system can produce that document. It's
enormously valuable, and it's a few hundred lines plus the discipline of having
built the system this way.

**Stretch:** include the timing channels (Chapter 23 §6.4) in the model, and be
honest about which ones remain open. A report with a *complete* list of residual
channels would be genuinely novel.

---

## 2. End-to-end zero copy, application to scanout ★★★

**The idea.** A pixel is written once, by the application, and is never copied
again before it reaches the panel. Chapter 15 built the machinery; this is its
most visible application.

**The state of the art:** everyone claims zero-copy and almost nobody achieves it
end to end. A typical path today: application renders → toolkit rasterizes into
its own surface → compositor composites into a scratch buffer → sometimes another
copy for format or modifier conversion → scanout. Direct scanout works only for
fullscreen; hardware planes are underused because plane-assignment logic is hard
and vendors' constraints are baroque.

**In Nyx:**
- Buffers are Frame capabilities, so sharing is free (Chapter 22 §2).
- The constraint-negotiating allocator (Chapter 22 §2.2) means a buffer is
  allocated *once*, satisfying every consumer's alignment and modifier
  requirements.
- The retained scene (Chapter 22 §4) gives the compositor the structure it needs
  to assign planes well.

**The interesting result:** instrument every buffer and count copies per frame.
Publish "for a desktop workload with N windows, X% of frames were composed with
zero copies and Y% used direct scanout." Then compare to a Linux+Wayland baseline
with the same instrumentation. Nobody has this number. **This is a strong,
achievable project.**

---

## 3. Latency as a scheduled, budgeted resource ★★★★

**The idea.** Treat input-to-photon latency the way a real-time system treats a
deadline: declare it, budget it across components, schedule to meet it, and detect
violations.

**Why nothing does this:** the pipeline crosses five components (Chapter 23 §2),
each scheduled independently, with the GPU as an unscheduled black box at the end.
Nobody owns the end-to-end number, so nobody meets it — desktop latency is an
emergent property, not a designed one.

**In Nyx you have the pieces:**
- Scheduling contexts as capabilities (Chapter 14) — a budget can be *given* to
  the component doing the work.
- **Deadline propagation through IPC**: the compositor knows it must present at
  time T; when it waits on a client's fence, the client should inherit that
  deadline. This is priority inheritance generalized to *time*, and it's the key
  mechanism.
- Timestamps at every stage (Chapter 23 §3.1).

**The experiment:** implement deadline propagation from the vblank clock back
through the compositor to the client's render. Measure the p99 input-to-present
latency with and without. If the tail improves substantially, that's a real
result — and it applies directly to VR, games, and stylus input where the tail is
what people feel.

**The hard part** is the GPU boundary (Chapter 25 §7.2), where your scheduler has
no authority. Which makes it a good thesis-shaped problem.

---

## 4. The restartable, crash-tolerant session ★★

**The idea.** From Chapter 22 §9: the compositor can crash and the session
survives, because scene state lives in the clients and the endpoint outlives the
component.

**Why it's novel in practice:** every mainstream system loses the session when the
compositor or window server dies. Not because it's impossible, but because the
state lives in the wrong place. This is exactly the MINIX 3 dependability argument
(Chapter 00) applied to the most crash-visible component in the system.

**Extend it:** can the *input server* restart without dropping a keystroke? The
*display driver* without blanking the screen? A GPU hang recovering without losing
window contents? Each one is a self-contained project with a demo you can film,
which matters more than it should for communicating why any of this is worth
doing.

**The measurement:** mean time to visible recovery, and a chaos test (Chapter 11
§6) that kills a random graphical component every few seconds while running a
workload, asserting the session survives for an hour.

---

## 5. One scene description, from application to scanout ★★★★

**The idea.** Today a UI is described and rasterized several times over: the
application describes it in widget terms; the toolkit rasterizes to pixels; the
compositor composites those pixels; sometimes a browser engine adds another two
layers. Each rasterization discards structure the next layer would have wanted.

**What if the structure survived all the way down?** The application submits a
retained scene of vector shapes, text runs, and images. The compositor holds the
whole thing. Rasterization happens once, at the end, at the true output
resolution, with real transforms.

Consequences:
- Resolution independence is free. Zoom and scale are exact, not resampled.
- The compositor knows what changed *semantically*, so damage is exact.
- Occlusion culling works at the shape level.
- Accessibility (§6) reads the same structure.
- Remoting sends geometry, not pixels — a hundredth of the bandwidth.

**The state of the art:** this is roughly what NeWS attempted in 1986 (and it
failed for reasons worth studying — the wrong language, the wrong decade), what
PDF/Quartz does partially, what the DOM does for the web, and what
Flutter/Skia/WebRender do inside a process. Nobody has made it the *system*
model.

**The obvious objection**, which you must answer honestly: this is a fat protocol
between untrusted parties, and Chapter 21 §2.1 says fat server-side APIs age
badly and expand the TCB. That objection killed NeWS and it may kill this. But the
counter-argument is that the compositor already has to be a rasterizer, and the
alternative — rasterizing three times — is not free either.

**A tractable first step:** support text runs and rounded rectangles as scene node
types, alongside buffers. Measure the memory bandwidth difference on a text-heavy
UI. If it's large, keep going.

---

## 6. Accessibility and automation as a first-class capability ★★★

**The idea.** The scene graph already knows the structure of the UI. Export it as
a semantic tree through a capability, and screen readers, automation, and testing
all become the same mechanism.

**Why it's a research direction and not just engineering:** on every existing
platform, accessibility is a parallel tree maintained by hand, which is
perpetually out of sync with the real UI, and which requires enormous ambient
privilege to consume. The result is that accessibility is chronically broken and
screen readers are the most over-privileged software on a typical desktop.

**In Nyx:** the automation tree is derived from the retained scene (Chapter 22 §4)
plus toolkit semantics, and access to it is a capability — scoped to a window, or
global for a screen reader the user explicitly authorized, revocably.

**What would make it interesting:** demonstrate that (a) the tree cannot go stale,
because it *is* the scene rather than a copy of it, and (b) a screen reader can
work with strictly less authority than on any existing platform. That's a real
contribution to a field that badly needs one, and it's the same machinery as UI
testing, which makes it likely to actually be maintained.

---

## 7. Declarative UI as the system model ★★★★

Chapter 24 §10 exercise 7 is a genuine fork in the road. The imperative
message-loop model won 1985–2005; the declarative retained model (DOM, SwiftUI,
Flutter, React) has won everything since, by an enormous margin among application
developers.

**The question:** should the *system* window API be declarative? Application
submits a UI description; the system does layout, damage, and rendering.

**Arguments for:** it's what developers demonstrably prefer; layout and damage are
solved once, correctly, instead of in every toolkit; it composes with §5 and §6
perfectly; and remoting becomes trivial.

**Arguments against:** it's an enormous policy commitment in a system component
(what layout algorithm? forever?); it dictates application architecture; it's the
"fat server API" trap again; and the web's version required a browser engine of
several million lines.

**The experiment worth running:** build *both* on top of the same scene graph —
the imperative API of Chapter 24, and a declarative layer beside it — and write
the same non-trivial application against each. Measure lines of code, latency,
memory, and (honestly) how it felt. Nobody has done this comparison with both
sides implemented natively on one system by one team, which is exactly what a
workbench is for.

---

## 8. Deterministic, reproducible UI ★★

**The idea.** Combine the virtual display backend (Chapter 22 §7), input recording
and replay (Chapter 23 §8), and Chapter 13 §C6's record/replay execution. Result:
a UI session is a *value* — replayable, diffable, bisectable.

**What that buys:**
- Bug reports include an input trace that reproduces exactly.
- CI can replay a hundred real sessions and diff every frame against references.
- `git bisect` works on visual regressions.
- Performance regressions are reproducible rather than statistical.

**Why nobody has it:** existing systems have too much nondeterminism (timing,
GPU, threading) and no single point that owns the frame. Nyx has both fixed
already — the compositor is the single point, and the virtual backend removes the
hardware.

**Low difficulty, high value.** This one is close to free given the rest of the
architecture, and it would be a better testing story than any shipping desktop
has. Build it early; it makes everything else in this chapter measurable.

---

## 9. Novel display arbitration ★★★

Some ideas that the current model forecloses and a workbench could test:

- **Multiple simultaneous compositors on one display**, each owning a region, with
  a tiny trusted arbiter beneath them. A crash or compromise in one affects
  nothing else. This is the microkernel argument applied *within* the graphical
  stack, and it's the natural answer to "the compositor is one huge trusted
  component" (Chapter 21 §2.2).
- **Per-window trust levels affecting composition**: a window from an untrusted
  component cannot be positioned over a trusted one, cannot be made transparent
  over it, and is visually marked. Clickjacking becomes structurally impossible
  rather than heuristically mitigated.
- **Display as a shared resource with quotas**: composition budget, plane budget,
  and bandwidth budget, allocated like memory. What does a "display quota" even
  mean? Nobody has defined it, and on a shared machine it's exactly what you'd
  want.
- **Migration**: move a running window between machines, or between a local
  display and a remote one, without the application knowing. The buffer-passing
  model plus capabilities makes this more tractable than it sounds — and it's the
  good version of the idea X11's network transparency was reaching for.

---

## 10. What to build, in what order

A concrete roadmap for this part, assuming the kernel from Parts I–IV exists:

| Milestone | Content | Rough effort |
|---|---|---|
| **G0** | Virtual backend, scene graph, one solid-colour node, reference-image test in CI | 1–2 weeks |
| **G1** | Buffers as capabilities, client submits a rendered buffer, damage tracking, damage-equivalence test | 2–3 weeks |
| **G2** | Software rasterizer: rects, blits, clipping, alpha | 1–2 weeks |
| **G3** | virtio-input → input server → hit test → client events; the isolation test | 2 weeks |
| **G4** | Window API (Ch. 24), event loop, `WM_PAINT` equivalent; the 40-line hello world | 2–3 weeks |
| **G5** | bootfb / virtio-gpu backend: real pixels, real mouse, on real (virtual) hardware | 1–2 weeks |
| **G6** | Text: port FreeType + HarfBuzz, glyph atlas, a terminal emulator client | 3–4 weeks |
| **G7** | Shell: focus policy, window placement, a panel. Now it's a desktop. | 3–4 weeks |
| **G8** | Compositor restart (§4), chaos test | 1 week |
| **G9** | Latency instrumentation end to end, waterfall tool, CI budget | 1 week |
| **G10** | Pick one research direction from this chapter | — |

Note that G0–G5 — a working, testable window system with real input on real
hardware — is roughly three months of evenings, and requires no GPU driver, no
font engine, and no toolkit. The terminal emulator at G6 is the moment it becomes
*useful*, because now the system's own console lives inside its own graphical
stack, which is the traditional and correct milestone.

---

## 11. Doing research here properly

Repeating Chapter 13's discipline, with graphics-specific notes:

1. **Every claim about performance needs a baseline on the same machine on the
   same day.** Graphics measurements are noisy; use p99, not means, and report the
   distribution.
2. **Reference images and frame diffs are your ground truth.** Build that harness
   first (G0) or you'll be arguing about screenshots.
3. **Latency is perceptual; measure it, but also *look* at it.** A 120 fps
   counter with a 4-frame latency feels worse than 60 fps with 1. Instrument the
   whole pipeline, then use a high-speed camera or a photodiode for the real
   end-to-end number if you're serious.
4. **Compare against Linux+Wayland honestly**, including where you lose. A paper
   that only reports wins isn't believed, and the losses are where the interesting
   engineering is.
5. **The graphical stack is where a demo matters.** Everything else in this book
   produces numbers; this part produces something you can show someone. Record
   the video. It's how the rest of the work gets read.

---

## 12. Exercises

1. Build G0 through G2 and record a video of a window being dragged. Note how much
   of the system had to exist for that to happen.
2. Implement §8 (deterministic replay) at G3, before you need it. Then use it for
   every subsequent bug.
3. Write the §1 capability-graph checker for the graphical subsystem and produce
   the report. Show it to someone who works on desktop security and record their
   reaction.
4. Pick one of §2, §3, or §7 and write the two-page design doc from Chapter 13
   §14 exercise 1: problem, design, invariants, measurement, and what result
   would falsify the hypothesis.
5. Measure your input-to-present latency and compare it against a Linux desktop
   measured the same way. Publish both numbers, including if yours is worse.
6. **Argue the other side, for the whole part:** make the case that building a
   graphical system is a distraction from a microkernel research project, and that
   the right move is to run existing software in a VM (Chapter 13 §C1) and spend
   the time on the kernel instead. Then decide, deliberately, which one you're
   doing.

---

Part VII ends here. The graphical system is the layer where the architecture of
Parts I–VI becomes visible to a person: capabilities become "this app cannot see
your keystrokes", restartability becomes "the desktop didn't die", zero-copy
becomes "the battery lasts", and real-time becomes "it feels immediate". If the
design is right, those are the same claim.

← [Back to the index](README.md)

Next: [27 — Composability: one design from microcontroller to server](27-composability.md)
