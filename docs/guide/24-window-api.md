# 24 — The window system API

> Goal: design the API applications actually call. This is where Chapter 21's
> thesis gets tested: keep Win32's window-object-and-message-queue model, replace
> its global namespace with capabilities and its synchronous cross-process calls
> with asynchronous ones, and see whether the result is still as pleasant to
> program against.

---

## 1. Why the API is the hard part

The compositor is a systems problem with a clear correctness criterion. The API
is a *design* problem with no criterion at all except "do people write good
programs with it, for thirty years, without the API becoming a tarball of
compatibility hacks."

The evidence about what works:

- **Win32 survived 35 years** of hardware revolution — 16-bit to 64-bit, software
  to GPU compositing, 96 DPI to 300 DPI — without breaking applications. Because
  the API expressed *intent* (`InvalidateRect`, `MoveWindow`, "handle this
  message") rather than mechanism.
- **X11's core API died in place.** Because it expressed mechanism (`XDrawLine`
  into a server-side drawable) and the mechanism became wrong.
- **Wayland declined to have one**, and got a decade of toolkit fragmentation.
- **The DOM won** the application-developer population, decisively, with retained
  declarative structure and automatic layout.

So: express intent, retain structure, version everything (Chapter 17), and
resist putting anything hardware-shaped in the interface.

---

## 2. The object model

Everything is an object reached by a capability. There is no global name for
anything.

| Object | Is | Held by |
|---|---|---|
| `Display` | A connection to the compositor, plus a client-scoped namespace | Every graphical client |
| `Window` | A top-level or child window: geometry, subtree, event target | Its creator |
| `Surface` | The buffer content of a window (Chapter 22) | Its window's owner |
| `EventQueue` | The consumer end of the event ring (Chapter 23 §4) | A thread |
| `Output` | A monitor: mode, DPI, colour space, position | Read-only caps to clients; control to the shell |
| `Cursor` | A named or custom pointer image | Clients, scoped to their windows |
| `Clipboard` | A transfer session, *not* a global store (§7) | Created per-transfer |

Compare the Win32 equivalents: `HWND`, `HDC`, the thread message queue,
`HMONITOR`, `HCURSOR`, and the global clipboard. The shapes match — deliberately.
The differences are that each is a capability rather than a globally-valid
integer, and that `Window` and `Surface` are separated (Win32 conflated window and
drawing context in ways that constrained it later).

**There is no `FindWindow`, no `EnumWindows`, no `GetForegroundWindow`.** Not
"they require a permission" — they do not exist. A client's window graph is its
own. The shell, which needs the global view, holds a `WindowRegistry` capability
that nothing else does.

---

## 3. The event loop

The single best thing about Win32, kept nearly verbatim:

```c
struct nyx_event ev;
while (nyxwin_next_event(queue, &ev, TIMEOUT_INFINITE) == OK) {
    nyxwin_dispatch(&ev);      /* calls the target window's procedure */
}
```

and the window procedure:

```c
static result_t my_window_proc(window_t w, const struct nyx_event *ev, void *ctx) {
    switch (ev->type) {
    case EV_PAINT: {
        struct paint p;
        nyxwin_begin_paint(w, &p);          /* p.damage = the invalid region */
        draw(&p, p.damage);
        nyxwin_end_paint(w, &p);            /* submits buffer + damage + fence */
        return HANDLED;
    }
    case EV_KEY:      return on_key(ctx, &ev->key);
    case EV_RESIZED:  return on_resize(ctx, ev->resized.w, ev->resized.h);
    case EV_CLOSE:    quit(); return HANDLED;
    default:          return nyxwin_default_proc(w, ev, ctx);
    }
}
```

Why this shape is right:

- **One queue, one loop, one place where an application's control flow lives.**
  Input, resize, paint, timers, clipboard offers, IPC replies, and
  application-defined events all arrive the same way, in order.
- **`nyxwin_default_proc` is the extension point.** Default behaviour lives in
  one place, and an application overrides only what it cares about. This is what
  made Win32 programs short.
- **It composes with the rest of Nyx**: the queue is backed by Chapter 23's ring
  plus a notification, so `next_event` with a full ring makes **zero syscalls**,
  and with an empty one makes exactly one wait. And because Chapter 08 binds
  notifications to endpoints, the *same* wait can cover window events, IPC
  replies from other servers, and timers. There is no `select`, no `epoll`, no
  "integrate the toolkit loop with the async runtime" problem — the thing that
  makes GUI programming painful on every existing platform.

That last point deserves emphasis: **the fact that a single wait primitive covers
every event source is a direct consequence of Chapter 08's design**, and it makes
the GUI event loop composable in a way that no mainstream system manages.

### 3.1 Where Win32 went wrong, and what we do instead

| Win32 | Problem | Nyx |
|---|---|---|
| `SendMessage` cross-process | Synchronous, deadlocks, one hung app hangs others | Not offered. Cross-client communication is ordinary IPC with a deadline. |
| A window belongs to a thread that must pump | Couples UI structure to threading; a busy thread freezes the window | A window belongs to a *queue*; queues can be moved between threads; the compositor never blocks on a client |
| `AttachThreadInput` | Shared mutable input state between processes | Doesn't exist |
| `PostMessage` to any `HWND` | Ambient authority | You may only post to a window you hold a capability for |
| `WM_TIMER` in the same queue with low resolution | Fine, actually | Kept — timer capabilities (Chapter 04) deliver into the same queue |

**The unresponsive-client rule**, stated plainly: the compositor never waits for a
client. If a client stops draining its ring, it stops receiving events (with
coalescing, Chapter 23 §4) and its last-submitted buffer keeps being displayed.
The shell may then decide to show it as unresponsive. Nothing else in the system
is affected. This single rule eliminates the "the whole desktop froze because one
app hung" experience, which is *still* a normal occurrence on shipping systems.

---

## 4. Painting: damage-driven, retained where it counts

Keep `InvalidateRect`/`WM_PAINT`. It was right in 1985 and it's still right:

```c
nyxwin_invalidate(w, &rect);          /* accumulates into the window's invalid region */
/* ... later, coalesced, at a good time for the frame schedule: */
EV_PAINT with ev->paint.damage = the accumulated region
```

Properties:

- The application draws only what changed, because the system *tells it* what
  changed. No application-side dirty tracking, no full redraws by default.
- Invalidations coalesce, so a hundred `invalidate` calls produce one paint.
- **The system decides when to paint**, which is what lets the compositor pace
  frames (Chapter 22 §6) and wake the client as late as safely possible. An
  application that renders on its own schedule cannot participate in that.

For continuously-animating clients (games, video), offer the other mode
explicitly:

```c
nyxwin_request_frame(w);   /* "call me at the next good time to render" */
→ EV_FRAME with { target_present_time_ns, last_present_time_ns, refresh_ns }
```

This is the callback-driven mode every modern system converged on
(`requestAnimationFrame`, `Choreographer`, `CVDisplayLink`, Wayland's frame
callbacks). Giving the client the *target presentation time* rather than just "go
now" lets it animate against the time its frame will actually be seen, which is
the fix for the judder that plagues naive animation loops.

---

## 5. Layout, DPI, and coordinates

Get this right at the bottom or fight it forever.

1. **Logical coordinates everywhere in the API**, with a per-window scale factor.
   A window is 800×600 logical units; on a 2× display that's 1600×1200 pixels.
2. **Fractional scale factors are mandatory**, not a later feature. 1.25 and 1.5
   are the most common real-world settings. Integer-only scaling (Wayland's
   original design) was a mistake that took a decade to fix.
3. **Scale can change while a window exists** — dragged to another monitor,
   user changes settings. Send `EV_SCALE_CHANGED` and expect the client to
   re-render. Test it, because nobody does and it's always broken.
4. **The client renders at the exact pixel size given.** Never let the compositor
   scale a client's buffer as the normal path; it looks bad and wastes bandwidth.
   Scaling is the *fallback* for a client that hasn't re-rendered yet.
5. **Subpixel positioning must be expressible.** A window or node at x=100.5 is
   legitimate for smooth animation. Use fixed-point (24.8) or float in the
   geometry, not integers.

Layout itself — where do child widgets go — is a *toolkit* concern (Chapter 25
§6), not a window-system concern. Keep it out of this API. Win32 correctly kept
layout out of USER; the fact that every toolkit reinvents it is fine, because
that's a place where competition is healthy and the OS has no special knowledge.

---

## 6. Window lifecycle and roles

A top-level window isn't just a rectangle; the shell needs to know what *kind* it
is to place and decorate it:

```c
enum window_role {
    ROLE_TOPLEVEL,     /* an ordinary application window */
    ROLE_DIALOG,       /* modal or modeless, has a parent */
    ROLE_POPUP,        /* menu, tooltip: transient, dismissed by outside click */
    ROLE_UTILITY,      /* palette, toolbar */
    ROLE_FULLSCREEN,   /* wants an entire output; enables direct scanout */
    ROLE_OVERLAY,      /* requires a capability; notifications, IME candidates */
    ROLE_LAYER,        /* panels, docks, wallpaper — shell components only */
};
```

`ROLE_OVERLAY` and `ROLE_LAYER` are capability-gated because "draw on top of
everything" is exactly the primitive used for clickjacking (Chapter 23 §6.3).
Android learned this the hard way over several releases; start with it gated.

**Popup semantics are worth getting right**, because they're where every window
system has bugs: a popup is positioned relative to an anchor rectangle on its
parent, has a defined flip/slide behaviour when it would leave the screen, and is
dismissed atomically when input goes elsewhere. Specify the constraint-adjustment
rules explicitly (Wayland's `xdg_positioner` is a good model of what this needs to
express) rather than letting each toolkit guess.

**Decorations:** decide once and write it down. Server-side decorations give
consistency and let the shell decorate unresponsive windows; client-side gives
applications design freedom and integrates the titlebar with content. The
long-running Wayland argument happened because *neither* was mandated.
Recommendation: **server-side by default, client-side opt-in with a declared
input region for the drag area** — so the shell can always move and close a window
even if the client is hung.

---

## 7. Clipboard and drag-and-drop as capability transfer

The clipboard is usually a global mutable store that any application can read at
any time. That's a privacy hole (background apps read passwords out of it) and it
doesn't fit our model at all.

Better, and it falls out naturally here:

1. The source client offers data by creating a **transfer object** and giving the
   compositor a capability to it, along with a list of available MIME types.
2. When the user pastes, the destination asks the compositor for the offer; the
   compositor mints a *one-shot, read-only* capability to the transfer object and
   hands it over.
3. The destination reads through that capability. It cannot read again later, and
   it never had access before the user acted.

Result: **paste requires a user action, structurally.** No polling, no background
reads, no clipboard managers-by-default (a clipboard manager becomes a component
holding an explicit, revocable capability — which is exactly right, since that's
what it *is*).

Drag-and-drop is the same machinery plus pointer tracking and a visual drag
image. Design them as one mechanism; they always end up sharing 90% of the code
anyway.

---

## 8. The API surface, sketched

Keep it small. This is the whole thing:

```c
/* connection */
display_t nyxwin_connect(void);
queue_t   nyxwin_queue_create(display_t);

/* windows */
window_t  nyxwin_create(display_t, const struct window_attr *);  /* versioned struct */
err_t     nyxwin_destroy(window_t);
err_t     nyxwin_set_title(window_t, str);
err_t     nyxwin_set_role(window_t, enum window_role, const struct role_attr *);
err_t     nyxwin_move_resize(window_t, struct rect);
err_t     nyxwin_set_input_region(window_t, const struct region *);
err_t     nyxwin_show(window_t), nyxwin_hide(window_t);

/* painting */
err_t     nyxwin_invalidate(window_t, const struct rect *);
err_t     nyxwin_begin_paint(window_t, struct paint *);
err_t     nyxwin_end_paint(window_t, struct paint *);
err_t     nyxwin_request_frame(window_t);

/* events */
err_t     nyxwin_next_event(queue_t, struct nyx_event *, uint64_t timeout_ns);
result_t  nyxwin_dispatch(const struct nyx_event *);
result_t  nyxwin_default_proc(window_t, const struct nyx_event *, void *);
err_t     nyxwin_post(window_t, uint32_t type, uintptr_t a, uintptr_t b);

/* outputs, cursor, clipboard, timers ... */
```

About forty functions total. Win32's USER exports over a thousand, most of which
are dialog boxes, controls, and thirty years of variants — the *core* is about
this size, which is the point.

Chapter 17's rules apply throughout: versioned attribute structs with a leading
`size`, zero as the valid default, append-only evolution, `MUST_USE` on
everything fallible, and `str` rather than `char *` (Appendix A).

### 8.1 Generate it

The client library is a thin layer over IDL-generated stubs (Chapter 10 §7). The
`.idl` file *is* the protocol specification, and it produces the C client, the
server dispatcher, the serialization, the version negotiation, and — if you want
Rust or another language later — those bindings too, for free. Do not hand-write
the wire format.

---

## 9. Verification

| Test | Asserts |
|---|---|
| `no_global_window_lookup` | Grep the ABI headers: no function takes a window id that isn't a capability |
| `zero_syscall_drain` | With N events queued, draining them makes no syscalls (count via a debug counter) |
| `invalidate_coalesces` | 1000 invalidations produce ≤ 1 paint per frame |
| `paint_damage_is_correct` | Damage passed to the client, when rendered, produces the same result as a full redraw (the Chapter 22 §8 test, extended into the client) |
| `hung_client_does_not_block` | A client that stops pumping affects nothing else; assert the compositor's frame rate is unchanged |
| `scale_change_handled` | Move a window between outputs of different scale; assert re-render at the right pixel size |
| `popup_dismissal` | Click outside; assert the popup closes and the click is *not* delivered to the underlying window (or is — decide, then test it) |
| `clipboard_requires_action` | A client that never receives a paste event cannot read clipboard data |
| `abi_stability` | Old client binary against new compositor: still works. Keep old binaries in the repo. |

That last one is the discipline that made Win32 last. Keep compiled test clients
from six months ago and run them in CI. The day one breaks, you learn about it
immediately instead of from a user in 2029.

---

## 10. Exercises

1. Write the smallest possible complete application: create a window, paint a
   rectangle, quit on close. Count the lines. It should be under 40. If it's
   over 80, the API is wrong.
2. Write the same program against raw Xlib, against Wayland with `wl_shell`, and
   against Win32. Compare the line counts and, more importantly, the number of
   concepts you had to learn.
3. Implement `nyxwin_next_event` and verify the zero-syscall drain with a counter.
4. Implement the clipboard transfer model and write the test that a background
   client cannot read the clipboard.
5. Take a Win32 program from a 1995 book and port it. Note every place the API
   shapes don't map — those are your design decisions showing.
6. Design the popup positioning constraint rules and test them at every screen
   edge and corner.
7. **Argue the other side:** the DOM's retained, declarative, auto-laid-out model
   beat the imperative message-loop model in the market by an enormous margin.
   Make the case that Nyx's window API should be declarative instead, and sketch
   what that would look like on top of Chapter 22's scene graph. (This is a real
   design fork; Chapter 26 §7 picks it back up.)

---

Next: [25 — Rendering, text, and the GPU](25-rendering-and-gpu.md)
