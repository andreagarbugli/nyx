# 32 — Tracing and instrumentation

> Goal: an always-on, low-overhead, unified event stream covering the kernel and
> every userspace component, with **causal chains reconstructed across IPC** — so
> that "why did this keystroke take 80 ms?" has a mechanical answer rather than a
> theory.
>
> Chapter 18 covers testing. This is the production instrument: it runs in
> release builds, all the time, and is the first thing you look at when something
> is slow or wrong.

---

## 1. Why a multi-server OS can do this better

In a monolithic kernel, a user action becomes a syscall, then an opaque descent
through subsystems joined by function calls. Reconstructing causality means
inferring it: `perf` gives you samples, `ftrace` gives you function entries, and
you correlate by hand.

In Nyx, **the causal graph is the IPC graph, and IPC is already mediated by the
kernel.** A keystroke crosses driver → input server → compositor → shell → client
as five explicit, timestamped, kernel-observed messages. If each carries a
propagated trace id, you get a complete causal chain — the same thing distributed
tracing gives microservices, for the operating system itself.

Nobody has this. It's Appendix E §E15, it's cheap, and it's the single highest
value-per-line item in this chapter. §5 is the design.

---

## 2. Requirements

Write these down, because they eliminate most designs:

| Requirement | Consequence |
|---|---|
| Enabled in production, always | Overhead budget: **< 1–2%** with tracing on, ~0 with it disabled |
| No allocation, ever | Pre-allocated per-CPU / per-thread ring buffers |
| No locks on the write path | Per-CPU buffers, atomic reserve/commit |
| Bounded memory | Fixed rings; overwrite oldest (flight recorder) or drop newest |
| **Lossy, but honestly** | Count and report drops. A trace that silently loses events is worse than none. |
| Uniform kernel + userspace | One format, one clock, one tool |
| Comparable timestamps | One monotonic source everyone reads cheaply (Appendix D §2) |
| Analyzable offline | The kernel emits raw binary; **all interpretation is offline** |

That last principle is the one that keeps overhead low: **the write path does the
absolute minimum — reserve, store a few words, commit.** No formatting, no symbol
lookup, no filtering that can't be a single predicted branch. Everything else
happens in a tool on a workstation.

---

## 3. The event and the ring

### 3.1 Event format

```c
/* Fixed 8-byte header, variable payload. Everything little-endian, packed. */
struct trace_hdr {
    uint32_t  id      : 16;   /* event type; schema is in the metadata stream */
    uint32_t  len     : 8;    /* payload bytes, 0-255 */
    uint32_t  ctx     : 8;    /* context: kernel, irq, or component id (low bits) */
    uint32_t  tsc_lo;         /* low 32 bits of TSC; full value reconstructed offline */
};
/* payload follows: raw arguments, no tags, laid out per the schema */
```

Design notes:

- **32-bit timestamps.** A full 64-bit TSC per event is 8 bytes you don't need:
  the low 32 bits wrap every ~1.4 s at 3 GHz, and a periodic full-timestamp event
  (once per ms, or on every buffer page boundary) lets the offline tool
  reconstruct the high bits. Halves the size of a typical event.
- **No self-description in the stream.** Field names and types live in a
  *metadata* section emitted once, describing every event id. This is what LTTng's
  CTF does, and it's the right call — it makes events tiny and the format
  evolvable.
- **Fixed layouts per event id**, generated from a declaration (§4.1), so the
  writer is a few `mov`s and the reader is a struct cast.

Typical event: 8-byte header + 8–16 bytes of payload = **16–24 bytes**. At 100k
events/second that's ~2 MB/s, which a ring of a few MB per CPU absorbs for
seconds — enough for a flight recorder.

### 3.2 The ring

Per-CPU in the kernel, per-thread (or per-component) in userspace. The write path:

```c
/* Reserve/commit. Single writer per ring — no CAS needed if we disable
   preemption, which we must anyway to stay on this CPU's ring. */
static inline void *trace_reserve(uint32_t id, uint32_t len) {
    struct trace_ring *r = &this_cpu()->trace;      /* Ch. 12 §3 */
    if (__builtin_expect(!r->enabled, 0)) return NULL;

    uint32_t head = r->head;                         /* only we write head */
    uint32_t need = sizeof(struct trace_hdr) + len;
    if (head + need > r->size) { head = 0; r->wraps++; }   /* flight recorder */

    struct trace_hdr *h = (void *)(r->base + head);
    h->id = id; h->len = len; h->ctx = r->ctx;
    h->tsc_lo = (uint32_t)__rdtsc();
    r->head_pending = head + need;
    return h + 1;
}

static inline void trace_commit(void) {
    struct trace_ring *r = &this_cpu()->trace;
    atomic_store_explicit(&r->head, r->head_pending, memory_order_release);
}
```

The `release` store is what makes a concurrent reader (the consumer draining the
ring) see a fully-written event. This is the same discipline as Chapter 15's
rings, and the same correctness argument — which means the same model-checking
harness applies (Chapter 12 §9).

**Overwrite vs. drop.** Two modes, both needed:
- *Flight recorder* (overwrite oldest): always on, dumped after a fault. What you
  want by default.
- *Streaming* (drop newest, count drops): when a consumer is draining to disk or
  the network for a recorded session.

### 3.3 Draining

A **trace server** holds a capability to each ring (mapped read-only via a Frame
capability — Chapter 09), plus a notification for "ring is half full." It drains,
concatenates, and writes to storage or a socket. It's an ordinary component; it
can crash and restart without losing the rings, because the rings belong to the
components.

---

## 4. Tracepoints

### 4.1 Declaring them

Generate the writer, the metadata, and the offline schema from one declaration —
the same principle as the IDL (Chapter 10 §7):

```
# trace/events.def
event ipc_send    { u32 src_tid; u32 dst_tid; u64 badge; u16 label; }
event ipc_recv    { u32 tid; u64 badge; }
event sched_switch{ u32 prev; u32 next; u8 reason; }
event irq_enter   { u8 vector; }
event fault       { u64 addr; u32 tid; u16 err; }
event span_begin  { u64 trace_id; u32 span; u32 parent; u16 name_id; }
event span_end    { u64 trace_id; u32 span; }
```

The generator emits `trace_ipc_send(src, dst, badge, label)` as a static inline
that reserves 22 bytes and stores four fields — a handful of instructions.

### 4.2 Making disabled tracepoints free

An `if (r->enabled)` branch costs a load and a predicted-not-taken branch. That's
~1 cycle and it's usually fine. To get to *actually* zero, use **runtime code
patching** (Linux's static keys):

```c
#define TRACE_IF(name)                                    \
    __asm__ goto("1: .byte 0x0f,0x1f,0x44,0x00,0x00\n"    /* 5-byte nop */  \
                 ".pushsection .trace_patch,\"a\"\n"      \
                 ".quad 1b, %l[enabled], " #name "\n"     \
                 ".popsection\n"                          \
                 :::: enabled);                           \
    goto disabled; enabled:

/* Enabling a tracepoint rewrites the nop into `jmp enabled`. */
```

Patching requires care on SMP (other CPUs may be executing that byte range —
Intel's documented safe procedure, or stop-the-world at a quiescent point) but
gets you a truly zero-cost disabled tracepoint. **Do the branch first, measure,
and only do this if the measurement justifies it.** Chapter 33 is how you decide.

### 4.3 Where to put them

The permanent, always-compiled set — kept small deliberately:

| Area | Events |
|---|---|
| IPC | send, recv, reply, notify, block, wake |
| Scheduling | switch, enqueue, dequeue, preempt, idle enter/exit |
| Interrupts | enter, exit, IRQ→notification delivery |
| Faults | page fault, exception, capability lookup failure |
| Memory | untyped retype, frame map/unmap, TLB shootdown |
| Capabilities | invoke, revoke |
| Spans | begin, end (§5) |

That's roughly 25 events, and it's enough to reconstruct everything the kernel
did. Component-level tracepoints are the component's business, using the same
mechanism.

---

## 5. Causal tracing across IPC — the good part

### 5.1 The mechanism

Add two fields to the TCB (Chapter 07):

```c
struct tcb {
    ...
    uint64_t trace_id;      /* the request this thread is currently working on */
    uint32_t span_id;       /* this thread's current span within it */
};
```

**The kernel propagates them on IPC.** In `ipc_call`, the receiver's `trace_id`
is set from the sender's; on reply, the sender's is restored. That's two stores on
the IPC path — call it 2–4 cycles, and only when tracing is enabled.

Now:

- A trace id is minted at the *origin* of a request: an interrupt (a keystroke
  arrives), a timer, or a user action.
- It flows automatically through every component that touches the request, with no
  cooperation from any of them.
- Every event any component emits is tagged with the request that caused it.

**Reconstructing "where did the 80 ms go" is now a database query**, not an
investigation. Group events by trace id, sort by timestamp, and you have the
waterfall Chapter 23 §7 asked for — automatically, for every request, without
anyone instrumenting anything.

### 5.2 Spans

Spans give you the tree structure within a trace: a component emits
`span_begin(name)` on entering a phase and `span_end` on leaving. The parent is
whatever span was active. Generated IPC stubs should emit them automatically, so
every cross-component call is a span for free.

### 5.3 Sampling

Full tracing of every request is too much data at scale. Sample: mint a real trace
id for 1 in N requests, and a zero (= don't trace) for the rest. The decision is
made **once at the origin** and propagates, so a sampled request is traced
completely or not at all — which is the property that makes the data useful. This
is exactly what distributed tracing systems do, and the reasoning transfers
directly.

Add *tail sampling* later: trace everything into a short ring, and only persist
traces that were slow or errored. That's where the interesting requests are.

### 5.4 Across machines

The trace id crosses to another node in the IPC transport header (Chapter 28 §2).
Now the causal chain spans machines with no additional mechanism. The clock
problem is real — use PTP (Appendix D §2) and record per-node clock offset
estimates so the offline tool can correct, and never assume cross-node timestamps
are ordered without it.

---

## 6. Tracing authority is a capability

On Linux, "who may trace whom" is `ptrace_scope`, `perf_event_paranoid`, root,
and a pile of LSM hooks — because tracing is ambient and must be restricted after
the fact. Here it's the opposite:

| Capability | Grants |
|---|---|
| `TraceEmit(ring)` | Write events to your own ring. Every component has it. |
| `TraceRead(ring)` | Read another component's ring. The trace server holds these. |
| `TraceControl(component)` | Enable/disable tracepoints in a component |
| `TraceGlobal` | Read every ring including the kernel's. Held by one component. |

Consequences worth stating: a component cannot observe another's trace stream by
default; giving a profiler that access is explicit, visible, and revocable; and
the security review of "what can see my execution" is a manifest query (Appendix
E §E4). Tracing is normally a *massive* information leak — timing, addresses,
arguments — and here it's confined by the same mechanism as everything else.

Note the trace data itself is sensitive: it may contain addresses (defeating
KASLR) and timing (Chapter 23 §6.4). Don't put raw pointers in events; use ids.

---

## 7. Format and tooling

### 7.1 The wire format

Emit your own binary format. Structure:

```
[ magic + version ]
[ metadata: event schemas, string table, clock calibration, component names ]
[ packet: cpu/ring id, sequence, drop count, base timestamp, events... ]
[ packet ... ]
```

Per-packet drop counts are essential — a trace must be able to say "I lost 400
events here." Sequence numbers let the tool detect a missing packet.

Consider **CTF** (Common Trace Format) rather than inventing one: it's the LTTng
format, it's designed for exactly this (self-describing via a separate metadata
language, tiny events), and `babeltrace` already reads it. The cost is
implementing enough of the metadata language. Inventing your own is a day; CTF
buys you an existing ecosystem. Either is defensible — just make the choice
deliberately and write a converter regardless.

### 7.2 The offline tool

One tool, several outputs:

| Output | Consumed by | Good for |
|---|---|---|
| **Chrome Trace Event JSON** | `chrome://tracing`, Perfetto UI, Speedscope | Timeline of spans across components. **Start here** — it's a trivial JSON format and the viewers are excellent. |
| **Perfetto protobuf** | Perfetto UI | Same, but handles gigabyte traces and has a SQL query engine over the trace |
| **Folded stacks** | `flamegraph.pl`, Speedscope | Flame graphs (Chapter 33) |
| **pprof** | `go tool pprof` | Aggregated profiles |
| **CSV / Parquet** | Anything | Ad-hoc analysis, CI regression tracking |
| **Custom waterfall** | Your own viewer | The per-request view of §5.1 |

**Recommendation:** binary format → converter → Chrome Trace JSON on day one
(a few hundred lines of Python, and the Perfetto UI is genuinely good), then
Perfetto protobuf when traces get large enough that the JSON viewer struggles.
Perfetto's trace processor gives you SQL over your traces, which turns "what's the
p99 latency of the compositor's frame span, grouped by client" into a query.

### 7.3 The one custom view worth building

A **per-request waterfall**: given a trace id, one row per component, showing
running time, blocked time, and the IPC edges between them, with the critical path
highlighted. That's the diagram that answers "where did the time go," and no
existing tool draws it because no existing OS produces the data.

---

## 8. Dynamic instrumentation

Static tracepoints cover what you anticipated. For everything else:

**Safe in-kernel filters.** Chapter 15's safe extension mechanism (the eBPF
analogue) applies: attach a verified filter to a tracepoint that decides whether
to emit, or that aggregates in place (a histogram in a map) instead of emitting
raw events. Aggregation-at-source is the big win — "histogram of IPC latency by
destination" costs one map update per event instead of 20 bytes of trace data.

**Dynamic probes** (kprobes-style: patch an arbitrary instruction to trap into a
handler) are powerful and hazardous: instruction decoding, re-execution of the
displaced instruction, and interaction with preemption. Worth having eventually,
worth deferring. In a microkernel, much of what kprobes is used for on Linux is
covered by IPC tracing, because the interesting boundaries *are* IPC.

**Userspace probes.** A component can register its own tracepoints; the trace
server can enable them via `TraceControl`. Since components are small and
recompilable, static tracepoints cover userspace better here than USDT does on
Linux.

---

## 9. Overhead, measured

Do not guess. Measure with the harness from Chapter 33:

| Configuration | What to measure | Target |
|---|---|---|
| Tracing compiled out | Baseline | — |
| Compiled in, all disabled | Branch cost | < 0.2% |
| Compiled in, patched-nop, disabled | Should be exactly baseline | 0% |
| **Enabled tracepoint, per event** | **The hot path** | **< 50 cycles per event** |
| Everything enabled | Worst case | < 10%, and say so |
| Trace id propagation only | The §5 mechanism alone | < 0.5% |

Publish these numbers in `docs/tracing.md`. A tracing system whose overhead is
unknown will be turned off by everyone, which makes it worthless.

### 9.1 Why the hot-path budget is per-event, not a percentage

The obvious way to write that fourth row is "< 2% on an IPC microbenchmark."
Don't. A ratio against a microbenchmark has a moving denominator, and it moves
the wrong way:

- **An event cannot cost less than one timestamp.** `rdtsc` is 20–40 cycles on
  contemporary x86 (measure it — it varies more than people expect, and it is
  emulated and meaningless under an interpreter like QEMU's TCG). Everything
  else a well-written tracepoint does — the enabled check, the bounds check,
  the header and payload stores, the release commit — is around 5 cycles.
  **The clock read is the tracepoint's cost**, and it is irreducible without
  giving up per-event timestamps, which is the thing that makes a trace a
  trace.
- **A percentage target gets harder as the system gets faster.** 2% of a
  1100-cycle slow-path IPC roundtrip is 22 cycles: already under one `rdtsc`,
  so already unreachable. Once §4 of Chapter 08's assembly fast path lands and
  the roundtrip is seL4-like at 300–500 cycles, 2% becomes 6–10 cycles — the
  budget tightens by 3× as a *reward* for optimizing IPC. A target that
  punishes progress on an unrelated axis is measuring the wrong thing.
- **Events per operation is the real variable, and it is a design choice.** A
  roundtrip that emits three events costs three timestamps. If that is too
  much, the answer is to emit fewer events on that path — a decision about
  what the trace is worth — not to make each event cheaper than a clock read,
  which is impossible.

So budget the thing you control: **cycles per enabled event**. It is directly
measurable, it does not silently change meaning when something else improves,
and it decomposes honestly — *N* events per operation at *C* cycles each, and
both numbers are yours to argue about separately.

If you want a whole-operation figure as well, state it as a derived quantity
with its inputs visible ("3 events × 37 cycles = 111 cycles on a 1143-cycle
roundtrip, 9.7%") rather than as the target itself. Then a reader can see
whether to attack the event count or the per-event cost.

**Do reuse a timestamp you already have.** If the code path already read the
TSC for its own purposes — a scheduler's cycle accounting, say — pass that
value into the tracepoint instead of taking a second reading. It is free and
it is exact, because it is the same instant. Do *not* extend this to events
that are merely close together: sharing one timestamp between two events tens
of cycles apart replaces a measurement with a fabrication, which is a strange
thing to do inside a measurement system.

---

## 10. Verification

| Test | Asserts |
|---|---|
| `ring_no_corruption` | Concurrent writer + drainer under stress; every event well-formed. Model-check with the Chapter 12 §9 harness. |
| `no_allocation_in_trace` | Poison the allocator; trace heavily |
| `drops_are_counted` | Overrun deliberately; assert the reported drop count is exact |
| `timestamps_monotonic_per_cpu` | Within a ring, never decreasing |
| `trace_id_propagates` | A synthetic request through 5 components; assert one trace id, correct parent/child spans |
| `trace_survives_component_crash` | Kill a component mid-span; assert the trace shows the span unterminated rather than corrupting |
| `flight_recorder_on_panic` | Panic; assert the last N events are recoverable and decodable |
| `overhead_budget` | The §9 table, enforced in CI |
| `converter_roundtrip` | Binary → JSON → parse; assert no event lost or misattributed |

---

## 11. Exercises

1. Implement the ring, the event generator, and five tracepoints. Convert to
   Chrome Trace JSON and look at your kernel's scheduling in the Perfetto UI.
2. Add trace id propagation to IPC. Measure the cost on your IPC benchmark before
   and after.
3. Build the per-request waterfall view (§7.3) and use it on a real slow path.
4. Implement the patched-nop tracepoint and measure whether it beat the branch.
   Report honestly if it didn't.
5. Wire the flight recorder into your panic handler and cause a panic. See if the
   trace tells you why.
6. Add in-kernel histogram aggregation and compare data volume against raw events
   for "IPC latency by destination."
7. **Argue the other side:** make the case that always-on tracing is a security
   liability (timing side channels, address leaks, and a large attack surface in
   the kernel) and that it should be a debug-build feature only. What would change
   your mind?

---

Next: [33 — Profiling and performance analysis](33-profiling.md)
