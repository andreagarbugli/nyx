# ABI

**`include/abi/` is the specification.** This file is prose. If they
disagree, the header wins and this file is wrong.

Nothing in `include/abi/` may include a kernel-internal header.
No `char *` crosses this boundary. `make abi-check` enforces both.
Every change under `include/abi/` is a versioned event and its own
commit (see [`abi-policy.md`](abi-policy.md)).

---

## Syscalls

`include/abi/syscall.h`. The list is **append-only**. Inserting a
number in the middle renumbers everything after it. That is not
hypothetical: adding `SYS_SIGNAL`/`WAIT`/`POLL` before `SYS_DEBUG`
moved `SYS_DEBUG` from 5 to 8, and the ring-3 blob’s “please exit”
became “signal a notification I do not hold.” It presented as a hang.

| # | Name | What |
|---|---|---|
| 0 | `SYS_YIELD` | Give up the CPU. |
| 1 | `SYS_CALL` | Send, block for reply. |
| 2 | `SYS_RECV` | Block until a message. |
| 3 | `SYS_REPLYRECV` | Reply, then receive. |
| 4 | `SYS_INVOKE` | Object method, dispatched on cap type. |
| 5 | `SYS_DEBUG` | Test builds only. Absent (`E_NOSYS`) in release. |
| 6 | `SYS_SIGNAL` | Notification: OR bits, wake waiter. Never blocks. |
| 7 | `SYS_WAIT` | Notification: block until bits, then clear. |
| 8 | `SYS_POLL` | Notification: read+clear, no block. |

There is no `SYS_SEND`, `SYS_NBSEND`, `SYS_NBRECV`. Do not publish
them until they exist. A published-but-unimplemented number is worse
than an absent one, because a stub gets written against it.

`SYS_DEBUG` sub-ops (`PUTC`, `EXIT`, `NOOP`) exist only under
`CONFIG_KTEST`. They are how M3.0 tested the ring without IPC.

### Registers

`syscall` destroys RCX (return RIP) and R11 (return RFLAGS).

**In**

| Register | Meaning |
|---|---|
| RAX | syscall number, plus the capability count in bits 32..35 (ADR-0009) |
| RDI | capability index (`cptr_t`) |
| RSI | message label (or invoke method, or debug op) |
| RDX, R10, R8, R9 | words 0..3 |

**Out**

| Register | Meaning |
|---|---|
| RAX | result / label. Negative is `enum nyx_err`. |
| RSI | badge (or notification bit word) |
| RDX, R10, R8, R9 | reply words 0..3 |
| RDI | how many capabilities the returned message carried |

Everything else is scrubbed. The entry stub loads the reply block
unconditionally, so “no reply” means zeros, not “whatever was there.”

Transport width is **four** words (`SYSCALL_MAX_REG_WORDS`).
`MSG_MAX_WORDS` is 6; words 4 and 5 would need SysV callee-saved
registers. Do not put a length in `w[4]` and expect it to arrive.

No syscall takes a pointer. A `cptr_t` is bounds-checked against a
kernel-owned table.

---

## Errors

`include/abi/errno.h`. Negative, so value and status share RAX.
Some codes have no producer yet. That is intentional.

| Code | Meaning | Producer today |
|---|---|---|
| `E_OK` (0) | success | — |
| `E_NOSYS` | no such syscall, or compiled out | unknown `nr`; `SYS_DEBUG` in release |
| `E_INVAL` | malformed argument | yes |
| `E_BADCAP` | CPtr does not resolve / empty slot | yes |
| `E_PERM` | missing right | yes |
| `E_TYPE` | wrong object kind | yes |
| `E_NOSLOT` | destination occupied | yes (Retype and the CNode methods) |
| `E_REVOKED` | was valid, now revoked | **none.** Reserved. |
| `E_WOULDBLOCK` | non-blocking, no peer | none (`SYS_NBSEND` unbuilt) |
| `E_PEERGONE` | endpoint destroyed (or peer died) while blocked | **yes**, endpoint finalizer. Not yet: server died after taking the message (`TS_BLOCKED_REPLY`). |
| `E_NOMEM` | out of Untyped or a pool | yes |
| `E_BUDGET` | scheduling budget exhausted | `TCB_RESUME` of a thread bound to an exhausted one-shot context |
| `E_RESTART` | long op yielded; re-invoke | `CNODE_REVOKE`, `UNTYPED_RETYPE` zeroing (ADR-0013) |

`E_PEERGONE` is a normal event, not a fault. The client should be
able to retry or rebind without unwinding.

---

## Messages

`include/abi/message.h` is the kernel’s buffer, not a wire format.
Bitfield layout is implementation-defined; do not serialize it.
The badge is written by the kernel from the capability. The sender
cannot forge it.

`ncaps` is live (ADR-0009, guide 09 §5). Capabilities travel **in the
message words**, top-anchored: cap *i* occupies word `3-i`, so one
capability rides in word 3 and leaves words 0..2 for data. The count
goes out in RAX’s high half and comes back in RDI — never in the label,
which belongs entirely to the protocol.

Transfer requires `RIGHT_GRANT` on the endpoint capability, and the
receiver must have registered a window with `TCB_SET_RECV_SLOT`; the
kernel allocates no slot. Fewer capabilities may arrive than were sent
(a full window drops the rest rather than failing the IPC), which is why
the returned count is the only honest source. On receive, the words hold
the **receiver’s** cptrs — where each capability landed in its own
CSpace. Transferred capabilities are derived, so revoke still crosses
the boundary.

`BADGE_NOTIFICATION` (bit 63) is set when a bound Notification woke a
`recv` (ADR-0007). Servers that mint badges must not set this bit.

`include/abi/fault.h`: a pager sees `FAULT_LABEL_VM` and replies
`FAULT_REPLY_RETRY` (0) or `FAULT_REPLY_KILL` (1).

---

## Invoke

`include/abi/invoke.h`. **Landed 2026-08-13** with nine ring-3 tests;
no longer proposed.

Object methods go through `SYS_INVOKE`, dispatched on the
capability’s type. Adding an object type adds no syscall. Method
numbers are **per type** and append-only.

RDI is the capability being invoked, RSI the method, and RDX/R10/R8/R9
the four argument words.

### `CAP_TCB`

| # | Method | Words |
|---|---|---|
| 0 | `TCB_CONFIGURE` | CSpace cptr, VSpace cptr, entry, stack |
| 1 | `TCB_RESUME` | — |
| 2 | `TCB_BIND_NOTIFICATION` | Notification cptr |
| 3 | `TCB_SET_FAULT_EP` | Endpoint cptr |
| 4 | `TCB_SET_RECV_SLOT` | CNode cptr, first slot, count |
| 5 | `TCB_BIND_SCHEDCONTEXT` | SchedContext cptr |

### `CAP_UNTYPED`

| # | Method | Words |
|---|---|---|
| 0 | `UNTYPED_RETYPE` | w0 = `type \| (size_bits << 8)`, w1 = dest CNode cptr, w2 = first slot, w3 = count |

`type` and `size_bits` share a word because Retype needs five
arguments against a four-word budget. Use
`UNTYPED_RETYPE_WHAT(type, bits)` rather than packing by hand.

Retypeable today: `CAP_FRAME` (always one page — the VMM does not map
huge pages either), `CAP_UNTYPED`, `CAP_ENDPOINT`, `CAP_NOTIFICATION`,
`CAP_CNODE` (radix in `size_bits`), `CAP_VSPACE`, `CAP_TCB`,
`CAP_SCHEDCONTEXT`. Objects are **constructed**, not merely zeroed —
a retyped endpoint has a valid queue head and a refcount of 1.

### `CAP_SCHEDCONTEXT`

A scheduling context is a capability (ADR-0012, guide 14 §4). A TCB
is runnable only while bound to one. Freshly retyped: unlimited.

| # | Method | Words |
|---|---|---|
| 0 | `SCHEDCONTEXT_CONFIGURE` | w0 = budget (TSC cycles), w1 = period (TSC cycles) |

### `CAP_CNODE`

The invoked capability is the **destination** CNode; the source is
always a slot in the caller’s own CSpace root.

| # | Method | Words |
|---|---|---|
| 0 | `CNODE_COPY` | w0 = dest slot, w1 = source slot, w2 = rights |
| 1 | `CNODE_MINT` | w0 = dest slot, w1 = source slot, w2 = rights, w3 = badge |
| 2 | `CNODE_MOVE` | w0 = dest slot, w1 = source slot |
| 3 | `CNODE_DELETE` | w0 = slot in the invoked CNode |
| 4 | `CNODE_REVOKE` | w0 = slot in the invoked CNode |

That asymmetry is deliberate: it is the shape the root task is in when
it hands a capability to a child. It is not a general
`(root, index, depth)` triple. The general form can be added as new
method numbers later without renumbering. Do not grow a second
`CNODE_COPY` that overloads the first.

Every method requires `RIGHT_WRITE` on the invoked capability: all of
them mutate. A read-only CNode capability lets you name it, not
rearrange it. Minting cannot add rights the source lacks
(monotonicity, guide 09 §2).

---

## Userspace

`libnyx` does not exist. When it does, it includes these headers and
does not invent a parallel convention. Linking is static (ADR-0005),
revisited at M4.0 against a measured duplication threshold.
