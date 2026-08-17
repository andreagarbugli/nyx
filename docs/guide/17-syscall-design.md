# 17 — System call and API design

> Goal: treat the kernel interface as what it is — a contract you will be living
> with for the life of the project — and design it deliberately. We extract the
> good ideas from POSIX and Win32, add what the last two decades learned, and
> arrive at the final Nyx ABI, together with the compatibility policy that keeps
> it stable.

---

## 1. Theory: what makes an interface good

A system call interface is judged on eight axes. They conflict, so the design is
a set of chosen trade-offs, not an optimum.

| Criterion | Question |
|---|---|
| **Minimality** | How many concepts must a programmer hold to use it? |
| **Orthogonality** | Can features be combined freely, or are there special cases? |
| **Composability** | Can a mechanism be applied to things its designer didn't foresee? |
| **Extensibility** | Can you add a capability in ten years without breaking anyone? |
| **Security** | Can a caller do only what it should, and is that statement checkable? |
| **Performance** | Is the common case cheap, and can it be batched? |
| **Diagnosability** | When it fails, do you learn why? |
| **Stability** | Can you promise not to break it? |

Two observations before the case studies.

**The interface outlives everything else.** You will rewrite your scheduler,
your allocator, and probably your IPC implementation. The ABI is what you cannot
rewrite, because other people's code depends on it. Linux's `stat` has four
versions and all still work; Windows still honours 1993 semantics. Design
accordingly: **the ABI deserves more design time per line than any other part of
the system.**

**Every interface encodes a security model.** `open(path, flags)` presumes
ambient authority — there is nowhere in the signature to put "and here is my
right to do this", so it must be implicit. You cannot fix that with better
implementation. Interfaces are where security models become irreversible.

---

## 2. POSIX: what to keep and what to learn from

### 2.1 The genuinely good

- **The file descriptor.** A small integer naming a kernel object, refcounted,
  inherited across `exec`, transferable over UNIX sockets. This *is* an
  object-capability, and Capsicum's success (`openat` + capability mode) is the
  proof: remove paths, keep fds, and you get a capability system out of UNIX.
- **`dup2` before `exec`.** The parent constructs the child's initial handle
  table. This is precisely Nyx's "initial CSpace is the namespace" (Chapter 16),
  invented in 1975.
- **`SCM_RIGHTS`.** Real capability passing over a channel.
- **`mmap`.** Decoupling memory from files, and giving userspace control of its
  address space, was ahead of its time.
- **Small original core.** Version 7 UNIX had about 50 syscalls. That was
  liberating; the current ~350 are not.
- **`pipe` + `fork` + `exec`.** Three primitives whose *composition* produced the
  shell. This is the composability lesson: primitives that compose beat features.

### 2.2 The instructive failures

**Path-based ambient authority.** `open("/etc/passwd")` succeeds based on who you
are, not on what you were given. Consequences: TOCTOU races between `access` and
`open` (the canonical confused deputy), path traversal, symlink attacks, and the
inability to sandbox without a whole-namespace mechanism (`chroot`, mount
namespaces) because there is no smaller unit. **Nyx's answer: no operation takes
a path. Ever.** (Chapter 16 §4.3.)

**`fork`.** Elegant in 1975 (its entire semantics is "copy"), disastrous now.
Interacts catastrophically with threads (what happens to locks held by threads
that don't exist in the child?), with signal handlers, with file offsets, and with
memory overcommit. The academic community has said so plainly ("A `fork()` in the
road", HotOS 2019). Copy-on-write made it *survivable*, not good. **Nyx's answer:
`posix_spawn`-style creation only — build the child's address space, CSpace, and
handles explicitly, then start it. `fork` is emulated in the POSIX personality if
at all.**

**Signals.** Asynchronous, unreliable (non-realtime signals coalesce), with a
tiny async-signal-safe function list, global per-process disposition, and
interaction with every blocking call (`EINTR`). Nobody would design this today.
**Nyx's answer: no signals. Asynchronous events are Notifications delivered to a
thread that chose to wait for them. Faults are IPC to a fault endpoint.** The
POSIX personality synthesizes signals in userspace.

**`errno`.** A thread-local global, set on failure, sometimes set on success,
overwritten by any intervening call including your logging. Error space is a flat
enum shared across every subsystem, so `EINVAL` from `ioctl` tells you nothing.
**Nyx's answer: errors are return values, typed per interface.**

**The readiness model (`select`/`poll`/`epoll`).** Tells you an operation *would
not block*, then you perform it — two syscalls per event, inherently racy under
concurrency, and fundamentally inapplicable to storage (a disk read is never
"ready", it just takes time). This is why Linux needed `aio`, then `io_uring`.
**Nyx's answer: completion, not readiness (Chapter 15).**

**`ioctl`.** Covered in Chapter 16. The untyped escape hatch.

**Blocking by default with no cancellation.** Most POSIX calls block, few take
timeouts, and cancellation is `pthread_cancel`, which almost nobody can use
correctly.

**Pointer arguments everywhere.** Every syscall taking a `void *` is a place the
kernel must validate a user pointer, and a place `copy_from_user` bugs live.

### 2.3 The summary judgement

POSIX's *mechanisms* (handles, inheritance, passing, composition) are excellent.
Its *naming* (paths), *asynchrony* (none), *error model* (errno), and *process
model* (fork/signals) are the parts that have not survived contact with the last
thirty years. Take the first list; replace the second.

---

## 3. Win32/NT: the underrated half

The NT kernel interface deserves more study than it gets from the UNIX world,
because it solved several problems POSIX did not.

### 3.1 The genuinely good

- **A uniform typed `HANDLE`.** Files, processes, threads, events, mutexes,
  timers, sections, and completion ports are all handles on typed kernel objects,
  with uniform duplication (`DuplicateHandle`, including *across processes*),
  uniform lifetime, and uniform security. This is a real object model, and it is
  closer to a capability system than POSIX's fds — NT even has explicit handle
  *access rights* granted at open time, which is a rights mask on the reference.
- **Wait on anything.** `WaitForMultipleObjects` waits on *any* waitable object:
  a process exiting, a thread finishing, a timer, an event, an I/O completion.
  POSIX has `select` for fds, `waitpid` for children, `sigwait` for signals, and
  condition variables for everything else — four mechanisms that don't compose.
  **The unified wait is one of the best ideas in systems API design** and Nyx
  should have it. (It does: bound Notifications, Chapter 08 §5.)
- **Completion ports.** Both the completion *model* and the *concurrency* model:
  a bounded thread pool dequeues completions, and the kernel keeps exactly N
  threads runnable, avoiding both thread-per-connection and single-reactor
  extremes. io_uring is IOCP with shared-memory rings.
- **Extensible parameter structures.** The `cbSize` / version-field convention
  lets a structure grow without a new function. Done properly (see §5.6) this is
  the best-known solution to ABI evolution.
- **Separate Create and Open**, with explicit disposition and attributes, rather
  than overloading flags into one call.
- **`NTSTATUS`.** A structured error code with severity, facility, and code
  fields. Far better than a flat errno space.
- **Asynchronous from the start.** `OVERLAPPED` was in NT 3.1 in 1993. POSIX is
  still catching up.

### 3.2 The failures

- **Enormous surface.** Win32 has thousands of functions with inconsistent
  naming, `Ex`/`Ex2` suffixes, and multiple ways to do everything.
- **A global object namespace with ambient ACLs** — same problem as paths.
- **The Registry**: a second namespace, with different semantics, for
  configuration. Two naming systems is worse than one.
- **Inconsistent error reporting**: `GetLastError`, `HRESULT`, `NTSTATUS`, and
  return-value-is-the-error all coexist.
- **Out-parameters everywhere**, making the calling convention noisy and making
  every call a potential pointer-validation bug.
- **Cancellation is under-specified.** `CancelIoEx` races; the ownership rules
  for the buffer during cancellation are famously subtle.

---

## 4. What came after

| System | The idea worth stealing |
|---|---|
| **seL4** | ~13 syscalls, and **dispatch on the object type rather than a syscall number**. Adding an object type adds zero syscalls. This is the single most important extensibility idea in the chapter. |
| **Fuchsia/Zircon** | Every syscall takes handles; **no ambient authority at all**; interfaces above the kernel are FIDL, so the kernel surface stays small while the system surface grows. Also: syscalls are versioned and the compatibility policy is written down. |
| **io_uring** | **Opcode-based batching**: the operation is data, not a call site. Adding an operation adds an opcode, not a syscall. Plus registration of pre-validated resources. |
| **Capsicum** | You can remove ambient authority incrementally, and `openat`-style *relative* operations are the general form ("do X relative to this capability"). |
| **WASI** | Preopened capabilities as the only root of authority; a proof that a capability-only POSIX-shaped API is usable by real software. |
| **Plan 9 / 9P** | Thirteen messages for an entire distributed system, and the same protocol locally and remotely. Minimality applied to a *protocol* rather than to a syscall table. |
| **Mach** | Ports as capabilities, done in 1986 — and the lesson that a beautiful IPC model with a slow implementation loses. |
| **Binder** | Refcounted object references across processes with generated typed stubs, in production on three billion devices. |

The convergence is unmistakable: **handles/capabilities, typed interfaces above a
minimal kernel, batched asynchronous operations, no ambient authority.** That is
the design Nyx has been building toward for sixteen chapters.

---

## 5. The Nyx ABI: nine rules and the interface

### Rule 1 — Every operation is an invocation on a capability

There is no `read(fd)` where `fd` is looked up in a per-process table by an
integer chosen by the kernel. There is `cap_invoke(cptr, method, args)`, where
the dispatch is `(object type, method number)`.

```c
/* The entire kernel interface, in one function. */
long nyx_invoke(cptr_t target, uint64_t msginfo, uint64_t a0,
                uint64_t a1, uint64_t a2, uint64_t a3);
```

**Why this matters more than anything else in the chapter:** adding a new object
type — `IoQueue`, `SchedContext`, `IommuCtx`, a hypervisor `VCPU` — adds *zero*
syscalls. Linux has ~350 syscalls largely because each new subsystem needed its
own entry points. seL4 has 13 and has added major features without adding any.
The syscall table stops being an extensibility bottleneck.

### Rule 2 — No ambient authority

No operation takes a path, a name, a PID, a global ID, or anything else that
could be forged or guessed. If an operation needs to designate something, it
takes a capability. Corollary: **there is no `getpid`-shaped operation whose
result confers anything.** (`getpid` for logging is fine; `kill(pid)` is not.)

### Rule 3 — No pointer arguments in the core set

Arguments are registers; bulk data is in a pre-registered `IoRegion` or the IPC
buffer, both of which were validated at registration. The kernel should never
dereference a user pointer on a hot path. Where it must (the IPC buffer), the
region is validated once at bind time and the access is bounded by construction.

This is a security property (`copy_from_user` bugs are a whole CVE genus) *and* a
performance property (no SMAP toggling, no page-fault handling in the middle of a
syscall) *and* a verification property (a kernel that doesn't dereference user
pointers has a dramatically simpler proof obligation).

### Rule 4 — Every operation is asynchronous-capable; synchronous is the degenerate case

Define operations in terms of *submit* and *complete*. The synchronous form is
"submit one, wait for its completion", provided as a library convenience. This is
the opposite of POSIX (synchronous primitive, asynchrony bolted on) and it is the
right way round, because you can build sync from async cheaply and async from sync
not at all.

### Rule 5 — Cancellation is designed first, not last

Both io_uring and Win32 got this wrong, so state it precisely and test it:

> A cancellation request is advisory. Every submitted operation produces
> **exactly one** completion, either its natural result or `-ECANCELED`. Resources
> referenced by the operation remain owned by the callee until that completion is
> observed. Cancelling an unknown or already-completed operation is not an error.

Three sentences. They eliminate an entire class of use-after-free.

### Rule 6 — Errors are typed values, not a global

Return values are `long`: `>= 0` is success, `< 0` is an error. Error spaces are
**per interface**, so `Block` errors and `Stream` errors are different types and a
tool can render them meaningfully. A small set of universal errors
(`-ENOSYS`, `-EINVAL`, `-ENOMEM`, `-ECANCELED`, `-EPERM`) is shared. No `errno`,
no thread-local state, no "check the return then check the global".

Give every error site a **distinct code**, even when the caller cannot
distinguish them. Diagnosability is worth more than tidiness: "invalid argument"
appearing at forty places in a server is a debugging nightmare, and the callers
who only check `< 0` are unaffected.

### Rule 7 — Wait on anything, with one primitive

Steal Win32's best idea. `nyx_wait(notification)` where a Notification can be
bound to endpoints, timers, IRQs, completion queues, thread exits, and fault
channels. There is no `select`, no `epoll`, no `waitpid`, no `sigwait` — one
mechanism, because they are all "tell me when something happened" and the kernel
should not have four answers.

### Rule 8 — Extensible structures, done properly

Anything that cannot fit in registers is a versioned structure in shared memory:

```c
struct nyx_args {
    uint32_t size;      /* sizeof the structure the caller compiled against  */
    uint32_t version;   /* semantic version of the layout                    */
    /* ... fields; new fields only ever appended ... */
};
```

Rules, learned from `cbSize`'s failure modes:
- **Zero always means "default"** for every field, so a shorter (older) structure
  is trivially valid — the callee zero-extends.
- **Fields are only ever appended**, never reordered, resized, or repurposed.
- **The callee validates `size` against known versions** and rejects unknown
  larger sizes only if the tail is non-zero (allowing forward compatibility where
  the new fields don't matter).
- **Explicit padding, `_Static_assert`ed offsets, fixed-width types.** No
  `long`, no `enum` in an ABI struct, no bitfields.

### Rule 9 — The interface is introspectable and versioned

Every interface is defined in the IDL, every object can `Describe` itself, and
the compatibility policy is a written document. (Chapter 16 §4.2, §6.)

---

## 6. The final syscall table

```c
/* include/abi/syscall.h — this list should essentially never grow. */
enum nyx_syscall {
    /* ---- IPC / invocation: the whole system, really ------------------ */
    SYS_SEND        =  1,   /* send, block until received                 */
    SYS_NBSEND      =  2,   /* send if a receiver waits, else fail        */
    SYS_RECV        =  3,   /* receive, block                             */
    SYS_NBRECV      =  4,   /* receive if a sender waits, else fail       */
    SYS_CALL        =  5,   /* send + wait for reply (one-shot reply cap) */
    SYS_REPLY       =  6,   /* reply to the saved reply capability        */
    SYS_REPLYRECV   =  7,   /* reply then receive — the server loop, 2x   */
    SYS_INVOKE      =  8,   /* invoke a method on a non-endpoint object   */

    /* ---- Asynchronous signalling ------------------------------------- */
    SYS_SIGNAL      =  9,   /* set bits in a Notification, never blocks   */
    SYS_WAIT        = 10,   /* wait on a Notification (Rule 7)            */
    SYS_POLL        = 11,   /* non-blocking check of a Notification       */

    /* ---- The batched data plane (Chapter 15) ------------------------- */
    SYS_SUBMIT      = 12,   /* flush an IoQueue doorbell; often skippable */

    /* ---- Escape hatches ---------------------------------------------- */
    SYS_YIELD       = 13,
    SYS_DEBUG       = 14,   /* debug builds only; #ifdef'd out in release */
};
```

Fourteen, one of which is compiled out. Everything else — creating objects,
mapping memory, configuring interrupts, setting priorities, retyping untyped
memory, binding queues, creating scheduling contexts, running a VM — is
`SYS_INVOKE` on a capability, dispatched by object type.

The invocation encoding:

```c
/* msginfo, packed into one register: */
struct msginfo {
    uint64_t method  : 16;   /* interface method number                    */
    uint64_t nwords  :  4;   /* message registers used (0..12)             */
    uint64_t ncaps   :  2;   /* capabilities transferred (0..3)            */
    uint64_t iface   : 16;   /* interface id — checked against object type */
    uint64_t version :  8;   /* interface version the caller compiled for  */
    uint64_t flags   :  8;
    uint64_t label   : 18;   /* free for protocol use                      */
};
```

Carrying `iface` and `version` in every invocation costs nothing (it is already
in a register you were sending) and buys: mismatch detection at the first call
rather than at the first divergent field, per-version dispatch in servers during
migration, and meaningful traces. **Do this; retrofitting version negotiation is
painful.**

---

## 7. Living with it: the compatibility policy

Write `docs/abi-policy.md` before you have users, because after you have users it
is too late. A workable policy:

1. **Method numbers are permanent.** A removed method's number is never reused;
   it returns `-ENOSYS` forever.
2. **Within a major version, changes are additive only**: new methods, new
   appended struct fields, new flag bits. Never a semantic change to an existing
   method.
3. **A new major version is a new interface id.** Servers may implement both
   during a migration window; `Introspect.ListInterfaces` reports both.
4. **Unknown flags are rejected, not ignored.** Ignoring unknown flags means you
   can never define them safely later — a lesson learned the hard way by many
   projects. Reject with `-EINVAL` so a future flag's absence is loud.
5. **Reserved fields must be zero, and this is checked**, for the same reason.
6. **The kernel's 14 syscalls are frozen.** Additions require a written argument
   for why the operation cannot be an invocation. This document is where you
   defend the design against your future self on a deadline.
7. **Every ABI change is a separate commit** touching only `include/abi/`, with
   the rationale in the message. Make ABI changes feel heavy, because they are.

Add a CI check: `include/abi/` may not include kernel-internal headers, and any
diff to it requires a corresponding entry in a changelog file. Mechanical
enforcement beats good intentions (Chapter 16 §7).

---

## 8. POSIX compatibility: the cost table

You will eventually want to run existing software. The right approach is a
**userspace personality** — a library plus a couple of servers — not kernel
support. What each POSIX feature costs:

| POSIX feature | Implementation | Cost | Notes |
|---|---|---|---|
| `open`/`read`/`write` on files | `Resolver` + `Stream` + `IoQueue` | Near-native for bulk; extra IPC for small ops | Cache the resolution |
| Paths and the global FS namespace | Resolver chain per process | One IPC per path component (cacheable) | The semantics gap: POSIX assumes a mutable global tree |
| `fd` table | Userspace array mapping int → capability | Free | Literally what fds always were |
| `dup`/`dup2`/`fcntl` | `cap_copy` | Free | |
| `select`/`poll`/`epoll` | Notification + `IoQueue` completions | Cheap; readiness emulated over completions | Some semantics (level-triggered on a regular file) are awkward |
| `fork` | Snapshot the address space via the memory server | **Expensive and semantically imperfect** | Document the divergence; most real uses are `fork`+`exec`, which maps to spawn |
| `exec` | Spawn + hand over the fd table | Cheap | Actually cleaner than POSIX |
| Signals | Userspace: a Notification plus a signal thread that runs handlers | Moderate; `EINTR` semantics are painful | Delivery to a *specific* thread mid-syscall is the hard part |
| `mmap` (file-backed) | Frame caps from the FS server + `VSpace` mapping | Cheap once set up | |
| `ioctl` | A translation table per device class | Ugly by definition | Confine it to the personality; never let it into the native ABI |
| `/proc` | A FUSE-ish shim over `Properties` | Slow but works | Useful mainly to keep tools alive |
| `pthread` | TCBs + futex-equivalent over Notifications | Cheap | Futex is a good design; reimplement it in userspace |
| `getuid`/permissions | The personality invents a UID model | Fake, but adequate | Note the philosophical mismatch: POSIX identity vs capabilities |

**Publish this table with real measurements.** "How much does POSIX cost on a
capability microkernel, per feature" is an open question (Chapter 13 D5) and a
genuinely useful result.

---

## 9. Verification

```c
KTEST(abi_struct_layouts_are_stable) {
    /* _Static_assert on sizeof and offsetof for every struct in include/abi/.
     * Generated by a script from a golden file. Any accidental layout change
     * fails the build rather than corrupting a user. */
}

KTEST(invoke_rejects_version_mismatch) {
    /* Invoke with a version the server doesn't implement; assert -ENOSYS and
     * that no side effect occurred. */
}

KTEST(unknown_flags_are_rejected) {
    /* Set a reserved flag bit on every method; assert -EINVAL everywhere. */
}

KTEST(no_syscall_dereferences_user_pointers) {
    /* Debug build: unmap the IPC buffer and invoke every syscall with
     * plausible arguments. Assert none faults in the kernel. Enforces Rule 3
     * mechanically. */
}

KTEST(errors_are_distinct) {
    /* Static analysis pass over the kernel: count distinct error return sites
     * per error code. Warn where one code is returned from more than N places
     * in one file. A lint, not a hard failure — but it makes you think. */
}
```

And a fuzzing target that matters more than any of them: **fuzz `nyx_invoke` with
random capability pointers, method numbers, and msginfo words, from an unprivileged
task.** The kernel must never fault, never leak, and never grant. Run it in CI
forever. This one harness will find more real bugs than any test you write by
hand, because the syscall boundary is exactly where an attacker is.

---

## 10. Open questions

1. **Is 14 syscalls actually better?** The claim is that type-dispatched
   invocation is more extensible than a syscall table. Test it: implement three
   new object types and count the ABI surface added versus what Linux would need.
2. **What does `iface`/`version` in every message cost?** Probably nothing
   (register already in flight), but measure it in the IPC fast path, since the
   fast path is where a "free" field turns out to cost a branch.
3. **Can the IDL generate the compatibility check?** Given two versions of an
   interface definition, mechanically decide whether the change is
   backward-compatible under the §7 policy. This is a small, tractable tool and
   would be genuinely useful beyond this project.
4. **What is the right ergonomic layer?** A capability-passing async API is
   powerful and verbose. What does a *pleasant* language binding look like — one
   that keeps the security properties visible rather than hiding them behind a
   POSIX-shaped façade? This is a real design problem and mostly unsolved; the
   ocap language community (E, Pony, Monte) has ideas worth mining.
5. **Does cancellation-first design actually prevent the io_uring bug class?**
   Enumerate the relevant CVEs, check each against the Rule 5 semantics, and
   report which would still be possible.

---

## 11. Exercises

1. Take ten POSIX syscalls you use often. For each, write the Nyx equivalent and
   note what authority it needed that POSIX left implicit. This exercise is the
   fastest way to internalize what ambient authority actually is.
2. Implement `SYS_INVOKE` dispatch for three object types. Then add a fourth and
   measure how many files you touched. Compare with what adding a Linux syscall
   requires (hint: the syscall table, three architectures' tables, a `compat`
   variant, a man page, and strace).
3. Write the `docs/abi-policy.md` document, then deliberately try to break each
   rule and see what would go wrong. Add the rule violations you can catch to CI.
4. Implement the invocation fuzzer (§9). Run it for an hour. Report what it
   found. If it found nothing, your coverage is wrong — check by injecting a bug.
5. Implement extensible-struct handling with the zero-means-default rule. Write a
   test where an old client calls a new server and vice versa, and assert both
   work.
6. **Argue the other side**: make the case that a wide syscall interface (Linux's
   350) is *better* than a narrow one with type dispatch — for tooling (`strace`),
   for auditing (`seccomp`), for performance (specialized paths), and for
   discoverability. What would Nyx lose, and what would it need to build to
   compensate? Be specific: `strace` and `seccomp` are real, valuable things that
   a narrow type-dispatched ABI makes harder, and you should have an answer.
7. **Design exercise**: specify how a component negotiates interface versions
   with a server it has never met, including the failure modes, in half a page.

---

Next: [18 — Testing, debugging, tracing, benchmarking](18-testing-and-workbench.md)
