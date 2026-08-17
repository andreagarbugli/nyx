# 09 — Capabilities: the security architecture

> Goal: a capability space, a derivation tree, revocation, and untyped memory —
> the machinery that turns "a bunch of servers" into a system with a defensible
> security model.

---

## 1. Theory: two ways to answer "may I?"

Every access control decision is a lookup in a conceptual matrix: rows are
subjects, columns are objects, cells are rights. You can slice it two ways.

### By column: Access Control Lists

Each object carries a list of who may do what. Subject identity is **ambient**:
you *are* uid 1000, and every action you take carries that identity implicitly.
UNIX, Windows ACLs, most databases.

### By row: Capabilities

Each subject holds an unforgeable set of *references*, each of which names an
object and carries rights. You don't *have an identity*; you *hold references*.
Possession is authority.

### Why the difference is deep, not cosmetic

**The confused deputy problem** (Hardy, 1988). A compiler service runs with
privilege to write a billing file `/sys/billing`. A user invokes it:

```
compile --output /sys/billing myprogram.c
```

With ACLs, the compiler checks "may I write this file?" — and yes, it may,
because *it* is privileged. The user's lower authority is invisible at the point
of the check. The compiler has been made a "confused deputy". Every `setuid`
vulnerability, every SSRF, every CSRF, and most path-traversal bugs are instances
of this pattern.

With capabilities, the user hands the compiler a *capability to the output file*.
The compiler writes through the capability it was given. It cannot name
`/sys/billing` because it was never given a reference to it. The authority to
perform the action and the designation of what to act on **arrive together**.
There is nothing to confuse.

This is the core insight: **capabilities unify designation and authorization.**
An ACL system separates them, and the gap between them is where the bugs live.

### The other properties you get

| Property | How |
|---|---|
| **Least authority is natural** | You can only pass what you hold; passing a subset is the default operation. |
| **Delegation without a central authority** | A holder can copy or mint a derived capability. No "root" needs to approve. |
| **Revocation is structural** | Destroying a parent capability destroys the subtree derived from it. |
| **No ambient authority ⇒ no privilege escalation by confusion** | There is no "current user" to trick. |
| **Auditable** | The complete authority of a component is enumerable: it's the contents of its CSpace. You can *print* the security posture of a process. |
| **Composable** | A proxy that holds a capability and re-exports a restricted version is just a program. Interposition needs no kernel support. |

### The costs

- **Bootstrapping.** Someone has to hand out the initial capabilities. That's the
  root task, and it's a substantial program.
- **Naming.** "Open /etc/passwd" doesn't exist. You must hold a capability to a
  directory server and navigate. Filesystem name resolution becomes explicit.
- **Revocation is not free.** You need a derivation tree, and revoking a
  widely-copied capability is O(copies).
- **Persistence.** Capabilities live in kernel memory. Making them survive a
  reboot requires either a persistent kernel (KeyKOS/EROS did this — the whole
  system checkpoints) or a userspace re-granting protocol.
- **Mental model shift.** Everyone on your project must internalize it.

---

## 2. Representation: CSpaces

A capability must be unforgeable. Three ways to achieve that:

1. **Sparse capabilities**: a big random number, checked against a table.
   Unforgeable probabilistically. Can live in user memory (nice for
   distributed systems). Amoeba did this.
2. **Tagged memory**: hardware distinguishes capability words from data words.
   CHERI does this. Best of all worlds, needs hardware.
3. **Partitioned / segregated**: capabilities live in kernel memory; userspace
   refers to them by index. **This is what we do**, and what seL4, KeyKOS, and
   Fuchsia do.

### The CSpace as a guarded page table

A thread's capability space is a tree of **CNodes** (arrays of capability slots),
addressed by a **CPtr** — a bit string, exactly like a virtual address indexes a
page table.

```
CPtr (64 bits, but only `depth` bits used):
  [ guard | index into L1 CNode | index into L2 CNode | ... ]
```

Each CNode has:

- `radix` — log2 of the number of slots
- `guard_bits` and `guard_size` — a prefix that must match (this is the "guarded
  page table" idea from Liedtke; it lets a sparse space be shallow)

Resolution walks CNodes, consuming bits, until it reaches a non-CNode
capability or runs out of bits.

```c
struct cap {
    uint64_t obj;      /* pointer to the kernel object | type in low bits */
    uint64_t data;     /* rights | badge | guard | size, type-dependent */
};                     /* exactly 16 bytes — two per cache line pair */

_Static_assert(sizeof(struct cap) == 16, "cap must be 16 bytes");

struct cnode {
    struct kobject hdr;
    uint8_t  radix;         /* 2^radix slots */
    uint8_t  guard_size;
    uint64_t guard;
    struct cap slots[];     /* 2^radix */
};
```

Lookup:

```c
struct cap *cap_lookup(struct cnode *root, cptr_t ptr, unsigned depth) {
    struct cnode *cn = root;
    unsigned bits_left = depth;

    for (;;) {
        if (cn->guard_size > bits_left) return NULL;
        uint64_t guard = (ptr >> (bits_left - cn->guard_size))
                         & ((1UL << cn->guard_size) - 1);
        if (guard != cn->guard) return NULL;
        bits_left -= cn->guard_size;

        if (cn->radix > bits_left) return NULL;
        uint64_t idx = (ptr >> (bits_left - cn->radix))
                       & ((1UL << cn->radix) - 1);
        bits_left -= cn->radix;

        struct cap *c = &cn->slots[idx];
        if (bits_left == 0) return c;
        if (cap_type(c) != CAP_CNODE) return NULL;   /* ran out of table */
        cn = cap_object(c);
    }
}
```

**Fast path:** most processes have a single-level CSpace with `radix = 12` and
`guard_size = 52`, so lookup is one bounds check and one array index. That's what
the assembly fast path in Chapter 08 assumes. Deep CSpaces exist for processes
that manage many objects; they cost a few extra cycles.

### Rights

```c
#define RIGHT_READ    (1 << 0)   /* receive from an endpoint; read a frame */
#define RIGHT_WRITE   (1 << 1)   /* send to an endpoint; write a frame */
#define RIGHT_GRANT   (1 << 2)   /* transfer capabilities through this endpoint */
#define RIGHT_EXEC    (1 << 3)   /* map a frame executable */
#define RIGHT_MINT    (1 << 4)   /* create badged derivatives */
```

**The monotonicity rule:** any derived capability's rights must be a subset of
its parent's. Enforce it in one place:

```c
static bool rights_ok(uint32_t parent, uint32_t child) {
    return (child & ~parent) == 0;
}
```

`RIGHT_GRANT` is subtle and important: without it, a capability can be *used* but
not *passed on*. That's how you build a component that can talk to a service but
cannot introduce third parties to it — a genuine confinement primitive.

---

## 3. Derivation and revocation

### The capability derivation tree (CDT)

Every capability except the originals is derived from another. Track this:

```c
struct cap {
    uint64_t obj;
    uint64_t data;
    struct cap *cdt_parent;    /* -- these push cap to 32 bytes; see below */
    struct cap *cdt_next, *cdt_prev;
};
```

seL4 stores the CDT as a **doubly-linked list in "mdb" (mapping database) order**,
where the tree structure is recoverable from the ordering plus a depth field —
this keeps the node small. For your first implementation, an explicit tree with
parent + sibling list is clearer. Optimize later; correctness first.

Operations:

```c
/* Copy: same rights (or fewer), becomes a child of `src`. */
int cap_copy(struct cap *dst, struct cap *src, uint32_t rights);

/* Mint: copy + attach a badge. Only valid for endpoints/notifications, and
   only if the source is unbadged (you cannot re-badge a badged cap — that
   would let a client impersonate another). */
int cap_mint(struct cap *dst, struct cap *src, uint32_t rights, word_t badge);

/* Move: transfer without deriving. dst takes src's place in the CDT. */
int cap_move(struct cap *dst, struct cap *src);

/* Delete: remove one capability. If it's the last reference to the object,
   the object is destroyed. */
int cap_delete(struct cap *c);

/* Revoke: delete every capability DERIVED FROM c, but not c itself. */
int cap_revoke(struct cap *c);
```

`cap_revoke` is the security workhorse. "Take away everything I gave out" is a
single operation, and it works transitively — if A gave to B who gave to C,
revoking A's grant removes C's too.

**Revoke is potentially long-running**, which conflicts with bounded kernel
execution time (Chapter 07). The seL4 answer: make it *preemptible and
restartable* — delete some capabilities, check `need_resched`, and if preemption
is needed, return a "not finished" status so the syscall is re-executed. The
invariant "the CDT is always well-formed" must hold at every preemption point.

### Object lifetime

```c
struct kobject {
    uint8_t  type;
    uint8_t  size_bits;
    _Atomic uint32_t refcount;   /* number of capabilities pointing here */
    struct untyped *origin;      /* which Untyped this was carved from */
};
```

When the last capability is deleted, the object is *finalized*:

- **Endpoint**: all blocked threads are woken with an error. (Critical — this is
  what unblocks clients when a server dies.)
- **TCB**: the thread is removed from all queues, suspended, and its stack freed.
- **Frame**: all mappings of it are removed. This requires the frame to know its
  mappings — either a reverse mapping list, or the seL4 rule that a Frame
  capability can be mapped **once**, and you copy the capability to map it
  again (each copy tracks its own mapping). The latter is much simpler and avoids
  an unbounded structure in the kernel. Adopt it.
- **CNode**: all contained capabilities are deleted, recursively (preemptibly).
- **Untyped**: all objects derived from it are deleted, and the memory returns
  to the untyped pool.

---

## 4. Untyped memory: no kernel heap

This is seL4's most distinctive idea and it is worth adopting.

### The model

At boot, all free physical memory is described by **Untyped** capabilities given
to the root task. An Untyped is a naturally-aligned power-of-two region of
physical memory that contains no live objects.

```c
struct untyped {
    struct kobject hdr;
    paddr_t base;
    uint8_t size_bits;        /* region is 2^size_bits bytes */
    size_t  watermark;        /* bump pointer: bytes already allocated */
    bool    is_device;        /* device memory: can only become Frames */
};
```

To create a kernel object you invoke `Untyped_Retype`:

```
Untyped_Retype(untyped_cap, type, size_bits, dest_cnode, dest_offset, count)
```

The kernel:

1. Checks the untyped has `count * 2^size_bits` bytes left after alignment.
2. Bumps the watermark.
3. Zeroes the memory (mandatory — it may have held another process's data).
4. Initializes `count` objects of `type`.
5. Places capabilities to them in the destination slots, as **children** of the
   untyped capability in the CDT.

```c
long untyped_retype(struct cap *ut_cap, int type, unsigned size_bits,
                    struct cnode *dest, unsigned offset, unsigned count) {
    struct untyped *ut = cap_object(ut_cap);
    size_t objsize = obj_size(type, size_bits);
    paddr_t start = ALIGN_UP(ut->base + ut->watermark, objsize);

    if (start + count * objsize > ut->base + (1UL << ut->size_bits))
        return -ENOMEM;
    if (!slots_empty(dest, offset, count))
        return -EDELETEFIRST;

    memset(P2V(start), 0, count * objsize);

    for (unsigned i = 0; i < count; i++) {
        void *obj = P2V(start + i * objsize);
        obj_init(obj, type, size_bits, ut);
        cap_init_child(&dest->slots[offset + i], obj, type, RIGHTS_ALL, ut_cap);
    }
    ut->watermark = start + count * objsize - ut->base;
    return 0;
}
```

### Why this is worth the trouble

1. **No kernel OOM.** The kernel never allocates. A process that wants 10,000
   threads must supply the memory for 10,000 TCBs, from its own budget.
2. **Delegatable budgets.** Give a subsystem a 16 MiB Untyped and it can never
   consume more kernel memory than that. This is *hard* resource isolation, not a
   heuristic quota.
3. **Revocation destroys everything.** `cap_revoke(untyped_cap)` deletes every
   object derived from it — every thread, every page table, every endpoint. That
   is process termination, container teardown, and sandbox destruction, all as
   one primitive.
4. **Accountability is exact.** You can answer "how much kernel memory does this
   component use?" with a number, not an estimate.
5. **Verification-friendly.** No allocator to reason about, no failure paths from
   allocation, no fragmentation policy.

### Migrating to it

Chapter 05 built a buddy allocator. The migration:

- At the end of boot, walk the buddy free lists and convert every free block into
  an Untyped capability, placed in the root task's CNode.
- Change `kmem_cache_alloc(cache)` to `obj_from_untyped(ut, type)`.
- Remove `kmalloc` from the kernel entirely. Every kernel data structure must
  now be either static, in a fixed-size object, or embedded in an object the
  caller supplied.

That last constraint is the demanding one. It means, for example, that your
scheduler's run queues must be intrusive lists (linkage in the TCB), not
dynamically-sized arrays. This is a *good* discipline; it's why intrusive lists
appear everywhere in kernel code.

---

## 5. Capability transfer over IPC

A message can carry capabilities. This is what makes the system composable — it's
how a client receives a file handle, how a driver receives an IRQ handler, how a
process gets its initial environment.

Rules:

- The sending endpoint capability must have `RIGHT_GRANT`.
- The receiver specifies, in advance, where to put received capabilities: a
  destination CNode + slot range, stored in its TCB (the "receive slot"). The
  kernel does not allocate slots.
- If the receiver has no free receive slot, the capability is silently dropped
  (and the message's `ncaps` is reduced) — the receiver sees how many arrived.
  Failing the whole IPC is the alternative; dropping is what seL4 does and it
  simplifies error handling.
- Transferred capabilities are *derived* from the sender's, so revocation still
  works across the boundary.

```c
static void cap_transfer(struct tcb *from, struct tcb *to) {
    unsigned n = MIN(from->msg.ncaps, to->recv_slots_count);
    for (unsigned i = 0; i < n; i++) {
        struct cap *src = cap_lookup(from->cspace_root, from->msg.caps[i], 64);
        struct cap *dst = &to->recv_cnode->slots[to->recv_slot_base + i];
        if (!src || cap_type(dst) != CAP_NULL) { n = i; break; }
        cap_copy(dst, src, cap_rights(src));
    }
    to->msg.ncaps = n;
}
```

---

## 6. What a process's authority looks like

A typical Nyx application's CSpace after `init` sets it up:

```
slot 1:  Endpoint (badged)  → the VFS server            [W, G]
slot 2:  Endpoint (badged)  → the process manager       [W, G]
slot 3:  Notification       → its own event source      [R, W]
slot 4:  VSpace             → its own address space     [all]
slot 5:  TCB                → its own main thread       [all]
slot 6:  CNode              → its own CSpace root       [all]
slot 7:  Untyped 4 MiB      → its kernel memory budget  [all]
slot 8:  Endpoint           → its fault handler         [W]
slots 16-31: Frames         → its initial mappings
```

That's the *complete* authority of the process. It can do exactly these things
and nothing else. There is no `/`, no syscall that opens things by name, no
`root` to become. To read a file it must ask the VFS server through slot 1, and
the VFS server knows exactly who it is via the badge.

**Print this.** A debug command that dumps a process's CSpace with human-readable
names is the single best security tool you can build. Diff it before and after a
change and you can *see* the authority you granted.

---

## 7. Security properties you can now state (and later prove)

With this architecture, you can make precise claims:

- **Integrity:** a component can only modify state it holds a `WRITE` capability
  to. (seL4 proves this.)
- **Authority confinement:** a component's authority cannot grow except by
  receiving capabilities through an endpoint it holds. Therefore, if you can
  enumerate a component's endpoints and the capabilities that flow through them,
  you have a complete authority bound.
- **Confinement (the strong form):** a component given only capabilities with
  `RIGHT_GRANT` cleared cannot introduce its peers to each other, and cannot
  create covert channels except through timing.
- **Non-interference (with care):** with no shared capabilities and partitioned
  scheduling, two components cannot influence each other at all. seL4 proves this
  for a specific configuration; achieving it requires eliminating timing channels,
  which is genuinely hard (cache partitioning, deterministic scheduling).

Write these as explicit claims in `docs/security.md`, along with your **threat
model**: what the attacker controls, what you're defending, what you concede.
Most projects skip this and then argue about whether something is a bug.

### Covert and side channels (be honest about them)

Capabilities control *explicit* information flow. They do nothing about:

- **Timing channels**: shared caches, shared TLB, memory bus contention,
  hyperthreading, DVFS. Spectre-class attacks make these practical.
- **Resource exhaustion channels**: allocation success/failure as a signal.
  (Untyped helps here — allocation is partitioned.)
- **Scheduling channels**: observing whether you were preempted.

Mitigations are expensive: cache colouring/partitioning (seL4 does this for its
verified configurations), disabling SMT, deterministic scheduling with padded
time slices. Know they exist; state which ones you address.

---

## 8. Comparison to other modern capability systems

| System | Capability form | Notable |
|---|---|---|
| **seL4** | CNode index, kernel-stored | Verified. Untyped memory. The reference design. |
| **Fuchsia / Zircon** | Integer handle in a per-process table | Pragmatic; not fully capability-pure (some ambient authority via the root job). Shows the model works at product scale. |
| **KeyKOS / EROS / Coyotos** | Kernel-stored, orthogonally persistent | The whole system checkpoints; capabilities survive reboot. Deeply interesting, largely unexplored territory today. |
| **Capsicum** (FreeBSD, Linux patches) | File descriptors in "capability mode" | Retrofits capabilities onto UNIX. Shows what's achievable incrementally. |
| **CHERI** | Hardware-tagged pointers with bounds+permissions | Capabilities at *memory* granularity, not object granularity. Composes beautifully with a capability OS — CheriBSD, and there's real research space in a CHERI microkernel. |
| **WebAssembly / WASI** | Imported host functions | Capability-ish by construction: a module can only call what's imported. |
| **Object-capability languages** (E, Pony, Monte) | Object references | Where the theory comes from. Worth reading Miller's thesis. |

---

## 9. Verification

```c
KTEST(cap_lookup_single_level)   { }
KTEST(cap_lookup_two_level)      { }
KTEST(cap_lookup_bad_guard_fails){ }
KTEST(cap_copy_cannot_add_rights) {
    struct cap *src = mk_endpoint_cap(RIGHT_WRITE);
    KASSERT(cap_copy(&dst, src, RIGHT_WRITE|RIGHT_GRANT) == -EPERM);
}
KTEST(cap_revoke_removes_grandchildren) {
    /* a → b → c ; revoke(a) ⇒ b and c are gone, a remains */
}
KTEST(cap_delete_last_ref_destroys_object) {
    size_t before = pmm_free_bytes();
    /* retype an untyped into a TCB, delete the cap, check the untyped
       reports the space as reclaimable */
}
KTEST(untyped_retype_zeroes_memory) {
    /* Write a pattern, delete, revoke, retype, check zeros.
       THIS TEST PREVENTS AN INFORMATION LEAK. */
}
KTEST(untyped_cannot_overcommit) {
    /* retype until failure; check the failure is clean and no object
       was half-created */
}
KTEST(endpoint_destroy_wakes_blocked_threads) { }
KTEST(cap_transfer_respects_grant_right) { }
```

**Fuzz the CSpace.** `cap_lookup` takes an arbitrary 64-bit value from userspace
and walks kernel data structures. Fuzz it with random CPtrs against randomly
constructed CNode trees, on the *host*, under ASan. This is one of the highest
value-per-hour testing activities in the whole project.

---

## 10. Exercises

1. Work through the confused deputy example concretely in both models. Write the
   code for the ACL version that has the bug and the capability version that
   can't.
2. Implement `cap_revoke` preemptibly: it must be interruptible mid-revocation
   with a well-formed CDT, and resumable. What state do you need to save, and
   where does it live (remember: no kernel heap)?
3. A frame capability can be mapped once. Design the API for mapping the same
   physical frame into two address spaces. How many capabilities are involved?
   How does unmapping work?
4. Design a *sandbox launcher*: a program that takes a binary and a set of
   capabilities, creates a CSpace containing only those, and runs it. How many
   lines is it? (In a capability system, remarkably few. That's the point.)
5. Enumerate the covert channels in your design. Pick one and measure its
   bandwidth in bits/second. Then implement a mitigation and re-measure.
6. Read the seL4 API manual's chapter on CNodes and identify three things it does
   that this chapter simplified away. Were the simplifications safe?

---

Next: [10 — Crossing the ring: syscalls, userspace, and the ELF loader](10-userspace-and-syscalls.md)
