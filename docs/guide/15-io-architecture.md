# 15 — I/O architecture: zero-copy, asynchronous, and direct to the device

> Goal: design the I/O subsystem *first*, as a core kernel concern, rather than
> discovering it later. The thesis of this chapter is that DPDK, SPDK, io_uring,
> RDMA, XDP and GPU command submission are all the same architecture — one that
> monolithic kernels have to bolt on as an escape hatch, and that a microkernel
> should simply *be*.

---

## 1. Theory: where I/O time actually goes

Start with the physics. A modern NVMe SSD services a 4 KiB read in ~10 µs. A
100 GbE NIC delivers a 64-byte packet every 6.7 ns at line rate. At those
timescales, the software overheads that were rounding errors in 1995 dominate:

| Cost | Cycles (typical modern x86-64) | Notes |
|---|---|---|
| `syscall` + `sysret` round trip | 80–150 | Plus 300–1500 with Spectre/Meltdown mitigations |
| Mode-switch cache/TLB pollution | 200–2000 | The *indirect* cost, larger than the direct one (FlexSC's finding) |
| One 4 KiB copy | ~500–1500 | Plus it evicts 4 KiB of someone's working set |
| Interrupt entry + EOI + handler | 1000–3000 | Plus the interrupted thread's lost cache state |
| Context switch (different address space) | 500–2000 | Plus TLB effects even with PCID |
| Cross-core cache line transfer | 100–400 | Every shared counter costs this |
| Memory allocation on the I/O path | 100–10000 | Highly variable — the real-time killer |
| **A 4 KiB NVMe read, hardware** | **~30 000 (10 µs)** | For scale |
| **A 64-byte packet at 100 GbE line rate** | **~20** | You cannot afford *anything* per packet |

The lesson is stark and it is the same one every high-performance I/O framework
independently rediscovered:

> **At modern device speeds, per-operation software overhead must be amortized or
> eliminated, not optimized. The only way to do that is to remove the kernel from
> the data path entirely and batch everything that remains.**

### 1.1 The control plane / data plane split

This is the unifying concept. Every fast I/O system separates:

- **Control plane**: create a queue, register memory, bind an interrupt, set up
  translations, check permissions. Rare, expensive, security-critical.
- **Data plane**: submit a request, poll a completion. Frequent, must be cheap,
  must involve as few parties as possible.

The right architecture puts *authorization in the control plane* and *nothing but
data movement in the data plane*. Once the kernel has decided that this process
may talk to this queue using these buffers, every subsequent operation needs no
kernel involvement at all — the check already happened, and the hardware (MMU
and IOMMU) enforces the result.

A monolithic kernel struggles with this because its security model is ambient:
authority is a property of the *calling context*, so it must be re-evaluated on
every call, so every call must enter the kernel. **A capability system evaluates
authority once, when the capability is handed over, and the capability's
existence is the ongoing proof.** That is why this architecture is natural here
and awkward in Linux.

---

## 2. What the state of the art actually teaches

Rather than list features, extract the *design lesson* from each system.

### 2.1 DPDK (networking, userspace poll-mode drivers)

Bypasses the kernel entirely: the NIC's queues are mapped into a userspace
process, packets land in pre-registered hugepage buffers, and the application
polls instead of taking interrupts.

**Lessons:** (a) polling beats interrupts above a load threshold, and the
crossover is lower than you think; (b) hugepages matter enormously because TLB
misses on packet buffers are a real cost; (c) per-core, share-nothing queue
design eliminates locking; (d) pre-allocated buffer pools eliminate allocation.

**What it gets wrong:** it burns a core at 100% even when idle, it takes over the
whole NIC, and it provides *no* isolation — a DPDK process has raw DMA access.
It is a performance hack that abandons the OS's job.

### 2.2 SPDK (storage, the same idea for NVMe)

NVMe was designed for this: up to 64 K submission/completion queue pairs, each
just a ring in host memory plus a doorbell register. SPDK maps a queue pair to a
userspace thread and polls completions.

**Lessons:** (a) modern devices already speak "shared ring + doorbell"; the
kernel's block layer is pure overhead on top of a protocol that is already a
queue; (b) an lock-free, per-core queue pair beats any amount of clever locking;
(c) the device's own multi-queue support is the isolation primitive — one queue
pair per tenant.

### 2.3 io_uring (Linux, the general answer)

Two shared rings (submission, completion) between the application and the kernel.
Submit N operations with zero or one syscall; reap completions with zero. Plus
**registered** buffers and file descriptors (pre-validated, so the fast path skips
lookup and pinning), and optional kernel-side polling (`SQPOLL`) for a truly
syscall-free data plane.

**Lessons:** (a) batching amortizes the fixed mode-switch cost — this is the big
one, and it is why io_uring beats micro-optimized syscalls; (b) *registration*
(pre-validating a resource so the fast path can skip the check) is the key
mechanism; (c) a completion model composes with everything, a readiness model
does not.

**What it gets wrong, instructively:** io_uring has been a security disaster
(Google disabled it on ChromeOS and Android; multiple sandbox escapes) precisely
because it lets a process queue up hundreds of ambient-authority operations that
execute later, in kernel worker threads, with credentials captured at some
earlier moment. The concept is right; the substrate is wrong. **A capability
system fixes this by construction** — an operation in the ring can only name a
capability the process holds, so "what may this ring do" is exactly "what may this
process do", and it is a static, inspectable set.

### 2.4 RDMA / RoCE / InfiniBand (the most complete model)

The application registers memory regions (getting an `rkey`/`lkey`), creates
queue pairs, and posts work requests. The NIC reads and writes application memory
directly, with no CPU involvement on either side for one-sided operations.

**Lessons:** (a) **memory registration is the right primitive** — pin, translate,
and authorize a region once, then reference it by handle forever; (b) completion
queues can be shared across multiple queue pairs, decoupling notification from
submission; (c) the doorbell/notification decision (poll the CQ vs arm an
interrupt) should be per-operation and dynamic; (d) one-sided operations (remote
read/write with no remote CPU involvement) are a genuinely different capability
and change how you write distributed software.

### 2.5 eBPF / XDP (programmable early hooks)

XDP runs a verified bytecode program at the driver's receive path, before any
allocation, and can drop, redirect, or pass packets.

**Lesson, and it is a subtle one:** XDP exists *because Linux's data plane is
inside the kernel*. If you want to act on a packet before the kernel's overhead
is incurred, and the kernel owns the driver, then your only option is to inject
your code into the kernel — hence a bytecode VM and a verifier. **In a
microkernel, the driver is already a userspace process, so "run my code early in
the receive path" is solved by placement, not by a VM.** You get XDP's benefit
with none of its machinery.

The residual case for verified bytecode is real but narrower: running filter
logic *somewhere you cannot place a process* — on a SmartNIC, inside another
protection domain you don't own, or in the kernel ISR itself for the rare
sub-microsecond decision. Keep that in mind as a possible extension (see §10),
but do not start there.

### 2.6 Windows IOCP / RIO, and Registered I/O

Completion ports: a kernel object that queues completions, with a bounded pool of
threads dequeuing them. RIO adds registered buffers and pre-registered
descriptors — io_uring's ideas, a decade earlier, for sockets.

**Lessons:** (a) the completion-port *concurrency* model (a fixed thread pool
that dequeues completions, with the kernel keeping exactly N runnable) is better
than the "thread per connection" and "one reactor thread" extremes; (b) explicit
completion delivery beats readiness signalling; (c) Windows got asynchrony right
in 1993 and POSIX still hasn't, which should tell you something about how hard it
is to retrofit.

**What it gets wrong:** cancellation is under-specified and racy, and the buffer
ownership rules across cancellation are famously error-prone. Design cancellation
*first*, not last. (io_uring made the same mistake.)

### 2.7 GPU command submission

The same shape again: a ring buffer of commands in memory the GPU can read, a
doorbell, and fences/completion signals. Modern APIs (Vulkan, CUDA) expose
explicit command buffers, explicit memory, explicit synchronization — because the
abstraction layers that hid this were the bottleneck.

**Lesson:** even the most complex device in the machine reduces to
*registered memory + command ring + doorbell + completion*. That is now four out
of four device classes with the same structure. This is not a coincidence; it is
what PCIe and DMA make efficient.

### 2.8 The synthesis

| System | Registered memory | Shared ring | Doorbell | Completion | Poll or IRQ | Kernel on data path |
|---|---|---|---|---|---|---|
| DPDK | Hugepage pools | RX/TX rings | MMIO write | Descriptor writeback | Poll | No |
| SPDK | Pinned buffers | NVMe SQ/CQ | MMIO write | CQ entry | Poll | No |
| io_uring | Registered buffers | SQ/CQ | `io_uring_enter` | CQE | Either | Yes (or SQPOLL thread) |
| RDMA | Memory regions | QP send/recv | MMIO write | CQE | Either | No |
| GPU | Buffer objects | Command ring | MMIO write | Fence | Either | No |
| **Nyx (this chapter)** | **`IoRegion`** | **`IoQueue`** | **cap invocation or MMIO** | **`IoQueue` CQ** | **Adaptive** | **No** |

Six systems, one architecture. **So make that architecture the OS's native I/O
model rather than an escape hatch from it.**

---

## 3. The Nyx I/O model

Three new kernel object types, and one rule.

### 3.1 The rule

> **The kernel establishes the data path and then is not on it.** Every kernel
> involvement in I/O is control-plane: creating a region, creating a queue,
> binding a queue to a device or a server, routing an interrupt. After that, a
> submission is a store to shared memory and a completion is a load.

### 3.2 `IoRegion` — registered memory

```c
/* A contiguous span of physical frames, mapped into one or more address spaces
 * and (optionally) into one or more IOMMU domains. Created by retyping
 * Untyped memory, like everything else. */
struct io_region {
    struct kobject hdr;
    paddr_t   base;             /* physical base (may be a frame list)       */
    size_t    size;
    uint32_t  flags;            /* IOR_DMA, IOR_COHERENT, IOR_HUGE, IOR_P2P  */
    uint16_t  ndomains;         /* IOMMU domains it is mapped into           */
    uint64_t  iova[MAX_IOMMU_DOMAINS];  /* device-visible address per domain */
    uint32_t  refcount;
};
```

Invocations: `IoRegion_MapVSpace(vspace, vaddr, rights)`,
`IoRegion_MapDevice(iommu_ctx, rights) → iova`, `IoRegion_Unmap`.

This single object unifies RDMA's memory region, io_uring's registered buffer,
DPDK's mempool backing, and a GPU buffer object. The properties that matter:

- **Pinned by construction.** It is retyped untyped memory; nothing can reclaim
  it while the capability exists. No `get_user_pages` equivalent, no pinning
  accounting, no `RLIMIT_MEMLOCK`. The capability *is* the pin.
- **Its IOVA is authority.** A device can only reach memory that has been mapped
  into its IOMMU domain. Handing a device queue to a process is only safe because
  the process's regions are the only thing that device can touch (§6).
- **Sharing is capability transfer.** Zero-copy between two processes is
  `cap_copy` of an `IoRegion` capability, possibly with reduced rights. No
  `mmap`, no shared-memory namespace, no naming problem.

### 3.3 `IoQueue` — the universal queue

```c
/* include/abi/ioqueue.h — SHARED between kernel, servers, and applications.
 * Layout is ABI. Version it. */

struct io_sqe {                 /* submission queue entry — 32 bytes         */
    uint16_t opcode;            /* interface method number                   */
    uint8_t  flags;             /* IOSQE_LINK, IOSQE_FIXED_REGION, ...       */
    uint8_t  ncaps;             /* capability slots referenced, if any        */
    uint32_t region;            /* IoRegion index in the queue's region table */
    uint64_t offset;            /* offset within the region                   */
    uint32_t len;
    uint32_t cap;               /* target object (index into queue's cap set) */
    uint64_t user_token;        /* opaque; echoed in the completion           */
};

struct io_cqe {                 /* completion queue entry — 16 bytes         */
    uint64_t user_token;
    int32_t  result;            /* >= 0 success (bytes/count), < 0 error     */
    uint32_t flags;             /* IOCQE_MORE (multishot), IOCQE_BUF_OWNED   */
};

struct io_queue_hdr {           /* first page of the shared region           */
    uint32_t sq_mask, cq_mask;  /* power-of-two sizes minus one              */
    uint32_t abi_version;

    _Alignas(64) volatile uint32_t sq_tail;   /* written by producer         */
    _Alignas(64) volatile uint32_t sq_head;   /* written by consumer         */
    _Alignas(64) volatile uint32_t cq_tail;   /* written by consumer         */
    _Alignas(64) volatile uint32_t cq_head;   /* written by producer         */

    _Alignas(64) volatile uint32_t flags;     /* IOQ_NEED_DOORBELL, IOQ_OVERFLOW */
    volatile uint32_t dropped;
};
```

`_Alignas(64)` on each index is not decoration: producer and consumer indices on
the same cache line cost you a coherence transfer per operation, which at
100 GbE is your entire budget. This is the single most common mistake in
hand-written ring code.

The kernel object:

```c
struct io_queue {
    struct kobject hdr;
    struct io_region *ring;         /* shared memory holding hdr + SQ + CQ   */
    struct io_endpoint *peer;       /* server endpoint, or                   */
    struct device_queue *hw;        /* hardware queue, or                    */
    cap_t     doorbell;             /* Notification to signal the consumer   */
    cap_t     completion;           /* Notification signalled on completion  */
    struct cap caps[IOQ_MAX_CAPS];  /* pre-registered target capabilities    */
    struct io_region *regions[IOQ_MAX_REGIONS];  /* pre-registered buffers   */
    struct sched_context *sc;       /* whose budget polling is charged to    */
};
```

The `caps[]` and `regions[]` arrays are the **registration** mechanism, the idea
lifted from RDMA and io_uring. A submission names a capability by *index into a
pre-authorized table*, not by CPtr lookup. So the authorization work — capability
lookup, rights check, IOMMU mapping, pinning — happens once at registration and
never again. This is what makes a zero-syscall data path *safe* rather than
merely fast.

### 3.4 The key architectural decision

> **A queue whose peer is a userspace server and a queue whose peer is a hardware
> device have the same structure and the same application-side code.**

An application submitting a read to a filesystem server and an application
submitting a read to an NVMe queue pair it has been granted execute *the same
instructions*. What differs is who consumes the submission: a server thread, or
the device itself.

The consequences are worth being explicit about, because this is the design's
main claim:

1. **Direct device access stops being a special case.** "Kernel bypass" is not a
   bypass; it is the normal path with a hardware peer. There is no fast path to
   escape to, because there is no slow path.
2. **Software services are as fast as they can be.** A userspace filesystem is
   not penalized by an OS-imposed syscall-per-operation model.
3. **You can substitute one for the other.** Start with a software peer (a driver
   server doing the NVMe submission on your behalf, with a copy or a translation)
   and later hand the application its own hardware queue pair. The application
   does not change. **This is a policy decision made at deployment time**, which
   is exactly the kind of thing a microkernel should make cheap.
4. **Interposition is free.** Want to log, rate-limit, encrypt, or multiplex?
   Put a component between the two queues. It sees the same interface. Try that
   with DPDK.

---

## 4. The data path in detail

### 4.1 Submission (userspace, no syscall)

```c
/* user/libnyx/io.c */
int ioq_submit(struct ioq *q, const struct io_sqe *sqe)
{
    uint32_t tail = q->hdr->sq_tail;               /* we are the producer    */
    uint32_t head = atomic_load_explicit(&q->hdr->sq_head, memory_order_acquire);

    if (tail - head > q->hdr->sq_mask)             /* full: backpressure     */
        return -EAGAIN;

    q->sqe[tail & q->hdr->sq_mask] = *sqe;

    /* Release: the entry must be visible before the index that publishes it. */
    atomic_store_explicit(&q->hdr->sq_tail, tail + 1, memory_order_release);
    return 0;
}

void ioq_flush(struct ioq *q)
{
    /* Ring the doorbell only if the consumer told us it needs one. A polling
     * consumer clears IOQ_NEED_DOORBELL; then this is free. */
    if (atomic_load_explicit(&q->hdr->flags, memory_order_acquire) & IOQ_NEED_DOORBELL)
        nyx_notify(q->doorbell);     /* one syscall for the whole batch      */
    else if (q->hw_doorbell)
        mmio_write32(q->hw_doorbell, q->hdr->sq_tail);   /* device: one store */
}
```

Submitting 64 operations costs 64 stores and at most one syscall — and often
zero. Compare with 64 syscalls, 64 credential checks, and 64 buffer validations.

### 4.2 Completion (userspace, no syscall)

```c
int ioq_reap(struct ioq *q, struct io_cqe *out, int max)
{
    uint32_t head = q->hdr->cq_head;
    uint32_t tail = atomic_load_explicit(&q->hdr->cq_tail, memory_order_acquire);
    int n = 0;
    while (head != tail && n < max)
        out[n++] = q->cqe[head++ & q->hdr->cq_mask];
    atomic_store_explicit(&q->hdr->cq_head, head, memory_order_release);
    return n;
}
```

### 4.3 The wait decision: adaptive polling

Pure polling burns a core. Pure interrupts cost 1–3 µs per event and destroy
cache locality. The right answer is the one NAPI, DPDK's interrupt mode, and
`io_uring`'s `IORING_SETUP_IOPOLL` all converge on: **poll while work is
arriving; arm a notification when it stops.**

```c
int ioq_wait(struct ioq *q, struct io_cqe *out, int max, uint64_t spin_ns)
{
    uint64_t deadline = now_ns() + spin_ns;
    do {
        int n = ioq_reap(q, out, max);
        if (n) return n;
        cpu_relax();                       /* `pause` — essential on SMT     */
    } while (now_ns() < deadline);

    /* Arm, then re-check: the classic lost-wakeup race. The re-check after
     * arming is mandatory and it is where everyone's first version is wrong. */
    ioq_arm_completion(q);
    int n = ioq_reap(q, out, max);
    if (n) { ioq_disarm(q); return n; }

    nyx_wait(q->completion);               /* block: one syscall             */
    return ioq_reap(q, out, max);
}
```

Two design notes that matter more than the code:

- **`spin_ns` should be adaptive**, converging on the observed inter-arrival
  time. A fixed value is wrong at both ends of the load range. Track an EWMA of
  the gap between completions and spin for roughly that long.
- **Polling is CPU consumption and must be charged.** This is where Chapter 14
  and this chapter meet: the queue's `sc` field means a busy-polling application
  burns *its own* budget. A polling loop cannot starve the system because the
  scheduler is still in charge. DPDK's "burn a core forever" behaviour is
  precisely a failure to account, and the fix falls out of having scheduling
  contexts.

### 4.4 The server side

A server consuming an `IoQueue` looks like a device:

```c
for (;;) {
    int n = ioq_wait(&q, cqes, 64, adaptive_spin);   /* drain a batch        */
    for (int i = 0; i < n; i++)
        handle(&sqe[i]);                             /* amortized dispatch   */
    ioq_complete_batch(&q, results, n);              /* one release store    */
}
```

Batching on the server side is where the throughput comes from: one wake-up
amortized over 64 requests, one cache-warm loop over homogeneous work, one
completion publish. This is why the io_uring design beats a hand-optimized
syscall — not because the syscall got faster, but because there are 1/64 as many.

---

## 5. Ownership, or how zero-copy actually goes wrong

Zero-copy is easy to describe and hard to get right, because a copy is also an
*ownership transfer* and removing the copy means the transfer must be made
explicit. Every zero-copy bug is an ownership bug.

Nyx's rules, which must be written in `docs/io-ownership.md` and enforced by the
generated stubs:

1. **A buffer has exactly one owner at a time.** Submitting an SQE transfers
   ownership of the referenced buffer range to the consumer. The producer must
   not read or write it until the corresponding CQE arrives.
2. **The completion returns ownership.** `IOCQE_BUF_OWNED` distinguishes "the
   buffer is yours again" from "the consumer kept it" (used for receive paths
   where the consumer hands you a *different* buffer from a pool).
3. **Cancellation must be explicit and must have a terminal completion.** This
   is the rule everyone gets wrong. `IORING_OP_ASYNC_CANCEL` and Win32's
   `CancelIoEx` both have subtle races. The Nyx rule: *cancellation is a request,
   never a guarantee; the original operation always produces exactly one CQE,
   either with its normal result or with `-ECANCELED`; the buffer is only safe to
   reuse after that CQE.* Specify this now, test it, and never break it.
4. **The consumer must validate everything, every time.** The producer shares
   memory with the consumer and can change it concurrently. Therefore: read each
   field *once* into a local, then validate the local. A re-read is a TOCTOU
   vulnerability. In C, that means using an explicit atomic load, not hoping the
   compiler doesn't reload.

```c
/* Correct: read-once-then-validate. */
struct io_sqe e = q->sqe[idx & mask];      /* single structure copy          */
if (e.region >= IOQ_MAX_REGIONS) return -EINVAL;
struct io_region *r = q->regions[e.region];
if (!r) return -EINVAL;
if (e.offset > r->size || e.len > r->size - e.offset) return -EINVAL;  /* no overflow */
```

5. **Bounded rings are the flow control.** A full submission queue means "stop";
   a full completion queue means the consumer must apply backpressure rather than
   drop. Never allocate to absorb a burst — that converts a bounded system into
   an unbounded one and reintroduces every problem you removed.
6. **Alignment and coherence are the producer's job to declare and the control
   plane's job to check.** DMA to a non-coherent region, or across a page
   boundary the IOMMU didn't map, fails in ways that are extremely hard to debug.
   Validate at registration.

---

## 6. Safe direct device access: the IOMMU is the whole story

Chapter 11 §5.3 made the point; here is the design that follows from it.

**A device performing DMA bypasses the MMU.** A userspace driver with raw access
to a device's DMA engine can write anywhere in physical memory, including your
kernel. Without an IOMMU, userspace drivers protect you from *buggy* drivers and
not at all from *malicious* ones — which is honest MINIX 3 territory and worth
saying out loud, but is not what we are building.

With an IOMMU (Intel VT-d, AMD-Vi, Arm SMMU), each device gets its own address
space:

```c
struct iommu_ctx {
    struct kobject hdr;
    uint16_t  domain_id;
    void     *root;                 /* second-level page tables              */
    uint32_t  nregions;
};

/* Control plane, kernel-mediated, once per region: */
int iommu_map_region(struct iommu_ctx *ctx, struct io_region *r,
                     uint64_t iova, uint32_t rights);
```

### 6.1 The granularity problem

An IOMMU context is normally **per device**, but you want isolation **per queue**
so that two mutually distrusting applications can each hold an NVMe queue pair on
the same drive. That requires hardware help:

| Mechanism | What it gives | Availability |
|---|---|---|
| **SR-IOV** | Virtual functions, each with its own PCI function and IOMMU context | Common on server NICs, some NVMe |
| **PASID / Scalable IOV** (Intel), Arm SMMUv3 substreams | Per-*process* address spaces on a single function; the device tags each transaction | Newer server hardware |
| **NVMe namespaces + queue ownership** | Logical isolation of storage, but not of DMA targets | All NVMe — but only useful *with* one of the above |
| **Nothing** | Per-device isolation only | Consumer hardware |

So the honest design is layered, and the layer is chosen at deployment:

1. **Best**: SR-IOV VF or PASID → the application gets a real hardware queue and
   direct isolation. Full zero-copy, zero-kernel data path.
2. **Middle**: a per-device **driver server** owns the device and hands each
   client a *software* `IoQueue`; the driver translates client submissions into
   device submissions. Still one shared-memory hop, still batched, still no
   copies (the client's `IoRegion` is what the device DMAs into — the driver only
   moves descriptors, not data). **This is the default, and it is already very
   good: the copy is gone, only the descriptor translation remains.**
3. **Worst**: no IOMMU → the driver server must copy into its own buffers, or you
   accept that drivers are trusted. Make this a build-time configuration with a
   loud warning, not a silent default.

The beautiful part is that **the application code is identical in all three
cases.** That is the payoff for the §3.4 decision.

### 6.2 Interrupt remapping is not optional

Repeating Chapter 11's warning because it is the one that gets skipped: without
**interrupt remapping**, a device (or a driver that programs it) can generate an
arbitrary MSI — including vector 2 (NMI) or an SMI — targeted at any core. That
is a complete bypass of your interrupt architecture. Enable `intremap` in VT-d,
and test with:

```
qemu-system-x86_64 -machine q35,kernel-irqchip=split \
  -device intel-iommu,intremap=on,device-iotlb=on ...
```

Default every context to **deny-all at boot**, before any driver starts. A device
left in a state where it is still DMAing from a previous OS (kexec, or firmware
that didn't quiesce) will otherwise corrupt you during boot.

### 6.3 Peer-to-peer DMA

GPUDirect, NVMe-to-GPU, NIC-to-NVMe: one device DMAs directly to another's BAR,
never touching host memory. In this model it is a natural extension — an
`IoRegion` with `IOR_P2P` whose backing is a device BAR rather than RAM, mapped
into both devices' IOMMU contexts. The plumbing is the same; only the physical
backing differs. Getting this right (ACS settings, root-complex support, and the
fact that many chipsets silently route P2P through host memory anyway) is fiddly
but the *architecture* costs nothing extra, which is a good sign that the
abstraction is the right one.

---

## 7. What this does to the rest of the system

### 7.1 IPC and I/O converge

Chapter 08 defined three mechanisms: Endpoints (synchronous, control plane),
Notifications (async signals), Rings (bulk data). This chapter promotes Rings to
`IoQueue`, gives them registration and capability semantics, and makes them the
*primary* interface for anything with throughput. The resulting decision rule:

| Situation | Mechanism |
|---|---|
| Request/response, needs an answer now, small | **Endpoint `Call`** (200–500 cycles) |
| Signalling an event, no data | **Notification** |
| Streams of operations, throughput matters, latency tolerant of batching | **`IoQueue`** |
| Anything touching a device | **`IoQueue`** |
| Setup, binding, authorization | **Endpoint `Call`** (control plane, always) |

Note the corollary: **the synchronous IPC fast path is now for control, not for
data.** That is a slightly heretical position for an L4-lineage kernel, where IPC
performance is the headline number, and it is worth defending explicitly: IPC
latency still determines how finely you can decompose the system, so it still
matters enormously — but it should not be on the path of a 4 KiB disk read.

### 7.2 Real-time interaction

From Chapter 14: because completions carry a `user_token` and queues carry a
scheduling context, the work a driver does on behalf of a request is *traceable
to the requester*. That makes the open problem in Chapter 14 §4.5 — charging
device and driver time to the client — actually implementable here. Concretely:
the driver, before processing an SQE, can switch to the scheduling context
associated with that SQE's originating queue. This is a small change and, as far
as I know, no OS does it. **It is the strongest single research idea in this
book.**

### 7.3 The "everything is a file" question

Notice what did *not* happen in this chapter: nothing was named by a path, and
nothing was a byte stream. A queue is bound to a peer by capability. That is
deliberate, and it is the subject of the next chapter.

---

## 8. Building it: a concrete order

1. **`IoRegion`** with VSpace mapping only. Test: two processes share a region,
   one writes, the other reads. No devices yet.
2. **`IoQueue`** with a software peer. Build a null service that completes every
   SQE immediately. Benchmark submissions/second. This is your baseline forever.
3. **The ownership rules and cancellation semantics**, with tests, before any
   real consumer exists. Retrofitting cancellation is how io_uring got its CVEs.
4. **A real software peer**: the ramdisk driver from Chapter 11, reimplemented as
   an `IoQueue` consumer. Compare with the Endpoint-based version. *Publish both
   numbers.*
5. **IOMMU support**, deny-all by default, with interrupt remapping. Test under
   QEMU's `intel-iommu`.
6. **A real device**: NVMe is the right first choice. Its queues are already
   exactly this shape, the spec is short and free, QEMU emulates it well, and the
   identify/admin-queue bootstrap is straightforward. `virtio-blk` is even easier
   if you want a warm-up.
7. **A NIC**: `virtio-net` first, then a real one (Intel e1000e is well
   documented; i40e/ice if you want multi-queue). Multi-queue is where the
   architecture pays off.
8. **Adaptive polling with budget accounting** (§4.3 + Chapter 14).
9. **Direct queue grant** with SR-IOV or PASID, if your hardware has it.

Milestones 1–4 are a couple of weekends and give you most of the intellectual
content. Milestone 6 is where it becomes a real system.

---

## 9. Verification and benchmarks

```c
KTEST(ioq_ownership_violation_detected) {
    /* Debug build: poison a submitted buffer and assert the producer cannot
     * touch it before completion (page-protect it, or check a shadow map). */
}

KTEST(ioq_cancel_always_completes_once) {
    /* Submit N ops, cancel all of them at random times, assert exactly N CQEs
     * arrive and every user_token appears exactly once. Run it 10^6 times
     * with randomized timing. This is the test that prevents your io_uring. */
}

KTEST(ioq_consumer_validates_toctou) {
    /* A malicious producer mutates the SQE while the consumer processes it.
     * Assert no out-of-bounds access. Run under a modified consumer that
     * re-reads, and confirm the test FAILS — proving the test has teeth. */
}

KTEST(ioq_full_applies_backpressure) {
    /* Fill the SQ; assert submit returns EAGAIN, nothing is dropped, no
     * allocation occurred, and memory usage is flat. */
}

KTEST(iommu_denies_unmapped_dma) {
    /* Program a device to DMA outside its mapped region; assert a fault is
     * reported and no memory changed. Requires QEMU intel-iommu. */
}
```

Benchmark table to track in CI from day one (Chapter 18):

| Benchmark | Baseline to beat | Why it matters |
|---|---|---|
| Null-service submissions/sec, batch=1 | ~1–2 M/s | Shows per-op overhead |
| Null-service submissions/sec, batch=64 | ~20–50 M/s | Shows the batching win |
| Ping-pong latency via `IoQueue`, polled | ~0.5–1 µs | Compare with Endpoint IPC |
| Ping-pong latency via Endpoint | 0.3–0.5 µs | The control-plane number |
| 4 KiB ramdisk read, batch=32 | Should approach memcpy bandwidth | Proves zero-copy works |
| NVMe 4 KiB random read IOPS, QD=32 | Within 10% of SPDK on the same device | The real claim |
| CPU cycles per I/O at saturation | < 1000 | The number SPDK/DPDK publish |

**Publishing "cycles per I/O" next to SPDK's and Linux's numbers, from an OS that
also provides isolation, would be the headline result of this project.**

---

## 10. Open questions worth your time

1. **Does the capability model actually make batched I/O safe?** State the claim
   precisely ("the set of operations a ring can perform is exactly the set of
   capabilities registered at setup, which is inspectable and static") and then
   try hard to break it. Compare, item by item, with the io_uring CVE list. This
   is a paper.
2. **Charge driver and device time to the requesting client** (§7.2). Implement,
   measure, and show that a storage-heavy tenant can no longer steal CPU from a
   latency-sensitive one.
3. **Is there still a case for verified bytecode?** With userspace drivers, XDP's
   motivation largely disappears — but SmartNIC offload and sub-microsecond
   in-ISR decisions remain. Characterize precisely when placement is insufficient.
4. **Automatic queue placement.** Given the observed queue graph, which core
   should each consumer run on? Ties to Chapter 13 D3.
5. **Can the queue interface be the *only* I/O interface?** Try to build a
   complete system — console, filesystem, network, timers — where every data
   operation is an `IoQueue` submission and Endpoints only ever do setup. Where
   does it become awkward? Interactive terminal I/O and single small
   configuration reads are the obvious stress cases. Report honestly.
6. **Multishot and streaming completions.** io_uring added multishot receives
   (one submission, many completions) because per-packet submission is wasteful.
   Design the semantics properly from the start, including how cancellation and
   buffer ownership work for a multishot operation — nobody has done this cleanly.

---

## 11. Exercises

1. Implement `IoRegion` and `IoQueue` with a null service. Measure
   submissions/second at batch sizes 1, 4, 16, 64, 256. Plot it. Explain the
   shape of the curve — specifically, where it stops improving and why.
2. Implement the same ramdisk service twice: once over synchronous Endpoint IPC,
   once over `IoQueue`. Measure both across a range of request sizes. Find the
   crossover point and explain it in terms of §1's cost table.
3. Write `ioq_cancel_always_completes_once` *before* implementing cancellation.
   Watch it fail. Then make it pass.
4. Implement adaptive spin. Compare fixed spin values (0, 1 µs, 10 µs, 100 µs)
   with the adaptive version across three load levels. Report CPU consumed as
   well as latency — a latency win paid for by a burned core is not a win.
5. Bring up `virtio-blk` as an `IoQueue` consumer under QEMU. Then bring up NVMe.
   Write down what the two device models have in common and where the abstraction
   leaked.
6. **Argue the other side**: make the case that a synchronous read/write syscall
   interface is the right default for most applications, and that this chapter's
   architecture is premature optimization that pushes complexity onto every
   programmer. What would a good ergonomic layer over `IoQueue` look like, and can
   it be zero-cost?
7. **Design exercise**: specify the semantics of a multishot receive operation —
   submission, completions, buffer provisioning, cancellation, and error
   handling — in one page, precisely enough to implement from. This is harder
   than it looks and is a genuine contribution if done well.

---

Next: [16 — Naming, objects, and system state: beyond "everything is a file"](16-naming-and-objects.md)
