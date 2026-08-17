# ADR-0003 — Define object teardown and `E_PEERGONE`

- date: 2026-08-13
- status: accepted (2026-08-13)
- guide: 08 §7, 09 §3; appendix E §E3; ADR-0001

## Context

`cap_delete` and `cap_revoke` do capability-derivation-tree bookkeeping and
nothing else. There is no `struct kobject`, no refcount, and no finalization.
Concretely, today:

- Deleting the last capability to an **endpoint** with threads blocked on it
  leaves those threads blocked forever, on an object nothing can name.
- A **server thread** that calls `thread_exit` (or faults, which since M3.0
  kills it) leaves every client blocked in `ipc_call` with no reply ever
  coming.
- A **TCB**'s kernel stack is never freed; a **frame**'s mappings are not
  tracked.

`E_PEERGONE` is reserved in `include/abi/errno.h` with no producer, precisely
because this is unresolved.

ADR-0001 (no IPC timeouts) is correct and makes this *more* pressing, not
less: it deliberately moves liveness to a userspace watchdog holding TCB
capabilities. That watchdog cannot work until "the thing I was talking to
died" is an event the kernel can deliver. Right now the watchdog's only tool
would be to suspend and restart a server whose clients stay blocked anyway.

This is a design exercise, not a one-line `list_for_each` in `cap_delete`.
The hard question is what happens to a thread that is *mid-`ep_link`* — on
an endpoint's queue, in `TS_BLOCKED_SEND` or `TS_BLOCKED_RECV`, with a
`blocked_on` pointer — at the moment the endpoint is finalized.

## Decision

Adopt seL4's shape, in three parts.

1. **Objects get a refcount and a finalizer.** A `struct kobject` header
   carries `type`, `size_bits`, and a count of capabilities pointing at it.
   `cap_delete` decrements; the finalizer runs when the count reaches zero.
   `cap_revoke` therefore already finalizes everything derived from a
   capability, which is what makes it the security workhorse guide 09 §3
   claims.

2. **Endpoint finalization unblocks every queued thread with `E_PEERGONE`.**
   Each thread on the queue is dequeued, its `blocked_on` cleared, its
   pending message result set to `E_PEERGONE`, and it is made runnable. The
   thread returns from its `ipc_call`/`ipc_recv` with an error rather than
   never returning. This is the single change that makes a dead server a
   recoverable event instead of a hang, and it is why `E_PEERGONE` is an
   ordinary result code and not a fault.

3. **A blocked thread's queue membership is owned by the endpoint, not the
   thread.** A TCB may be finalized while queued, so TCB finalization must
   dequeue it from whatever it is blocked on first. The invariant to hold and
   to test: `t->blocked_on != NULL` if and only if `t` is on that endpoint's
   queue, at every point where either object can be destroyed.

## Alternatives rejected

- **Leave it; a watchdog restarts servers.** This is what ADR-0001 assumes,
  and it is exactly what does not work: restarting the server does not
  unblock the clients already queued on the old endpoint. The watchdog would
  have to destroy the endpoint, which is the operation being specified here.
- **Reference-count endpoints but leave blocked threads queued, and let the
  scheduler notice.** Rejected: it turns a bounded, explicit operation into a
  scan, and there is no point at which the scheduler could correctly
  distinguish "blocked forever" from "blocked and will be replied to".
- **Deliver a fault instead of an error return.** Rejected: a peer dying is a
  normal event in a multi-server system (appendix E §E3), and routing it
  through the fault path would conflate "your correspondent went away" with
  "you did something illegal". The client should be able to retry or rebind
  without unwinding.
- **Full seL4 `Reply` capability objects now.** Nyx stores `reply_to` as a
  TCB pointer, which cannot be transferred, revoked, or audited. That is a
  real limitation, but it is a *separate* one — worth its own ADR when a
  server first wants to delegate a reply to a worker thread. Teardown does
  not depend on it.

## Consequences

Makes easy:

- M3.2's driver restart, M4.2's reincarnation server, and the watchdog
  ADR-0001 already promised.
- Track A (ADR-0002), where a partition that overruns must be stoppable
  without hanging its peers.
- `cap_revoke(untyped_cap)` becomes real process termination — guide 09 §4's
  "revocation destroys everything" claim, which today is bookkeeping only.

Makes hard:

- `cap_revoke` becomes long-running in a new way: finalizing objects, not
  just unlinking capabilities. Combined with its existing unbounded recursion
  this pushes preemptible/restartable revoke (guide 09 §3) from "later" to
  "with this".
- Every object type must define a finalizer, which is a per-subsystem cost
  (Endpoint, TCB, VSpace, Frame, CNode, Untyped) and the reason this should
  land **before** more object types are added, not after.

Forecloses: a kernel that can hand out object capabilities without also
answering what their death means. That is the intended foreclosure.

## Revisit when

The decision itself should not need revisiting; the *scope* should be
reconsidered if TCB finalization turns out to require freeing a kernel stack
from the thread standing on it (guide 07 §9 ex. 2 — still unsolved, still
leaking). If so, split TCB teardown out and land endpoint teardown alone,
since endpoint teardown is what unblocks M3.2.
