# ADR-0011 — IPC off the BKL, via endpoint and CSpace locks

- Status: accepted
- Date: 2026-08-15
- Milestone: after M4.3 (hot path)
- Guide: 08 §4, 12 §1 step 3, 12 §4, docs/evaluation-2.md §2.4

## Context

Same-core IPC on four CPUs was 1507 cy, of which a large part is the
BKL bounce in `switch_to` and the BKL itself. Two independent pairs
scale at ~1.1×, not 2×. Guide 12 §1's next path off the lock is IPC.
Ranks 20 (endpoint) and 40 (CSpace) have been reserved since M4.3.

Taking the BKL off `SYS_CALL` without those locks races
`cap_revoke` / `CNODE_DELETE` on another CPU against the lookup.

## Decision

1. **Every endpoint has a rank-20 ticket lock. Every CNode has a
   rank-40 ticket lock.** Host builds of `cap.c` (`NYX_HOSTTEST`)
   omit the CNode lock so the fuzzer stays kernel-free.
2. **Never hold both.** Lookup: lock CSpace, walk, `kobject_retain`
   the endpoint, unlock CSpace, lock the endpoint. Delete: lock
   CSpace, detach the cap, unlock CSpace, then release (finalizer
   takes the endpoint lock).
3. **`SYS_CALL` / `SYS_RECV` / `SYS_REPLYRECV` do not take the BKL.**
   `SYS_INVOKE`, notifications, and teardown still do, and they
   take the new locks when they touch the same objects.
4. **`reply_to` / `reply_from` are exchanged atomically.** Teardown
   and `ipc_reply` then commute: one wins, the other is the existing
   one-shot no-op.
5. **`rq_covered_by_bkl` is false.** A BKL-free `thread_resume`
   mutates a runqueue; the RQ lock is now the real one.
6. **Fast path:** `syscall_entry` tries `SYS_CALL` / `SYS_REPLYRECV`
   with `ncaps == 0` in asm and calls a C helper that handles the
   single-level, receiver-waiting, same-CPU case. Anything else
   falls through to the slow C path. Both run the same tests. The
   guide's register-stay `sysret` into the receiver is not done:
   `struct cap` is 56 bytes, not 16, and user RIP lives on the
   kernel stack, not the TCB. That tightening needs packed caps
   and is a later ADR.

## Alternatives rejected

- **Stay on the BKL.** Leaves the 1.1× scaling number as the
  architecture. Track A cannot bound latency.
- **Fast path with no locks (IF=0 only).** IF=0 is this CPU.
  Another CPU can delete the cap. Unsafe.
- **Hold CSpace across the endpoint op.** Rank 40 then 20 is a
  lockdep panic, and a cycle waiting to happen.
- **Full asm `sysret` into the receiver now.** Wrong cap size,
  no saved user RIP on the TCB, untestable against the C path
  without a second ABI. The helper is the fast path the suite
  can actually share.

## Consequences

- Kernel-thread yield under the BKL pays the RQ lock again. That
  is the honest context-switch number on a kernel that no longer
  pretends the BKL covers the queues.
- `make test FASTPATH=0` disables the helper so the slow path is
  still a first-class citizen (guide 08 §4).
