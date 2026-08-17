# Tracing

Guide 32 §9: "Publish these numbers in `docs/tracing.md`. A tracing system
whose overhead is unknown will be turned off by everyone, which makes it
worthless."

Every number here is measured by `trace_overhead_budget` in
`tests/ktest/t_trace.c`, under `make test ACCEL=kvm`, with baseline and
variant interleaved (off/on/off/on) so drift lands on both sides equally.

## Overhead

| Configuration | Measured | Guide 32 §9 target | |
|---|---|---|---|
| Tracing compiled in, disabled | p50 unchanged vs. baseline within noise | < 0.2% | met |
| Enabled tracepoint, per event | **27 cycles** | < 50 cycles/event | met |

Derived, with its inputs visible (guide 32 §9.1): 3 events per IPC roundtrip
× 27 cycles = **+82 cycles on a 1153-cycle roundtrip, 7.11%**.

Measured 2026-08-13, commit M2.2, on QEMU/KVM `-cpu host`, TSC 1497 MHz.

**Only measured under `ACCEL=kvm`.** `trace_overhead_budget` skips under plain
TCG, and that is not a convenience: TCG is an interpreter, so a "cycle" there
is an interpreter step. The same test measured under TCG reports `rdtsc` at 80
cycles and the overhead at 24% — neither number describes any real machine,
and asserting a performance budget against them would be enforcing it against
the emulator. Every number on this page is hardware (via KVM).

### Where the 27 cycles go, and why the budget is per-event

- **One `rdtsc` costs 37 cycles** (measured directly, median of 4000 samples,
  same warm-up discipline as everything else).
- Four events fire per roundtrip, but only **two read the clock**:
  `ipc_send` and `ipc_recv` from the client's rendezvous. That is 74 cycles of
  the 82-cycle delta.
- The third recorded event (`sched_switch` back to the client) and the direct
  switch into the server both reuse the TSC `switch_to()` already reads for
  its cycle accounting, via `trace_sched_switch_at()`. Free and exact — it is
  the same instant.
- Everything else all the tracepoints do — enabled check, bounds check, header
  stores, payload stores, release commit — is the remaining ~8 cycles across
  three events. **The clock read is the tracepoint's cost.**

That last point is why guide 32 §9's budget is *per event* rather than a
percentage of a microbenchmark. The original wording was `< 2% on an IPC
microbenchmark`; measuring it here showed the form was wrong, and the guide
was corrected on 2026-08-13 (see ROADMAP.md's "Guide corrections applied").
Briefly: 2% of this roundtrip is 22 cycles, already less than a single
`rdtsc`, so it was unreachable in principle rather than by oversight — and it
would have got *harder* as IPC improved, tightening to ~6–10 cycles once
Ch.08's fast path lands. A per-event budget is measurable, achievable, and
decomposes honestly into "how many events" × "how much each", which are two
separate arguments to have.

The optimization that was taken (reuse a TSC the path already read) is
deliberately **not** extended to `ipc_send`/`ipc_recv`: those are genuinely
tens of cycles apart, and sharing one timestamp between them would replace a
measurement with a fabrication.

If the per-roundtrip cost ever needs to come down, the lever is the **event
count**, not the per-event cost — `ipc_recv` on the rendezvous path is
inferable offline from `ipc_send` plus the following `sched_switch`. That is a
decision about what the trace is worth, and should be made deliberately.

## What is traced

Five permanent tracepoints, one per area of guide 32 §4.3's table:

| Event | Where | Payload |
|---|---|---|
| `ipc_send` | `kernel/ipc/ipc.c` | src/dst tid, badge, trace_id, label |
| `ipc_recv` | `kernel/ipc/ipc.c` | tid, badge, trace_id |
| `sched_switch` | `kernel/sched/sched.c` | prev/next tid, reason |
| `irq_enter` | `kernel/irq/dispatch.c` | vector |
| `fault` | `kernel/irq/dispatch.c` | address, tid, vector |

Event size is 8 bytes of header plus 1–26 of payload, i.e. 9–34 bytes.

## Causal tracing

`struct tcb` carries `trace_id`; the kernel propagates it across IPC with no
cooperation from either side (guide 32 §5.1). A receiver adopts the sender's
id for as long as it is handling that request and gets its own back on reply.
`trace_id_propagates` in `tests/ktest/t_trace.c` asserts all three parts of
that: the server sees the client's id, the server's own id is restored on
reply, and the client's id is never disturbed.

Spans (`span_begin`/`span_end`, guide 32 §5.2) are **not** implemented — they
are primarily a userspace mechanism and there is no userspace yet.

## Getting a trace out

The ring is a flight recorder: it overwrites its oldest events and counts
laps. `trace_dump()` writes a self-describing text block to the console —
header, event schema, then hex — and `tools/trace2json.py` reads that out of
a serial log and emits Chrome Trace Event JSON.

    make test ACCEL=kvm > serial.log
    tools/trace2json.py serial.log -o trace.json

The **schema travels with the data** rather than being hardcoded in the
converter. A converter that hardcodes field layouts silently misreads every
event the day someone adds a field, and the misreading looks like plausible
data rather than an error.

### Verification status of the JSON

`tests/host/t_trace2json.py` (11 tests, run by `make host-test`) checks the
output against the Chrome Trace Event format mechanically: required keys per
phase type, `dur` on every `X` event, real serialize/parse roundtrip, correct
µs scaling from the in-stream `tsc_hz`, 32-bit TSC wrap reconstruction, and
that malformed input is an error rather than plausible-looking garbage.

**Not verified: that it renders correctly in the Perfetto UI.** That needs a
browser and a human looking at it. The format is checked against the spec,
not against the viewer — if it does not open, the bug is real and this note
is where to start.
