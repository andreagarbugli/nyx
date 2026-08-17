# 21 — Display architecture: what a graphical system actually is

> Goal: understand the design space before writing a line of it. By the end of
> this chapter you should be able to say precisely what X11, Wayland, Win32,
> Quartz, and Scenic each decided, where each was right, and what Nyx's position
> is — including the rule that the whole graphical stack must be *optional*.
>
> This chapter is Part VII's version of Chapter 00: theory first, because the
> graphical system is the part of an OS most often built by accretion and most
> painful to change afterwards.

---

## 1. Five responsibilities, usually conflated

Every graphical system does these five things. Most systems' problems come from
having merged two of them that should have been separate.

| # | Responsibility | The question it answers |
|---|---|---|
| 1 | **Display arbitration** | Who owns the scanout hardware, and how do multiple clients share one screen? |
| 2 | **Input routing** | A key was pressed. Which client hears about it, and who decided that? |
| 3 | **Window state and lifetime** | What is a window, who owns it, how is it created, resized, destroyed, and who can see that it exists? |
| 4 | **Drawing** | How do pixels get produced, and where does the memory come from? |
| 5 | **The application-facing API** | What does a program actually call, and how much of the above does it have to understand? |

Notice that only (1) touches hardware, and only (4) *might*. Responsibilities 2,
3, and 5 are pure software policy — which means, in a microkernel, they are
ordinary userspace programs with no special privilege at all. That is a bigger
deal than it sounds: on Windows, (3) and (5) lived in `win32k.sys`, in the
kernel, and became one of the largest sources of privilege-escalation CVEs in
computing history. We get to not do that, for free, by construction.

### 1.1 The three questions that separate the designs

1. **Where does the drawing API live?** In the display server (X11's core
   protocol, Win32 GDI), or in the client (Wayland, modern everything)?
2. **Who owns window policy?** The server (Win32), a separate window manager
   (X11), or the compositor (Wayland)?
3. **What is the unit of authority?** A connection (X11: connect and you can do
   almost anything), a global name (Win32: `HWND` is a global integer), or a
   capability (Fuchsia, and us)?

Answer those three and you've described 80% of any graphical system.

---

## 2. The historical designs, honestly assessed

### 2.1 X11 (1984)

**The model:** a server owns the display; clients connect over a byte stream and
issue drawing commands; a separate window manager (just another client, with a
special selection) implements policy.

**What it got right:**
- The client/server split itself, and the idea that the display is a shared
  resource with an explicit protocol.
- Network transparency, in 1984, was visionary and genuinely useful.
- Extensibility: the extension mechanism kept X alive for forty years.
- Separating the window manager from the server was the correct instinct — policy
  out of mechanism, the same argument as Chapter 00.

**What it got wrong, structurally:**
- **Ambient authority.** Any client can enumerate every window, read any window's
  contents, grab the keyboard, and synthesize events into other clients. X11 has
  essentially no security model between clients. Every screenshot tool, every
  automation tool, and every keylogger uses the same API. This is not a bug that
  can be fixed; it's the design.
- **The drawing API is dead.** Core X drawing (`XDrawLine`, server-side fonts) was
  abandoned decades ago; everyone renders client-side and uploads pixmaps. So the
  server carries an enormous obsolete API surface it must still support.
- **Synchronous round-trips.** The protocol has request/reply patterns that force
  latency; toolkits spend real effort avoiding them.
- **No frame-perfect model.** Nothing in X guarantees that what you see is a
  consistent composition of complete frames. Tearing and partial updates are
  normal.
- **The extension pile.** Composite, Damage, XInput2, RandR, Render, Shape, Sync,
  Present — the real X11 of 2010 is a dozen extensions with an obsolete core
  underneath.

**The lesson:** network transparency and a server-side drawing API both became
liabilities, and neither could be removed. Choose what goes in your *core* very
carefully, because you will support it forever.

### 2.2 Wayland (2008)

**The model:** clients render into buffers and hand them to a compositor; the
compositor is also the window manager and the display server; the protocol is a
minimal core plus extensions.

**What it got right:**
- **"Every frame is perfect."** The compositor only ever presents complete,
  consistent frames. This is the correct model and everyone has adopted it.
- **Buffer-passing instead of drawing commands.** The client owns rendering; the
  server owns composition. Clean and zero-copy-capable.
- **Isolation by default.** A client cannot see other clients' buffers or input.
  A genuine, deliberate improvement over X11.
- Merging the compositor and window manager removed an entire class of race
  conditions (X's WM is asynchronous with respect to the server).

**What it got wrong, or at least didn't solve:**
- **Minimalism pushed the hard problems into "protocols" that then fragmented.**
  Screen capture, global hotkeys, window positioning, session restore, remote
  access, accessibility, and clipboard behavior all live in optional protocols
  with inconsistent support. The result is that "supports Wayland" doesn't mean
  much.
- **There is no standard application-facing window API**, only a wire protocol
  plus a toolkit. This is a defensible choice, but it means every toolkit
  re-invents the same layer and they disagree.
- **Security by "you can't do it" rather than "you can do it if authorized"** —
  which produced the portal layer as a bolt-on, essentially reintroducing
  capabilities via D-Bus without the structure.
- **The compositor is one enormous trusted component** doing arbitration, input
  routing, window policy, rendering, and often the shell. When it crashes, the
  session dies.

**The lesson:** correct buffer model, correct isolation instinct, but the
"mechanism only, no policy, no API" position leaves users to reassemble the
system, and they do it inconsistently.

### 2.3 Win32 USER/GDI (1985–)

**The model:** the system owns a hierarchy of *window objects* identified by
`HWND` handles. Every window has a **window procedure** — a callback. Everything
that happens to a window (input, resize, paint, timers, IPC, custom messages)
arrives as a **message** in a per-thread queue. `GetMessage`/`DispatchMessage`
drives it. Drawing is device-independent through GDI (later Direct2D), with
explicit invalidation and clipping.

**What it got right — and this is more than the internet gives it credit for:**

| Feature | Why it's good |
|---|---|
| **Windows are objects with handles** | Uniform lifetime, uniform identity, a natural place to hang authority. Exactly the object model of Chapter 16. |
| **One unified event queue** | Input, lifecycle, paint, timers, and app-defined messages all arrive by the same mechanism, in order. Applications have *one* loop. Compare X11, where you get events, plus a separate `select`, plus toolkit timers. |
| **`WM_PAINT` + invalid region** | Damage-driven repainting, expressed in the API, in 1985. The system tells you *what* to redraw. This is still the right model. |
| **Window hierarchy with clipping** | Parent/child relationships give you clipping, coordinate spaces, hit testing, and lifetime for free. |
| **The window procedure is polymorphism** | `DefWindowProc` gives default behavior; subclassing and superclassing let you extend it. It's an object system built out of an integer and a function pointer. |
| **Controls are windows** | Buttons, edit boxes, and list views are the same kind of thing as top-level windows. One concept, not two. |
| **The API outlived the implementation** | DWM added GPU compositing in Vista without breaking a 1990 application. That is an extraordinary piece of interface design, and it happened because the API described *intent* (invalidate, paint, move) rather than mechanism (blit to this framebuffer). |
| **One coherent API surface** | Windowing, input, drawing, dialogs, and clipboard are one documented system, not eleven optional protocols. Applications got written. |

**What it got wrong, and these are serious:**

| Problem | Consequence |
|---|---|
| **`HWND` is a global, guessable namespace** | Any process can `FindWindow` any window and `SendMessage` to it. This produced the "shatter attack" class: send a message to a higher-privileged window and get code execution. Microsoft's eventual fix (UIPI/integrity levels) is a filter bolted over an ambient-authority design. |
| **`SetWindowsHookEx`** | System-wide input hooking as a supported API. Keylogging as a feature. |
| **Synchronous `SendMessage` across processes** | Cross-process deadlocks; one hung app hangs others. `SendMessageTimeout` is the admission of defeat. |
| **`AttachThreadInput` and shared input state** | Input queues can be merged, making focus and key state a shared mutable global between processes. |
| **USER/GDI ran in the kernel** (`win32k.sys`) | The single largest local-privilege-escalation attack surface in Windows for decades. A font parser in ring 0. |
| **Message-pump coupling** | A window belongs to a thread; that thread must pump messages or the whole UI stalls, including other apps' `SendMessage`s to it. This shaped (and constrained) Windows application architecture for thirty years. |
| **Everything is synchronous-by-default** | Which made all of the above worse. |

**The lesson, and the core insight of this whole part:** Win32's *object and
message model* is excellent. Its *security model* and *synchrony* are the
problems. Those are separable. **You can keep the model and fix the rest** — and
a capability system is exactly the tool for fixing the namespace problem, since
the ambient global `HWND` table is precisely what capabilities replace.

### 2.4 The others, briefly

| System | Key idea worth stealing |
|---|---|
| **Quartz / CoreGraphics** (macOS) | Compositing from day one; a resolution-independent, PDF-based drawing model; window server as a separate privileged process. Also: the window server owns a *scene*, not just pixels. |
| **Fuchsia Scenic / Flatland** | The display is a **retained scene graph** the compositor owns; clients contribute subtrees. Views are capabilities. Explicitly designed for a capability OS — the closest thing to what we want. |
| **Android SurfaceFlinger** | BufferQueue as the universal producer/consumer abstraction; explicit fences everywhere; hardware overlay planes used aggressively to avoid composition entirely. |
| **Haiku `app_server`** | A modern, coherent re-implementation of the Win32-style model with a much cleaner API. Very worth reading — it's small, readable, and proves this model can be done well. |
| **Plan 9 `rio` / `draw`** | Radical minimalism: the window system is a file server, windows are directories, and `rio` is ~3000 lines. Demonstrates that a usable window system need not be large. |
| **Arcan** | A display server designed as a *scripted* engine, with an explicit security model and genuinely novel ideas about what a display server is allowed to be. Underrated, and the most interesting recent work in this space. |
| **Web/DOM** | Retained-mode declarative UI with automatic layout and damage. The most successful UI model ever deployed, and worth taking seriously as a design influence rather than dismissing. |

---

## 3. Nyx's position

The design, stated as five decisions:

**D1 — Win32's object/message model, capability-secured.**
Windows are typed objects reached through capabilities, not a global integer
namespace. There is no `FindWindow`, no window enumeration, no way to name a
window you weren't given. Possession of a window capability *is* the right to
manipulate that window. `SetWindowsHookEx` has no expressible analogue: to
observe another window's input you need a capability that only the shell can
mint, and minting it is a visible, revocable, auditable act.

This single change deletes: shatter attacks, keyloggers-by-default, screen
scraping without consent, clipboard sniffing, and window-title-based
fingerprinting. It costs nothing at runtime.

**D2 — Asynchronous by default; synchronous only where it's proven safe.**
Messages are posted, never sent-and-blocked, across a trust boundary. Where a
reply is needed, it is an explicit request/reply with a deadline, using
Chapter 08's call/reply, which cannot deadlock across a level boundary
(Chapter 11 §2). Win32's cross-process `SendMessage` is not offered at all.

**D3 — Wayland's buffer and frame model.**
Clients render into buffers they own; the compositor presents complete frames;
damage is explicit; synchronization is by explicit fences. No client ever draws
into the scanout buffer, and no drawing commands cross the protocol.

**D4 — The scene is retained, and the compositor owns it.**
Like Scenic and Quartz, not like Wayland's flat surface list. Clients contribute
subtrees; the compositor knows the structure. This is what makes clipping,
hit-testing, occlusion culling, hardware-plane assignment, accessibility, and
input routing tractable rather than heuristic.

**D5 — Every layer is optional and replaceable.**
There is no graphical code in the kernel. The display server is a userspace
component that you may simply not start. This is not a slogan; §5 makes it a
testable property.

### 3.1 What this looks like as a stack

```
┌──────────────────────────────────────────────────────────────┐
│ applications                                                 │
├──────────────────────────────────────────────────────────────┤
│ toolkit (libnyxui)     — widgets, layout, text, theming       │  optional
├──────────────────────────────────────────────────────────────┤
│ window API (libnyxwin) — Window objects, event loop, damage   │  optional
├──────────────────────────────────────────────────────────────┤
│ shell                  — policy: focus, placement, workspaces │  optional
├──────────────────────────────────────────────────────────────┤
│ compositor             — scene graph, damage, presentation    │  optional
├──────────────────────────────────────────────────────────────┤
│ input server           — device → events → routing decisions  │  optional
├──────────────────────────────────────────────────────────────┤
│ display driver         — modeset, scanout, planes, vsync      │  optional
│ GPU driver             — command submission, memory           │  optional
├──────────────────────────────────────────────────────────────┤
│ Nyx kernel             — frames, IPC, notifications, IRQ, DMA │  REQUIRED
└──────────────────────────────────────────────────────────────┘
```

Every box above the line is a normal, restartable, capability-confined userspace
process (Chapter 11). Note the split between **compositor** (mechanism: scene,
damage, presentation) and **shell** (policy: which window gets focus, where new
windows go, what a workspace is). X11 got this split right and Wayland merged it;
we keep it split, because it is the same policy/mechanism argument the entire book
is built on — and because it means you can replace the shell without replacing the
thing that talks to the GPU.

---

## 4. What the kernel provides (and it's nothing graphical)

The complete list of kernel support required for the entire graphical stack:

| Need | Existing kernel mechanism | Chapter |
|---|---|---|
| Framebuffer / GPU MMIO access | Frame capabilities with uncached/WC attributes | 06, 11 |
| GPU/display interrupts | `IRQHandler` + `Notification` | 04, 11 |
| DMA for command buffers and scanout | IOMMU-backed DMA capabilities | 11, 15 |
| Buffer sharing between client and compositor | Frame capabilities passed over IPC | 09 |
| Event delivery | Endpoints, notifications, rings | 08 |
| Frame pacing / vblank timing | Timer capabilities, TSC-deadline | 04, 14 |
| Priority for the compositor | Scheduling contexts | 14 |

**Zero new kernel objects. Zero new syscalls.** That's the test that the
microkernel decomposition is real, and it's worth stating as a CI check:

```sh
# must return nothing
grep -rniE 'window|surface|framebuffer|composit|render|font' kernel/ include/nyx/
```

(The bootloader's early framebuffer for panic output is the one exception, and it
should live in `arch/` and be disabled once the display server takes over. Even
then: keep it, because a kernel panic must be visible on a machine with no serial
port.)

---

## 5. Headless is not a mode, it's the default

You raised this and it deserves to be an architectural rule rather than a
configuration option:

> **The system boots, runs, and is fully usable with no graphical component
> started. The graphical stack is a set of components that can be launched
> later, by anyone with the right capabilities, and killed without affecting
> anything else.**

How you enforce it:

1. **The root task's manifest decides.** Chapter 10 §8 has the root task
   bootstrapping from a manifest. A headless server profile simply doesn't list
   the display driver, compositor, or input server. Nothing else changes. No
   `#ifdef`, no build variant.
2. **No component may depend on the display server to start.** The dependency
   graph (Chapter 11 §2) puts the graphical stack at a *high* level, so nothing
   below it can call into it. Enforced by capability distribution: components
   below simply don't hold the capability.
3. **The console is not the display.** Chapter 16's console is a serial/virtual
   terminal component. A graphical terminal emulator is a *client* of the display
   server, not a replacement for the console. This keeps the "boot to a shell over
   serial and debug the compositor" workflow working forever, which you will need
   constantly.
4. **CI runs headless, always**, plus a separate job with a virtual display
   (§5.1). The headless job is the one that gates merges.
5. **Test it for real**: a KTEST-equivalent integration test that boots the
   headless profile, runs the full test suite, and asserts that no display,
   input, or GPU component was ever started.

This is exactly the property that makes Linux usable on servers, and it's usually
achieved there by accident and convention. Here it's achieved by the dependency
graph, which means it can't rot.

### 5.1 The virtual display, which you should build first

Before any real hardware: a display driver backend that renders into an ordinary
memory buffer and writes PNGs (or streams to a socket).

Reasons this is the right first move:

- The compositor, input routing, window API, and toolkit can all be developed and
  tested with **no GPU, no modesetting, and no hardware knowledge whatsoever**.
- It makes the graphical system **testable in CI**: render a scene, compare
  against a reference image, fail on diff. Chapter 18's harness extends to this
  directly.
- It makes bugs **reproducible**, because there's no hardware timing involved.
- It's the foundation for remote display later (§6), for free.

Build the backend interface first, with two implementations — `virtual` and
`framebuffer` — and only add real GPU support once the whole stack above works.

---

## 6. Network transparency, done deliberately

X11 made remoting a core protocol feature and paid for it forever. Wayland
omitted it and produced a decade of "how do I do remote desktop" bug reports.
Both are wrong for the same reason: they treated it as a binary property of the
protocol.

The right framing: **remoting is a compositor backend and an input source, not a
protocol feature.** Because clients hand over buffers and receive events, a
compositor that encodes its output and receives synthetic input is a *different
backend*, not a different protocol. That gets you:

- local display,
- virtual display for tests,
- remote display over a network (buffer encode + input injection),
- recording,
- and nested compositors (a compositor as a client of another compositor, which
  is how you get a window manager inside a window),

from one interface with no protocol changes. The capability model then makes the
authority explicit: a remote-display component needs a capability to a display
*output* and to inject input, and giving it that is a visible, revocable act —
unlike X11, where connecting is enough.

---

## 7. What "novel" could mean here

The graphical stack is, honestly, the part of modern OS design with the most
unexploited room. A short list to keep in mind while reading the next five
chapters — Chapter 26 develops them:

1. **Capability-secured UI**: screenshot, input injection, and window enumeration
   as explicit, revocable, auditable capabilities rather than "the app has
   permission". Then: can you *prove* an application cannot observe another's
   input?
2. **A single retained scene description shared from app to scanout**, with no
   re-rasterization at each layer — currently a browser rasterizes, a toolkit
   rasterizes, and a compositor composites three times over.
3. **End-to-end latency as a first-class, measured, budgeted quantity** —
   connected to Chapter 14's real-time work. Almost no desktop system treats
   input-to-photon latency as a schedulable resource with a deadline.
4. **Zero-copy from application to scanout**, using Chapter 15's machinery, with
   hardware planes so composition is often *free*.
5. **Deterministic, reproducible UI** — the virtual display plus Chapter 13's
   record/replay makes "replay this session and diff the frames" possible, which
   would be a genuinely better testing story than anything shipping.
6. **A restartable compositor.** Chapter 11's reincarnation server plus retained
   scene state held outside the compositor means a compositor crash is a
   half-second flicker, not a lost session. No mainstream system does this.

---

## 8. Verification

At this stage there's nothing to run, but there is something to write. Produce
`docs/display-architecture.md` containing:

- [ ] The five responsibilities (§1) and which component owns each.
- [ ] Your answer to the three questions in §1.1, with reasoning.
- [ ] The component/dependency diagram, showing where it sits in Chapter 11's
      level graph, and the capability each component holds.
- [ ] The explicit statement of the headless rule and how it is enforced.
- [ ] The list of things you are deliberately *not* doing (server-side drawing,
      network transparency in the protocol, synchronous cross-process messages,
      global window enumeration) — with one sentence each on why.

That last item is the most valuable, because in two years you will be tempted by
every one of them.

---

## 9. Exercises

1. Write the sentence "in X11, a screenshot tool and a keylogger use the same
   API" as a precise statement about the protocol, then find the equivalent
   statement for Win32, Wayland, and your design.
2. Take five Win32 APIs you consider well-designed and five you consider badly
   designed. For each of the bad ones, determine whether the flaw is in the
   *model* or in the *security/synchrony*. This is the argument of §2.3; test it.
3. Read Haiku's `app_server` architecture documentation and Fuchsia's Flatland
   design doc. Write a page on where they disagree and who you think is right.
4. Design the headless-profile manifest and the graphical-profile manifest for
   your root task. They should differ only by a list of components and
   capabilities.
5. **Argue the other side:** make the strongest case that Wayland's minimalism is
   correct and that Nyx's richer window API will become the next legacy burden.
   What would you need to do to avoid that fate? (Hint: versioned interfaces,
   Chapter 17.)

---

Next: [22 — The compositor: buffers, frames, and presentation](22-compositor.md)
