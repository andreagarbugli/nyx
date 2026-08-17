# 23 — Input: events, focus, and why input is a security boundary

> Goal: get keystrokes and pointer motion from a device to the right window, with
> low and *bounded* latency, and with a security model in which keylogging is not
> an API. Input is the part of a graphical system where the security argument is
> sharpest, because the thing being routed is literally the user's passwords.

---

## 1. Theory: input is authority flowing backwards

Everything else in the system is about a program acting on the world. Input is the
world acting on programs — and *which* program receives an input event is a
security decision made on the user's behalf, dozens of times per second, by
whatever component owns focus.

Three properties any input system must have, and which X11 has none of:

1. **Directedness.** An event reaches exactly the intended recipient.
2. **Non-observability.** No other client learns that the event occurred, its
   contents, or its timing.
3. **Attributability.** The recipient can tell a real user action from a
   synthesized one, and can find out who synthesized it.

That third one matters more than it sounds. "Did the user click this button, or
did something click it for them?" is the question underlying clickjacking,
UI redress attacks, and the entire reason mobile OSes restrict overlays. A system
that cannot answer it cannot make any UI-based security decision — including
"grant this app camera access", which is exactly the dialog an attacker wants to
click for you.

### 1.1 What existing systems do

| System | Directed | Non-observable | Attributable |
|---|---|---|---|
| X11 | Yes, nominally | **No** — `XGrabKeyboard`, `XQueryKeymap`, any client can listen | No — `XTest` events are indistinguishable |
| Win32 | Yes | **No** — `SetWindowsHookEx`, `GetAsyncKeyState` | Partially — `LowLevelKeyboardProc` sees `LLKHF_INJECTED`, and `SendInput` sets it. A real attempt, bolted on late. |
| Wayland | Yes | **Yes** — no protocol to observe other clients' input | Partially — portals gate injection |
| Android | Yes | Yes | Yes — `FLAG_WINDOW_IS_OBSCURED`, overlay restrictions, and it *still* took years of exploits to get there |
| macOS | Yes | Gated by an accessibility permission prompt | Partially |

Wayland got this right by omission — there is no API, so there is no attack. But
omission means screen readers, automation, remote desktop, and hotkey daemons all
became special cases requiring a portal, a permission dialog, and a lot of
argument. **We can do better than "you can't": we can do "you can, if you hold the
capability."** That's the whole point of Chapter 09.

---

## 2. The pipeline

```
device (USB HID / PS2 / virtio-input)
   │  IRQ → Notification (Ch. 04, 11)
   ▼
device driver         — decode the transport, emit raw events
   │  ring (Ch. 15)
   ▼
input server          — normalize, apply keymap, accelerate pointer,
   │                    gesture-recognize, timestamp
   ▼
compositor            — hit test against the scene (Ch. 22 §4)
   │
   ▼
shell (policy)        — focus rules, grabs, hotkeys, "which client?"
   │
   ▼
client                — event queue → window procedure (Ch. 24)
```

Five hops. That sounds expensive and it isn't: each is a same-core IPC with no
kernel allocation (Chapter 08 §7), so the whole chain is a few microseconds. The
budget that matters is in §7, and it is dominated by the *display*, not the
routing.

Note the split between compositor (mechanism: what's under the cursor) and shell
(policy: who gets focus). Same argument as Chapter 21 §3.

---

## 3. The event

```c
/* include/abi/input.h */
struct input_event {
    uint32_t size;
    uint32_t type;            /* KEY, POINTER_MOTION, BUTTON, SCROLL, TOUCH, ... */
    uint64_t time_ns;         /* device timestamp, monotonic; NOT arrival time */
    uint32_t device_id;
    uint32_t flags;           /* INPUT_SYNTHETIC, INPUT_REPEAT, ... */
    uint32_t seq;             /* per-device, monotonic, gapless */
    union {
        struct { uint32_t scancode, keysym, modifiers; uint8_t state; } key;
        struct { int32_t dx, dy; int32_t x, y; } motion;   /* both! see §3.2 */
        struct { uint32_t button; uint8_t state; } button;
        struct { int32_t dx, dy; uint32_t source; } scroll;
        struct { uint32_t id; int32_t x, y; uint32_t pressure; } touch;
    };
};
```

Design notes that are easy to get wrong:

**3.1 Timestamps come from the device, not the receiver.** The event carries when
the *hardware* saw it. Every latency measurement in the system depends on this,
and re-stamping at each hop destroys the information you most need. If the
transport can't provide it, stamp it in the driver's interrupt handler, at the
earliest possible moment, and mark it estimated.

**3.2 Pointer events carry both relative and absolute coordinates.** Games and
3D applications need unaccelerated relative motion; everything else needs
accelerated absolute position. Carrying both avoids the "pointer lock" protocol
mess. Also send the *unaccelerated* delta separately if you apply acceleration —
otherwise an application that wants raw input can't recover it.

**3.3 `seq` is gapless per device.** A client that sees a gap knows it lost
events, which is infinitely better than silently mis-tracking button state. This
matters most for the ring transport (§4).

**3.4 Key events carry scancode *and* keysym.** The scancode is physical (useful
for games: "the key where WASD is"), the keysym is logical (useful for text).
Systems that only provide one make the other impossible to reconstruct.

**3.5 `INPUT_SYNTHETIC` is set by the input server, never by the sender**, and
records *which capability* was used to inject. A client can then refuse to act on
synthetic input for security-sensitive actions — the attributability property from
§1. Make this queryable: `event_origin(event) -> injector_id`.

---

## 4. Transport: rings, not messages

Input is high-frequency (a 1000 Hz mouse, a 8000 Hz gaming mouse, multitouch with
ten contacts) and latency-critical. Chapter 15's decision rule applies: use a
**ring**, not an IPC message per event.

- Driver → input server: SPSC ring, notification on non-empty.
- Input server → compositor: SPSC ring.
- Compositor → client: SPSC ring per client, plus a notification.

The client's event queue (Chapter 24) *is* the consumer end of that ring. So
`GetMessage` becomes: drain the ring; if empty, wait on the notification. That's
one syscall when idle and **zero syscalls** when events are already queued — which
is exactly the property that makes a message-pump architecture cheap.

**Coalescing** is essential and must be done deliberately. If a client is slow,
motion events pile up. The right behavior:

| Event type | If the client is behind |
|---|---|
| Pointer motion | **Coalesce** — replace with the latest position, accumulate relative deltas. Never deliver 200 stale motion events. |
| Button, key | **Never coalesce.** Every press and release must be delivered, in order. Dropping a key-up leaves a stuck modifier. |
| Scroll | Accumulate deltas, preserve discrete detents separately |
| Touch | Coalesce motion within a contact; never drop down/up |

Note this is the same NAPI-style "the consumer must drain" discipline as Chapter
04 §8, and the same backpressure question as Chapter 15. If a client's ring is
full of key events, the answer is **not** to drop them and **not** to block the
input server — it's to stop delivering to that client and mark it unresponsive,
which is a shell policy decision. Write it down.

---

## 5. Focus, hit testing, and grabs

**Hit testing** is a walk of the retained scene (Chapter 22 §4), depth-first,
front to back, testing the cursor against each node's `input_region`. The
`input_region` is deliberately separate from the node's bounds: a window with a
drop shadow or rounded corners must not accept clicks in the transparent parts,
and only the client knows where its input region is.

**Focus** is policy, and lives in the shell:

| Model | Where |
|---|---|
| Click to focus | Windows, macOS default |
| Focus follows mouse | X11 traditional |
| Focus follows mouse with auto-raise | Chaos |
| Explicit / tiling | i3, sway |

The shell holds a capability that lets it set focus; nothing else does. A client
cannot steal focus, which deletes the entire "focus-stealing" nuisance *and* the
security problem of a window grabbing focus just before you type a password.

**Keyboard grabs** (a menu that must receive all keys until dismissed) are the
dangerous primitive. X11 lets any client grab the keyboard globally, which is
indistinguishable from a keylogger. Nyx's version:

- A grab is scoped to a window subtree the client already owns.
- A *system-wide* grab requires a capability minted by the shell.
- The shell must be able to break any grab unconditionally (the "a client grabbed
  the keyboard and hung" failure mode, which is a real and infuriating X11 bug).
- There is a hard-coded, un-grabbable **secure attention key** (§6.2).

---

## 6. The security model

### 6.1 Capabilities, enumerated

Every dangerous input capability, named, so it can be reasoned about and granted
deliberately:

| Capability | Grants | Who normally holds it |
|---|---|---|
| `InputSink(window)` | Receive events routed to this window | Every client, for its own windows |
| `InputInject` | Synthesize events (marked synthetic) | Remote desktop, test automation, accessibility |
| `InputObserveGlobal` | See all input regardless of focus | **Nobody by default.** Screen readers, macro recorders — granted per-session, revocably, visibly |
| `InputGrabGlobal` | Take all input until released | Screen lockers, the shell |
| `FocusControl` | Set focus | The shell only |
| `HotkeyRegister(combo)` | Receive a specific combination globally | Granted per-combination, not blanket |

That last row is the good design that nobody ships: instead of "this app can see
all keys so it can implement its hotkey", the app receives a capability for
`Super+E` specifically, and nothing else. Global hotkeys stop being a privacy
hole. Register-per-combination also makes conflicts detectable and resolvable by
the shell.

**The property you can now state and test:** a client with only
`InputSink(its own windows)` cannot observe any input directed elsewhere. Not by
timing, not by polling, not by any API — because there is no other API. Write the
test in §8.

### 6.2 The secure attention sequence

One key combination that is guaranteed to be delivered to a trusted component and
cannot be intercepted, grabbed, or observed by anyone. This is Windows'
Ctrl+Alt+Del and it exists for exactly one reason: it lets the user reach a
trusted UI without an attacker being able to fake it.

Handle it in the **input server**, before routing, unconditionally. It is the one
piece of policy that isn't the shell's. Use it for: the lock screen, the "what is
running" viewer, and the capability-grant dialog (§6.3).

### 6.3 Trusted UI and clickjacking

When a component asks for a dangerous capability, *something* must ask the user.
That dialog must be unspoofable, which requires:

1. Rendered by a trusted component, in a way clients cannot draw over or
   position under (the compositor guarantees a trusted overlay layer that no
   client node can enter).
2. Input to it cannot be synthesized (`INPUT_SYNTHETIC` events are rejected).
3. The window under it cannot be moved or changed while it's up.
4. Ideally reached by, or visually anchored to, the secure attention key.

This is where the capability model and the input model meet, and it's the most
security-relevant UI in the system. Design it explicitly; don't let it emerge.

### 6.4 Timing side channels

Even with perfect routing, a client can learn about input it doesn't receive:
frame timing changes when another window animates, CPU contention correlates with
typing, and the compositor's presentation timing is observable. Keystroke timing
alone is enough to substantially narrow down typed text — this is a well-studied
result, not a theoretical worry.

Mitigations are the same as Chapter 13 §B1: don't give clients precise timing they
don't need, consider quantizing presentation feedback, and be honest in
`docs/security.md` that this channel exists and is not closed.

---

## 7. Latency

The budget, on a 60 Hz display, for a click that changes something on screen:

| Stage | Typical | Notes |
|---|---|---|
| Device → host | 1–8 ms | USB polling interval. **The largest term you don't control.** 1000 Hz devices help. |
| IRQ → driver → input server | < 50 µs | Chapter 08 IPC; negligible |
| Routing and hit test | < 50 µs | Negligible |
| Client wakeup → render | 1–10 ms | Scheduling + the app's own work |
| Compositor waits for vblank | 0–16.7 ms | The pacing decision (Chapter 22 §6) |
| Composition | 0.5–3 ms | |
| Scanout + panel | 5–20 ms | Physics and the panel's own processing |

Total: 15–60 ms. The interesting observation is that **the routing and hit
testing — the part a microkernel supposedly makes slow — is under 1% of the
budget.** The costs are USB polling, frame pacing, and the panel. This is worth
measuring and publishing, because "microkernel IPC makes the UI laggy" is an
assumption nobody has actually tested on modern hardware, and the numbers say it's
false by two orders of magnitude.

Where you can actually win:

- **Late client wakeup** (Chapter 22 §6): saves up to a full frame.
- **Direct scanout / planes**: removes a composition pass.
- **VRR**: removes the wait-for-vblank term entirely.
- **Deadline propagation** from compositor to client: makes the client's render
  land on time rather than on average.
- **Input prediction**: extrapolate pointer position forward by the known
  latency. Cheap, effective for dragging and drawing, and mostly unexploited
  outside of stylus code paths.

Instrument every stage. Chapter 18's harness plus the timestamps from §3.1 give
you an end-to-end histogram — build the tooling that prints it as a waterfall for
a single event, because that's the diagram that tells you where the time went.

---

## 8. Verification

| Test | Asserts |
|---|---|
| `input_ordering` | Events arrive in `seq` order with no gaps |
| `no_stuck_modifiers` | Fuzz key up/down sequences including drops; assert modifier state recovers |
| `coalescing_preserves_buttons` | Under extreme load, every press/release is delivered |
| `client_cannot_observe_foreign_input` | Client A types; client B (without `InputObserveGlobal`) receives nothing. **The headline security test.** |
| `synthetic_is_marked` | Injected events always carry the flag and the injector id |
| `grab_is_breakable` | Client grabs and hangs; shell breaks it; system remains usable |
| `focus_cannot_be_stolen` | Client attempts to set focus; assert `ERR_PERM` |
| `hit_test_matches_render` | Property test: for random scenes and points, hit test agrees with which node's pixels are on top |
| `sak_always_delivered` | With a client grabbing everything, the secure attention key still reaches the trusted component |
| `latency_budget` | End-to-end input→present p99 under a threshold, tracked in CI |

That `hit_test_matches_render` test deserves emphasis: hit testing and rendering
are two implementations of the same geometry, and they drift. Property-testing one
against the other catches a class of "the button doesn't work near the edge" bugs
that are otherwise found by users.

Also: replay. Record an input event stream to a file and replay it into the input
server. Now UI tests are deterministic (combined with Chapter 22's virtual
backend and reference images, you get "replay this session, diff every frame"),
and bug reports can include the exact input sequence.

---

## 9. The things people forget

- **Key repeat is a client-side or input-server-side timer, not a device
  feature.** Decide where it lives, and make sure a repeat is marked so text
  fields and games can treat it differently.
- **Modifier state must be re-synchronized** whenever focus changes or a client
  starts, or the user's Alt-Tab leaves Alt stuck down in the newly focused app.
  Send a "here is the current modifier state" event on focus-in. Everyone hits
  this bug.
- **Input methods (IME)** for CJK and others are not an add-on. A keystroke may
  produce no text, or text later, or a candidate window. Design the API so a text
  event is separate from a key event *from the start*, or retrofitting IME will be
  a rewrite. This is the single most commonly deferred and most painful-to-add
  piece of input design.
- **Accessibility** needs the scene structure (Chapter 22 §4) and a scoped
  observation capability. Designed in, it's clean; bolted on, it becomes the
  screen-scraping-with-full-privileges mess it is on most platforms.
- **Multitouch requires per-contact tracking with stable ids**, and gestures are a
  state machine that belongs in the input server, not in every application.
- **Tablet/stylus** have pressure, tilt, and hover, and are not mice. Leave room
  in the event union.
- **Hotplug**: devices appear and disappear. The input server must handle it
  without dropping the events that were in flight.

---

## 10. Exercises

1. Implement the driver → input server → compositor ring chain with a virtio-input
   device under QEMU. Measure the time from IRQ to hit test.
2. Write the `client_cannot_observe_foreign_input` test. Then try to defeat it —
   look for timing channels, resource-contention channels, and API leaks. Write
   down what you find in `docs/security.md`.
3. Implement per-combination hotkey registration. Design what happens when two
   clients request the same combination.
4. Build the latency waterfall tool: given one input event, print the timestamp at
   every stage through to vblank. Use it to find your worst stage.
5. Implement input recording and replay, then write one UI test using it plus
   reference images.
6. Implement pointer prediction and measure whether it actually improves perceived
   drag latency. Be honest about the result.
7. **Argue the other side:** Wayland's answer to `InputObserveGlobal` is "there is
   no such thing, use a portal". Make the case that a revocable capability is
   *worse* than no API at all, and decide what would have to be true for that
   argument to win.

---

Next: [24 — The window system API](24-window-api.md)
