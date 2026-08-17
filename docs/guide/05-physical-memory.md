# 05 — Physical memory: frames, zones, and allocators

> Goal: a frame allocator that can hand out 4 KiB and contiguous multi-page
> blocks, a kernel heap for small objects, and a clear story about who is allowed
> to consume memory.

---

## 1. Theory: what physical memory management actually is

Physical memory is a flat array of page frames. The manager's job is a set
membership problem — which frames are free — plus three complications:

1. **Contiguity.** DMA engines, page tables (single frame, easy), and huge pages
   (2 MiB / 1 GiB aligned) need physically contiguous, aligned runs.
2. **Constraints.** Old DMA devices can only address 24 or 32 bits. NUMA systems
   have per-node memory with different latencies.
3. **Accountability.** Who is charged for this frame? In a multi-server system,
   an unaccounted allocation is a denial-of-service vector.

That third point is where microkernels diverge sharply from monolithic designs,
and it's the most important design decision in this chapter.

### The kernel memory problem

In Linux, the kernel has a heap. If a process makes syscalls that cause kernel
allocations, the kernel may run out of memory and the OOM killer fires — a
heuristic, best-effort mechanism. This is a known and unfixed class of DoS.

seL4's answer, which Nyx adopts: **the kernel has no heap at all.** All physical
memory not used by the kernel image itself starts as **Untyped** capabilities
handed to the root task at boot. To create a kernel object (a TCB, a page table,
an endpoint), a process must:

1. Hold an `Untyped` capability covering enough memory
2. Invoke `Untyped_Retype` to convert part of it into objects of the desired type
3. Receive capabilities to the new objects

The consequences:

- Kernel memory consumption is **exactly** the memory a principal explicitly
  gave up. No OOM heuristics needed.
- Memory is a **delegatable resource**: a parent can give a child a bounded
  budget by handing over an Untyped of a specific size.
- Revocation is well-defined: revoking the Untyped capability destroys all
  objects derived from it (and thus all threads, mappings, etc.).
- The kernel's allocator is trivial: bump-allocate within an Untyped.

The cost: userspace must manage memory explicitly, which means the root task and
your memory server become non-trivial. This is a real burden but the design
payoff is large, and it's the modern practice.

**Pragmatic path:** build a conventional buddy allocator first (this chapter), so
you can bring the system up. Then, in Chapter 09, introduce Untyped on top of it:
the buddy allocator becomes a boot-time-only mechanism that carves memory into
the initial Untyped set, and after boot the kernel *never allocates*.

---

## 2. Reading the memory map

The bootloader gives you regions with types. E820/Multiboot2/UEFI types:

```
1  Available            ← usable
2  Reserved             ← firmware, MMIO holes: never touch
3  ACPI reclaimable     ← ACPI tables; usable AFTER you've parsed them
4  ACPI NVS             ← must be preserved across sleep; don't use
5  Bad memory           ← don't use
(UEFI adds: LoaderCode/Data, BootServicesCode/Data — reclaimable after
 ExitBootServices; RuntimeServices — must be preserved and mapped)
```

Things you must exclude from the free pool even though they're marked available:

- The first 1 MiB (real-mode IVT, BIOS data area, VGA, option ROMs, EBDA).
  Reserve it wholesale; it's cheap and avoids a class of weird bugs. You'll want
  a small piece of it back for SMP AP startup (Chapter 12) — carve that out
  explicitly.
- Your kernel image. Use the **physical** pair for this
  (`__image_phys_start` .. `__image_phys_end`, guide 02 §4) — not
  `__kernel_start` / `__kernel_end`, which are in different address spaces
  and whose difference underflows. `.boot` sits below `__kernel_start`, so
  a range that starts there misses it.
- The multiboot/limine info structure and any modules (the initrd!).
- Anything the firmware maps for runtime services.

```c
static void reserve_boot_regions(void) {
    pmm_reserve(0, 0x100000);                          /* low 1 MiB */
    pmm_reserve(__image_phys_start,
                __image_phys_end - __image_phys_start);
    pmm_reserve(g_boot.mbi_phys, g_boot.mbi_size);
    for (unsigned i = 0; i < g_boot.nmodules; i++)
        pmm_reserve(g_boot.modules[i].start,
                    g_boot.modules[i].end - g_boot.modules[i].start);
}
```

**Sanity-check the map.** Real firmware produces overlapping regions, unsorted
regions, zero-length regions, and regions above the CPU's physical address width.
Sort, merge, clamp to `cpu_phys_addr_bits`, and log everything.

---

## 3. Allocator designs, compared

| Design | Alloc | Free | Contiguous? | Metadata | Notes |
|---|---|---|---|---|---|
| **Bitmap** | O(n) scan | O(1) | Yes (scan for run) | 1 bit/frame = 32 KiB per GiB | Simple, cache-unfriendly to scan. Good for bring-up. |
| **Free list (stack)** | O(1) | O(1) | No | 0 (store next pointer in the free frame itself) | Fastest for single frames. Cannot do contiguous. |
| **Buddy** | O(log n) | O(log n) | Yes, power-of-two | ~1 byte/frame + free lists | The standard. What Linux uses. |
| **Region/extent tree** | O(log n) | O(log n) | Yes, arbitrary | Small, but needs an allocator for nodes (chicken-and-egg) | Elegant; awkward at boot. |

**Recommendation: bitmap for the first hour, then buddy.** A stack free-list
layered on top of the buddy for order-0 frames gives you the best of both — this
is essentially Linux's per-CPU page frame cache.

### The bootstrap problem

Your allocator needs memory for its own metadata, but there's no allocator yet.
Standard solutions:

1. **Static array sized for a maximum.** Ugly, wastes memory, has a hard limit.
2. **Bump allocator over the largest free region**, used only during init, then
   the bump region is reserved. This is what Linux's `memblock` does. **Do this.**
3. Place metadata at the start of the region it describes.

```c
/* A boot-time bump allocator; retired after pmm_init(). */
static uintptr_t boot_brk, boot_brk_end;

void *boot_alloc(size_t sz, size_t align) {
    boot_brk = ALIGN_UP(boot_brk, align);
    if (boot_brk + sz > boot_brk_end) panic("boot_alloc exhausted");
    void *p = P2V(boot_brk);
    boot_brk += sz;
    memset(p, 0, sz);
    return p;
}
```

> **Do not start the arena at the largest region's base.** It is the
> obvious reading of "bump allocator over the largest free region" and it
> overwrites the running kernel. GRUB loads the kernel at 1 MiB, and on
> every PC the region starting at 1 MiB *is* the largest available one — so
> `boot_brk = big->base` hands the allocator the memory `.text` is
> executing from. The first `boot_alloc` of any size then walks over the
> kernel image.
>
> The symptom is a hang with **no output at all**, because the code that
> would have reported it is what got overwritten. It is not caught by §2's
> `reserve_boot_regions` either: that reserves the kernel image, but it runs
> *after* the bump allocator has already been handed the region.
>
> Start the arena at the highest of: the region's base, the end of the
> kernel image, the end of the Multiboot info structure, and the end of
> every module — page-aligned:
>
> ```c
> uintptr_t start = big->base;
> start = MAX(start, kernel_phys_end);
> start = MAX(start, mbi_phys_end);
> for (each module m) start = MAX(start, m->end);
> boot_brk = ALIGN_UP(start, PAGE_SIZE);
> boot_brk_end = big->base + big->length;
> ```
>
> Everything in that list is something a bootloader placed in the same
> region and that you are still using. Corrected 2026-08-15, found by
> implementation.

---

## 4. Implementation: a buddy allocator

### Data structures

```c
/* kernel/mm/pmm.c */
#define PAGE_SHIFT 12
#define PAGE_SIZE  (1UL << PAGE_SHIFT)
#define MAX_ORDER  11              /* orders 0..10 => 4 KiB .. 4 MiB */

struct page {                      /* one per physical frame */
    uint32_t flags;
    uint8_t  order;                /* valid only if this is a buddy head */
    uint8_t  zone;
    uint16_t refcount;             /* for shared frames / COW */
    struct list_head lru;          /* free list linkage */
    void    *owner;                /* Untyped or address space, Ch.09 */
};

#define PG_FREE  (1u << 0)
#define PG_HEAD  (1u << 1)         /* head of a buddy block */
#define PG_RSVD  (1u << 2)

struct zone {
    const char *name;
    uint64_t base, npages;
    struct page *pages;                     /* the frame database */
    struct list_head free[MAX_ORDER + 1];
    size_t nfree;
    spinlock_t lock;
};

enum { ZONE_DMA,      /* < 16 MiB, for ISA DMA. Keep it, it's cheap. */
       ZONE_DMA32,    /* < 4 GiB, for 32-bit-only PCI devices */
       ZONE_NORMAL,
       NZONES };

static struct zone zones[NZONES];
```

**The frame database** (`struct page` array, one per frame) is the key structure.
It costs ~32 bytes per 4 KiB frame — about 0.8% of RAM. In exchange you get O(1)
frame → metadata lookup:

```c
static inline struct page *phys_to_page(paddr_t p) {
    struct zone *z = zone_of(p);
    return &z->pages[(p - z->base) >> PAGE_SHIFT];
}
static inline paddr_t page_to_phys(struct page *pg) {
    struct zone *z = &zones[pg->zone];
    return z->base + ((pg - z->pages) << PAGE_SHIFT);
}
```

### The buddy invariant

A block of order *k* covers 2^k frames, aligned to 2^k frames. Its **buddy** is
the adjacent block of the same order that, together with it, forms an aligned
block of order *k+1*:

```c
static inline size_t buddy_index(size_t idx, unsigned order) {
    return idx ^ (1UL << order);
}
```

That XOR is the entire trick. Allocation splits down; free merges up.

```c
static struct page *buddy_alloc(struct zone *z, unsigned order) {
    unsigned o;
    for (o = order; o <= MAX_ORDER; o++)
        if (!list_empty(&z->free[o])) break;
    if (o > MAX_ORDER) return NULL;

    struct page *pg = list_pop(&z->free[o], struct page, lru);
    pg->flags &= ~PG_FREE;

    /* Split down to the requested order, returning the halves to free lists. */
    while (o > order) {
        o--;
        struct page *half = pg + (1UL << o);
        half->order = (uint8_t)o;
        half->flags |= PG_FREE | PG_HEAD;
        list_add(&z->free[o], &half->lru);
    }
    pg->order = (uint8_t)order;
    z->nfree -= 1UL << order;
    return pg;
}

static void buddy_free(struct zone *z, struct page *pg, unsigned order) {
    size_t idx = (size_t)(pg - z->pages);
    z->nfree += 1UL << order;

    while (order < MAX_ORDER) {
        size_t bidx = buddy_index(idx, order);
        if (bidx >= z->npages) break;
        struct page *b = &z->pages[bidx];
        if (!(b->flags & PG_FREE) || b->order != order) break;

        list_del(&b->lru);                      /* merge */
        idx = MIN(idx, bidx);
        order++;
    }
    struct page *head = &z->pages[idx];
    head->order = (uint8_t)order;
    head->flags |= PG_FREE | PG_HEAD;
    list_add(&z->free[order], &head->lru);
}
```

### Public API

```c
paddr_t pmm_alloc(void);                       /* one frame, zeroed */
paddr_t pmm_alloc_order(unsigned order, int zone);
paddr_t pmm_alloc_contig(size_t npages, paddr_t max_addr, size_t align);
void    pmm_free(paddr_t p);
void    pmm_free_order(paddr_t p, unsigned order);
size_t  pmm_free_bytes(void);
```

**Always zero frames before handing them out** — otherwise you leak one process's
memory contents to another. This is a real vulnerability class. Zero on *free*
if you want the alloc path fast (and it also makes use-after-free bugs
deterministic), or zero on alloc; do not skip it. Later you can add a
"pre-zeroed pool" filled by an idle-time thread.

---

## 5. The kernel object allocator (slab)

Frames are 4 KiB; you need `struct thread` (a few hundred bytes) and list nodes.
A **slab allocator** (Bonwick, 1994) is the right structure:

- One cache per object *type*, with fixed object size.
- A slab is one or more frames divided into objects, with a free list.
- Objects are constructed once and reused, preserving initialized state.
- Excellent locality; no fragmentation from mixed sizes.
- Per-CPU magazines make the fast path lock-free (Chapter 12).

```c
struct kmem_cache {
    const char *name;
    size_t objsize, align;
    unsigned per_slab;
    struct list_head partial, full, empty;
    void (*ctor)(void *);
    spinlock_t lock;
    /* stats: allocated, freed, slabs, high-water */
};

struct slab_hdr {
    struct list_head link;
    struct kmem_cache *cache;
    uint16_t inuse, free_head;
    /* followed by a uint16_t freelist[] index array, then the objects */
};

void *kmem_cache_alloc(struct kmem_cache *c);
void  kmem_cache_free(struct kmem_cache *c, void *obj);
```

Add a red-zone / poison mode under `CONFIG_DEBUG`:

- Fill freed objects with `0xDEADBEEF` — a use-after-free then reads recognisable
  garbage instead of plausible data.
- Put a magic value before and after each object; check it on free.
- Optionally delay reuse (quarantine) to widen the detection window.

This is a poor man's KASAN and it works well.

Then a general `kmalloc` on top: caches for 16, 32, 64, ..., 4096 bytes, falling
back to `pmm_alloc_order` for larger requests.

> **But wait** — didn't §1 say the kernel has no heap? Yes, eventually. During
> bring-up you need one. The migration in Chapter 09 is: each `kmem_cache`
> becomes "allocate from an Untyped supplied by the caller", so the *structure*
> survives and only the *source* of memory changes. Design your allocator APIs to
> take an explicit "where does this come from" argument now, even if it's ignored:
> `kmem_cache_alloc(c, src)`.

---

## 6. NUMA (design for it, implement later)

On multi-socket machines, memory is attached to a socket; accessing another
socket's memory costs 1.5–2×. ACPI's **SRAT** table maps physical ranges to
proximity domains, and **SLIT** gives the distance matrix.

The design implication now: make `struct zone` per-(node, kind), and make the
allocator take a node hint:

```c
paddr_t pmm_alloc_node(int node, unsigned order, int zone_kind);
```

Even if `node` is always 0 today, having the parameter means adding NUMA later
isn't a rewrite. In a microkernel, the natural policy is: memory follows the
thread, and userspace memory servers can be node-affine.

---

## 7. Modern considerations worth designing for

**Memory hotplug / ballooning.** Under a hypervisor, memory can appear and
disappear. Your zone structure should tolerate `npages` growing. Keep the frame
database in a sparse, chunked form (Linux's `SPARSEMEM`) rather than one giant
array, if you want this.

**Persistent memory / CXL.** Byte-addressable non-volatile memory shows up as a
separate memory type in the E820/UEFI map. It shouldn't be in the general free
pool; it should become a distinct object type with its own capability. This is a
good research direction (Chapter 13).

**Memory tagging (ARM MTE, x86 LAM).** Not on x86 yet in a usable form, but the
design hook is: `struct page` gets a tag field, and allocation assigns tags.

**Encrypted memory (AMD SME/SEV, Intel TME/MKTME).** Physical addresses get an
encryption-key bit in the high bits. This *directly affects your P2V/V2P macros*
— mask it off. Worth knowing before it surprises you.

**Frame poisoning for KASLR/info-leak resistance.** Zeroing on free is your
baseline defence.

---

## 8. Verification

Write these tests now; they'll catch regressions for years.

```c
KTEST(pmm_alloc_free_roundtrip) {
    size_t before = pmm_free_bytes();
    paddr_t p = pmm_alloc();
    KASSERT(p && (p & (PAGE_SIZE-1)) == 0);
    KASSERT(pmm_free_bytes() == before - PAGE_SIZE);
    pmm_free(p);
    KASSERT(pmm_free_bytes() == before);
}

KTEST(pmm_frames_are_zeroed) {
    paddr_t p = pmm_alloc();
    uint8_t *v = P2V(p);
    memset(v, 0xAA, PAGE_SIZE);
    pmm_free(p);
    paddr_t q = pmm_alloc();            /* likely the same frame */
    uint8_t *w = P2V(q);
    for (size_t i = 0; i < PAGE_SIZE; i++) KASSERT(w[i] == 0);
    pmm_free(q);
}

KTEST(pmm_no_double_alloc) {
    /* Allocate everything, check for duplicates via a shadow bitmap,
       then free everything and check the free count returns exactly. */
}

KTEST(buddy_merges_fully) {
    size_t before = pmm_free_bytes();
    paddr_t a = pmm_alloc_order(0, ZONE_NORMAL);
    paddr_t b = pmm_alloc_order(0, ZONE_NORMAL);
    pmm_free_order(a, 0); pmm_free_order(b, 0);
    /* After freeing, an order-1 alloc must succeed at the merged address. */
    paddr_t c = pmm_alloc_order(1, ZONE_NORMAL);
    KASSERT(c != 0);
    pmm_free_order(c, 1);
    KASSERT(pmm_free_bytes() == before);
}
```

Add a **fragmentation stress test**: random alloc/free of random orders for
100k iterations, asserting the free count is conserved and that a large
allocation still succeeds after everything is freed. This finds buddy merge bugs
that unit tests miss.

**Host-side testing:** the buddy allocator is pure logic. Compile `pmm.c` for
your host with a stub `struct page` array and run it under ASan/UBSan and a
fuzzer. This is a huge win — you get real tooling on the hardest-to-debug code.
Structure the file so it has no hardware dependencies (put those behind
`pmm_arch_*` hooks). Chapter 18 expands on this.

---

## 9. Exercises

1. Compute the metadata overhead of your `struct page` for 4 GiB, 64 GiB, and
   1 TiB of RAM. At what point does it become a problem, and what would you do?
2. Implement `pmm_alloc_contig(npages, max_addr, align)` for a non-power-of-two
   count (needed for DMA buffers). What's the cleanest algorithm on top of buddy?
3. Add a per-CPU order-0 frame cache (a small array of frames each CPU can
   alloc/free without taking the zone lock). Measure the improvement with a
   microbenchmark. What's the correct behaviour when a CPU's cache overflows?
4. Argue for or against the seL4 no-kernel-heap model for a general-purpose
   desktop OS. What would `fork()` cost?
5. Implement a `/proc`-style debug dump of the buddy free lists (count per
   order) and use it to visualize fragmentation over a stress test.

---

Next: [06 — Virtual memory: address spaces, mapping, and hardening](06-virtual-memory.md)
