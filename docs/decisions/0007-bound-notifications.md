# ADR-0007 — Bind a Notification to a TCB

- date: 2026-08-14
- status: accepted (2026-08-14)
- guide: 08 §5

## Context

A userspace driver must wait for *either* a client request (Endpoint) or
an IRQ (Notification). Those are two blocking calls. There is no
`NBRECV`, a Notification has at most one waiter, and a second
`notify_wait` is refused. A one-thread `replyrecv` loop therefore
cannot see interrupts.

M3.2's done-when is a userspace driver. Two threads per driver would
work but doubles TCB burn, and the manifest cannot express "this
component has two threads." Polling burns the CPU and is incompatible
with track A.

## Decision

A Notification may be **bound** to a TCB (`TCB_BIND_NOTIFICATION`).
While that thread is blocked in `recv` / `replyrecv`, a signal wakes
it. The received badge has `BADGE_NOTIFICATION` (bit 63) set and the
notification word in the low bits. Pending bits are also observed at
the start of `recv`, so a signal that arrived while the server was
running is not lost.

Binding is 1:1. Rebinding replaces. Finalizing either side unbinds.
Signalling still never blocks and never allocates.

## Alternatives rejected

- **Two threads per driver.** Works with today's objects. Rejected:
  doubles TCB (and leak) cost, and the manifest cannot name the
  second thread. A workaround, not a model.
- **`select` / `NBRECV` in a poll loop.** Adds a syscall and a
  readiness model the ABI otherwise refused (guide 17). Burns CPU.
- **Kernel `select` of endpoints.** The thing Liedtke deleted.

## Consequences

Makes easy: the canonical server loop is also the IRQ loop. A driver
is one thread.

Makes hard: a badge's top bit is no longer available to userspace.
63 bits remain. Servers that mint badges must not set bit 63.

Forecloses: nothing. Unbound notifications and `SYS_WAIT` stay.

## Revisit when

A server needs to wait on *two endpoints* as well as a notification.
That is a different problem (a second thread, or a userspace mux).
Do not grow a kernel `select`.
