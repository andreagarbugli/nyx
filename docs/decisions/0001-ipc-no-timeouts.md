# ADR-0001 — IPC has no timeouts

- date: 2026-08-10
- status: accepted
- guide: 08 §7

## Context

A blocking `ipc_call` to a server that never replies would hang the caller
forever. The obvious fix is a timeout parameter. But a timeout requires the
kernel to hold a timer per blocked thread, which is per-thread kernel state with
a lifetime independent of the IPC — and that breaks the invariant that IPC
allocates no kernel memory (guide 08 §7). It also adds a timer-queue operation to
the fast path.

## Decision

IPC never times out. A caller that cannot tolerate blocking uses non-blocking
send. Liveness is a userspace concern: a watchdog component holds capabilities to
its clients' TCBs and unblocks or restarts them.

## Alternatives rejected

- **Per-call timeout (L4 classic)** — reintroduces per-thread kernel timer state,
  puts a timer-queue insert on the IPC path, and makes the fast path's
  precondition list longer. L4 later moved away from this too.
- **Global watchdog in the kernel** — same state cost, plus the kernel now has a
  policy about how long is too long, which is exactly what it shouldn't have.
- **Timeout only on the slow path** — the fast/slow paths must be semantically
  identical or `ipc_fastpath_matches_slowpath` can't be a test.

## Consequences

Easy: IPC allocates nothing, ever; the fast path stays short; the kernel has no
timing policy.

Hard: every server must be written to always reply, including on error paths. A
buggy server hangs its clients until the watchdog acts, which is slower than a
timeout would be. Deadlock is prevented structurally by the level discipline
(guide 11 §2), so this only bites on genuine server bugs.

Forecloses: any design where the kernel bounds IPC latency itself. Real-time
guarantees therefore come from budgets and passive servers (guide 14), not from
timeouts.

## Revisit when

A watchdog-based recovery is measured to be too slow for a hard real-time
partition — i.e. if P5 track A produces a case where the detection latency itself
breaks a deadline.
