# Appendix B — Memory ownership and allocation patterns

> Goal: a set of allocation and ownership disciplines that make lifetime bugs
> structurally rare rather than caught-in-review, and that survive contact with
> the untyped-memory model from Chapter 09 and the real-time goals from
> Chapter 14.
>
> The short version: **the kernel should barely allocate at all, servers should
> allocate per-request from an arena, and anything long-lived should be an object
> with an explicit owner written down in a comment.**

---

## 1. The four lifetimes

Almost every memory bug is a disagreement about which of these a pointer has.
Name them, and require every allocation site to state one.

| Lifetime | Freed by | Typical use | Allocator |
|---|---|---|---|
| **Static** | never | per-CPU areas, page tables at boot, the frame database | linker / boot bump allocator |
| **Request** | end of the operation | parsed paths, temporary buffers, marshalling scratch | **arena**, reset wholesale |
| **Object** | explicit destroy / capability revoke | TCB, endpoint, VSpace, file handle | untyped retype (kernel), slab (servers) |
| **Borrowed** | not yours | a `str` into a caller's buffer, a slice of a ring | nothing — you must not free it |

The rule to write into `docs/style.md`:

> Every function that returns a pointer documents which lifetime it returns, in
> one word, on the same line as the declaration.

```c
struct tcb  *tcb_create(struct untyped *ut);      /* object: caller owns, tcb_destroy */
str          path_component(str path, size_t i);  /* borrowed: valid while path is */
void        *arena_alloc(arena *a, size_t n);     /* request: freed by arena_reset */
```

That one-word annotation catches more bugs per character than any tool.

---

## 2. The kernel: no heap at all

Chapter 09's untyped memory is not just a security mechanism; it is the strongest
possible answer to kernel memory management, because it removes the question.

```
Kernel object creation = Untyped_Retype(untyped_cap, type, size, dest_slots)
```

Properties you get for free:

- **No allocation failure path in the kernel.** The caller supplied the memory.
  Either the untyped is big enough or the syscall returns `ERR_NOMEM` before
  anything has been modified. There is no partially-constructed state to unwind,
  which is where allocation-failure bugs live.
- **No fragmentation policy in the kernel.** It's a userspace problem now.
- **Exact accounting.** "How much kernel memory does this container use?" is
  answered by summing its untypeds. Try answering that on Linux.
- **Bounded latency.** Retype is O(number of objects created), with no search,
  no reclaim, no compaction. This is what makes Chapter 14's WCET analysis
  tractable.
- **Revocation is defined.** Revoke the untyped; the objects derived from it are
  destroyed; the memory is reusable. Not "eventually", not "when refcounts drop".

The consequences you must accept:

1. **Every kernel object must be intrusively linked** — no `malloc`'d list nodes.
   See Appendix C.
2. **Object sizes must be fixed at compile time** (or be a power-of-two size
   class chosen by the caller). `struct cnode` with a runtime radix is fine
   because the caller sizes the untyped accordingly.
3. **`kmalloc` disappears.** Anywhere you reach for it, either the object gets a
   type, or the caller passes the memory in. This is a real constraint and it is
   the point.

### 2.1 Migrating from Chapter 05's buddy allocator

The path (also sketched in Chapter 09 §4), stated as a sequence you can actually
execute:

1. Keep the buddy allocator and slab for now; add `src` parameters to every
   allocation call so the *call sites* already name their memory source.
2. Convert the internal allocators to intrusive lists (Appendix C §2). This is
   the largest mechanical change, and it's independent of everything else.
3. At end of boot, convert every free buddy block into an `Untyped` object and
   hand the capabilities to the root task.
4. Delete `kmalloc`. Compile. Fix ~30 call sites. Each fix is a design decision
   about who owns that memory — write the answer down.
5. `_Static_assert` that no kernel translation unit references the buddy
   allocator except `untyped.c`.

Do step 2 early even if you never finish the rest; it's valuable alone.

---

## 3. Arenas for request-scoped memory

In servers (the VFS, the process manager, the network stack) the dominant
lifetime is *request*: allocate a bunch of small things, use them, drop them all.
Individual `free` calls for that pattern are pure overhead and pure risk.

```c
typedef struct arena {
    uint8_t *base;
    size_t   cap, used;
    struct arena *next;      /* chained blocks, optional */
} arena;

static inline void *arena_alloc(arena *a, size_t n, size_t align) {
    size_t off = (a->used + align - 1) & ~(align - 1);
    if (off + n > a->cap) return arena_grow(a, n, align);   /* or NULL */
    a->used = off + n;
    return a->base + off;
}

#define ANEW(a, T)       ((T *)arena_alloc((a), sizeof(T), _Alignof(T)))
#define ANEWN(a, T, n)   ((T *)arena_alloc((a), sizeof(T) * (n), _Alignof(T)))

static inline void arena_reset(arena *a) { a->used = 0; }
```

Why this is the right default in a server:

- **Allocation is three instructions.** Faster than any free-list.
- **Freeing is one store.** No traversal, no coalescing, no latency spike.
- **Use-after-free within a request is impossible**, because nothing is freed
  within a request.
- **Leaks are impossible** — the reset happens in the server loop, once, in one
  place you can see.
- **It composes with the untyped model**: an arena is backed by frames the server
  got from its own untyped budget. Its size *is* its memory quota.

The canonical server loop becomes:

```c
for (;;) {
    msg = nyx_replyrecv(ep, reply);
    arena_reset(&req_arena);            /* <-- the entire memory management */
    handle(msg, &req_arena);
}
```

### 3.1 Rules

1. **A pointer into an arena must never outlive the request.** If a handler needs
   to keep something, it copies into an object-lifetime allocation. Make this
   loud: name the function `promote_*`.
2. **Arena allocation can still fail** (bounded arena = bounded per-request
   memory, which is exactly what Chapter 11 §5.4 demands). Return `ERR_NOMEM`;
   don't grow without limit, or one client's request consumes the server.
3. **One arena per in-flight request**, not one per server, if the server is
   concurrent.
4. **Poison on reset in debug builds** (`memset(base, 0xDD, used)`), which turns
   every escaped pointer into an immediate, obvious crash.

### 3.2 Scratch arenas and the "temporary allocator" pattern

For nested helpers that need scratch space and shouldn't touch the request arena:

```c
typedef struct { arena *a; size_t mark; } arena_temp;

static inline arena_temp temp_begin(arena *a) { return (arena_temp){ a, a->used }; }
static inline void temp_end(arena_temp t)     { t.a->used = t.mark; }

#define WITH_TEMP(name, a) \
    for (arena_temp name = temp_begin(a), *_i = &name; _i; \
         temp_end(name), _i = NULL)
```

Combined with `cleanup` from Appendix A §4.2 this gives you a stack discipline
for heap memory, which is what you actually wanted from `alloca` without the
stack-overflow hazard.

---

## 4. Object lifetime: ownership, not refcounting

Refcounting is the default answer and usually the wrong one. It's easy to get
wrong (missed increment, decrement on an error path), it makes destruction
non-deterministic (bad for Chapter 14), and it hides the ownership design instead
of expressing it.

**Prefer a single owner.** For each object type, write in `docs/objects.md`:

```
struct endpoint
  owned by:      the untyped it was retyped from
  destroyed by:  cap_revoke on that untyped, or the last capability being deleted
  references:    capabilities only (never raw pointers from other objects)
  on destroy:    wake all queued threads with ERR_DEAD
```

That last field is the one people forget, and it's the one that determines
whether a server crash takes down its clients (Chapter 11 §6).

### 4.1 When you do need refcounts

Frames shared between address spaces, and objects with genuinely multiple
independent owners. Then:

```c
/* Acquire: must already hold a reference (you can't resurrect from zero). */
static inline void frame_get(struct page *p) {
    atomic_fetch_add_explicit(&p->refcount, 1, memory_order_relaxed);
}

static inline void frame_put(struct page *p) {
    if (atomic_fetch_sub_explicit(&p->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);   /* pairs with the releases */
        frame_destroy(p);
    }
}
```

The `release`/`acquire` pairing is not optional and is the classic bug: without
it, the destructor can observe writes made by another thread's use of the object
out of order. (On x86's TSO you'll get away with it. On the RISC-V port from
Chapter 13 §B5 you will not — which is one more reason to do that port.)

Three rules:

1. **Never take a reference from zero.** If you need weak references, you need a
   different design (a generation counter, §4.2).
2. **Document the pairing at every `_get`**: which `_put` releases it.
3. **In debug builds, log the acquire/release sites** into a small per-object
   ring. Refcount leaks are otherwise nearly undebuggable.

Note how much of this the capability system already does for you: the derivation
tree (Chapter 09 §3) *is* a refcount with provenance, and it supports revocation,
which plain refcounts cannot.

### 4.2 Generation counters: the use-after-free killer

For any table of objects addressed by index (file descriptors, device handles,
timer IDs), don't hand out raw indices:

```c
typedef struct { uint32_t idx; uint32_t gen; } handle_t;

struct slot { uint32_t gen; bool live; void *obj; };

static void *resolve(struct table *t, handle_t h) {
    if (h.idx >= t->n) return NULL;
    struct slot *s = &t->slots[h.idx];
    if (!s->live || s->gen != h.gen) return NULL;    /* stale handle */
    return s->obj;
}

static void release(struct table *t, uint32_t idx) {
    t->slots[idx].live = false;
    t->slots[idx].gen++;                             /* invalidates all handles */
}
```

Two 32-bit fields in one word. A stale handle now fails a comparison instead of
silently referring to whatever got allocated in that slot next — which is the
entire "fd reuse" bug class (and its security cousin, where a stale fd number
grants access to a file that replaced it).

Use this in every server that hands out IDs. Wrapping `gen` after 4 billion
reuses of one slot is a theoretical concern you can note and ignore, or handle by
retiring the slot.

---

## 5. Slabs, caches, and the allocation hot paths

Chapter 05 built a slab allocator. Some patterns worth adding:

**Per-CPU magazines.** A per-CPU array of ~16 free objects, refilled from the
shared slab under a lock. The common case becomes a pop from a per-CPU array with
no atomics at all (Chapter 12 §3: "every per-CPU field is a lock you don't need").
Bonwick's magazine paper is the reference.

**Constructor/destructor caching.** If an object needs non-trivial
initialization that survives free (a lock in the unlocked state, an initialized
list head), keep it initialized in the cache. `kmem_cache_create(..., ctor)`.
Measure before bothering.

**Object poisoning as your KASAN.** In debug builds:
- write `0x5A` over freed objects, verify on alloc that it's untouched
  (catches use-after-free *writes*),
- red-zone before and after (catches overflow),
- keep the last N free sites per cache (catches double-free with a useful
  backtrace),
- delay reuse (quarantine the last 64 freed objects) — this dramatically raises
  detection rates for use-after-free at trivial cost.

That's maybe 150 lines and it approximates what a sanitizer would give you, in an
environment where you can't run one.

---

## 6. Memory that isn't ordinary memory

A kernel deals with several kinds of memory that look alike and behave
differently. Give each a distinct type so you cannot confuse them.

| Kind | Property | Type it |
|---|---|---|
| Normal RAM | cacheable, coherent | `paddr_t` |
| MMIO | uncacheable, side effects on access, **must not be `memcpy`'d** | `mmio_t` + explicit `mmio_read32/write32` |
| DMA-visible | must be pinned, IOMMU-mapped, and cache-flushed on non-coherent platforms | `dma_addr_t` (IOVA, *not* a physical address) |
| Framebuffer | write-combining | separate mapping type |
| Persistent (NVDIMM/CXL) | survives reboot; needs `clwb` + fence for durability | its own capability type (Chapter 13) |
| Encrypted (SME/SEV) | the C-bit is part of the physical address | breaks naive `P2V`/`V2P` — see Chapter 05 §7 |

Two specific hazards:

**MMIO is not memory.** The compiler may split, merge, reorder, or duplicate
accesses. Never use plain loads/stores, never `memcpy`, never `volatile` alone
(it prevents compiler reordering but not CPU reordering on weaker
architectures). Use explicit accessors with the right barriers, exactly as you'd
use C11 atomics for shared memory (Chapter 12 §5).

**A DMA address is not a physical address.** With an IOMMU it's an IOVA; under
virtualization it's a guest physical address; on some SoCs there's a fixed offset.
Conflating them is the classic "works on my machine, corrupts memory on real
hardware" bug. `dma_addr_t` being a distinct one-field struct (Appendix A §6)
makes it a compile error.

---

## 7. Zeroing, and the information-leak class

Chapter 05 states the rule; here is the complete discipline, because this is the
single most common way kernels leak secrets:

1. **Every frame handed to userspace is zeroed.** No exceptions, no "it was ours
   anyway" reasoning — "ours" included the previous process's data.
2. **Every kernel object is zeroed on retype.** Chapter 09's
   `untyped_retype_zeroes_memory` test exists for this.
3. **Every structure copied to userspace is fully initialized, including
   padding.** Padding is the sneaky one: `struct { uint32_t a; uint64_t b; }` has
   four bytes of stack garbage between the fields. Either `memset` first, or
   declare padding explicitly and set it. This has produced many real CVEs.
4. **`-ftrivial-auto-var-init=zero`** (Appendix A §9.1) covers the stack case
   broadly.
5. **Scrub scratch registers on the syscall exit path** (Chapter 10 §2, hazard 4)
   — register contents are memory too, and they leak KASLR offsets.
6. **Zero on free, not only on allocate**, for anything holding secrets. If a
   crash dump or a persistence checkpoint captures the freed page, you want it
   empty. Note that the compiler may eliminate a "dead" final `memset` — use
   `memset_explicit` (C23) or a barrier.

Write a KTEST that allocates, writes a pattern, frees, reallocates, and asserts
zeroes. Run it in CI forever.

---

## 8. Layout, alignment, and the cache

Performance work that is really a memory-design decision:

- **`_Alignas(64)` on anything written by multiple CPUs.** False sharing on a
  `struct spinlock` next to a hot counter can cost more than the lock itself
  (Chapter 12 §4).
- **Split hot and cold fields.** The TCB layout in Chapter 07 does this: IPC path
  fields in the first cache line, name and accounting far away. Verify with
  `pahole` on the host build, or a `_Static_assert(offsetof(...) < 64)`.
- **Prefer indices to pointers** in large tables. A `uint32_t` index halves the
  memory of the frame database versus a 64-bit pointer, and indices survive
  relocation (which matters for the persistence work in Chapter 13 §C4).
- **Struct-of-arrays for anything you scan.** The scheduler's runqueue bitmap is
  the example: scanning 256 priority bits is four `lzcnt`s over 32 bytes, versus
  touching 256 TCBs.
- **Huge pages for the direct map** (Chapter 06). One TLB entry per gigabyte
  instead of one per 4 KiB is not a micro-optimization; it's often several
  percent of total system performance.

Measure before and after. Chapter 18's benchmark harness exists so that "I made
the struct smaller" becomes a number rather than a belief.

---

## 9. Memory pressure and quotas

The untyped model gives you quotas for free, and it's worth stating what that
buys:

- A component's memory limit is the sum of the untypeds it holds. It cannot
  exceed it. There is no OOM killer, because there is no over-commit, because
  there is no shared pool to over-commit.
- A memory server (Chapter 11 §4) can implement any policy on top: over-commit,
  ballooning, swapping — all in userspace, all replaceable, all measurable.
- Denial of service via memory exhaustion is confined to the component and its
  descendants.

The cost: a component that runs out cannot borrow. That's usually correct, and
where it isn't, the memory server is the place to fix it — a component can ask
for more, and the server decides. That request/grant path is a good exercise, and
it's a place where a policy experiment (Chapter 13) is cheap to run.

---

## 10. Checklist

Copy this into `docs/memory.md`:

- [ ] Every pointer-returning function documents its lifetime in one word.
- [ ] No `kmalloc` in the kernel after the untyped migration.
- [ ] Servers use one arena per request, reset in the server loop.
- [ ] Every ID handed to another component is `(index, generation)`.
- [ ] Refcounts use release/acquire, documented in pairs.
- [ ] Every frame to userspace is zeroed; a KTEST proves it.
- [ ] Every struct crossing the ABI has explicit padding and static asserts.
- [ ] `paddr_t`, `vaddr_t`, `dma_addr_t`, `mmio_t` are distinct types.
- [ ] Debug builds poison freed memory and quarantine recent frees.
- [ ] Multi-CPU-written structures are cache-line aligned.
- [ ] Per-request memory is bounded, so one client cannot exhaust a server.

---

## 11. Exercises

1. Implement the arena and convert one server to it. Count `free` calls removed.
2. Add generation counters to your VFS handle table. Write a test that closes a
   handle, opens a new one, and asserts the old handle fails.
3. Turn on `-ftrivial-auto-var-init=zero` and measure the code size and boot time
   difference. Decide whether you'd ever turn it off.
4. Write the object lifetime table for every kernel object type. For each, answer
   "what happens to capabilities pointing at it when it dies?" Find the one you
   hadn't thought about.
5. Implement free-memory poisoning with quarantine, then deliberately write a
   use-after-free bug and confirm the harness catches it.
6. **Argue the other side:** make the case for a conventional kernel heap. When is
   untyped memory genuinely worse? (Hint: think about a workload with highly
   variable object counts, and about developer velocity in the first month.)

---

Next: [Appendix C — Kernel data structures](C-data-structures.md)
