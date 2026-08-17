# Open questions

A decision with real alternatives, not yet an ADR (or an ADR whose
*scope* is still open). If you are about to pick one of these in
code, stop and write the ADR first.

---

## Settled

| Question | Where |
|---|---|
| `SYS_INVOKE` method set, asymmetric CNode | M3.1; general triple = new method numbers |
| ELF loader in the root task | M3.1 |
| Manifest v0, binary at runtime | `include/abi/manifest.h` + `uses_ep2` / `irq_vector` |
| Bound notification vs two threads vs poll | **ADR-0007** |
| Frame finalizer | **ADR-0008** — live until Untyped reclaim |
| Capability transfer over IPC | **ADR-0009** |
| Where the page cache lives | **ADR-0010** — with the pager; none until mmap |
| VFS as name resolver | Guide 11 §4.3 (b), implemented M4.0 |
| P5 vertical | ADR-0002 track A |
| Verticals as manifests | ADR-0006 |
| Static linking | ADR-0005; revisited M4.0, trigger not met |

---

## Decide before the M3.2 driver itself

| Question | Notes |
|---|---|
| Who walks MADT / programs the IOAPIC | **Settled:** kernel walks MADT only (no AML). GET packs GSI; ACK unmasks. |
| First device | **COM2** (CAP_IOPORT 0x2f8..0x2ff, irq=3). Not COM1. virtio later. |
| Device binding in the manifest | `irq=` → IRQHandler in COMP_SLOT_IRQ. IRQControl stays with root. |

---

## Decide before M4.0

| Question | Notes |
|---|---|
| ~~Where the page cache lives~~ | **ADR-0010.** With the pager, none until mmap. |
| ~~Capability transfer over IPC~~ | **ADR-0009.** Cptrs in the message words. |
| ~~VFS as name resolver~~ | Design (b), implemented. |
| ~~Dynamic linking, measured~~ | **ADR-0005, held.** libnyx `.text` is 68 B (the syscall stub). Nine components: duplicated stub is 4.0% of summed `.text`, 0.3% of ELF-file bytes. Under the ~15% trigger. Reopen if independent shipping becomes a requirement. |

---

## Track A blockers (not M3.2)

1. ~~Priority check on IPC's direct switch~~ **done** (and on `ipc_reply`).
2. Timeslice accounting (ADR-0004).
3. `SchedContext` / passive servers.
4. Preemptible, restartable `cap_revoke`.
5. A bound on kernel `IF=0` regions.
6. Untyped migration; TCB/VSpace retype still uses pools.

---

## Still split out

| Question | Why |
|---|---|
| Reply as a capability | `reply_to` is a TCB pointer. Own ADR when a server wants a worker. |
| How a thread is stopped | **Decided 2026-08-14: `TCB_SUSPEND`, holder-authorised** — whoever holds the TCB capability with `RIGHT_WRITE` may make that thread inactive (release its IPC obligations, take it off the runqueue, leave the object alive so `pm_wait` and the parent's process capability still mean something). Kill stays what it is today: drop the last capability. Not built yet; ROADMAP M4.3. The problem it solves: **there is no way to stop a thread except to drop the last capability naming it.** Measured 2026-08-14: pm cannot end a child on `pm_exit`, because guide 11 §4.2 has spawn *return a process capability to the parent* — so the parent's copy keeps the refcount above zero and the thread runs on. Today's exits are therefore deliberate faults (`user/child/main.c` returns into a ring-3 `hlt`, and the #GP kills it), and today's kill is root sweeping 64 CNode slots by hand. Both work; neither is nameable. Wants a `TCB_SUSPEND`/`TCB_KILL` method, which is an ABI addition and a decision about who may stop whom. |
| Packed 16-byte caps | Fast-path trigger. |
| Hardware IRQ mask | IOAPIC; software `masked` only suppresses a second signal. |
