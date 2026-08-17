# 36 — Networking: beyond sockets

> Goal: design the network API and the stack architecture from scratch. Sockets
> are a 1983 interface that conflates naming with addressing, mandates a copy,
> reports readiness instead of completion, and cannot express a single timing
> requirement. Every modern high-performance networking system bypasses them.
> Rather than bypass, don't build them.

---

## 1. What's actually wrong with sockets

Be specific, because "sockets are bad" is a mood and this needs to be an argument.

| Problem | Detail | Modern workaround |
|---|---|---|
| **Address is identity** | A connection is `(src IP, src port, dst IP, dst port)`. Change your address and the connection dies. | NAT traversal, mobile IP, QUIC connection IDs |
| **Copy is mandatory** | The kernel owns packet buffers; `read()` copies into yours | `sendfile`, `MSG_ZEROCOPY`, `AF_XDP`, DPDK |
| **Readiness, not completion** | `epoll` says "a syscall would now succeed"; you then make the syscall | io_uring, IOCP |
| **Byte stream hides messages** | TCP delivers bytes; every protocol re-implements framing | Every protocol re-implements framing |
| **One syscall per operation** | Historically one per packet | `recvmmsg`, io_uring batching |
| **`fd` is an ambient integer** | A per-process table; inherited by accident across `fork`/`exec` | `O_CLOEXEC`, and vigilance |
| **Untyped options** | `setsockopt(fd, level, optname, void*, socklen_t)` | Nothing; it's still a grab bag |
| **No timing expression** | `SO_PRIORITY` is an advisory hint | TSN required entirely new interfaces (`SO_TXTIME`, `taprio`, `etf`) |
| **Partial writes** | `write()` may accept 900 of 1400 bytes | Loop, and get the loop wrong |
| **Blocking is a property of the fd** | Not of the call | `MSG_DONTWAIT`, inconsistently supported |
| **No scatter-gather composition** | `writev` exists but doesn't compose with zero-copy or offload | mbuf/skb chains, internal to the stack only |

Notice the pattern in the right-hand column: **every one of these has a modern
workaround, and every workaround is a separate, partially-overlapping interface.**
Linux now has sockets, `epoll`, `sendfile`, `MSG_ZEROCOPY`, `recvmmsg`, `AF_XDP`,
io_uring, and `SO_TXTIME`, all doing overlapping things with different semantics.
That's what accumulated retrofit looks like, and it's the thing you get to skip.

---

## 2. Five decisions

**D1 — Messages, not byte streams.** The base abstraction is a message with a
boundary. Streams are a layer *above*, for the cases that want them. Ousterhout's
Homa argument applies: datacenter traffic is overwhelmingly request/response, and
forcing it through a byte stream costs you message boundaries, head-of-line
blocking, and connection state you didn't need.

**D2 — Completion, not readiness.** Chapter 15's rings. You post work; you reap
completions. There is no `select`, no `epoll`, no "is it ready?" — and because
Chapter 08 binds notifications to endpoints, a single wait covers network
completions, IPC, and timers with no integration layer.

**D3 — Zero-copy is the only mode.** Buffers come from a registered, DMA-mapped
pool. The application writes into a buffer the NIC will transmit from, or reads
from a buffer the NIC wrote into. There is no `send(buf, len)` that copies,
because there is no copying path to fall back to.

**D4 — Declare transport requirements, not a protocol.** The same inversion as
Chapter 35: you say *reliable, ordered per stream, latency target 200 µs, drop
late data*; the stack picks and configures the protocol. This is IETF TAPS's
design, and it's right — it decouples applications from the transport monoculture
and makes QUIC-vs-TCP-vs-something-new a deployment decision.

**D5 — Everything is a capability.** A flow, a buffer pool, a NIC queue, a name.
No fd table, no global port namespace, no ambient ability to bind port 80 or open
a raw socket.

---

## 3. Layer separation, done properly

The single biggest structural mistake in the Internet stack is that **an IP
address is simultaneously an identity, a location, and a routing directive.**
That's why NAT, mobility, multihoming, and multipath are all painful — they're all
cases where those three need to differ.

Separate them:

| Layer | Answers | Changes when |
|---|---|---|
| **Identity** | *Who* am I talking to? A public key, or a name bound to one. | Never (that's the point) |
| **Path** | *Which* interface, route, and address pair right now? | Constantly — roaming, failover, multipath |
| **Transport** | Reliability, ordering, flow and congestion control | Per flow, negotiated |
| **Framing** | Message boundaries, serialization | Per application |

A flow is bound to an **identity**, not an address. Paths are attributes of the
flow that can be added, removed, and used simultaneously without the flow
noticing. This is what QUIC's connection IDs achieve partially, what HIP and LISP
proposed properly, and what a new system has no reason not to do natively.

Consequences worth stating: connection migration is free; multipath is a path-set
policy rather than a new protocol (compare the decade MPTCP took); a "reconnect"
after a network change doesn't exist as a concept; and authentication is not a
separate handshake bolted on top, because the identity *is* the key.

**Congestion control is a policy component**, per flow, replaceable — the same
argument as Chapter 11's pluggable servers. Datacenter flows want DCTCP or Swift;
wide-area wants BBR; a real-time flow inside a TSN domain wants none at all
because the network is scheduled (Chapter 37).

---

## 4. The buffer model

This is the foundation; get it right and zero-copy and scatter-gather come free.

```c
/* A pool: contiguous frames, DMA-mapped once, IOMMU-confined to this device. */
struct net_pool_spec {
    uint32_t size;
    uint32_t n_buffers;
    uint32_t buffer_size;      /* 2048 typical; 9216 for jumbo */
    uint32_t headroom;         /* bytes reserved before the payload for headers */
    uint32_t tailroom;
};
MUST_USE err_t net_pool_create(cptr_t nic, const struct net_pool_spec *,
                               net_pool_t *out);

/* A buffer reference: index into the pool, not a pointer. 8 bytes. */
typedef struct { uint32_t pool_id; uint32_t index; } net_buf_t;

/* A scatter-gather element. First-class, not an afterthought. */
struct net_sg {
    net_buf_t buf;
    uint32_t  off;
    uint32_t  len;
};
```

Design notes:

- **Headroom is mandatory and explicit.** A message assembled by an application
  needs room for transport, network, and link headers to be prepended *without a
  copy*. This is what `skb_reserve` and DPDK's mbuf headroom exist for; making it
  a pool parameter means no layer ever has to reallocate.
- **References are indices, not pointers.** Half the size, no pointer translation
  between the application's mapping and the driver's, and a bounds check that's a
  single comparison. Combine with Appendix B §4.2's generation counters if you
  want stale-reference detection.
- **Buffer chaining** (a message spanning several buffers) is expressed by the
  scatter-gather list, not by a `next` pointer in the buffer. The list is a value
  the caller owns; buffers stay simple.
- **Ownership is explicit and one-way.** You own a buffer, or the stack does, or
  the NIC does. Transitions happen at `net_send` (you → NIC) and at completion
  (NIC → you). Debug builds poison buffers on transfer, which catches the
  use-after-send bug that plagues every zero-copy API.

**Why scatter-gather matters beyond avoiding one copy:** a message is naturally
"header I just built" + "payload that was already in memory" + "trailer". Without
SG you either copy the payload next to the header or make two transmissions.
With SG the NIC gathers them at line rate. It's also how you do zero-copy
forwarding, TLS record framing, and vectored serialization from a component's
arena (Appendix B §3) without any copies at all.

---

## 5. The API

```c
/* ---- flow creation: declare requirements ---- */
struct net_flow_spec {
    uint32_t  size;

    cptr_t    peer;               /* an identity capability, or a name to resolve */
    uint8_t   reliability;        /* RELIABLE | UNRELIABLE | PARTIAL(k) */
    uint8_t   ordering;           /* NONE | PER_STREAM | TOTAL */
    uint8_t   congestion;         /* AUTO | NONE(scheduled) | policy capability */
    uint8_t   security;           /* REQUIRED | OPPORTUNISTIC — never OFF by default */

    nanos_t   latency_target;     /* what "good" means for this flow */
    nanos_t   deadline;           /* 0 = none; see NET_DROP_LATE */
    uint64_t  bandwidth_min;      /* for admission control; Ch. 37 */
    uint32_t  max_message;

    uint32_t  flags;              /* NET_DROP_LATE | NET_MULTIPATH | NET_ZERO_RTT */
};
MUST_USE err_t net_flow_create(cptr_t net, const struct net_flow_spec *,
                               net_flow_t *out);

/* ---- transmit ---- */
struct net_send {
    const struct net_sg *sg;
    uint16_t   n_sg;
    uint16_t   stream;            /* multiplexed streams within a flow */
    uint32_t   flags;             /* NET_EOM | NET_MORE | NET_TIMESTAMP */
    nanos_t    launch_time;       /* 0 = ASAP; else transmit exactly then (Ch. 37) */
    nanos_t    deadline;          /* 0 = flow default */
    uint64_t   cookie;            /* returned in the completion */
};
MUST_USE err_t net_send(net_flow_t, const struct net_send *);   /* enqueues; never partial */

/* ---- completions ---- */
struct net_completion {
    uint64_t  cookie;
    uint8_t   kind;               /* SENT | RECEIVED | FLOW_EVENT | ERROR */
    err_t     status;
    nanos_t   hw_timestamp;       /* from the NIC, not the CPU */
    struct net_sg sg[NET_MAX_SG]; /* for RECEIVED: buffers you now own */
    uint16_t  n_sg;
    uint16_t  stream;
};
size_t net_poll(net_cq_t, struct net_completion *out, size_t max);  /* batch */
```

The properties that matter:

- **`net_send` never partially sends.** A message is enqueued whole or rejected
  with `ERR_AGAIN`. The partial-write loop, and its bugs, cease to exist.
- **Backpressure is ring fullness**, visible and explicit, not a hidden buffer
  that grows until the machine swaps (the bufferbloat mechanism, in miniature).
- **`launch_time` and `deadline` are in the base API**, not a socket option added
  in 2018. Chapter 37 depends on this.
- **Hardware timestamps come back by default**, which makes every latency
  measurement in Chapters 32–33 accurate rather than approximate.
- **Receive hands you buffers you own.** No `recv(buf, len)`, no copy, no
  guessing at sizes. You release them when done, back to the pool.
- **Batching is the normal case**: `net_poll` returns many, and sends go into a
  ring drained on a doorbell. One syscall (or zero, with a polling driver) per
  batch.

### 5.1 Streams, when you want them

A flow multiplexes streams, QUIC-style: ordered within a stream, independent
across streams, so head-of-line blocking is contained. Streams are cheap (an
integer, some state) — you don't open a connection per request.

This is strictly better than the socket model for the dominant modern workload
(many concurrent requests to one peer) and it costs nothing for the simple case
(use stream 0).

---

## 6. Where does the stack run?

The architectural question. Four options:

| Design | Latency | Isolation | Complexity |
|---|---|---|---|
| (a) In the kernel | — | Violates everything in this book | — |
| (b) One server for all clients | +1 IPC hop each way | Shared trust and failure domain; a bottleneck | Low |
| (c) Library in every process, NIC demultiplexes by flow | Best | Excellent — hardware-enforced | Needs flow steering and a control plane |
| (d) **Hybrid: (c) for data, a server for control** | Best | Excellent | Moderate |

**Choose (d).** This is where the industry has independently arrived — Snap
(Google), TAS, Demikernel, and every RDMA deployment — and it fits the capability
model unusually well:

```
┌─────────────────────────────────────────────────────────┐
│ net control server                                      │
│   owns the NIC's control registers                      │
│   allocates queues, programs flow-steering rules        │
│   allocates identities/ports, enforces policy           │
│   performs flow setup, name resolution, key exchange    │
└─────────────────────────────────────────────────────────┘
        │ hands out: queue capability + pool + flow rules
        ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│ app A         │  │ app B         │  │ app C         │
│ libnet (stack)│  │ libnet        │  │ libnet        │
│ TX/RX queues ─┼──┼───────────────┼──┼──► NIC        │
└───────────────┘  └───────────────┘  └───────────────┘
```

**Why the isolation is real, and this is the good part:** the NIC's flow-steering
table only delivers packets matching app A's flows into app A's queue. App A's
buffer pool is IOMMU-mapped so the NIC can only DMA into A's memory. App A
therefore *cannot* receive another app's traffic — not by policy, by hardware. And
it cannot forge source addresses, because the control server programmed the TX
queue's allowed source set.

That's stronger isolation than a kernel stack provides, obtained by giving
applications *more* direct access rather than less. It's the same argument as
Chapter 15's per-process NVMe queues, and it's one of the better demonstrations
that capability thinking and performance thinking point the same way.

**The control server does the slow, complex, security-critical work** — name
resolution, policy, key exchange, port allocation — where it can be restarted
(Chapter 11 §6) without dropping established flows, because the data path doesn't
go through it.

### 6.1 What about a shared stack?

Some workloads want (b): many small components, none of which needs line rate.
Offer both — a component either gets its own queue or uses the shared stack
server, chosen in the manifest. Same API either way. That's the isolation-spectrum
argument from Chapter 29 §3.1 applied to networking.

---

## 7. Naming and identity

Sockets take an address. That's the wrong input.

```c
/* A name is resolved by a name-service capability the component holds.
   No global DNS, no /etc/resolv.conf, no ambient resolution. */
MUST_USE err_t net_resolve(cptr_t name_service, str name, cptr_t *identity_out);
```

- **The result is an identity capability**, not an address. It carries the peer's
  public key. Connecting to it is authenticated by construction — there is no
  unauthenticated mode to fall back to and no certificate-validation step to skip.
- **The name service is a capability**, so different components can have different
  namespaces. A sandboxed component's name service resolves three names and
  nothing else. That's network policy expressed as capability distribution rather
  than as firewall rules applied to an ambient network.
- **Which addresses to use is a path decision**, made after and separately (§3).

This also makes the firewall question mostly disappear: a component can only reach
peers it has identity capabilities for. Egress filtering isn't a packet-inspection
problem; it's the manifest.

---

## 8. Real-time safety of the stack

Tie into Chapter 35 §8. For a flow marked real-time:

| Requirement | Mechanism |
|---|---|
| No allocation on the data path | Pool pre-allocated at flow creation |
| No page faults | Pool pinned and pre-faulted |
| Bounded processing per packet | No fragmentation reassembly, no dynamic option parsing, bounded header chain |
| No unbounded queuing | Fixed ring; `NET_DROP_LATE` discards stale data instead of delivering it late |
| Deterministic transmit time | `launch_time` + hardware gating (Chapter 37) |
| RT-safe API | `net_send`, `net_poll`, buffer alloc/release all `RT_SAFE`; flow *creation* is not |

That "drop late data" flag deserves emphasis: for control traffic, a sensor
reading that arrives 5 ms late is not merely delayed, it's **wrong**, and
delivering it is worse than dropping it. TCP's "reliable delivery eventually" is
the wrong semantics for a control loop, and no socket option expresses that.

---

## 9. What about existing software?

The honest answer, same as Chapter 30 §6: a POSIX socket shim over this API for
ported software, and Linux in a VM (Chapter 29) for everything else. The shim is
straightforward for the common cases and impossible for the corners (`fork`
inheritance, `SO_REUSEPORT` semantics, signal-driven I/O) — document what's
unsupported rather than approximating it badly.

Keep the shim strictly on top. The moment socket semantics leak into the native
API's design, you've rebuilt the thing you were avoiding.

---

## 10. Verification

| Test | Asserts |
|---|---|
| `zero_copy_verified` | Instrument every copy; assert zero on the send and receive paths for a large message |
| `no_partial_send` | Fuzz message sizes and ring states; `net_send` is all-or-nothing |
| `sg_correctness` | Random scatter-gather lists reassemble byte-identically at the peer |
| `flow_isolation` | App B cannot receive app A's packets, even with a malicious libnet. **The headline test** — run it with a deliberately hostile driver. |
| `no_source_spoofing` | An app cannot transmit with a source identity it wasn't granted |
| `buffer_ownership` | Poison on transfer; assert no use-after-send |
| `identity_survives_path_change` | Kill and change the path mid-flow; assert the flow continues without application involvement |
| `rt_flow_bounded` | Under adversarial load from another partition (Chapter 34 §7), an RT flow's processing time stays within its bound |
| `drop_late_works` | Delayed data is dropped, not delivered, and the drop is reported |
| `completion_batching` | N messages produce ≤ 1 syscall to reap |

The `flow_isolation` test is the one that justifies the architecture. Run it with
an intentionally malicious userspace driver that writes garbage descriptors — the
IOMMU and flow-steering rules should make it harmless. If it isn't harmless, you
have the Chapter 11 §5.3 problem and the design doesn't hold.

---

## 11. Exercises

1. Implement the buffer pool and scatter-gather primitives, and verify zero copies
   with an instrumented build.
2. Implement `net_flow_create` over UDP first — no reliability, no congestion — and
   get a message round trip working through the ring API.
3. Add streams and a reliability layer. Compare your implementation's complexity
   against what a byte-stream design would have required.
4. Write the POSIX shim and port one small existing program. Note every semantic
   you couldn't reproduce.
5. Implement identity-based flows with path migration. Move the flow between two
   interfaces mid-transfer without the application noticing.
6. Build the `flow_isolation` test with a hostile driver.
7. Measure round-trip latency against a Linux socket baseline on the same
   hardware, at p50 and p99.9, for 64-byte and 64 KB messages.
8. **Argue the other side:** sockets are universal, well-understood, and every
   programmer knows them; a novel API means porting everything and training
   everyone. Make the case for a really good socket implementation plus io_uring
   instead, and identify what you'd lose.

---

Next: [37 — Deterministic and real-time networking](37-tsn.md)
