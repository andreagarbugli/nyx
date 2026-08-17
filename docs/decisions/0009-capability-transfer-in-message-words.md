# ADR-0009 — Capabilities travel in message words

- Status: accepted
- Date: 2026-08-14
- Milestone: M4.0 (first slice)
- Guide: 09 §5 (the policy), 08 §2 and §6 (the transport)

## Context

Every core server in guide 11 §4 hands capabilities back to its clients:
`mem_alloc` returns Frame caps, `pm_spawn` takes a `cap[]`, and the VFS design
the guide tells us to choose — (b), name resolution only — works precisely
because `open()` returns *a badged endpoint to the file object* and the data
path then skips the VFS entirely. None of that can be written without
capability transfer over IPC. `message_t.ncaps` has been a reserved field since
M2.1 and nothing has ever set it.

Guide 09 §5 already settles the **policy**, and this ADR does not revisit it:
the sending endpoint capability needs `RIGHT_GRANT`; the receiver registers a
destination CNode and slot range *in advance* (the kernel allocates nothing);
if there is no free slot the capability is dropped and the receiver is told how
many arrived, rather than the whole IPC failing; transferred capabilities are
derived, so revocation still reaches across the boundary.

What the guide does not settle is the **transport**. Our syscall carries four
message words in registers (`SYSCALL_MAX_REG_WORDS`) and there is no IPC
buffer. A cptr has to live somewhere.

## Options

**(a) Cptrs occupy message words.** The first `ncaps` words counted from the
top (`w[3]`, then `w[2]`, …) are cptrs; the rest are data. No new mechanism, no
new memory, and it works with the transport that exists today. The cost is that
a message carrying one capability has three data words left.

**(b) A per-thread IPC buffer** (guide 08 §6a, seL4's shape). A Frame
registered on the TCB and mapped in both the thread's VSpace and the kernel's,
holding message words 4–5 and up to `MSG_MAX_CAPS` cptrs. Lifts the four-word
ceiling and is the foundation bulk transfer will want. Costs a page per thread,
a kernel-side mapping, and a second message shape to keep working forever.

## Decision

**(a).** Capabilities travel in message words.

Three words of payload alongside a capability covers every M4.0 protocol we can
actually name: `open() -> file endpoint`, `mem_alloc() -> frame`,
`pm_spawn(path_id, caps…)`. Taking the IPC buffer now would mean designing the
bulk-data path (guide 08 §6) to serve a milestone that does not move bulk data —
and doing it before there is a workload to measure it against, which is the
kind of decision this workbench exists to avoid making blind.

(b) is not rejected, only deferred: it arrives when bulk data does, and it
arrives as an *additional* shape, since a message that fits in registers must
never start paying for a buffer it does not use.

### Encoding

- **Count, outbound: the high bits of RAX.** `RAX = nr | (ncaps << 32)`.
  The count does not go in the label, because the label belongs entirely to the
  protocol — `user/lib/con.h` already partitions it into an op and a length,
  and the kernel having an opinion about any bit of it would end that. Syscall
  numbers are small and ring 3 has always had to pass zero in RAX's high half,
  so this extends the ABI without renumbering anything.
- **Placement: top-anchored.** cptrs occupy `w[3-i]` for `i` in `0..ncaps-1`.
  Anchoring at the top rather than the bottom keeps a protocol's data words at
  stable indices when a capability is optionally attached.
- **Count, inbound: RDI.** The entry stub already loads RDI on the way out
  (it was excluded from the return map and zeroed); it now comes from the
  return block like every other returned register, so "load, never leave
  alone" — the property that makes HAZARD 4 unfalsifiable — is unchanged.
  A receiver reads it to learn how many capabilities actually arrived, which
  is what makes drop-on-no-slot a reportable outcome rather than a silent one.
- **On receive, the same words hold the destination cptrs**: where each
  capability landed in the receiver's own CSpace. A receiver never sees a
  sender's cptr, which would be meaningless in its CSpace and would leak the
  shape of the sender's.

## Consequences

- `message_t.ncaps` finally means something, and `MSG_MAX_CAPS` (4) is now
  bounded from below by the transport as well: at most four, and each one costs
  a data word.
- A receive slot is per-TCB state, set by a new `TCB_SET_RECV_SLOT` method
  (appended to `enum tcb_method`, per the append-only rule). A server sets it
  once at startup and re-points it as it consumes slots.
- `RIGHT_GRANT` stops being decorative. An endpoint capability without it can
  carry messages but not authority — the distinction the rights bit was
  reserved for in M2.1.
- Replies transfer capabilities too, and must: `open()` returns its file
  capability in the reply, not in a subsequent send.
