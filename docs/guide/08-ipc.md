# 08 — IPC: the heart of a microkernel

> This is the chapter that determines whether your OS is good. Everything else is
> replaceable; the IPC design is load-bearing for the entire system's
> performance, security, and structure.

---

## 1. Theory: why IPC is *the* microkernel problem

In a monolithic kernel, a subsystem calls another subsystem with a `call`
instruction: ~1 ns, no state change, shared memory. In a microkernel, the same
interaction costs a mode switch, possibly an address space switch, a scheduling
decision, and a data copy.

Liedtke's framing: **IPC performance is the primary determinant of microkernel
viability, and it must be optimized to within a few percent of the hardware
minimum.** He argued you should compute the theoretical minimum — the cycles the
hardware *must* spend — and treat any gap as a bug.

For a modern x86-64 same-core, cross-address-space call:

```
syscall entry (SYSCALL + swapgs + stack switch)     ~50-80 cycles
save/restore minimal state                          ~20 cycles
message transfer in registers                       ~10 cycles
address space switch (CR3 with PCID)                ~150-250 cycles
scheduling decision (skipped with direct switch)    ~0
sysret exit                                         ~50 cycles
────────────────────────────────────────────────────────────────
theoretical round trip (call + reply)               ~600-1000 cycles ≈ 0.2-0.3 µs
```

seL4 measures ~300–500 cycles one-way on x86-64. If your first implementation is
5000 cycles, that's fine — but you should know the number, know the target, and
close the gap deliberately.

### Design axes

Every IPC design picks a point on each of these:

| Axis | Options | Tradeoff |
|---|---|---|
| **Synchrony** | Synchronous (rendezvous) / Asynchronous (buffered) | Sync: no kernel buffers, no overflow, natural flow control, but forces the caller to block and requires both parties to be ready. Async: decoupled, but the kernel must buffer, which means allocation, which means DoS. |
| **Naming** | Direct (thread IDs) / Indirect (ports/endpoints) | Direct is faster (no lookup) but couples the sender to a specific thread and leaks identity. Indirect allows server thread pools, migration, and interposition. |
| **Data** | Registers / Kernel copy / Shared memory / Page mapping | Registers are free; copies are O(n); mapping is O(1) but costs TLB and page-table work. |
| **Authority** | Ambient (any thread can send to any) / Capability-gated | Capabilities are the whole point. |
| **Blocking** | Blocking / Non-blocking / Timeout | Timeouts prevent DoS-by-not-receiving, but add a timer per blocked thread. |

### Historical designs

**Mach**: asynchronous, ports with kernel-buffered message queues, complex typed
messages with out-of-line data and port-right transfer. Powerful, slow, and the
buffering is a resource-management nightmare.

**MINIX 3**: synchronous `send`/`receive`/`sendrec`, fixed-size 64-byte messages
copied by the kernel, direct addressing by process number, plus `notify` for
asynchronous events. Simple and readable. Grants for bulk data.

**L4 / seL4**: synchronous rendezvous on *endpoint* objects, message in registers
(plus an optional per-thread IPC buffer for longer messages), capability-gated,
badges for client identification, direct process switch, no timeouts in seL4
(they were removed as unverifiable/unnecessary), separate Notification objects
for async.

**Nyx** takes the L4/seL4 structure and adds a modern asynchronous bulk path.

---

## 2. The Nyx IPC design

### Three mechanisms, deliberately distinct

```
1. Endpoint    — synchronous rendezvous. Small messages in registers.
                 The control plane. Call/reply RPC.

2. Notification— asynchronous, coalescing bitmask signal. No data.
                 Events: "IRQ fired", "data ready", "your child died".

3. Ring        — shared-memory SPSC/MPMC ring buffers between two processes,
                 with a Notification for wakeup. The data plane. Batched.
```

The insight (which io_uring made mainstream in Linux, and which Barrelfish, FlexSC
and others explored earlier): **the cost of a mode switch is fixed, so amortize
it over many operations.** For a high-throughput path (network packets, disk
blocks) you must batch. Rings give you that; synchronous IPC never can.

### The message

```c
/* include/abi/message.h — part of the STABLE ABI */

#define MSG_MAX_WORDS 6
#define MSG_MAX_CAPS  4

typedef uint64_t word_t;

typedef struct {
    word_t label;           /* method selector + flags, set by sender */
    word_t nwords : 8;      /* how many of w[] are valid */
    word_t ncaps  : 4;      /* how many capabilities are being transferred */
    word_t flags  : 20;
    word_t badge;           /* set by the KERNEL on receive; sender cannot forge */
    word_t w[MSG_MAX_WORDS];
} message_t;
```

Register mapping for the fast path (System V says RDI RSI RDX RCX R8 R9 are args,
but `syscall` destroys RCX and R11, so we shuffle):

```
Syscall entry:
  RAX = syscall number / operation
  RDI = capability index (the destination endpoint)
  RSI = message label + counts (packed)
  RDX, R10, R8, R9, R12, R13 = message words w[0..5]
Return:
  RAX = result / label
  RSI = badge
  RDX, R10, R8, R9, R12, R13 = reply words
```

> **Transport width is a separate number from message width.** `MSG_MAX_WORDS`
> above is how many words the kernel's message buffer holds. How many a
> *syscall* can carry is a property of the register mapping, and the two
> registers this table assigns to words 4 and 5 (R12, R13) are callee-saved
> under SysV — so using them obliges every generated stub to save and restore
> them on every call. A transport that carries four words and leaves the
> remaining two reachable only to kernel-internal callers is a reasonable
> point on that tradeoff. Whichever is chosen, `include/abi/syscall.h` is the
> specification; this table is prose.

**Six words is not arbitrary.** It's enough for: an operation code, a
file/object handle, an offset, a length, and two flags — which covers the
overwhelming majority of RPC calls. Anything bigger uses a ring or a shared
frame. Measure your actual message size distribution once you have servers
running; if 95% fit in 6 words, the design is right.

### Endpoints

```c
struct endpoint {
    struct kobject  hdr;          /* type, refcount, CDT links (Ch.09) */
    enum { EP_IDLE, EP_SEND_Q, EP_RECV_Q } state;
    struct list_head queue;       /* threads blocked, all in the same direction */
};
```

**The key invariant:** an endpoint's queue holds either senders or receivers,
never both. If a sender arrives and there's a receiver waiting, they rendezvous
immediately and neither queues. This makes the object tiny and the logic small.

An endpoint is *not* a mailbox, a channel, or a queue of messages. It is a
**meeting point**. No message ever resides in an endpoint.

### Badges: how a server knows who's calling

When a capability to an endpoint is *minted* (derived with a value attached), the
kernel stamps that value into every message sent through it:

```
Server creates Endpoint E, holds cap E₀ (unbadged, can receive)
Server mints  E₁ = badge(E, 0x1001) → gives to client A
Server mints  E₂ = badge(E, 0x1002) → gives to client B

Client A sends via E₁ → server receives msg with badge == 0x1001
Client B sends via E₂ → server receives msg with badge == 0x1002
```

Properties:

- **Unforgeable.** The badge is in the capability, which lives in the kernel's
  CSpace, not in user memory. A client cannot claim to be another client.
- **Zero-cost authentication.** No credentials, no tokens, no lookup. The server
  uses the badge as a direct index into its client table.
- **Revocable.** Deleting the badged capability cuts off exactly that client.

This one mechanism replaces UIDs, session tokens, and most of what an
authentication layer does. It is the single best argument for capabilities.

### Reply capabilities

When a client uses `call` (send + wait for reply), the kernel creates a one-shot
**reply capability** and puts it in the receiving server's designated slot. The
server replies by invoking it; the capability is then consumed.

Why not just "reply to the thread that sent"? Because:

- A server may want to *delegate* the reply to another thread or process
  (essential for asynchronous server architectures and for a VFS that forwards to
  a filesystem server without staying in the loop).
- One-shot semantics prevent a buggy server from replying twice.
- It makes "who is allowed to unblock this thread" explicit and auditable.

```c
struct tcb {
    ...
    struct tcb *reply_to;      /* the caller we owe a reply to (fast path) */
    word_t      reply_badge;
};
```

For the fast path, storing the caller pointer in the callee's TCB is sufficient
and free. For delegation, promote it to a real `Reply` capability object.

---

## 3. The syscall surface

Deliberately tiny:

```c
enum syscall {
    SYS_SEND,       /* block until a receiver takes the message */
    SYS_NBSEND,     /* deliver if a receiver is waiting, else fail */
    SYS_RECV,       /* block until a message arrives */
    SYS_NBRECV,
    SYS_CALL,       /* send + block for reply (the common case) */
    SYS_REPLY,      /* reply to the stored reply cap */
    SYS_REPLYRECV,  /* reply then immediately receive — THE server loop */
    SYS_SIGNAL,     /* notification: set bits, wake waiter */
    SYS_WAIT,       /* notification: block until bits are set, then clear */
    SYS_POLL,       /* notification: read+clear without blocking */
    SYS_YIELD,
    SYS_INVOKE,     /* object-specific method (Retype, Map, SetPriority, ...) */
    SYS_DEBUG,      /* only in debug builds: putchar, dump, halt */
};
```

`SYS_REPLYRECV` deserves emphasis. The canonical server loop is:

```c
message_t m;
word_t badge = nyx_recv(service_ep, &m);
for (;;) {
    handle(badge, &m);                          /* fills m with the reply */
    badge = nyx_replyrecv(service_ep, &m);      /* one syscall, not two */
}
```

Combining reply and receive into one syscall halves the mode switches for a
server. This is a 2× win on the dominant path, from one line of design. Liedtke's
lesson in miniature.

---

## 4. Implementation

### The slow path (write this first, in C, clearly)

```c
/* kernel/ipc/ipc.c */

static void msg_transfer(struct tcb *from, struct tcb *to) {
    unsigned n = MIN(from->msg.nwords, MSG_MAX_WORDS);
    to->msg.label  = from->msg.label;
    to->msg.nwords = n;
    for (unsigned i = 0; i < n; i++)
        to->msg.w[i] = from->msg.w[i];

    /* Badge comes from the capability the SENDER used, not from the sender. */
    to->msg.badge = from->send_badge;

    /* Capability transfer, if any (Ch.09). */
    if (from->msg.ncaps)
        cap_transfer(from, to);
}

long ipc_call(struct tcb *t, cptr_t ep_cap, message_t *user_msg) {
    struct cap *c = cap_lookup(t->cspace_root, ep_cap);
    if (!c || cap_type(c) != CAP_ENDPOINT) return -EBADCAP;
    if (!(cap_rights(c) & RIGHT_WRITE))     return -EPERM;

    struct endpoint *ep = cap_object(c);
    t->msg = *user_msg;                   /* already in registers, in practice */
    t->send_badge = cap_badge(c);

    struct tcb *r = ep_dequeue_receiver(ep);
    if (r) {
        /* --- Rendezvous: a receiver is waiting. --- */
        msg_transfer(t, r);
        r->reply_to = t;                  /* r owes us a reply */
        t->state = TS_BLOCKED_REPLY;

        sched_make_ready(r);
        /* Direct switch: donate our timeslice and go straight to the server. */
        if (r->prio >= sched_highest_ready_prio())
            switch_to(r);
        else
            schedule();
    } else {
        /* --- No receiver: queue ourselves as a sender. --- */
        t->state = TS_BLOCKED_SEND;
        t->blocked_on = ep;
        t->wants_reply = true;
        ep_enqueue_sender(ep, t);
        schedule();
    }

    /* We get here when someone replied to us. */
    *user_msg = t->msg;
    return t->msg.label;
}

long ipc_recv(struct tcb *t, cptr_t ep_cap, message_t *user_msg) {
    struct cap *c = cap_lookup(t->cspace_root, ep_cap);
    if (!c || cap_type(c) != CAP_ENDPOINT) return -EBADCAP;
    if (!(cap_rights(c) & RIGHT_READ))      return -EPERM;

    struct endpoint *ep = cap_object(c);

    struct tcb *s = ep_dequeue_sender(ep);
    if (s) {
        msg_transfer(s, t);
        if (s->wants_reply) {
            t->reply_to = s;
            s->state = TS_BLOCKED_REPLY;
        } else {
            sched_make_ready(s);          /* plain send: sender continues */
        }
        *user_msg = t->msg;
        return t->msg.label;
    }

    t->state = TS_BLOCKED_RECV;
    t->blocked_on = ep;
    ep_enqueue_receiver(ep, t);
    schedule();

    *user_msg = t->msg;
    return t->msg.label;
}

long ipc_replyrecv(struct tcb *t, cptr_t ep_cap, message_t *m) {
    if (t->reply_to) {
        struct tcb *caller = t->reply_to;
        t->reply_to = NULL;
        t->msg = *m;
        t->send_badge = 0;                /* replies carry no badge */
        msg_transfer(t, caller);
        caller->state = TS_READY;
        sched_make_ready(caller);
    }
    return ipc_recv(t, ep_cap, m);
}
```

### The fast path (after it works, and after you've measured)

The fast path is a hand-written assembly routine that handles the single most
common case and falls back to C for everything else. Its preconditions:

- Operation is `CALL` or `REPLYRECV`
- The capability lookup hits a single-level CSpace (a direct index)
- The capability is a valid, unrevoked endpoint with the right rights
- A receiver is waiting (for CALL) with no other queued senders
- Message fits in registers, transfers no capabilities
- The receiver's priority permits a direct switch
- No fault, no interrupt pending

If any check fails: `jmp slowpath_c`. The structure:

```nasm
; arch/x86_64/ipc_fastpath.asm  (sketch — the real thing needs care)
syscall_entry:
    swapgs
    mov     gs:[CPU_USER_RSP], rsp
    mov     rsp, gs:[CPU_KERNEL_RSP]

    cmp     eax, SYS_CALL
    jne     .not_call

    ; --- capability lookup, single level ---
    mov     r11, gs:[CPU_CURRENT]           ; struct tcb *
    mov     r12, [r11 + TCB_CSPACE]
    cmp     rdi, [r12 + CNODE_SIZE]
    jae     slowpath
    shl     rdi, 4                          ; sizeof(struct cap) == 16
    add     rdi, [r12 + CNODE_SLOTS]
    mov     r13, [rdi + CAP_TYPE_RIGHTS]
    cmp     r13b, CAP_ENDPOINT
    jne     slowpath
    test    r13, RIGHT_WRITE
    jz      slowpath

    ; --- is a receiver waiting? ---
    mov     r14, [rdi + CAP_OBJECT]         ; struct endpoint *
    cmp     dword [r14 + EP_STATE], EP_RECV_Q
    jne     slowpath
    mov     r15, [r14 + EP_QUEUE_HEAD]      ; struct tcb *receiver

    ; --- priority check for direct switch ---
    movzx   ecx, byte [r15 + TCB_PRIO]
    cmp     cl, gs:[CPU_HIGHEST_READY_PRIO]
    jb      slowpath

    ; --- transfer: message words are ALREADY in the right registers ---
    ; rsi=label, rdx,r10,r8,r9 = w[0..3]  → stay where they are!
    mov     rax, [rdi + CAP_BADGE]
    mov     [r15 + TCB_BADGE], rax

    ; --- dequeue receiver, block caller, switch ---
    ...
    ; --- sysret into the receiver ---
    mov     rcx, [r15 + TCB_USER_RIP]
    mov     r11, [r15 + TCB_USER_RFLAGS]
    mov     rsp, [r15 + TCB_USER_RSP]
    swapgs
    sysretq
```

The magic: **the message words never move**. The sender put them in RDX/R10/R8/R9;
the receiver reads them from RDX/R10/R8/R9. Zero copies, zero memory traffic.
That's how you get to a few hundred cycles.

**Do not write this until:**

1. The C version is correct and passes a thorough test suite.
2. You have a benchmark that reports cycles per round trip.
3. You have a way to run the *same* tests against both paths.

The standard technique: a build flag that disables the fast path, and a CI job
that runs the full test suite with it disabled. Any behavioural difference is a
bug in the fast path.

---

## 5. Notifications (asynchronous signals)

```c
struct notification {
    struct kobject   hdr;
    word_t           word;         /* accumulated signal bits */
    struct tcb      *waiter;       /* at most one, or a queue */
    struct tcb      *bound_tcb;    /* optional: deliver to this TCB's recv */
};

void notification_signal(struct notification *n, word_t bits) {
    n->word |= bits;                       /* coalescing: OR, don't queue */
    if (n->waiter) {
        struct tcb *w = n->waiter;
        n->waiter = NULL;
        w->msg.badge = n->word;
        n->word = 0;
        sched_make_ready(w);
    }
}

word_t notification_wait(struct tcb *t, struct notification *n) {
    if (n->word) { word_t w = n->word; n->word = 0; return w; }
    n->waiter = t;
    t->state = TS_BLOCKED_NOTIFY;
    schedule();
    return t->msg.badge;
}
```

Properties that matter:

- **Never blocks the signaller.** This is what makes it usable from an interrupt
  handler and from a thread that must not be delayed by a slow receiver.
- **Coalesces.** Ten signals of the same bit before the waiter runs produce one
  wakeup with one bit set. The receiver must therefore be **level-triggered
  minded**: on wakeup, drain everything, don't assume one event.
- **No allocation.** Fixed-size state in a fixed-size object. Cannot be used to
  exhaust kernel memory.

Signalling is like `sem_post` on a bitmask semaphore. It's the microkernel
equivalent of a UNIX signal, but capability-gated and race-free.

### Binding notifications to endpoints

A server often needs to wait for *either* a client request (endpoint) or an event
(notification). Rather than adding a `select`, seL4 lets you **bind** a
notification to a TCB: while that thread waits on an endpoint, an incoming
notification also wakes it, delivered with a distinguishing flag.

```c
word_t badge = nyx_recv(service_ep, &m);
if (badge & BADGE_IS_NOTIFICATION)
    handle_events(badge & ~BADGE_IS_NOTIFICATION);
else
    handle_request(badge, &m);
```

One wait primitive, two event sources, no `select`/`epoll` in the kernel. This is
minimality doing real work.

---

## 6. Bulk data transfer

Six words is not enough to `read()` 4 KiB. Three approaches, in increasing
sophistication:

### (a) Kernel copy through an IPC buffer

Each thread has a pinned page (its "IPC buffer") mapped in both its own address
space and reachable by the kernel. Long messages are copied buffer-to-buffer.

- Simple. Costs one `memcpy` of up to a page.
- L4 and seL4 support this for messages up to ~120 words.
- **Downside:** the kernel dereferences user-supplied lengths — the classic
  vulnerability location. And it's O(n).

### (b) MINIX-style grants

The client explicitly authorizes: "process P may write N bytes at address A".
A grant table entry is created; the server presents the grant ID; the kernel
performs a *checked* copy between address spaces.

- Explicit authority, revocable, no shared mapping.
- Still O(n) copy, but the authority model is clean.
- This is a good design and worth implementing to understand it.

### (c) Shared memory + rings (the modern answer)

The client and server both map the same frames. Data is written once, by the
producer, and read in place. A ring buffer carries descriptors; a notification
carries the wakeup.

```c
/* include/abi/ring.h — a single-producer single-consumer ring */
struct ring_hdr {
    _Alignas(64) _Atomic uint32_t head;    /* producer writes */
    _Alignas(64) _Atomic uint32_t tail;    /* consumer writes */
    uint32_t mask;                          /* entries - 1, power of two */
    uint32_t entry_size;
};

static inline bool ring_push(struct ring_hdr *r, void *entries, const void *e) {
    uint32_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (((h + 1) & r->mask) == (t & r->mask)) return false;    /* full */
    memcpy((char *)entries + (h & r->mask) * r->entry_size, e, r->entry_size);
    atomic_store_explicit(&r->head, h + 1, memory_order_release);
    return true;
}
```

Note the `_Alignas(64)`: head and tail must be on different cache lines or the
producer and consumer will ping-pong the line between cores (false sharing),
costing 10× throughput. This is the kind of detail that separates a working
design from a fast one.

**The full pattern** (this is io_uring, and Xen's netfront/blkfront, and
virtio):

```
Submission ring (client → server):  descriptors of work to do
Completion ring (server → client):  results
Shared data pages:                  the actual buffers
Notification:                       "I put something in the ring" / "results ready"
```

With batching and a spin-then-block strategy on the server side, you can process
thousands of operations per mode switch. Throughput becomes comparable to a
monolithic kernel — sometimes better, because the polling server never leaves its
cache-hot loop.

**Design the protocol so that:**

- The consumer validates *everything* — the producer is untrusted. Never trust an
  offset or length read from shared memory. Read it once into a local (a
  `volatile` read or an atomic load), *then* validate, *then* use. Reading twice
  is a TOCTOU bug (this is a real and repeated class of vulnerability in
  virtio/vhost implementations).
- Buffer ownership is explicit: after a descriptor is submitted, the client must
  not touch that buffer until the completion arrives.
- The ring is bounded, so backpressure is natural.

### The decision rule

```
message ≤ 6 words       → registers (synchronous endpoint)
message ≤ ~1 KB, rare   → grant / kernel copy
bulk or high-frequency  → ring + shared frames + notification
```

Build (a) or (b) for correctness and (c) for the paths that matter. Measure to
find out which those are.

---

## 7. Timeouts, DoS, and the failure model

**The problem:** synchronous IPC means a malicious or crashed server can block a
client forever.

Options:

1. **Timeouts on send/receive** (L4 v2/X.2). Every IPC takes a timeout;
   expiration returns an error. Flexible, but requires a timer per blocked
   thread, complicates the fast path, and — Elphinstone/Heiser argued — nobody
   uses anything except 0 and ∞ in practice.
2. **No timeouts, use non-blocking variants + a watchdog** (seL4). `nbsend`
   fails immediately if no receiver is ready. For "call a server that might
   hang", you use a separate watchdog thread holding a capability to suspend or
   restart the server. This keeps the kernel simple and pushes policy out.
3. **Timeout only as a capability-gated exception**, delivered to a handler.

**Nyx: option 2**, with these consequences you must design around:

- Never `call` a server you don't trust with your liveness. Use `nbsend` +
  notification, or interpose a proxy.
- The system needs a **reincarnation server** (Chapter 11) holding TCB
  capabilities for all servers, with a heartbeat notification. When a server
  stops responding, the RS suspends it, kills its clients' pending calls (by
  destroying the endpoint, which unblocks everyone with an error), restarts it,
  and hands out new capabilities.
- Document, per server, whether it is "trusted for liveness" by its clients. This
  is a real architectural property that most systems leave implicit.

Also note: because endpoints hold *threads*, not messages, and each thread queues
on at most one endpoint, **the kernel's IPC memory usage is exactly zero beyond
the TCBs that already exist.** No sender can cause an allocation. This is the
structural property that makes synchronous IPC DoS-resistant, and it's why it's
worth the inconvenience.

---

## 8. Deadlock

Synchronous IPC makes deadlock possible: A calls B, B calls A. The dependency
graph is `thread → endpoint → thread`, and a cycle is a deadlock.

Standard mitigations:

1. **Layering discipline.** Assign each server a level; a server may only call
   strictly lower-level servers. Enforce it in the capability distribution: don't
   give the filesystem server an endpoint capability to the process manager if
   the PM calls the FS. **This is the main answer** — it's a design-time,
   statically-checkable property.
2. **No blocking in servers.** A server never `call`s while holding a client's
   reply; it delegates the reply capability instead and returns to its loop.
   This makes servers *reentrant* and eliminates a huge class of cycles.
3. **Deadlock detection** in a debug build: walk the `blocked_on` chain on every
   block and detect cycles. Cheap enough for testing, invaluable for finding
   design errors. Build this.

```c
#ifdef CONFIG_DEADLOCK_DETECT
static void check_cycle(struct tcb *t) {
    struct tcb *slow = t, *fast = t;
    while (fast && fast->blocked_on) {
        fast = ep_owner(fast->blocked_on);
        if (!fast || !fast->blocked_on) return;
        fast = ep_owner(fast->blocked_on);
        slow = ep_owner(slow->blocked_on);
        if (slow == fast) panic("IPC deadlock involving thread %s", slow->name);
    }
}
#endif
```

---

## 9. Verification

Test the state machine exhaustively — this is where subtle bugs hide.

```c
KTEST(ipc_send_then_recv)      { /* sender first, receiver second */ }
KTEST(ipc_recv_then_send)      { /* receiver first, sender second */ }
KTEST(ipc_call_reply)          { /* full round trip, check payload */ }
KTEST(ipc_badge_delivered)     { /* minted cap → correct badge received */ }
KTEST(ipc_badge_unforgeable)   { /* sender can't set badge field */ }
KTEST(ipc_multiple_senders_fifo) { /* 5 senders queue, served in order */ }
KTEST(ipc_nbsend_fails_when_no_receiver) { }
KTEST(ipc_rights_enforced)     { /* read-only cap can't send */ }
KTEST(ipc_reply_is_one_shot)   { /* second reply fails */ }
KTEST(ipc_endpoint_destroy_unblocks_all) { /* everyone gets an error */ }
KTEST(ipc_no_kernel_allocation) {
    size_t before = pmm_free_bytes();
    for (int i = 0; i < 100000; i++) do_ipc_roundtrip();
    KASSERT(pmm_free_bytes() == before);     /* THE microkernel invariant */
}
KTEST(ipc_fastpath_matches_slowpath) {
    /* Run the same 1000 randomized scenarios with the fast path on and off;
       compare all observable state. */
}
```

### The benchmark you must have

```c
/* user/bench/ipc_pingpong.c */
int main(void) {
    /* Thread A: for (i) { call(ep, m); }
       Thread B: for (i) { replyrecv(ep, m); }   */
    uint64_t t0 = rdtsc();
    for (int i = 0; i < 1000000; i++)
        nyx_call(ep, &m);
    uint64_t t1 = rdtsc();
    printf("round trip: %lu cycles\n", (t1 - t0) / 1000000);
}
```

Report four numbers, always:

| Configuration | Expected order of magnitude |
|---|---|
| Same address space, same core | 200–400 cycles |
| Cross address space, same core, PCID on | 400–800 cycles |
| Cross address space, PCID off | 800–2000 cycles |
| Cross core (via IPI) | 2000–10000 cycles |

Track these in CI over time. A performance regression in IPC is a design
regression. Plot it. Care about it.

---

## 10. Exercises

1. Draw the complete state machine for `struct endpoint` and `struct tcb`
   interaction, including every syscall and every error case. Find at least one
   case your code doesn't handle. (There is one. There always is.)
2. Implement `nbsend` and use it to build a non-blocking logging client that
   drops messages when the log server is busy.
3. Implement grants (MINIX-style) and measure the crossover point where a
   grant-based copy beats a shared-ring setup, as a function of message size.
4. What happens if a thread blocked on an endpoint is destroyed? Write the code
   and the test.
5. Design the IDL for a file server: `open`, `read`, `write`, `close`, `stat`.
   Which operations fit in 6 words? Which need a ring? Write down the wire
   format.
6. Measure the cost of the badge mechanism versus an alternative where the server
   authenticates clients with a token in the message. Include the security
   analysis, not just the cycles.

---

Next: [09 — Capabilities: the security architecture](09-capabilities-and-security.md)
