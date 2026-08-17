# Invariants

Violating one of these is a bug, not a tradeoff. Tests exist to make
that mechanical. If a milestone seems to need a violation, stop and
write an ADR — or a spike that shows the feature can be expressed
without the violation.

Source of the list: `CLAUDE.md`, restated with current status.

| # | Invariant | Held? | How we know |
|---|---|---|---|
| 1 | The kernel never dereferences a user pointer. | Yes. Arguments are registers or `cptr_t`. | Construction. First threat: an IPC buffer. Do not add one “for convenience.” |
| 2 | IPC allocates no kernel memory, ever. | Yes. Endpoint queues are TCB links. Notifications are one word + one waiter. | `ipc_no_kernel_allocation`, `notification_allocates_nothing`. |
| 3 | No string crosses a syscall boundary. | Yes. | `make abi-check`. |
| 4 | Every frame given to userspace is zeroed. | Yes for `pmm_alloc` and `untyped_retype`. | `pmm_frames_are_zeroed`, `untyped_retype_zeroes_memory`. Hold this in the ELF loader. |
| 5 | `paddr_t`, `vaddr_t`, `dma_addr_t` are distinct types. | `paddr_t` / `vaddr_t` are structs. `dma_addr_t` is correctly absent. | Compiler. `cap.obj` is a `uint64_t` holding a paddr for `CAP_FRAME`/`CAP_UNTYPED` and a kernel pointer otherwise — the one bypass, now documented on `struct cap` itself. Readers go through `endpoint_of`/`notification_of`; retype picks the representation in one `obj_handle()`. This bit *did* go off: retype stored a paddr for an endpoint and the refcount hook read it as a pointer. |
| 6 | Every fallible function is `MUST_USE`. | Mostly, on the public allocators and cap ops. | `-Werror`. |
| 7 | Every lock has a rank. | Yes. BKL 5, per-CPU runqueue 10, klog 100; ranks 20–60 reserved. | `lock_ranks_are_tracked_and_ordered`; `docs/locking.md`. |
| 8 | Every ABI struct has `_Static_assert` on size and offsets. | `message_t`, `ublob`, `struct cpu`, `struct regs`, `struct tss`. | Build. |
| 9 | Badge is unforgeable. | Yes. `msg_transfer` overwrites from the capability. | `ipc_badge_correct`; hostile ring-3 version still thin. |
| 10 | An endpoint’s queue holds senders or receivers, never both. | Yes. | State machine + tests. |
| 11 | `t->blocked_on != NULL` iff `t` is on that endpoint’s queue. | Yes. `ep_dequeue` / `ep_unlink_blocked` clear it. | Own test; teardown #PF at CR2=0 if violated. |
| 12 | Last capability dropped ⇒ finalizer runs; remaining root cap ⇒ object lives. | Yes for Endpoint and Notification. | `revoke_finalizes_transitively`, `endpoint_survives_while_any_capability_remains`. |
| 13 | A Notification never blocks the signaller. | Yes. `thread_resume`, not a direct switch. | `notification_never_blocks_signaller`. |
| 13a | A reply obligation is symmetric: destroying either end cancels it. | Yes, both directions (`reply_to` / `reply_from`). | `a_server_that_dies_mid_request_releases_its_client` and `killing_a_caller_clears_the_servers_reply_obligation`. The caller side was missing until 2026-08-14: a killed client left the server holding a pointer to it. |
| 14 | W^X. `PTE_W` without `PTE_NX` is refused before any table is allocated. | Yes, including the kernel image. | `w_xor_x_is_enforced` plus the M3.0 image tests. Effective permissions are the AND of the walk. |
| 15 | Frames given to ring 3 are `PTE_U`. Kernel pages are not. | Yes. | User `#PF` on a mapped kernel address is `PF_USER\|PF_PRESENT`. |
| 16 | Exactly one `swapgs` in, one out, on every ring transition. | Intended, on syscall and interrupt paths. | Convention stated in `percpu_init`. Do not add a third `sysret`. |
| 17 | A capability crosses an endpoint only if that endpoint capability carries `RIGHT_GRANT`. | Yes (ADR-0009). | `cap_transfer_respects_grant_right`. The message still arrives; the authority does not. |
| 18 | Capability transfer allocates nothing and is bounded by the *receiver's* registered window. | Yes. | `cap_transfer_drops_what_the_window_cannot_hold`, `cap_transfer_needs_a_window_at_all`. A sender cannot enlarge the bound. |

Related, not quite invariants:

- **No kernel heap after the untyped migration** (guide 09 §4). Not
  held. `pmm_alloc` is live. Do not claim this property in prose.
- **IPC has no timeouts** (ADR-0001). Held. Revisit only if track A
  measures detection latency itself breaking a deadline.
- **Syscall numbers are append-only.** Policy, enforced by review and
  by having been burned once.
