# Architecture

The system as it is, not as the guide will be. Guide 11 asked for this
file the day the first two servers exist. They do: console, uart,
ramdisk, ramfs, VFS, mem, pm, and hello.

The waist (guide 39): kernel object types, IPC and capability
semantics, the manifest format, the trace event model, the IDL. Those
are one, on `master`. Everything else is composition. See
[`verticals.md`](verticals.md).

---

## 1. What the kernel is

A capability microkernel in the seL4 / L4 lineage, with MINIX 3’s
restartability and a modern bulk path still ahead. It provides:

```
threads · address spaces · CSpaces · IPC · notifications ·
untyped retype · scheduling contexts · a fixed-priority scheduler
```

and nothing else. Not a filesystem. Not `fork`. Not a drawing API.

P5 is **track A: real-time + TSN** (ADR-0002). The deliverable is a
number, not a demo. Graphics, virtualization-as-a-goal, and
distributed are out of scope for P5; they share this kernel later if
A works.

---

## 2. Objects

A capability names one of these. Types without a finalizer cannot yet
be destroyed safely from the last cap.

| Type | Exists | How created today | Finalizer |
|---|---|---|---|
| `CAP_UNTYPED` | yes | `untyped_from_pmm` (still via PMM) | reclaim only; no header-as-kobject |
| `CAP_FRAME` | yes | `untyped_retype` | none — raw page, no header (ADR-0008) |
| `CAP_CNODE` | yes | `untyped_retype` (radix in `size_bits`) | none; slots are not walked on delete |
| `CAP_ENDPOINT` | yes | `untyped_retype` | unblocks waiters with `E_PEERGONE` |
| `CAP_NOTIFICATION` | yes | `untyped_retype` | wakes the one waiter |
| `CAP_TCB` | yes | `untyped_retype` / pool; exited slots reused | waiters get `E_PEERGONE`; slot+stack recycled |
| `CAP_VSPACE` | yes | `untyped_retype` | none; `vspace_destroy` is still kernel-side |
| `CAP_IRQCONTROL` | yes | one, minted by the kernel at boot | — |
| `CAP_IRQHANDLER` | yes | `IRQCONTROL_GET` | releases the vector |
| `CAP_IOPORT` | yes | kernel (COM2 range) | — |
| `CAP_SCHEDCONTEXT` | yes | `untyped_retype` | unbinds the TCB |

Retype produces Frame, Untyped, Endpoint, Notification, CNode, VSpace,
TCB, SchedContext, and the storage for IRQHandler. IRQControl and IOPort
are not retyped. A TCB is runnable only while bound to a SchedContext.
Kernel-created threads share an unlimited boot context; a retyped TCB
starts unbound. A passive server (`t->sc == NULL`) runs on its client's
context for the duration of a Call (ADR-0012).

`reply_to` is a TCB pointer, not a Reply capability. It cannot be
transferred, revoked, or audited. A client already in
`TS_BLOCKED_REPLY` is not on any endpoint queue; destroying the
endpoint does not save it. Killing the server would, and that is TCB
teardown. Recorded in `ep_finalize` and ADR-0003.

---

## 3. IPC

Three mechanisms, deliberately distinct (guide 08):

1. **Endpoint** — synchronous rendezvous. Message in the TCB, never
   in the endpoint. Queue holds senders *or* receivers. Badge comes
   from the capability, overwritten in `msg_transfer`.
2. **Notification** — asynchronous, coalescing bitmask. At most one
   waiter. May be bound to a TCB (ADR-0007). `notify_signal` never
   blocks and never allocates. Usable from an interrupt handler.
3. **Ring** — not built. Shared-memory data plane, later.

No timeouts (ADR-0001). Liveness is a userspace watchdog holding TCB
capabilities. TCB teardown produces `E_PEERGONE` for anyone the dead
thread owed a reply to; the watchdog itself is still unwritten.

Direct switch on rendezvous skips the scheduler only if the
receiver is on this CPU *and* its priority is ≥ the highest ready
thread here (guide 07 §7, ADR-0002 blocker 1). A remote receiver is
enqueued on its home runqueue and kicked; `schedule()` picks locally.

The syscall transport carries **four** message words. `message_t`
still has six; the extra two are kernel-internal only. The wire
format is the register map in `include/abi/syscall.h`, not the bytes
of `message_t`.

---

## 4. Authority

A thread’s complete authority is the contents of its CSpace. There is
no ambient user, no path, no `ioctl`.

- Ring 3 reaches objects only through `ipc_*_cap` / `notify_*_cap` /
  `SYS_INVOKE`.
- A kernel thread with `cspace_root == NULL` fails closed (`E_BADCAP`).
- A freshly created `user_proc` starts with an empty CSpace.
- Single-level CSpaces used from ring 3 must have radix + guard_bits
  = 64. A radix-3 node with no guard consumes the *top* three bits of
  a depth-64 lookup; every small index hits slot 0. Found at M3.0
  when a test passed for the wrong reason.

`cap_lookup` copies by value. The mutable `cap_lookup_slot` is a
separate function. Capability code has no hardware dependency and
fuzzes on the host.

---

## 5. Levels

Synchronous IPC plus no timeouts means a cycle is a deadlock. Guide
11’s rule, checked by `tools/mkmanifest.py` (a `uses=` cycle is a
build error):

```
level 0  kernel
level 1  root task            holds Untyped, creates everyone
level 2  memory server        mem: alloc + demand-zero pager
level 3  device drivers       con, uart, rd
level 4  filesystem servers   ramfs
level 5  VFS                  name resolver only; / → ramfs
level 6  process manager      spawn, poll-wait, exit
level 7  applications         hello, sh, and anything they spawn
```

A component may only `call` a strictly lower level. Upward traffic
is a reply or a notification. Enforced by which capabilities the
root task hands out, not by a kernel check.

What exists today: `user/con`, `user/uart`, `user/srv/{rd,ramfs,vfs,mem,pm}`,
`user/hello`, `user/sh`, `user/child`. Root *is* the reincarnation
server after the servers start (guide 11 §7): it keeps the
endpoint, reclaims the component Untyped, and rebuilds
`{con,rd,ramfs,vfs}`. `user/srv/{init,rs}/` remain a map.

The shell reads COM2 (uart). COM1 is kprintf and is not a driver. A
line becomes `pm_spawn("/name")` with the shell's VFS cap granted.

`open()` is the VFS. It returns a capability to ramfs; `read` goes
there directly (guide 11 §4.3 (b)). The memory server hands out
Frames (`mem_alloc`) and demand-zeros a registered window (the
pager). There is no page cache (ADR-0010): when one exists it
lives here, and nothing mmaps yet.

`pm_spawn` builds a process; it does not copy one. The parent
grants the child's initial caps (v0: one, the VFS send cap).
Wait is a poll (`E_WOULDBLOCK`) until Reply objects exist. Child
kernel objects are carved from mem's Untyped, not from a budget
the parent provided.

---

## 6. Scheduling

ADR-0004: the M1.3 **fixed-priority bitmap runqueue is the
mechanism** and stays. Timeslice accounting belongs on it (not yet
built). Guide 14’s `SchedContext` and passive servers are a **layer**
for track A — they supply the budget that replenishes a timeslice;
they do not replace priority selection.

Today: 256 levels, O(1) pick, one runqueue per CPU, no migration
except `thread_bind` on a TS_INACTIVE thread. Round-robin within a
level by re-queueing on each tick, no quantum bound, no donation.
`current` and idle are per-CPU. Syscalls still take the BKL and run
with `IF=0` for the whole path. That last fact is an A-blocker: the
non-preemptible region is currently “all of it.” The first path off
the BKL is the sched-wake IPI to an idle CPU.

---

## 7. Memory

- Buddy PMM, frames zeroed, `paddr_t` / `vaddr_t` distinct structs.
- `dma_addr_t` arrives with the first device (M3.2).
- Untyped retype exists. `pmm_alloc` is still the live general
  allocator. Guide 14’s “kernel never allocates” is a claim about a
  kernel that does not exist yet. A-blocker #6.
- Kernel image is W^X (4 KiB remap of every 2 MiB page it occupies).
  The hole that closed was also the boot stub’s RWX 2 MiB alias of
  physical 0–1 GiB.
- Direct map is NX.
- Kernel stacks are guard-paged. Exited TCBs leak their stack
  (cannot free the stack you stand on).
- Page faults from ring 3 call `fault_ep` if set (retry on reply 0),
  else kill the thread.
- A Notification may be bound to a TCB (ADR-0007): a signal wakes
  `recv`, badge has `BADGE_NOTIFICATION`.

---

## 8. Profiles, not products

One `nyx.elf`. What boots is a manifest and an initrd.

| Profile | What is in the initrd | When |
|---|---|---|
| headless | ktests, later root task + core servers | now, and CI forever |
| rt | headless + the A workload (sensors, TSN, adversary) | track A |
| workstation | headless + display + input + compositor + shell | B-thin, after A has a number |

`make test` is headless. A graphical test is a different initrd, not
a different kernel. See [`verticals.md`](verticals.md).
