# Appendix C — Kernel data structures

> Goal: the small set of data structures a microkernel actually needs, chosen for
> the constraints that matter here — **no allocation on the hot path, bounded
> worst-case latency, and correctness under concurrency**.
>
> The selection criteria are different from userspace. An algorithm with a great
> amortized bound and an occasional O(n) rehash is *disqualified* if it sits on a
> path with a deadline (Chapter 14). Predictability beats average speed.

---

## 1. The selection criteria

Before each structure, ask:

| Question | Why it matters |
|---|---|
| Does it allocate? | Chapter 09: the kernel has no heap. Insertion must not require memory. |
| What's the **worst case**, not the average? | Chapter 14: WCET analysis needs a bound, not an expectation. |
| Can it be preempted mid-operation? | A long operation must be restartable (Chapter 07 §5). |
| How does it behave under concurrent access? | Chapter 12: prefer per-CPU, then lock-free reads, then locks. |
| Can I dump it from a debugger? | You will need to, at 3am, with only a serial console. |

A structure that fails the first two is out, regardless of how elegant it is.
This eliminates most of what a textbook would recommend: hash tables with
resizing, dynamic arrays, red-black trees with rotations under a global lock,
anything with amortized bounds.

---

## 2. The intrusive doubly-linked list

The workhorse. If your kernel has one data structure, it's this.

```c
struct list_head { struct list_head *next, *prev; };

#define LIST_HEAD_INIT(n)  { &(n), &(n) }
#define LIST_HEAD(n)       struct list_head n = LIST_HEAD_INIT(n)

static inline void list_init(struct list_head *l) { l->next = l->prev = l; }
static inline bool list_empty(const struct list_head *l) { return l->next == l; }

static inline void __list_add(struct list_head *nw,
                              struct list_head *prev, struct list_head *next) {
    next->prev = nw; nw->next = next; nw->prev = prev; prev->next = nw;
}
static inline void list_add(struct list_head *nw, struct list_head *head)
    { __list_add(nw, head, head->next); }            /* push front */
static inline void list_add_tail(struct list_head *nw, struct list_head *head)
    { __list_add(nw, head->prev, head); }            /* push back  */

static inline void list_del(struct list_head *e) {
    e->prev->next = e->next;
    e->next->prev = e->prev;
    e->next = e->prev = NULL;                 /* poison: catches double-del */
}

#define container_of(ptr, type, member) \
    ((type *)((char *)(ptr) - offsetof(type, member)))

#define list_entry(p, type, member)  container_of(p, type, member)

#define list_for_each_entry(pos, head, member)                       \
    for (pos = list_entry((head)->next, typeof(*pos), member);       \
         &pos->member != (head);                                     \
         pos = list_entry(pos->member.next, typeof(*pos), member))

/* Safe against pos being removed during iteration. */
#define list_for_each_entry_safe(pos, tmp, head, member)             \
    for (pos = list_entry((head)->next, typeof(*pos), member),       \
         tmp = list_entry(pos->member.next, typeof(*pos), member);   \
         &pos->member != (head);                                     \
         pos = tmp, tmp = list_entry(tmp->member.next, typeof(*tmp), member))
```

Why intrusive and circular:

- **No allocation.** The link is a field of the object. This is what makes it
  compatible with untyped memory: creating a TCB does not require also allocating
  a list node.
- **O(1) removal given only the element.** You don't need the head. This is why
  `thread_unblock` doesn't have to search an endpoint queue.
- **Circular means no NULL cases.** Insert, delete, and iterate have no branch
  for "the list is empty" or "this is the last element". Fewer branches, fewer
  bugs, no special-case code path that never gets tested.
- **An object can be on several lists at once** with several `list_head` fields
  — a `struct page` on both a free list and an LRU list, a TCB on both a run
  queue and a wait queue.

**The poison on delete matters.** Setting `next`/`prev` to NULL (or `0xDEAD...`)
turns "removed twice" from silent list corruption — which will manifest as an
unrelated crash ten seconds later — into an immediate NULL dereference at the
scene of the crime. In debug builds, also assert `e->next != NULL` on entry to
`list_del`.

### 2.1 Where it's used in Nyx

Endpoint send/receive queues, run queues (one per priority), free lists in the
buddy allocator, slab partial/full/empty lists, per-CPU deferred-free lists, the
capability derivation tree's sibling list, timer queues (see §5).

### 2.2 The singly-linked variant

For per-CPU free lists and lock-free stacks where you only push and pop at one
end, a singly-linked list halves the memory and enables a simple atomic
push/pop. Use `struct slist_head { struct slist_head *next; }` and don't
generalize it further.

---

## 3. Bitmaps

The second workhorse, and the reason the scheduler is O(1).

```c
static inline void bitmap_set(uint64_t *b, unsigned i)   { b[i/64] |=  (1ull << (i%64)); }
static inline void bitmap_clear(uint64_t *b, unsigned i) { b[i/64] &= ~(1ull << (i%64)); }
static inline bool bitmap_test(const uint64_t *b, unsigned i)
    { return b[i/64] & (1ull << (i%64)); }

/* Highest set bit, or -1. 256 priorities = 4 words = 4 branches worst case. */
static inline int bitmap_last_set(const uint64_t *b, unsigned nwords) {
    for (int w = (int)nwords - 1; w >= 0; w--)
        if (b[w]) return w * 64 + (63 - __builtin_clzll(b[w]));
    return -1;
}
```

`__builtin_clzll` compiles to `lzcnt` (or `bsr`): one instruction. A 256-level
priority scan is four loads, four branches, one `lzcnt` — call it 10 cycles,
constant, no matter how many threads exist. That constancy is the property; the
speed is a bonus.

Uses: runqueue priority mask, free capability slots in a CNode, IOVA allocation
in the IOMMU, PCID allocation, free frames in a small pool, per-CPU pending-IPI
masks.

**Two-level bitmaps** scale this: a summary word where bit *i* means "word *i* is
non-empty". 4096 items in two loads. Worth it above ~1024 bits; not before.

---

## 4. Radix trees (and why the CSpace is one)

A radix tree indexes by chopping a key into fixed-width chunks, one per level.
The page table *is* a radix tree (9 bits per level). The CSpace (Chapter 09 §2)
*is* a radix tree with a guard.

```
CPtr:  [ guard bits ][ radix bits ][ ... next level ... ]
```

Properties that make it right here:

- **Worst case is the depth, which is a constant** determined by the key width
  and radix. No rebalancing, no rotations, no amortization. Perfect for WCET.
- **Lookup is a sequence of bounds-check-and-index.** For the common
  single-level CSpace with radix 12, that's *one* check and *one* index — which
  is what makes the IPC fast path (Chapter 08 §5) viable.
- **No allocation on lookup**, and insertion allocates only a node when a level
  is missing — and in the untyped model, the caller supplied that node anyway.
- **Sparse keys cost nothing.** A process with capabilities at slots 1–16 and
  0x40000 has two nodes, not a 256K array.

The guard is the trick that makes deep sparse trees cheap: a node can say "the
next *g* bits of the key must equal this constant", collapsing a chain of
single-child nodes into one node. seL4's manual explains this well and it's worth
reading even if you never build one.

**Where else to use it:** the VFS's inode-number-to-object map, a memory server's
IOVA map, the timer wheel's overflow list, anything keyed by a sparse integer.

---

## 5. Timers: sorted list vs. wheel vs. heap

Chapter 04 chose TSC-deadline one-shot timers, so the question is: given N pending
timeouts, what's the data structure?

| Structure | Insert | Expire-next | Worst case | Verdict |
|---|---|---|---|---|
| Sorted linked list | O(n) | O(1) | O(n) insert | Fine for n < ~16. Start here. |
| Binary heap | O(log n) | O(log n) | O(log n) | Good general answer, but needs an array (allocation) |
| **Timer wheel** | O(1) | O(1) amortized | O(buckets) on cascade | Linux's choice; the cascade is a latency spike |
| **Hierarchical wheel, no cascade** | O(1) | O(1) | O(1) | Best for real-time |
| Red-black tree | O(log n) | O(1) with cached leftmost | O(log n) | Linux's hrtimers; intrusive, no allocation |

Recommendation, in order: **sorted intrusive list** while n is small (it will be
for a long time — most timeouts in a microkernel are IPC watchdogs), then an
**intrusive red-black tree with a cached leftmost pointer** when it isn't. Skip
the classic timer wheel; its cascade operation is exactly the unbounded pause
Chapter 14 forbids.

Note that the untyped model bites here: a heap needs a contiguous array that
grows. An intrusive tree doesn't. That's a recurring pattern — **prefer
pointer-linked structures over array-backed ones**, the opposite of the usual
cache-locality advice, because allocation is the harder constraint.

---

## 6. Queues between CPUs and between components

Three distinct problems, three answers:

**SPSC ring (single producer, single consumer).** Chapter 08 §6. Head and tail in
separate cache lines, release/acquire pairing, power-of-two capacity so the
wrap is a mask. This is the shared-memory IPC data plane and the io_uring-style
submission queue. It needs *no locks and no atomics beyond load/store with
ordering* — the cheapest possible cross-domain queue.

**MPSC inbox (many producers, one consumer).** Chapter 12 §8's cross-core IPC.
An atomic swap on the head pointer, with the consumer reversing the list:

```c
/* Producer: one CAS-free atomic exchange. */
static void mpsc_push(struct mpsc *q, struct slist_head *n) {
    struct slist_head *old = atomic_exchange_explicit(&q->head, n,
                                                      memory_order_release);
    n->next = old;
}
/* Consumer: take the whole list, reverse it, process. Amortized O(1). */
```

Wait-free for producers, which is the property you want when the producer is
holding a lock you'd rather it didn't hold.

**MPMC**: don't. Restructure until it's one of the above. If you truly need it,
use a lock — a well-written ticket spinlock beats a subtly wrong lock-free MPMC
queue, and you can actually reason about the latency.

---

## 7. Hash tables, carefully

You need one occasionally (name lookup in the VFS, PCI device index). The
constraints rule out the usual implementation:

- **No resizing** on a latency-sensitive path. Size it at creation from the
  untyped the caller provided.
- **Chaining with intrusive lists**, not open addressing, because open addressing
  needs a contiguous array and has terrible worst-case behavior when full.
- **Worst case is O(chain length)**, which an adversary controls if the key comes
  from userspace. **Seed the hash with a per-boot random value** or you have an
  algorithmic-complexity DoS. This has been a real vulnerability in many systems.
- Prefer a radix tree (§4) when the key is an integer. Hash only for strings.

And the honest recommendation: **a linear scan of an array is the right answer
more often than you think.** 32 entries in a cache-friendly array beats a hash
table on real hardware, has trivially bounded worst case, and can be dumped and
read by a human. Measure before adding a hash.

---

## 8. RCU-friendly structures

Chapter 12 §7 makes the point that a microkernel is unusually good at RCU: every
return to userspace is a quiescent state, so grace periods are short and detection
is nearly free.

The structures that benefit:

- **Read-mostly lists** — loaded drivers, registered IRQ handlers, the CPU list.
  Readers take no lock at all.
- **Lookup tables** where writes are rare — the device tree, the object
  namespace (Chapter 16).

The pattern:

```c
/* Reader — no lock, no atomic RMW, no cache-line bouncing. */
rcu_read_lock();
struct handler *h = rcu_dereference(irq_table[vec]);
if (h) h->fn(h->arg);
rcu_read_unlock();

/* Writer */
old = irq_table[vec];
rcu_assign_pointer(irq_table[vec], new);   /* release store */
synchronize_rcu();                          /* wait for readers */
free_handler(old);
```

Where **not** to use it: anything a writer needs to see immediately (revocation!),
and anything where the deferred free breaks your memory accounting. Capability
revocation must be synchronous and complete when it returns — that's a security
property, and RCU's "eventually" is the wrong semantics.

---

## 9. Per-CPU everything

Restating Chapter 12 §3, because it belongs in a data-structures appendix: the
best concurrent data structure is N non-concurrent ones.

| Shared version | Per-CPU version |
|---|---|
| Global runqueue + lock | Per-CPU runqueue, work stealing only when idle |
| Global slab free list | Per-CPU magazines, refilled in batches |
| Global counter | Per-CPU counters, summed on read |
| Global timer list | Per-CPU timer list (a timer belongs to the CPU that set it) |
| Global IPI queue | Per-CPU inbox (§6) |

The costs are real and worth naming: memory scales with CPU count, reads that
need a global view become O(ncpus), and migration needs explicit handling. Accept
them; they're cheaper than lock contention, and each one is a *predictable* cost.

---

## 10. Debuggability

A structure you cannot inspect from a serial console at 3am is a structure you
cannot debug.

1. **Write a dumper for every structure.** `list_dump`, `runqueue_dump`,
   `cspace_dump`, `ep_dump`. Wire them to serial console commands (Chapter 07
   §8's `ps`-like command is the model). This is an afternoon of work that pays
   back the first time something hangs.
2. **Add a validator.** `list_check` walks the list verifying
   `n->next->prev == n` and that the length is under a sane bound. Call it from
   assertions in debug builds after every mutation. Corrupted lists are otherwise
   found *far* from where they were corrupted.
3. **Magic numbers in debug builds.** `struct endpoint { uint32_t magic; ... }`
   checked on entry to every function that takes one. Catches type confusion and
   use-after-free instantly, at the cost of four bytes and one compare.
4. **Keep the count.** A list with an explicit `count` field, asserted against a
   walk in debug builds, converts silent leaks into loud ones.
5. **GDB pretty-printers.** A short Python file that teaches GDB to walk your
   `list_head` and print `struct tcb` fields. Chapter 18 has the harness; this is
   the piece that makes it pleasant.

---

## 11. Summary table

| Need | Use | Not |
|---|---|---|
| Any collection of kernel objects | Intrusive circular list | Array of pointers |
| Pick highest-priority runnable | Bitmap + `lzcnt` | Sorted list, heap |
| Sparse integer key → object | Radix tree (guarded) | Hash table |
| Capability lookup | Guarded radix tree | Anything else |
| Timeouts, small N | Sorted intrusive list | Timer wheel |
| Timeouts, large N | Intrusive RB tree, cached leftmost | Timer wheel (cascade!) |
| Bulk data across a boundary | SPSC ring | Kernel copy |
| Cross-CPU messages | MPSC inbox + IPI | Shared queue + lock |
| Read-mostly registry | RCU-protected list | Reader-writer lock |
| Anything with < 32 entries | A plain array and a loop | Anything clever |
| Shared counter | Per-CPU counters | Atomic increment |

---

## 12. Exercises

1. Implement `list_check` and call it from every list mutation under
   `CONFIG_DEBUG_LIST`. Deliberately corrupt a list and confirm you catch it at
   the mutation rather than at the next traversal.
2. Benchmark your priority selection: 256-level bitmap versus a sorted list, at
   1, 10, and 1000 runnable threads. Plot it. The point is the *shape*, not the
   absolute numbers.
3. Implement the MPSC inbox and write a stress test with N producer CPUs. Run it
   under TSan on the host by stubbing the atomics.
4. Take your timer implementation and compute its worst-case execution time by
   hand. Then measure it with the harness from Chapter 18 and see whether you
   were right.
5. Write GDB pretty-printers for `list_head`, `struct tcb`, and `struct cap`.
6. **Argue the other side:** find a case in your kernel where an array-backed
   structure (needing allocation) would genuinely be better than a pointer-linked
   one, and describe how you'd get the memory for it under the untyped model.

---

Next: [Appendix D — The layers nobody writes chapters about](D-missing-layers.md)
