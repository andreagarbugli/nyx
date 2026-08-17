# 38 — NIC drivers: from e1000 to multi-queue

> Goal: write real network drivers as userspace components. Start with virtio-net
> and e1000 under QEMU because they're simple and you can iterate in seconds, then
> move to igb/igc — multi-queue, RSS, MSI-X per queue, hardware timestamping, and
> LaunchTime — which is what Chapters 36 and 37 actually need.
>
> The i210 and i225/i226 are the right hardware targets: cheap, well documented,
> and the standard TSN development parts.

---

## 1. The staging

| Stage | Device | Why | Effort |
|---|---|---|---|
| **0** | `virtio-net` | Simplest possible: virtqueues are the rings you already built (Chapter 15). Gets the stack working with no hardware knowledge. | Days |
| **1** | `e1000` (82540EM) | QEMU's default emulated NIC. Real descriptor rings, real MMIO registers, real (emulated) interrupts. **The learning driver.** Single queue, no offloads worth having. | ~1 week |
| **2** | `e1000e` (82574) | MSI-X, better descriptors, closer to real hardware. QEMU models it. | Days on top of stage 1 |
| **3** | `igb` (i210, i350) | **Multi-queue, RSS, MSI-X per queue, PTP hardware timestamping, LaunchTime, Qbv gates on i210.** This is the TSN target. QEMU has partial igb support; real hardware is ~£30. | 2–4 weeks |
| **4** | `igc` (i225/i226) | 2.5 GbE, same architecture as igb, better TSN (Qbv + Qbu). The current best TSN development NIC. | Days on top of igb |
| **5** | Something at 25–100 GbE | Only if you need it. Much more complex; consider a SmartNIC instead. | Months |

**Do stages 0 and 1 in the same week.** virtio proves the stack; e1000 proves you
understand descriptor rings. Then jump straight to igb — e1000's single queue
cannot support Chapter 36's per-process queue model, so it's a stepping stone, not
a destination.

---

## 2. The universal structure

Every one of these drivers is the same shape, which is worth internalizing before
writing any of them:

```
        ┌──────────── descriptor ring (in DMA memory) ────────────┐
        │ desc[0] │ desc[1] │ ... │ desc[n-1] │   circular         │
        └────┬────────────────────────┬────────────────────────────┘
             │ points to              │ points to
        ┌────▼────┐              ┌────▼────┐
        │ buffer  │              │ buffer  │   ← Chapter 36's pool
        └─────────┘              └─────────┘

  HEAD (device-owned)  ──────────►  TAIL (driver-owned)
```

- The driver writes descriptors, then advances **TAIL** (an MMIO write — the
  "doorbell").
- The device consumes up to TAIL, advances **HEAD**, and writes back status.
- The driver detects completion by reading the writeback (a **DD** — descriptor
  done — bit) rather than by reading HEAD, because an MMIO read costs ~1 µs and a
  memory read of a DMA-written cache line costs ~100 ns.

That last point is the single most important performance rule in NIC driver
programming: **never poll a device register in a loop.** Poll memory the device
wrote.

### 2.1 The rules that apply to all of them

1. **Descriptors are DMA memory** — allocate from the pool, use the IOVA
   (`dma_addr_t`, Appendix B §6), never a physical address, never a virtual one.
2. **Memory ordering matters.** Before ringing the doorbell you need a store
   barrier so the descriptor writes are visible to the device. Before reading a
   descriptor's payload after seeing DD, you need a load barrier. On x86 TSO the
   first is nearly free and the second is a compiler barrier — on ARM/RISC-V
   neither is. Use explicit C11 atomics (Chapter 12 §5) so the RISC-V port doesn't
   silently break.
3. **Batch doorbells.** One MMIO write per *batch* of descriptors, not per packet.
   An MMIO write is ~100–1000 cycles; at 1.4 Mpps you cannot afford one each.
4. **Keep head and tail on separate cache lines**, and never let two CPUs touch
   the same queue (Chapter 12 §3). One queue, one owner.
5. **Prefetch the next descriptor** while processing the current one. Worth
   several percent on the receive path.
6. **Never trust the device.** Validate lengths and status bits from writeback.
   A malfunctioning or malicious device writes garbage, and your driver is
   userspace but your buffer pool is real memory.

---

## 3. e1000, concretely

Enough detail to start. The registers you need (BAR0 MMIO offsets):

| Register | Offset | Purpose |
|---|---|---|
| `CTRL` | 0x0000 | Device control; `RST` bit for reset, `SLU` to set link up |
| `STATUS` | 0x0008 | Link up, speed |
| `ICR` / `ICS` / `IMS` / `IMC` | 0x00C0–0x00D8 | Interrupt cause read/set/mask set/mask clear |
| `RCTL` | 0x0100 | Receive control: enable, buffer size, broadcast accept, strip CRC |
| `TCTL` | 0x0400 | Transmit control: enable, pad short packets, collision params |
| `RDBAL/RDBAH` | 0x2800/0x2804 | Receive descriptor ring base (DMA address, 16-byte aligned) |
| `RDLEN` | 0x2808 | Ring length in bytes (multiple of 128) |
| `RDH` / `RDT` | 0x2810/0x2818 | Receive head (device) / tail (driver) |
| `TDBAL/TDBAH/TDLEN/TDH/TDT` | 0x3800… | Same for transmit |
| `RAL/RAH` | 0x5400/0x5404 | Receive address (the MAC filter) |
| `MTA` | 0x5200 | Multicast table array — clear it |

Descriptors:

```c
struct e1000_rx_desc {          /* 16 bytes */
    uint64_t addr;              /* IOVA of the buffer */
    uint16_t length;
    uint16_t checksum;
    uint8_t  status;            /* bit 0 = DD (done), bit 1 = EOP */
    uint8_t  errors;
    uint16_t special;
} __attribute__((packed));

struct e1000_tx_desc {          /* 16 bytes */
    uint64_t addr;
    uint16_t length;
    uint8_t  cso;
    uint8_t  cmd;               /* EOP | IFCS | RS (report status) */
    uint8_t  status;            /* bit 0 = DD */
    uint8_t  css;
    uint16_t special;
} __attribute__((packed));
```

Bring-up sequence:

1. Get the BAR0 Frame capability and the IRQ capability from the PCI server
   (Chapter 11 §5). Map BAR0 **uncached**.
2. Reset (`CTRL.RST`), wait, then clear interrupt causes.
3. Read the MAC from EEPROM (or from `RAL/RAH` if firmware set it).
4. Allocate the RX ring, fill every descriptor with a buffer IOVA, set
   `RDBAL/RDBAH/RDLEN`, `RDH=0`, `RDT=n-1`, then `RCTL.EN`.
5. Allocate the TX ring, set the base/length, `TDH=TDT=0`, then `TCTL.EN` plus the
   pad and collision-threshold bits.
6. Enable the interrupts you want in `IMS` (`RXT0`, `TXDW`, `LSC`).
7. Set `CTRL.SLU` and wait for `STATUS.LU`.

**The classic mistakes**, all of which produce a silent non-working NIC:

- Forgetting to clear the multicast table array — you receive nothing or
  everything.
- Setting `RDT` to `n` instead of `n-1` — the ring looks empty to the device.
- Using a physical address where an IOVA is required, which works without an
  IOMMU and fails mysteriously with one.
- Forgetting `RS` in the TX command, so `DD` is never written back and you think
  every transmit hung.
- Not marking the BAR mapping uncached, so your register writes sit in a store
  buffer and never reach the device.

---

## 4. Multi-queue: igb and igc

This is where the architecture from Chapter 36 becomes possible.

### 4.1 What changes

| Feature | e1000 | igb / igc |
|---|---|---|
| Queues | 1 RX, 1 TX | 4–16 of each (i210: 4; i225: 4) |
| Interrupts | One line | MSI-X, one vector per queue |
| Steering | MAC filter only | **RSS** (hash → queue) and **flow director** style exact-match filters |
| Descriptors | Legacy 16-byte | Advanced: separate read and writeback formats, 16 or 32 bytes |
| Offloads | Checksum | Checksum, TSO, VLAN, RSS hash delivered in the descriptor |
| Timestamps | No | **PTP hardware timestamps, TX and RX** |
| TSN | No | **LaunchTime; i210 and i225 have Qbv gates, i225 adds Qbu** |
| Moderation | Crude | Per-vector interrupt throttling (ITR/EITR) |

**Advanced descriptors** split the read format (what you write: buffer addresses)
from the writeback format (what the device writes: length, RSS hash, status,
timestamp, checksum result) in the *same* 16 or 32 bytes. Get the union right and
`_Static_assert` both layouts.

### 4.2 A queue is a capability

The point of multi-queue, for us:

```
PCI/net control server owns: BAR0 control registers, RSS table, filter rules
   │
   ├─ queue 0 capability + filter rule (flow F1) ──► app A
   ├─ queue 1 capability + filter rule (flow F2) ──► app B
   └─ queue 2..3                                  ──► shared stack server
```

A queue capability grants: a mapping of just that queue's doorbell registers
(they're in separate 4 KB pages on igb/igc — deliberately, for exactly this
virtualization use case), the descriptor ring memory, and the associated MSI-X
vector delivered as a Notification.

**Isolation properties:**

- App A can only ring *its* doorbell — the register page it holds is mapped, the
  others aren't.
- Only frames matching A's filter rules land in A's ring, so A cannot receive B's
  traffic.
- A's descriptors can only point into A's IOMMU domain, so a malicious A cannot
  make the NIC DMA into B's memory or the kernel's.
- A cannot reprogram filters or RSS — those registers live in the control page,
  which only the control server holds.

This is hardware-enforced network isolation with a userspace driver, and it's the
concrete answer to Chapter 11 §5.3's warning. **Without the IOMMU none of it
holds** — write that in the driver's header comment.

### 4.3 RSS and flow steering

**RSS** hashes the 5-tuple and indexes a redirection table to pick a queue. Good
for spreading load, useless for isolation (you don't control which flow lands
where). Use it for the shared stack's queues.

**Exact-match filters** (igb's "queue filters", i350's flow director, i225's
similar facility) match a specific tuple to a specific queue. That's what the
control server programs for a per-process flow. The number available is limited
(tens, not thousands) — which caps how many processes can have private queues, and
is an honest limitation to document. Beyond that, fall back to the shared stack.

**Set the RSS hash key to a random per-boot value** or you have an
algorithmic-complexity DoS: an attacker who knows the key can craft flows that all
hash to one queue.

---

## 5. Offloads: which to use, which to avoid

| Offload | Verdict |
|---|---|
| **RX/TX checksum** | Always. Free, saves a full pass over the data. |
| **TSO** (segment a 64 KB buffer into MTU frames) | Yes for bulk. Amortizes per-packet cost enormously. |
| **RSS hash in the descriptor** | Yes — free flow identification, useful for steering within your stack |
| **VLAN insert/strip** | Yes if you use VLANs (TSN usually does — PCP carries the traffic class) |
| **Hardware timestamps** | **Mandatory** for Chapter 37 |
| **LaunchTime** | **Mandatory** for Chapter 37 §3.1 |
| **LRO** (coalesce received segments) | **No.** It destroys packet boundaries, breaks forwarding, and adds latency. GRO-style software coalescing, opt-in per queue, if you want it at all. |
| **Interrupt moderation** | Per queue, per policy: aggressive for bulk, **off for real-time queues**. It is literally a latency-for-CPU trade and RT queues want the other side of it. |

That last row is a good example of why per-queue policy matters: a single
system-wide moderation setting is wrong for a machine running both a control loop
and a file transfer. Queue-as-capability makes per-queue policy natural.

---

## 6. Interrupts, polling, and power

Chapter 04 §8 established the pattern: the interrupt masks the source and signals
a Notification; the userspace driver drains until empty and re-arms. That NAPI-like
discipline is mandatory here — at 1.4 Mpps you cannot take an interrupt per packet.

The three modes, and use all three:

| Mode | Latency | CPU | When |
|---|---|---|---|
| Interrupt-driven | ~5–20 µs wakeup | Low | Idle or light load |
| **Hybrid** (poll after an interrupt, for N µs, then re-arm) | Good | Moderate | **Default** |
| Busy poll | < 1 µs | A whole core | RT queues, or heavy load |

The hybrid mode is where you should live: an interrupt wakes the driver, it polls
for a short adaptive window (long enough to catch the next packet of a burst),
then re-arms and sleeps. This gets close to busy-poll latency under load and close
to interrupt-driven power at idle.

For a real-time queue on a dedicated core (Chapter 34 §6), busy poll is correct
and the core is *reserved for it*, so the cost is accounted rather than stolen.

---

## 7. Testing drivers

Driver bugs are painful because the failure is usually silence. Build the harness
first.

**Under QEMU:**

- `-netdev socket` to connect two QEMU instances back to back — a two-node network
  with no hardware.
- `-object filter-dump` to capture everything to a pcap and inspect it.
- Deliberate malformation: QEMU's `filter-*` objects can drop, delay, and duplicate
  frames. Test your driver against a hostile wire.
- `-netdev user` with port forwarding for talking to the host.

**Test list:**

| Test | Asserts |
|---|---|
| `ring_wraparound` | Send exactly `n`, `n+1`, `2n-1` descriptors; assert no corruption at the wrap |
| `descriptor_writeback_validated` | Inject bogus lengths/status; assert the driver rejects rather than trusting |
| `rx_starvation` | Stop refilling; assert graceful drop and recovery, not a hang |
| `doorbell_batching` | Count MMIO writes per packet under load; assert it's well under 1 |
| `iommu_confinement` | Malicious driver writes descriptors pointing outside its pool; assert the IOMMU blocks it and reports a fault. **The test that justifies userspace drivers.** |
| `link_flap` | Toggle link state repeatedly; assert clean recovery |
| `multiqueue_isolation` | Traffic for queue 1 never appears in queue 0 |
| `timestamp_accuracy` | Compare TX timestamp against a second machine's RX timestamp |
| `line_rate` | 64-byte frames at line rate; report pps and cycles/packet |
| `no_allocation` | Poison the allocator; run at line rate |

**Measure cycles per packet** and track it in CI (Chapter 33 §6.1). A good
userspace driver is 50–150 cycles/packet on the fast path; if you're at 1000,
something is wrong and it's usually an MMIO read or a cache miss on a descriptor.

---

## 8. Writing the driver so the next one is easier

Six devices in, you want them sharing structure. Factor early:

```c
struct nic_ops {
    err_t (*init)(struct nic *, cptr_t bar, cptr_t irq);
    err_t (*queue_create)(struct nic *, uint16_t idx, const struct queue_spec *);
    err_t (*tx_burst)(struct nic_queue *, const struct net_sg *, uint16_t n);
    uint16_t (*rx_burst)(struct nic_queue *, struct net_sg *out, uint16_t max);
    err_t (*filter_add)(struct nic *, const struct flow_match *, uint16_t queue);
    err_t (*ts_enable)(struct nic *, uint32_t flags);
    err_t (*launch_time_set)(struct nic_queue *, bool);
    err_t (*gate_program)(struct nic *, const struct gcl *);
    uint32_t caps;
};
```

Note the shape: `tx_burst`/`rx_burst` take **arrays**, not single packets. That's
DPDK's most important API decision and it's right — per-packet function call
overhead is a measurable fraction of the budget at line rate, and burst APIs
amortize it along with the doorbell.

Keep device-specific code to descriptor formats and register layouts. The ring
management, buffer pool interaction, and the burst loops should be shared.

---

## 9. Exercises

1. Write the virtio-net driver. Get a ping working end to end through Chapter 36's
   API.
2. Write the e1000 driver under QEMU. Time how long it takes from `CTRL.RST` to
   the first received frame — this is the exercise that teaches descriptor rings.
3. Connect two QEMU instances with `-netdev socket` and run your stack between
   them.
4. Implement the `iommu_confinement` test with a driver that deliberately writes
   out-of-bounds descriptors.
5. Buy an i210 or i225 and port to igb/igc. Get multi-queue with two processes
   holding separate queue capabilities, and prove they can't see each other's
   traffic.
6. Enable hardware timestamping and measure PTP offset between two machines
   (Chapter 37 §8).
7. Implement LaunchTime and measure transmit accuracy from the peer's RX
   timestamps.
8. Measure cycles/packet for 64-byte frames and find your bottleneck with the
   Chapter 33 profiler. Then fix it and measure again.
9. **Argue the other side:** make the case that NIC drivers belong in the kernel —
   that the IOMMU's cost, the flow-steering table's size limits, and the
   complexity of per-process queues outweigh the isolation benefit for most
   systems. What workload would settle it?

---

← [Back to the index](README.md)

Next: [39 — Composability as a discipline](39-composability-discipline.md)
