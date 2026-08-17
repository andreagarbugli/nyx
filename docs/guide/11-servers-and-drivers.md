# 11 — Servers and userspace drivers

> Goal: a multi-server system — process manager, VFS, memory server, console and
> ramdisk drivers, and a reincarnation server that restarts them when they crash.
> Plus the thing that makes userspace drivers actually safe: the IOMMU.

---

## 1. Theory: system structure above the kernel

The kernel gave you threads, address spaces, IPC, and capabilities. Now you build
an operating system out of them. The design questions are:

1. **Decomposition**: what are the components, and where are the boundaries?
2. **Dependency structure**: who calls whom, and is the graph acyclic?
3. **Naming**: how does a component find a service?
4. **Failure**: what happens when a component dies?
5. **Bootstrapping**: what order do things start in?

### Decomposition heuristics

Split along these lines, in priority order:

- **Trust boundaries.** If component A shouldn't be able to compromise B, they
  must be separate. Drivers are the canonical case: a NIC driver processes
  attacker-controlled input and should not be able to touch the filesystem.
- **Failure boundaries.** If A should survive B crashing, separate them.
- **Replaceability.** If you want to swap implementations (ext2 vs FAT), the
  interface should be an IPC boundary.
- **Development independence.** Separate teams, separate languages (a Rust
  driver next to a C server), separate release cycles.

Do **not** split along these lines:

- "It felt like a module." Every boundary costs IPC.
- Very hot paths with trivial logic. If A and B exchange 10 million messages per
  second and B is 50 lines, they should be one component (or use a ring).

### The dependency graph must be acyclic

With synchronous IPC, a cycle is a potential deadlock (Chapter 08). Assign
**levels**:

```
level 0:  kernel
level 1:  root task / init          (holds all Untyped, creates everyone)
level 2:  memory server             (allocates and maps memory for others)
level 3:  device drivers            (console, ramdisk, disk, NIC, PCI)
level 4:  filesystem servers        (ramfs, ext2, ...)
level 5:  VFS                       (namespace, mount table, routing)
level 6:  process manager           (spawn, wait, exit)
level 7:  applications
```

**Rule: a component may only `call` strictly lower levels.** Upward
communication happens by *reply* (to a call already in progress) or by
*notification* (which never blocks). This rule, enforced by which capabilities
you hand out at boot, makes deadlock structurally impossible. Write it in
`docs/architecture.md` and check it in your manifest generator.

*(Notice this forces some designs: the process manager cannot be called by the
VFS. If the VFS needs to know who a client is, it uses the badge — which it
already has. Constraints like this improve designs.)*

---

## 2. The canonical server

Every server is the same shape:

```c
/* user/srv/example/main.c */
int main(void) {
    struct client clients[MAX_CLIENTS] = {0};
    message_t m;

    /* The endpoint we serve on was handed to us by init in a known slot. */
    cptr_t ep = CAP_SERVICE_EP;

    word_t badge = nyx_recv(ep, &m);
    for (;;) {
        if (badge & BADGE_NOTIFICATION) {
            handle_events(badge & ~BADGE_NOTIFICATION);
            badge = nyx_recv(ep, &m);          /* nothing to reply to */
            continue;
        }

        struct client *c = &clients[badge & CLIENT_MASK];
        example_dispatch(c, &m);               /* generated stub; fills reply */
        badge = nyx_replyrecv(ep, &m);
    }
}
```

Properties to hold yourself to:

- **Never `call` while holding an unreplied request** unless you've thought hard
  about it. If you must contact a lower-level server, either (a) do it and accept
  that you're serialized, or (b) delegate the reply capability and return to the
  loop immediately (asynchronous server).
- **Validate everything from the badge**, not from the message. A client can put
  anything in `m`; it cannot forge the badge.
- **Bound your per-client state.** A client that opens 4 billion handles must
  fail cleanly. Charge resources to the client's Untyped where possible.
- **Be restartable.** See §6.

---

## 3. Naming and service discovery

You need a way for a process to obtain an endpoint to "the filesystem" without
ambient authority creeping back in.

**Bad:** a global name server that anyone can query for any service. That's
ambient authority with extra steps — every component can reach every service.

**Good:** capabilities are passed down at creation time. When `init` spawns a
process, it puts exactly the endpoints that process should have into its CSpace,
at ABI-fixed slots:

```c
/* include/abi/slots.h — the initial CSpace layout for a spawned process */
#define CAP_NULL          0
#define CAP_SELF_CNODE    1
#define CAP_SELF_VSPACE   2
#define CAP_SELF_TCB      3
#define CAP_FAULT_EP      4
#define CAP_UNTYPED       5
#define CAP_MEMSRV_EP     6
#define CAP_VFS_EP        7
#define CAP_PM_EP         8
#define CAP_CONSOLE_EP    9
#define CAP_FIRST_FREE   16
```

A process's authority is fixed at spawn and visible in the manifest. If a process
should not be able to touch the filesystem, slot 7 is empty. Done. No policy
engine, no LSM, no seccomp filter — the absence of a capability *is* the policy.

**When you do need dynamic discovery** (a plugin architecture, a device that
appears at runtime), use a *broker* pattern: the component holds an endpoint to a
broker that it was given, and the broker decides — per-client, by badge — what it
may be introduced to. That's a normal program implementing a policy, not a kernel
feature.

---

## 4. The core servers

### 4.1 Memory server

Owns the bulk of physical memory (as Untypeds delegated by `init`) and provides:

```
mem_alloc(size, flags) -> (cap frames[], err)
mem_free(cap frames[])
mem_map(cap vspace, vaddr, cap frame, rights)
mem_share(cap peer_badge, cap frame, rights) -> (cap)
mem_dma_alloc(size, constraints) -> (cap frame, u64 physaddr, cap iommu_handle)
```

It's also the **pager** for most processes: it holds their fault endpoints and
handles page faults by allocating and mapping. That's where demand paging, lazy
allocation, and copy-on-write live — in a userspace program you can debug with
`printf`.

A satisfying consequence: you can run *two different memory servers* for
different subsets of processes, with different policies. Try a compacting one, a
NUMA-aware one, a deterministic one for real-time processes. This is the kind of
experiment a microkernel makes cheap and a monolith makes a research project.

### 4.2 Process manager

Owns process identity and lifecycle:

```
pm_spawn(string path, cap[] initial_caps, u32 flags) -> (u32 pid, cap process)
pm_wait(u32 pid) -> (i32 status)
pm_exit(i32 status)
pm_kill(u32 pid, i32 sig)
```

Implementation: for `spawn`, the PM asks the memory server for Untyped, retypes
it into a VSpace/CNode/TCB, asks the VFS for the binary, loads the ELF,
populates the CSpace per the manifest, and resumes the thread.

Note what `pm_spawn` is **not**: it's not `fork`. `fork` requires copying an
address space with COW and duplicating file descriptors — it's a UNIX artifact
that fits badly here. `posix_spawn` semantics (build a process, then run it) are
a much better match, and are what everyone should have used anyway. If you later
add POSIX compatibility, implement `fork` in a userspace compatibility layer and
enjoy the fact that its costs are visible.

### 4.3 VFS

Maintains the namespace (mount table) and routes operations to filesystem
servers. Two designs:

**(a) VFS in the data path.** Client → VFS → FS server → driver, and back. Simple,
but every read costs 3 round trips and the VFS is a bottleneck.

**(b) VFS as a name resolver only.** `open()` goes through the VFS, which returns
a **capability to the FS server's file object** (a badged endpoint). Subsequent
`read`/`write` go *directly* from client to FS server. The VFS is out of the data
path entirely.

**Choose (b).** This is the capability system paying for itself: a file
descriptor is literally a capability, and handing it to the client removes an
entire hop. It also means passing a file descriptor to another process is
`cap_copy` over IPC — no `SCM_RIGHTS` special case needed.

### 4.4 Console and ramdisk drivers

Start with these two because they're trivial and they unblock everything else.

- **Console**: owns an `IOPort` capability for COM1 (or a framebuffer mapping),
  serves a `write` method, and delivers input via a notification.
- **Ramdisk**: owns Frame capabilities to the initrd, serves block reads. Zero
  hardware involved — pure logic, so you can build and test your driver *protocol*
  before dealing with real devices.

---

## 5. Real device drivers in userspace

This is MINIX 3's signature idea and it's where a lot of the payoff is. But it is
only safe if you handle four things.

### 5.1 Register access

A driver needs its device's MMIO region mapped. That means:

1. A **PCI server** enumerates the bus (via the ECAM region from ACPI MCFG),
   reads BARs, and holds `Frame` capabilities for each device's MMIO.
2. When a driver claims a device, the PCI server gives it Frame capabilities to
   *only that device's* BARs, mapped uncacheable.
3. Legacy port I/O goes through an `IOPort` capability covering a specific range.

```c
/* The device Frame must be mapped with cache disabled. */
mem_map(my_vspace, MMIO_BASE, dev_frame, RIGHT_READ|RIGHT_WRITE, ATTR_UNCACHED);
volatile uint32_t *regs = (void *)MMIO_BASE;
```

Note the driver now has *exactly* the authority to talk to one device. A
compromised NIC driver cannot reprogram the disk controller. That's already a
massive improvement over a monolithic kernel.

### 5.2 Interrupts

Covered in Chapter 04: `IRQHandler` capability + `Notification`. The driver's
main loop waits on the notification, services the device, and acks.

### 5.3 DMA — the part everyone gets wrong

**A device performing DMA bypasses the MMU entirely.** If a driver can program
a DMA descriptor with an arbitrary physical address, it can write to kernel
memory. Userspace drivers without an IOMMU provide *no isolation at all* against
a malicious driver — they only protect against accidental bugs (which is still
worth something, and is what MINIX 3 mostly delivers).

The fix is the **IOMMU** (Intel VT-d, AMD-Vi):

```
Device (Bus:Dev:Fn)  →  root table  →  context table  →  a page table
                                                          (per-device address space)
```

Design in Nyx:

```c
/* A new kernel object type. */
struct iommu_ctx {
    struct kobject hdr;
    uint16_t   source_id;      /* PCI BDF */
    struct vspace *dma_space;  /* second-level page tables */
};

/* Invocations */
IOMMUCtx_Map(ctx_cap, frame_cap, iova, rights)
IOMMUCtx_Unmap(ctx_cap, iova)
```

The driver asks the memory server for a DMA buffer; the memory server maps it
into both the driver's VSpace (so it can fill it) and the device's IOMMU context
(so the device can read it), and returns the **IOVA** (the address the device
should be programmed with). The driver never learns a real physical address, and
the device can only reach pages explicitly mapped for it.

Now a compromised driver can, at worst, corrupt its own buffers. That's the
property that makes userspace drivers a security *win* rather than a security
theatre.

**Practical notes:**

- QEMU supports emulated VT-d: `-device intel-iommu,intremap=on` plus
  `-machine kernel-irqchip=split`. Test with it.
- Also enable **interrupt remapping** — without it, a malicious device can send
  arbitrary MSIs, including to vector 2 (NMI). This is a real attack.
- Set up a **default-deny** context for every device at boot, before any driver
  starts. Devices left in passthrough are holes.

### 5.4 Bounded resource use

A driver that allocates per-request state can be DoS'd by its clients. Charge
allocations to the client's Untyped, or preallocate a fixed pool and apply
backpressure. Rings give you backpressure for free (the ring fills, the client
blocks) — another reason to prefer them.

---

## 6. Failure and recovery: the reincarnation server

MINIX 3's most valuable idea. The premise: **components will crash. Design for
recovery instead of pretending they won't.**

### Mechanism

The reincarnation server (RS) holds, for every managed component:

- Its TCB capability (can suspend/resume/inspect)
- Its Untyped capability (can revoke → destroys everything it owns)
- Its fault endpoint (receives its crashes as messages)
- A description of how to restart it (binary, capabilities, manifest entry)
- A heartbeat notification

```c
for (;;) {
    word_t badge = nyx_recv(rs_ep, &m);

    if (m.label == MSG_LABEL_VM_FAULT || m.label == MSG_LABEL_EXCEPTION) {
        struct comp *c = comp_by_badge(badge);
        log("component %s faulted: %s at %p",
            c->name, fault_name(m.w[2]), (void *)m.w[0]);
        restart_component(c);
    }
    else if (badge & BADGE_HEARTBEAT_TIMER) {
        for (each component c)
            if (now - c->last_heartbeat > c->timeout) restart_component(c);
    }
}
```

```c
static void restart_component(struct comp *c) {
    /* 1. Freeze it so it can't do more damage. */
    nyx_invoke(c->tcb, TCB_Suspend);

    /* 2. Optionally snapshot for post-mortem debugging. */
    if (c->dump_on_crash) dump_component(c);

    /* 3. Destroy everything it owned. One operation. */
    nyx_invoke(c->untyped_slot, CNode_Revoke);

    /* 4. Rebuild from the manifest. */
    spawn_component(c);

    /* 5. Notify its clients so they can re-establish. */
    for (each client of c) nyx_signal(client_notif, BIT_SERVICE_RESTARTED);
}
```

### What makes a component restartable

This is a *design property*, not something the RS can provide:

1. **State that matters must live elsewhere or be reconstructible.** A ramdisk
   driver's state is the ramdisk frames — held by capabilities that survive.
   A TCP stack's state is connections, which don't survive; so either you
   checkpoint them or you accept connection loss on restart.
2. **Clients must handle "service restarted"**. In practice: reconnect, re-open
   handles, retry the in-flight operation if idempotent. Bake this into the
   generated client stubs so every client gets it for free.
3. **Idempotent operations** where possible. `write(handle, offset, data)` is
   idempotent; `write(handle, data)` with implicit position is not. Design your
   IDL accordingly. This is the same lesson as distributed systems, because a
   multi-server OS *is* a distributed system on one machine.
4. **The endpoint is recreated**, so old client capabilities become invalid.
   Clients must obtain new ones. Alternatively, keep the endpoint object alive
   (owned by the RS, not the component) so clients keep valid capabilities and
   just see requests handled by a fresh thread. **This is the better design** —
   do it, and restart becomes nearly transparent.

### Beyond restart

Once you have this machinery, several interesting things become easy:

- **Live upgrade**: instead of restarting with the same binary, restart with a
  new one. If the endpoint persists, clients never notice.
- **N-version programming**: run two implementations of a driver and compare.
- **Fault injection testing**: have the RS kill a random component every 30
  seconds and assert the system stays up. **This is an excellent CI job** and it
  will find real bugs in your recovery paths — which are otherwise never
  exercised.

---

## 7. Boot sequence, end to end

```
1. Firmware → GRUB/Limine → kernel
2. Kernel: serial, GDT/IDT, PMM, VMM, scheduler, syscall MSRs
3. Kernel: converts free memory to Untypeds
4. Kernel: loads `root` from initrd, builds its CSpace with everything
5. Kernel: resumes root thread; kernel is now done allocating forever
6. root: parses the manifest embedded in the initrd
7. root: spawns memory server, gives it most Untypeds
8. root: spawns console driver (so everyone can print)
9. root: spawns PCI server, gives it the ECAM Frames + IOPort caps
10. root: spawns ramdisk driver, gives it the initrd Frames
11. root: spawns ramfs, gives it an endpoint to the ramdisk driver
12. root: spawns VFS, gives it an endpoint to ramfs, mounts it at /
13. root: spawns the process manager
14. root: becomes (or spawns) the reincarnation server
15. root: spawns the first application
```

Steps 6–15 are ~500 lines of userspace C driven by a manifest. Getting this
sequence to work end-to-end is the moment your project becomes an operating
system rather than a kernel.

**Debugging tip:** number each step and print it. When the boot hangs at step 11,
you know exactly where to look. This is worth more than any debugger.

---

## 8. Verification

- [ ] Two servers communicate through the VFS with correct badges.
- [ ] `pm_spawn` creates a process that runs and exits, and `pm_wait` returns
      its status.
- [ ] Killing the ramdisk driver (deliberately: `*(int*)0 = 0`) causes the RS to
      restart it, and an in-flight client read succeeds after a retry.
- [ ] A driver cannot map another driver's MMIO (attempt it; expect `-EBADCAP`).
- [ ] With `-device intel-iommu`, a driver programming a DMA address outside its
      mapped IOVA range causes a DMA fault, not memory corruption.
- [ ] The chaos test: RS kills a random component every 5 seconds for 10 minutes;
      the system remains functional and memory usage is stable.

The memory-stability check is important: restart loops leak. Have the RS log
total system Untyped consumption after each restart and assert it returns to
baseline.

---

## 9. Exercises

1. Draw your system's component dependency graph. Verify it's acyclic. Find the
   one edge you'd most like to remove and explain why it exists.
2. Implement the VFS in "name resolver only" mode and measure the difference in
   `read()` latency versus the in-data-path design.
3. Implement a `virtio-blk` driver in userspace. Virtio is well-documented, QEMU
   implements it perfectly, and it uses shared rings — so you'll exercise your
   ring infrastructure against a real protocol.
4. Set up QEMU with `intel-iommu` and demonstrate that a driver cannot DMA
   outside its mapped region.
5. Implement live upgrade: replace a running console driver with a new binary
   without dropping any client. What's the minimum downtime you can achieve?
6. Write the chaos-monkey CI job. How many bugs did it find in the first run?

---

Next: [12 — SMP, concurrency, and memory ordering](12-smp-and-concurrency.md)
