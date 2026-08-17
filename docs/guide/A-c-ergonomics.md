# Appendix A — C ergonomics: strings, slices, results, and internal style

> Goal: fix the parts of C that produce bugs, without giving up the properties
> that made you choose C. Every pattern here is zero-cost or near-zero-cost, and
> every one of them turns a class of runtime bug into either a compile error or a
> bounds check you can point at.
>
> This appendix is the source for `docs/style.md`. Write it down, enforce it in
> review, and check the mechanical parts in CI.

---

## 1. The argument: this is a security decision, not a taste decision

C's NUL-terminated string is not merely awkward. In a kernel it is a specific
hazard:

**A NUL scan over memory you do not control is an unbounded loop.** If any kernel
path calls `strlen` on a buffer whose contents came from userspace, you have:

- a denial of service (the scan runs until it finds a zero byte, possibly after
  crossing into unmapped memory),
- a fault in kernel context on a user-controlled address,
- and a length that no longer relates to the allocation you thought you had.

Every fix for this — `strnlen`, `strlcpy`, `snprintf` return-value discipline —
is the same fix: *carry the length separately*. So carry the length separately
from the start and delete the entire class.

Related failure modes that length-prefixing removes outright:

| Bug class | Why NUL-termination causes it |
|---|---|
| Off-by-one on the terminator | The buffer must be `n+1`; someone will write `n` |
| Truncation silently succeeding | `strncpy` doesn't terminate; `strlcpy` reports but nobody checks |
| Embedded NUL smuggling | `"safe.txt\0../../etc/shadow"` — the checker and the user disagree about where the string ends. This is a *real* filesystem exploit pattern |
| O(n) length queries | Every `strlen` in a loop is accidentally quadratic |
| Substring requires a copy | You cannot point *into* a string without mutating or allocating |

That last one is the ergonomic complaint, and it is the one that causes bad path
handling code: because you cannot cheaply name a slice of a path, people copy,
and copying needs a buffer, and a buffer needs a size, and now you are writing
the bug.

### 1.1 The scope in Nyx is small, which is why you can be strict

Before designing this, notice how little of it lives in the kernel:

| Where | Strings? |
|---|---|
| Kernel objects, IPC, capabilities | **None.** Capabilities are integers; badges are integers; message words are integers. |
| Kernel debug/diagnostics | `char name[16]` on TCBs, `printf`, panic output |
| VFS server | Paths — this is where path parsing lives |
| Object namespace (Ch. 16) | Names, but resolved by a userspace server |
| Device/driver metadata | Property strings, ACPI IDs, PCI class names — userspace |

**The kernel does not parse strings from userspace.** That is a design rule worth
writing into `docs/abi.md`: no syscall takes a string. `TCB_SetName` is the one
grudging exception, and it takes a fixed-size array.

So this appendix is mostly about `libnyx`, the IDL, and the servers. That is
good: you can be as opinionated as you like without touching the IPC fast path.

---

## 2. The string view

```c
/* include/nyx/str.h */

typedef struct {
    const char *p;   /* NOT required to be NUL-terminated */
    size_t      n;
} str;

/* Construct from a literal. The "" concatenation forces a compile error if
   someone passes a char* instead of a literal — sizeof would be wrong. */
#define S(lit)  ((str){ "" lit, sizeof(lit) - 1 })

#define STR_NULL  ((str){ NULL, 0 })

/* Escape hatch at a legacy boundary. Note the bound: never unbounded. */
static inline str str_from_cstr_n(const char *s, size_t max) {
    size_t i = 0;
    while (i < max && s[i]) i++;
    return (str){ s, i };
}
```

Two words. Under the SysV AMD64 ABI a two-word struct is passed **in two
registers**, so `f(str s)` costs exactly what `f(const char *p, size_t n)` costs.
Verify this once with `-S` and then stop worrying about it.

### 2.1 The operations you actually need

The whole useful API is about twenty functions, all of which are pointer
arithmetic:

```c
static inline bool str_eq(str a, str b) {
    return a.n == b.n && (a.n == 0 || memcmp(a.p, b.p, a.n) == 0);
}

static inline str str_sub(str s, size_t off, size_t len) {
    if (off > s.n) return STR_NULL;
    if (len > s.n - off) len = s.n - off;
    return (str){ s.p + off, len };
}

static inline bool str_prefix(str s, str pfx) {
    return s.n >= pfx.n && memcmp(s.p, pfx.p, pfx.n) == 0;
}

/* Cut at the first occurrence of c. Returns true if found.
   *before and *after are views into s — no allocation, no copy. */
static inline bool str_cut(str s, char c, str *before, str *after) {
    for (size_t i = 0; i < s.n; i++) {
        if (s.p[i] == c) {
            *before = (str){ s.p, i };
            *after  = (str){ s.p + i + 1, s.n - i - 1 };
            return true;
        }
    }
    *before = s; *after = STR_NULL;
    return false;
}

static inline str str_trim(str s, char c) {
    while (s.n && s.p[0] == c)        { s.p++; s.n--; }
    while (s.n && s.p[s.n - 1] == c)  { s.n--; }
    return s;
}
```

Now look at what path resolution becomes:

```c
/* Walk "/usr/local/bin/nyxsh" one component at a time. Zero allocations,
   zero copies, and every loop is bounded by rest.n. */
str rest = path, comp;
rest = str_trim_left(rest, '/');
while (rest.n) {
    str_cut(rest, '/', &comp, &rest);
    if (str_eq(comp, S(".")))  continue;
    if (str_eq(comp, S(".."))) { node = node->parent; continue; }
    node = lookup(node, comp);
    if (!node) return ERR_NOENT;
    rest = str_trim_left(rest, '/');
}
```

Compare that to the same loop with `char *`, `strchr`, a scratch buffer, and a
`PATH_MAX`. The `str` version has no buffer to overflow because there is no
buffer.

### 2.2 Printing

Make `printf` understand it. With GCC/Clang you can't add a conversion specifier
safely, so use the precision trick everywhere, and wrap it:

```c
#define STR_FMT       "%.*s"
#define STR_ARG(s)    (int)(s).n, (s).p

klog("open %"PRIu64" path=" STR_FMT "\n", handle, STR_ARG(path));
```

If you write your own `vsnprintf` (Chapter 03 says you should), just add `%S`
taking a `str` and be done. Then add `__attribute__((format(printf, ...)))`-style
checking in a CI grep, or accept that `%S` is unchecked and keep it rare.

### 2.3 When you must produce a NUL-terminated string

Make it explicit, allocating, and rare:

```c
char *str_dup_c(arena *a, str s);   /* only at a legacy boundary */
```

The rule: `str_dup_c` may appear only where you are calling into code you did not
write. If it appears anywhere else, that's a review comment. Grep for it
periodically — the count should stay near zero.

### 2.4 Mutable string building

Views are read-only. For building, use an explicit builder over caller-provided
storage — no hidden allocation, no truncation surprises:

```c
typedef struct { char *p; size_t n, cap; bool overflow; } strbuf;

static inline strbuf sb_init(char *buf, size_t cap) {
    return (strbuf){ buf, 0, cap, false };
}
static inline void sb_put(strbuf *b, str s) {
    if (b->n + s.n > b->cap) { b->overflow = true; return; }
    memcpy(b->p + b->n, s.p, s.n);
    b->n += s.n;
}
static inline str sb_str(const strbuf *b) { return (str){ b->p, b->n }; }
```

`overflow` is a sticky flag: you build the whole thing, then check *once* at the
end. This is much harder to get wrong than checking a return value on every
append (which is why nobody does).

---

## 3. Slices generalize the idea

The same shape works for every buffer in the system:

```c
typedef struct { uint8_t *p; size_t n; } bytes;
typedef struct { const uint8_t *p; size_t n; } cbytes;

#define SPAN(T) struct { T *p; size_t n; }

/* One place where bounds are checked. */
#define AT(s, i)  (*(ASSERT((size_t)(i) < (s).n), &(s).p[i]))
```

Two consequences worth stating explicitly:

1. **Array parameters stop decaying.** `void f(SPAN(struct cap) caps)` cannot
   lose its length the way `void f(struct cap *caps)` can.
2. **You get a natural place to put the untrusted-input check.** A
   `bytes` obtained from a shared ring is validated once, at the edge, and every
   downstream function receives an already-bounded slice.

---

## 4. Error handling: results, not errno

`errno` is thread-local ambient state — the same anti-pattern as ambient
authority, and it composes just as badly. Use explicit returns.

The cheap version, which is enough for most of the kernel:

```c
typedef enum {
    OK = 0, ERR_NOMEM, ERR_INVAL, ERR_NOENT, ERR_PERM, ERR_EXISTS,
    ERR_AGAIN, ERR_FAULT, ERR_RANGE, ERR_TIMEOUT, ERR_DEAD, ERR_BUSY,
} err_t;

#define MUST_USE __attribute__((warn_unused_result))

MUST_USE err_t vspace_map(struct vspace *, uint64_t va, uint64_t pa, uint64_t f);
```

`warn_unused_result` plus `-Werror` is the entire enforcement mechanism, and it
is remarkably effective. Put `MUST_USE` on **every** fallible function; the day
you forget one is the day something silently fails.

For functions returning a value *and* a status, use a small tagged struct rather
than an out-parameter:

```c
#define RESULT(T)  struct { err_t e; T v; }

typedef RESULT(struct cap *) cap_result;

static inline cap_result cap_ok(struct cap *c) { return (cap_result){ OK, c }; }
static inline cap_result cap_err(err_t e)      { return (cap_result){ e, NULL }; }
```

Two words again — returned in RAX:RDX, free. This beats out-parameters because
the caller physically cannot use `v` without having the struct that also contains
`e` in front of them.

### 4.1 The `TRY` macro

```c
#define TRY(expr) do { err_t _e = (expr); if (_e != OK) return _e; } while (0)

MUST_USE err_t setup_thread(struct tcb *t, str name) {
    TRY(cspace_init(&t->cspace));
    TRY(vspace_init(&t->vspace));
    TRY(stack_alloc(t));
    tcb_set_name(t, name);
    return OK;
}
```

Use this only where there's nothing to unwind. Where there *is* cleanup, use §4.2
rather than making `TRY` clever.

### 4.2 Cleanup: `__attribute__((cleanup))` gives you `defer`

```c
#define DEFER_FREE  __attribute__((cleanup(cleanup_free)))
static inline void cleanup_free(void **p) { if (*p) kfree(*p); }

#define WITH_LOCK(l) \
    for (int _i = (spin_lock(l), 0); !_i; _i = (spin_unlock(l), 1))

void f(void) {
    void *buf DEFER_FREE = kmalloc(4096);
    if (!buf) return;
    WITH_LOCK(&rq->lock) {
        /* ... early return here is safe: unlock and free both run ... */
    }
}
```

This is a GCC/Clang extension, not standard C, and it is worth the dependency:
it eliminates the goto-cleanup ladder, which is where a large fraction of real
kernel CVEs live (double free, free-on-uninitialized, missed unlock on an error
path).

Two rules: (1) the cleanup function must tolerate the zero/NULL value, because it
runs even on the early-return-before-initialization path — so **always
initialize at declaration**; (2) don't nest `WITH_LOCK` without checking your
lock ranking (Chapter 12 §4).

### 4.3 The error model at the IPC boundary

Errors crossing IPC are a different thing from errors inside a server. Encode
them in the message label, not in a data word:

```
label = (interface_id << 20) | (method << 8) | status
```

Then a client stub checks one field, and a failed call is not distinguishable
from a successful one by *shape* — which matters, because a caller that must
parse the reply to discover it failed will eventually parse garbage.

Also: distinguish **operation failed** (`ERR_NOENT` — the server is fine) from
**the server is gone** (`ERR_DEAD` — the endpoint was revoked; see Chapter 09
§3). Generated stubs should surface these as different things, because the
recovery is different: retry versus rebind.

---

## 5. Struct arguments and ABI evolution

The single best idea in the Win32 API is the versioned struct: a leading `size`
field that lets the callee know which version of the struct it received.

```c
struct thread_attr {
    uint32_t size;          /* = sizeof(struct thread_attr) */
    uint32_t flags;
    uint8_t  priority;
    uint8_t  affinity_hint;
    uint16_t _pad;
    uint64_t stack_size;
    /* new fields appended here, and ONLY here */
};

err_t thread_create(struct thread_attr *a, ...) {
    if (a->size < offsetof(struct thread_attr, stack_size)) return ERR_INVAL;
    uint64_t stack = (a->size >= sizeof *a) ? a->stack_size : DEFAULT_STACK;
    ...
}
```

Combine with designated initializers so callers name what they set:

```c
thread_create(&(struct thread_attr){
    .size = sizeof(struct thread_attr),
    .priority = 128,
}, ...);
```

Three rules that make this work:

1. **Zero must be a valid default for every field.** If it isn't, you can't add
   the field later. This is a design constraint on the *semantics*, not just the
   layout — pick "0 = inherit" or "0 = system default" deliberately.
2. **Append only.** Never reorder, never repurpose, never shrink.
3. **Explicit padding, and `_Static_assert(sizeof(...) == N)`.** Compilers pad
   differently than you expect; assert the layout so a change is loud.

For anything crossing the *stable* ABI boundary (`include/abi/`), add
`_Static_assert` for both the size and the offset of every field, and run a CI
check that the assertion list only ever grows.

---

## 6. Handles and typed integers

Chapter 09 makes capability pointers plain integers. Wrap them anyway:

```c
typedef struct { uint64_t v; } cptr_t;      /* capability pointer */
typedef struct { uint32_t v; } tid_t;
typedef struct { uint64_t v; } paddr_t;     /* physical address */
typedef struct { uint64_t v; } vaddr_t;     /* virtual address */
```

A one-field struct is passed in a register exactly like the integer, but it is
**not implicitly convertible** to any other one-field struct. This catches the
single most common bug in this codebase's problem domain: passing a physical
address where a virtual one was expected. `P2V`/`V2P` become the only functions
that can convert between them, which is exactly the property you want.

The cost is `.v` noise at use sites. Worth it. If you find it intolerable, apply
it selectively — but apply it to `paddr_t`/`vaddr_t` at minimum.

---

## 7. Generate the boundary code

The highest-leverage ergonomic decision in the whole system is Chapter 10 §7's
IDL. Everything above becomes automatic if humans never hand-write marshalling:

```
interface vfs {
    method open(str path, uint32 flags) -> (cap file, uint64 size);
}
```

The generator emits:

- a client stub taking `str` and packing `(offset, len)` into message words with
  the payload in the IPC buffer,
- a server dispatcher that **validates the length against the received buffer
  size once**, then hands the handler an already-bounded `str`,
- a `_Static_assert` on every message layout,
- the interface/method/status label encoding from §4.3,
- and a "server restarted" path that regenerates the client's endpoint binding.

Every one of those is a place where a hand-written server would eventually get it
wrong. Two rules follow: **no hand-written marshalling anywhere**, and
**validation happens in generated code only**, so there is exactly one copy of it
to audit.

---

## 8. What to leave alone

Some ergonomic improvements aren't worth it here:

| Tempting | Why not |
|---|---|
| A generic container library via macros | Type-unsafe, unreadable in a debugger, and the intrusive list (Appendix C) covers 90% of uses |
| Exceptions via `setjmp`/`longjmp` | Skips cleanup, breaks lock discipline, unverifiable |
| A garbage collector or refcount-everything | Non-deterministic latency; conflicts with Chapter 14's real-time goals |
| Heavy `_Generic` overloading | Great demo, terrible error messages, hard to grep |
| C++ or "C with classes" | Now you're auditing the vtable layout and exception ABI too |
| Reimplementing all of libc | You need ~15 functions. Write them, test them on the host, move on. |

The test for any addition: **does it turn a runtime bug into a compile error, or
a runtime bug into a bounded check?** If it only makes code shorter, skip it.

---

## 9. Style rules for `docs/style.md`

Mechanical, checkable, and worth enforcing:

1. Every fallible function is `MUST_USE`.
2. No `strlen`, `strcpy`, `strcat`, `sprintf`, `strncpy`, `alloca` anywhere. CI
   greps for them. `strlcpy` only inside `str_dup_c`.
3. No string crosses a syscall boundary. CI greps `include/abi/` for `char *`.
4. All variables initialized at declaration (required by `cleanup`, and it kills
   the uninitialized-read class).
5. `paddr_t`/`vaddr_t` are never `uint64_t`.
6. Every struct in `include/abi/` has `_Static_assert` on size and offsets.
7. Every lock acquisition has a rank (Chapter 12 §4); the rank order lives in
   `docs/locking.md`.
8. Functions that can block are named or annotated so; a function that may block
   is never called with a spinlock held. Consider `__attribute__((annotate))` or
   a naming convention (`*_blocking`).
9. `-Werror -Wall -Wextra -Wvla -Wshadow -Wconversion` (the last one hurts for a
   week and then stops).
10. Every `TODO` has a name and a date, or it is deleted.

### 9.1 Compiler flags that are ergonomics in disguise

Beyond Chapter 02's list:

```
-fanalyzer                    # GCC: finds double-free, leak, NULL-deref paths
-Wnull-dereference -Wduplicated-cond -Wduplicated-branches
-Wlogical-op -Wcast-align -Wswitch-enum
-fstrict-flex-arrays=3
-ftrivial-auto-var-init=zero  # kills the uninitialized-stack info leak class
```

`-ftrivial-auto-var-init=zero` deserves a note: it costs a little code size and
essentially no time (the compiler removes stores it can prove dead), and it
eliminates the "kernel stack garbage leaked to userspace" bug class that has
produced a steady stream of CVEs. Turn it on and never think about it again.

---

## 10. Exercises

1. Implement `str.h` and port your VFS path resolver to it. Count the lines
   removed and the buffers eliminated.
2. Write a host-side fuzzer for your path resolver using `str` inputs, run it
   under ASan. Then write the equivalent with `char *` and fuzz that. Compare
   what each finds.
3. Verify that `str` is register-passed: compile `size_t f(str s){return s.n;}`
   with `-S -O2` and read the assembly. Do the same for `RESULT(void*)`.
4. Add `%S` to your `vsnprintf` and convert all `STR_FMT`/`STR_ARG` sites.
5. Take one existing function with a goto-cleanup ladder and rewrite it with
   `cleanup` attributes. Diff them and decide which you'd rather review.
6. **Argue the other side:** find a place where NUL-termination is genuinely
   better (hint: interfacing with firmware tables, or a case where you must not
   store a length). Write down the boundary rule for it.

---

Next: [Appendix B — Memory ownership and allocation patterns](B-memory-patterns.md)
