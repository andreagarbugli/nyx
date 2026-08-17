# 06 — Virtual memory: address spaces, mapping, and hardening

> Goal: an address space object you can create, map frames into, switch between,
> and tear down; page faults delivered as messages to a userspace pager; and the
> hardware protections (NX, SMEP, SMAP, W^X, PCID) turned on.

---

## 1. Theory: what an address space buys you

Virtual memory provides four distinct things that are often conflated:

1. **Protection** — a process cannot name memory it wasn't given.
2. **Relocation** — every program can be linked at the same address.
3. **Abstraction over physical layout** — contiguous virtual, scattered physical.
4. **A fault hook** — the ability to run code when memory is touched. This one is
   the most powerful and the most under-appreciated: demand paging,
   copy-on-write, memory-mapped files, garbage collector write barriers,
   checkpointing, distributed shared memory, and lazy allocation are all just
   "run my code on access".

In a microkernel, #4 is the crucial one, because the code that runs is in
**userspace**. Mach called the component an "external pager"; L4 calls it a
"pager"; we'll use that term. The kernel provides the mechanism (deliver the
fault as IPC, allow a frame to be mapped) and userspace provides the policy
(where does the page come from, what to evict, whether to kill the thread).

### Address space layout for Nyx

```
0x0000_0000_0000_1000  ┐
      ...              │  User space (128 TiB).
0x0000_7FFF_FFFF_FFFF  ┘  Layout is entirely userspace's business.
                          Page 0 is never mapped (null pointer traps).

    ---- non-canonical hole ----

0xFFFF_8000_0000_0000  ┐  Direct map of all physical memory (64 TiB max)
0xFFFF_BFFF_FFFF_FFFF  ┘  1 GiB pages, NX, kernel-only, global

0xFFFF_C000_0000_0000  ┐  Kernel dynamic mappings (vmalloc-style, MMIO, guard
0xFFFF_FFFF_7FFF_FFFF  ┘  pages for stacks)

0xFFFF_FFFF_8000_0000  ┐  The kernel image (-2 GiB, matches -mcmodel=kernel)
0xFFFF_FFFF_FFFF_FFFF  ┘
```

**Crucial invariant:** every address space has *identical* upper-half mappings.
This means:

- Entering the kernel doesn't require a CR3 switch.
- Kernel data is at the same address regardless of which process is running.
- You implement it by making all PML4s share the same entries for indices
  256–511. Allocate those PDPTs once at boot and copy the 256 PML4 entries into
  every new address space. **Note:** if you later add kernel mappings *after*
  processes exist, you must propagate them — which is why the shared entries
  should be allocated up front, so only lower-level tables change (and those are
  shared by pointer). Linux gets this wrong-then-right with `vmalloc_fault`;
  avoid the problem by pre-allocating.

*(KPTI, if you need it, breaks this: the user CR3 has almost no kernel mapping.
See §7.)*

---

## 2. Page table manipulation

```c
/* arch/x86_64/paging.c */
typedef uint64_t pte_t;

#define PTE_P     (1UL << 0)
#define PTE_W     (1UL << 1)
#define PTE_U     (1UL << 2)
#define PTE_PWT   (1UL << 3)
#define PTE_PCD   (1UL << 4)
#define PTE_A     (1UL << 5)
#define PTE_D     (1UL << 6)
#define PTE_PS    (1UL << 7)
#define PTE_G     (1UL << 8)
#define PTE_SW0   (1UL << 9)    /* software-defined: "COW" */
#define PTE_SW1   (1UL << 10)   /* software-defined: "shared" */
#define PTE_NX    (1UL << 63)

#define PTE_ADDR_MASK 0x000FFFFFFFFFF000UL
#define PTE_ADDR(e)   ((e) & PTE_ADDR_MASK)

#define PML4_IDX(v) (((v) >> 39) & 0x1FF)
#define PDPT_IDX(v) (((v) >> 30) & 0x1FF)
#define PD_IDX(v)   (((v) >> 21) & 0x1FF)
#define PT_IDX(v)   (((v) >> 12) & 0x1FF)

struct vspace {
    paddr_t   pml4_phys;
    pte_t    *pml4;             /* direct-map pointer */
    uint16_t  pcid;
    atomic_size_t nmapped;      /* accounting */
    spinlock_t lock;
    cpumask_t active_on;        /* for TLB shootdown, Ch.12 */
};
```

The walk, with optional allocation:

```c
static pte_t *walk(struct vspace *as, vaddr_t va, bool alloc, void *src) {
    pte_t *tbl = as->pml4;
    for (int level = 3; level > 0; level--) {
        size_t idx = (va >> (12 + 9 * level)) & 0x1FF;
        pte_t e = tbl[idx];

        if (!(e & PTE_P)) {
            if (!alloc) return NULL;
            paddr_t frame = pmm_alloc_from(src);       /* zeroed */
            if (!frame) return NULL;
            /* Intermediate entries are permissive; leaves decide.
               Permissions AND across levels, so setting U|W here is safe. */
            e = frame | PTE_P | PTE_W | PTE_U;
            tbl[idx] = e;
        } else if (e & PTE_PS) {
            return NULL;    /* a huge page is in the way; caller must split */
        }
        tbl = (pte_t *)P2V(PTE_ADDR(e));
    }
    return &tbl[PT_IDX(va)];
}
```

> **Design note on intermediate permissions.** Two schools: (a) make intermediate
> entries maximally permissive (`U|W`) and let leaves decide — simple, and what
> Linux does; (b) compute intermediate permissions as the union of children —
> lets you revoke a whole subtree by clearing one bit, but requires refcounting
> permissions. Start with (a).

Map and unmap:

```c
int vspace_map(struct vspace *as, vaddr_t va, paddr_t pa, uint64_t flags) {
    KASSERT((va & 0xFFF) == 0 && (pa & 0xFFF) == 0);
    KASSERT(canonical(va));

    spin_lock(&as->lock);
    pte_t *pte = walk(as, va, true, as->src);
    if (!pte) { spin_unlock(&as->lock); return -ENOMEM; }
    if (*pte & PTE_P) { spin_unlock(&as->lock); return -EEXIST; }

    *pte = pa | flags | PTE_P;
    as->nmapped++;
    spin_unlock(&as->lock);
    /* Not-present -> present: no flush needed on x86, but see Ch.12. */
    return 0;
}

int vspace_unmap(struct vspace *as, vaddr_t va, paddr_t *out_pa) {
    spin_lock(&as->lock);
    pte_t *pte = walk(as, va, false, NULL);
    if (!pte || !(*pte & PTE_P)) { spin_unlock(&as->lock); return -ENOENT; }
    if (out_pa) *out_pa = PTE_ADDR(*pte);
    *pte = 0;
    as->nmapped--;
    spin_unlock(&as->lock);

    tlb_invalidate(as, va);          /* MUST flush: present -> not present */
    return 0;
}
```

**The rule that will bite you:** any transition from present, or any reduction of
permissions, requires a TLB flush. Increasing permissions or making a page
present does not (on x86). When in doubt, flush.

### The debugging tool you must write

```c
void vmm_dump_walk(paddr_t cr3, vaddr_t va) {
    pte_t *tbl = P2V(cr3 & PTE_ADDR_MASK);
    static const char *names[] = { "PML4", "PDPT", "PD  ", "PT  " };
    for (int level = 3, n = 0; level >= 0; level--, n++) {
        size_t idx = (va >> (12 + 9 * level)) & 0x1FF;
        pte_t e = tbl[idx];
        kprintf("  %s[%3zu] = %016lx  %c%c%c%c%c%c\n", names[n], idx, e,
                e & PTE_P ? 'P':'-', e & PTE_W ? 'W':'-', e & PTE_U ? 'U':'-',
                e & PTE_PS ? 'S':'-', e & PTE_A ? 'A':'-',
                e & PTE_NX ? 'X':'-');
        if (!(e & PTE_P) || (e & PTE_PS)) return;
        tbl = P2V(PTE_ADDR(e));
    }
}
```

Call it from your #PF panic handler. It turns "it faulted, why?" into a
five-second answer.

---

## 3. Address space lifecycle

```c
struct vspace *vspace_create(void *src) {
    struct vspace *as = kmem_cache_alloc(&vspace_cache, src);
    as->pml4_phys = pmm_alloc_from(src);
    as->pml4 = P2V(as->pml4_phys);
    /* Share the kernel half: copy PML4 entries 256..511 from the master. */
    memcpy(&as->pml4[256], &kernel_pml4[256], 256 * sizeof(pte_t));
    as->pcid = pcid_alloc();
    return as;
}

void vspace_destroy(struct vspace *as) {
    /* Walk only the LOWER half (0..255). The upper half is shared —
       freeing it would take down the kernel. This is a classic bug. */
    free_level(as->pml4, 3, 0, 256);
    pmm_free(as->pml4_phys);
    pcid_free(as->pcid);
    kmem_cache_free(&vspace_cache, as);
}
```

Switching:

```c
static inline void vspace_switch(struct vspace *as) {
    uint64_t cr3 = as->pml4_phys | as->pcid;
    if (cpu_has(PCID))
        cr3 |= (1UL << 63);        /* don't flush this PCID's entries */
    __asm__ volatile("mov %0, %%cr3" :: "r"(cr3) : "memory");
}
```

---

## 4. Page faults as IPC — the microkernel core mechanism

```c
int page_fault(struct regs *r) {
    vaddr_t fault_addr = read_cr2();
    uint64_t err = r->error;

    /* Kernel-mode faults are (almost) always bugs. Exceptions:
       - a deliberate copy_from_user that faulted -> fixup table
       - a kernel stack guard page -> report cleanly            */
    if (!(err & PF_USER)) {
        if (fixup_exception(r)) return 0;
        return -1;                          /* -> panic_regs */
    }

    struct thread *t = current;

    /* Build the fault message and send it to the thread's fault endpoint.
       The thread blocks. The pager decides what to do.                    */
    struct message m = {
        .label = MSG_LABEL_VM_FAULT,
        .w[0]  = fault_addr,
        .w[1]  = r->rip,
        .w[2]  = (err & PF_WRITE) ? FAULT_WRITE :
                 (err & PF_INSTR) ? FAULT_EXEC : FAULT_READ,
        .w[3]  = err,
    };

    if (!t->fault_ep) {
        KWARN("thread %u faulted at %p with no pager; killing", t->id,
              (void *)fault_addr);
        thread_suspend(t);
        return 0;
    }

    ipc_send_fault(t, t->fault_ep, &m);     /* blocks t, may switch away */
    return 0;
}
```

The pager replies with either "I've mapped it, retry" (the kernel simply resumes
the thread; the retried instruction now succeeds) or "fatal" (the thread stays
suspended and the pager can inspect/kill it).

**Why this is beautiful:** demand paging, memory-mapped files, swapping,
copy-on-write, lazy zero pages, distributed shared memory, and checkpointing all
become *userspace programs* that you can write, debug with a normal debugger,
restart, and replace at runtime. That's the payoff for all the IPC machinery.

**Why it's expensive:** a fault is now a mode switch + IPC + a mapping operation
+ IPC back + resume. Measure it (Chapter 18). Mitigations: map eagerly in
batches, use larger pages, and let the pager pre-map a whole region on one fault.

### Fixup tables for kernel access to user memory

When the kernel deliberately reads user memory (during a syscall that takes a
pointer), a fault is *expected* and must not panic:

```c
/* Mark instructions that may fault, with a recovery address. */
#define USER_ACCESS(insn, fixup_label) \
    insn "\n" \
    ".pushsection .fixup_table, \"a\"\n" \
    ".quad 1b, " #fixup_label "\n" \
    ".popsection\n"
```

`fixup_exception()` looks up `r->rip` in the sorted `.fixup_table` and, if found,
sets `r->rip` to the recovery address and returns success. This is how Linux's
`copy_from_user` works.

**With SMAP enabled**, you must also `stac` before and `clac` after. Wrap it:

```c
static inline int copy_from_user(void *dst, const void __user *src, size_t n) {
    if (!user_range_ok(src, n)) return -EFAULT;
    stac();
    int r = __copy_with_fixup(dst, src, n);
    clac();
    return r;
}
```

`user_range_ok` must check the range is entirely in the lower half **and doesn't
wrap**. Getting this wrong is the classic kernel vulnerability:

```c
static inline bool user_range_ok(const void *p, size_t n) {
    uintptr_t a = (uintptr_t)p;
    return n <= USER_MAX && a <= USER_MAX - n;   /* no overflow */
}
```

> **Microkernel note:** ideally you avoid this entirely. If all IPC payloads fit
> in registers, and bulk transfer happens through shared mappings the *userspace*
> processes set up, the kernel never dereferences a user pointer. That's an
> excellent property — it removes an entire vulnerability class. Aim for it.

---

## 5. Copy-on-write and shared frames

COW is the canonical demonstration of the fault hook:

1. Both address spaces map the frame read-only, with `PTE_SW0` (our COW bit) set.
2. Increment the frame's refcount.
3. On a write fault to a page with `PTE_SW0`:
   - If refcount == 1, just make it writable (the other side already copied).
   - Else allocate a new frame, copy, map it writable, decrement the old refcount.
4. Flush the TLB for that address.

```c
static int handle_cow(struct vspace *as, vaddr_t va, pte_t *pte) {
    paddr_t old = PTE_ADDR(*pte);
    struct page *pg = phys_to_page(old);

    if (atomic_load(&pg->refcount) == 1) {
        *pte = (*pte | PTE_W) & ~PTE_SW0;
    } else {
        paddr_t new = pmm_alloc();
        if (!new) return -ENOMEM;
        memcpy(P2V(new), P2V(old), PAGE_SIZE);
        *pte = new | (*pte & ~(PTE_ADDR_MASK | PTE_SW0)) | PTE_W;
        page_put(pg);
    }
    tlb_invalidate(as, va);
    return 0;
}
```

**In Nyx, where does this live?** In a pure design, in *userspace* — the pager
gets the write fault and does the copying via mapping operations. That's slower
but more flexible. A pragmatic compromise: implement COW in the kernel as an
optimization for a specific, well-defined case, and keep the general mechanism in
userspace. Decide deliberately and write it in `docs/`.

Frame refcounting requires care: the refcount must be atomic, and the last
`page_put` frees. Use the same discipline as capability refcounting (Chapter 09)
so there's one lifetime model, not two.

---

## 6. TLB management and PCID

### Basic invalidation

```c
static inline void invlpg(vaddr_t va) {
    __asm__ volatile("invlpg (%0)" :: "r"(va) : "memory");
}
```

### PCID: the microkernel performance lever

Without PCID, every `mov cr3` flushes the entire TLB. In an IPC-heavy system,
you switch address spaces thousands of times per second, and each switch costs
hundreds of TLB misses afterward. PCID tags TLB entries with a 12-bit process
context ID, so switching away and back preserves them.

```c
/* CR3 layout with PCID:
   bits 11:0  = PCID
   bits 51:12 = PML4 physical address
   bit 63     = 1 means "do NOT flush this PCID's TLB entries"  */

void pcid_enable(void) {
    if (!cpu_has(PCID)) return;
    write_cr4(read_cr4() | CR4_PCIDE);
}
```

You have only 4096 PCIDs, so you need an allocator with reclamation: when you run
out, flush all and start over (a "generation" scheme). Linux keeps a small number
of PCIDs and assigns them per-CPU on demand — that's the right approach; a
process gets a PCID on the CPU it runs on, and switching CPUs may reassign.

`invpcid` (CPUID 7:0 EBX[10]) gives targeted invalidation:

```c
static inline void invpcid(unsigned type, uint16_t pcid, vaddr_t va) {
    struct { uint64_t pcid; uint64_t addr; } d = { pcid, va };
    __asm__ volatile("invpcid %0, %1" :: "m"(d), "r"((uint64_t)type) : "memory");
}
/* type 0: single address in a PCID
   type 1: all in a PCID
   type 2: all, including globals
   type 3: all, excluding globals    */
```

**Measure the difference.** Write an IPC ping-pong benchmark (Chapter 18), run it
with and without PCID, and record the number. This is exactly the kind of result
that justifies a microkernel design, and having your own measurement beats
citing a paper.

### Global pages

Set `PTE_G` on kernel mappings and `CR4.PGE`; those entries survive CR3 writes.
Big win, since the kernel half is identical everywhere. **But**: global pages
interact badly with KPTI and were part of the Meltdown attack surface. If you
implement KPTI, don't mark user-visible trampolines global.

---

## 7. Hardening

Enable these in order and test after each; each one will break something and you
want to know which.

```c
void vmm_harden(void) {
    uint64_t cr4 = read_cr4();
    if (cpu_has(SMEP)) cr4 |= CR4_SMEP;   /* ring0 can't execute user pages */
    if (cpu_has(SMAP)) cr4 |= CR4_SMAP;   /* ring0 can't touch user data */
    if (cpu_has(UMIP)) cr4 |= CR4_UMIP;   /* ring3 can't sgdt/sidt/str */
    write_cr4(cr4);
    write_cr0(read_cr0() | CR0_WP);       /* ring0 respects read-only */
    /* EFER.NXE was set in the boot stub. */
}
```

**W^X policy** — enforce in `vspace_map`:

```c
if ((flags & PTE_W) && !(flags & PTE_NX))
    return -EINVAL;   /* no page may be both writable and executable */
```

This forces JITs to use two mappings of the same frame (one W, one X) and
explicitly transition — which is exactly what you want, because the transition
becomes an auditable operation.

**Guard pages.** Every kernel stack gets an unmapped page below it. Combined with
an IST-backed #DF handler, a stack overflow becomes a clean diagnostic rather
than silent corruption of whatever is below.

```c
void *kstack_alloc(void) {
    vaddr_t base = kvm_alloc_region(KSTACK_SIZE + 2 * PAGE_SIZE);
    /* leave the first and last page unmapped as guards */
    for (size_t i = PAGE_SIZE; i < KSTACK_SIZE + PAGE_SIZE; i += PAGE_SIZE)
        vspace_map(&kernel_vspace, base + i, pmm_alloc(), PTE_P|PTE_W|PTE_NX|PTE_G);
    return (void *)(base + PAGE_SIZE + KSTACK_SIZE);
}
```

**KASLR.** Randomize the kernel's virtual base at boot. Requires either a
relocatable kernel (`-fPIE` + processing relocations) or a fixed set of candidate
offsets. Meaningful only once you have userspace that could exploit anything —
but design the direct-map base as a *variable* (`hhdm_offset`) rather than a
constant now, and you keep the option open.

**KPTI (Meltdown mitigation).** Two PML4s per process: the kernel one (full) and
a user one containing only the entry trampoline, the GDT/IDT, and per-CPU
structures. Switch CR3 in the syscall/interrupt entry and exit paths. This is
significant work and significant cost (~5–30% on syscall-heavy workloads). Check
CPUID for `ARCH_CAPABILITIES.RDCL_NO` — modern CPUs don't need it. Implement it
only if you care about running on affected hardware; but *do* note in your design
doc where the trampoline would go, because retrofitting is painful.

---

## 8. The mapping API exposed to userspace

Preview of Chapter 09 — every operation is a capability invocation:

```
Frame_Map(frame_cap, vspace_cap, vaddr, rights, attrs)
Frame_Unmap(frame_cap)
Frame_GetAddress(frame_cap)                 -- only for DMA-authorized frames
PageTable_Map(pt_cap, vspace_cap, vaddr)    -- userspace supplies page tables!
VSpace_Clean/Invalidate(...)                -- cache maintenance
```

Note `PageTable_Map`: in the seL4 model, even *page tables* are objects that
userspace allocates from Untyped and inserts explicitly. The kernel never
allocates on a fault. That's what makes memory consumption fully accountable —
and it means the pager has to handle "map failed because there's no page table
here" by creating one. Slightly more work; complete determinism in return.

`rights` is masked by the rights carried on the frame capability, so a process
that received a read-only frame capability cannot map it writable. The check is
one AND.

---

## 9. Verification

- [ ] Map a frame at a chosen address, write, read back, unmap, and confirm the
      next access faults.
- [ ] Confirm a user page mapped without `PTE_U` faults from ring 3 with
      `err & PF_USER`.
- [ ] Confirm `CR0.WP` works: write to a read-only kernel page from ring 0 and
      get a #PF, not silent success.
- [ ] Confirm SMEP: attempt to `call` a user address from ring 0, see #PF with
      the instruction-fetch bit.
- [ ] Confirm SMAP: read a user address from ring 0 without `stac` and see #PF.
- [ ] Create 100 address spaces, map 1000 pages in each, destroy them all, and
      confirm `pmm_free_bytes()` returns to its original value. **This test
      catches page-table leaks, which are otherwise invisible for months.**
- [ ] With PCID on, run an address-space-switch microbenchmark and compare TLB
      miss counts (use the PMU, or just wall-clock).

```c
KTEST(vspace_destroy_frees_everything) {
    size_t before = pmm_free_bytes();
    struct vspace *as = vspace_create(boot_src);
    for (int i = 0; i < 1000; i++)
        vspace_map(as, 0x400000 + i * PAGE_SIZE, pmm_alloc(),
                   PTE_P | PTE_W | PTE_U | PTE_NX);
    vspace_destroy_deep(as);     /* also frees mapped frames */
    KASSERT(pmm_free_bytes() == before);
}
```

---

## 10. Exercises

1. Implement `vmm_dump_walk` and use it to diagnose a deliberately broken
   mapping (e.g. set `PTE_U` at the leaf but not at the PD).
2. Implement 2 MiB page support in `vspace_map`, including splitting a huge page
   when a 4 KiB mapping is requested inside it. What's the TLB flush requirement?
3. Measure the cost of a page fault round-trip through a userspace pager versus
   an in-kernel handler. How many microseconds? What fraction is IPC?
4. Implement lazy-zero pages: map a single shared zero frame read-only for all
   anonymous memory, and COW it on write. How much memory does this save for a
   process that allocates 100 MiB and touches 1 MiB?
5. Write the design doc for KPTI in Nyx: what exactly must be in the user PML4,
   and where does the CR3 switch go in `entry.asm`?

---

Next: [07 — Threads, context switching, and scheduling](07-tasks-and-scheduling.md)
