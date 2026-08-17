# 16 — Naming, objects, and system state: beyond "everything is a file"

> Goal: work out what "everything is a file" actually bought UNIX, where it
> breaks (devices, system state, structured configuration, discovery), survey
> every serious alternative that has been tried, and design a replacement for Nyx
> that keeps the composability without the `ioctl` escape hatch.

---

## 1. Theory: what a naming system is for

A naming system answers four separate questions that are usually conflated:

1. **Designation** — how do I refer to this thing?
2. **Authorization** — am I allowed to use it?
3. **Discovery** — what things exist, and which one do I want?
4. **Interface** — what can I do with it, and what shape is the result?

UNIX answers all four with one mechanism: a path in a global hierarchy, checked
against ambient credentials, listed with `readdir`, and operated on with
`read`/`write`. That unification is the source of both its elegance and all four
of its failure modes.

Chapter 09 already separated (1) and (2): a capability is a designator that *is*
the authorization, which is why path traversal, TOCTOU, and confused-deputy bugs
do not exist here. This chapter deals with (3) and (4).

---

## 2. "Everything is a file": the honest accounting

### 2.1 What it genuinely bought

Do not be glib about this. The idea won for real reasons:

- **One API to learn.** `open/read/write/close` works on a disk file, a terminal,
  a pipe, and a socket. Enormous cognitive economy.
- **Composability.** Because programs speak byte streams over fds, `|`,
  `>`, and `<` compose *arbitrary* programs that were never designed to work
  together. This is the single greatest usability achievement in systems design
  and nothing since has matched it.
- **Namespace as policy.** `chroot`, mount namespaces, and Plan 9's per-process
  namespaces all exploit the fact that the name space *is* the visible world.
- **fd passing is capability passing.** `dup2` before `exec`, and `SCM_RIGHTS`
  over a UNIX socket, are genuine object-capability mechanisms hiding inside
  UNIX. Capsicum's whole design is "remove paths, keep fds", and it works.
- **Uniform lifetime management.** Refcounted handles, closed on exit. Simple
  and correct.

Keep all of that. The goal is not to throw it away.

### 2.2 Where it breaks

**`ioctl` is the abstraction admitting defeat.** The moment a device has an
operation that is not "read some bytes" or "write some bytes", UNIX provides an
untyped, unversioned, undiscoverable escape hatch: an integer command number and
a `void *`. Linux has thousands of them. They are the single largest source of
kernel CVEs, they cannot be introspected, they cannot be proxied without
knowing every one of them, and they have no schema. Every criticism of "everything
is a file" reduces to: *the model is a byte stream and devices are not byte
streams, so there is an escape hatch, and the escape hatch is where reality
lives.*

**System state is structured, and files are not.** `/proc/meminfo` is a table.
`/proc/self/maps` is a record stream. `/sys` is a typed object graph flattened
into directories. To read any of them you write a parser, and the format is
undocumented, unversioned, locale-sensitive, and changes between kernel releases.
There is no schema, no atomicity across related values, no change notification
(you poll), and no way to ask a question — you read everything and filter. Linux
ended up with **five** incompatible answers to "how do I get system state"
(`/proc`, `/sys`, `netlink`, `ioctl`, and `seq_file`-backed debugfs), which is
strong evidence that the file model didn't fit.

**Blocking, stream-shaped I/O is the wrong default.** Chapter 15 covered this:
`read()` is synchronous, single-shot, and copies. Everything fast is a queue.

**Discovery is by convention.** "Which of these is my sound card?" is answered by
globbing paths and reading magic files. There is no query, no type system, no
capability-based binding.

**No versioning story.** A file has no interface version. When the semantics of
`/proc/foo` change, everything that parsed it breaks silently.

### 2.3 The diagnosis

> A file is *a named byte stream with ambient access control*. Devices and system
> state are *typed objects with structured state, typed operations, and events*.
> Forcing the second into the first produces `ioctl`, `/proc` parsing, and five
> competing namespaces.

---

## 3. What everyone else tried

| System | Model | The good idea | Where it falls down |
|---|---|---|---|
| **UNIX** | Path → inode → byte stream | Composability, fd as handle | `ioctl`, ambient paths, no types |
| **Plan 9** | Everything is a *file server*; per-process namespaces; 9P (13 messages) | Per-process namespace is exactly right; network transparency for free; `ctl` files instead of `ioctl` | Still untyped text; still stream-shaped; `ctl` files are `ioctl` with better manners; performance of a synchronous RPC per operation |
| **Windows NT Object Manager** | Typed kernel objects in a namespace, referenced by `HANDLE`, with ACLs and a uniform wait | Uniform typed handles; **wait on anything**; extensible attribute structures; separate Create/Open | Namespace is still global + ambient ACLs; the Registry is a second, worse namespace; API surface enormous |
| **macOS IOKit** | A typed object *tree* with properties; drivers bind by **matching dictionaries** | Property-based device matching is genuinely the right model for discovery; introspectable (`ioreg`) | C++ in the kernel; the property model doesn't extend to non-device state |
| **Android Binder** | Typed interfaces (AIDL), object references with refcounting, a service manager | Real object-capability semantics (a Binder reference is unforgeable and transferable); interface definitions generate stubs | Central service manager = ambient-ish; Android-specific |
| **D-Bus** | Named services, object paths, typed interfaces, introspection, signals | Introspection and signals done right; a genuine interface concept | Slow (broker-mediated), text-heavy, complex type signature language |
| **Fuchsia** | Handles + channels + **FIDL** + per-component namespaces from manifests | The most complete modern synthesis: capability routing declared in manifests, typed IPC, no global namespace | Complex tooling; component framework is heavyweight |
| **WMI / CIM** | Typed, queryable, schema'd system information with subscriptions | **Querying and subscribing to system state instead of parsing it** — the right idea | COM, XML-era complexity, notoriously slow |
| **sysfs/netlink/devlink** | Files, sockets, and a message protocol | Netlink's event notification | Three answers to one question; no schema |
| **Capsicum** | Remove ambient paths, keep fds, add `openat` | Incremental path to object-capabilities in a real UNIX | Retrofit; the ambient world still exists next door |

Two conclusions from the table:

- **Plan 9 got the namespace right and the data model wrong.** Per-process
  namespaces are a superb idea (Fuchsia, containers, and Capsicum all rediscovered
  them). Untyped text as the universal data model is the part that has not aged
  well.
- **Windows and IOKit got the data model right and the namespace wrong.** Typed
  objects with attributes, uniform handles, and property-based matching are good;
  a global namespace with ambient ACLs is not.

Nyx should take the namespace model from Plan 9/Fuchsia and the data model from
IOKit/WMI, with capabilities underneath.

---

## 4. The Nyx model

Three statements define it.

> 1. **Everything is an object with a typed interface.** A file is one interface
>    (`Stream`), not the interface.
> 2. **A process's namespace is its CSpace.** Names are a userspace convention
>    that resolve *to* capabilities; a name never confers authority.
> 3. **System state is a typed, queryable, subscribable property tree**, served
>    by whoever owns the state, never a parseable text file.

### 4.1 Interfaces

An interface is defined in the IDL (Chapter 10 §7) and identified by a
`(interface_id, version)` pair. Every object capability carries its type; every
invocation carries a method number.

```idl
// user/idl/stream.idl — the "file" interface, now just one interface among many
interface Stream : 0x0001 version 1 {
    // Data operations go through IoQueue (Chapter 15); this is control plane.
    method Seek(int64 offset, uint32 whence) -> (uint64 pos);
    method Stat() -> (StreamInfo info);
    method Truncate(uint64 size) -> ();
    method BindQueue(cap IoQueue q) -> ();     // attach a data plane
}

interface Block : 0x0010 version 1 {
    method GetInfo() -> (uint64 blocks, uint32 block_size, BlockFlags flags);
    method BindQueue(cap IoQueue q, uint32 depth) -> ();
    method Flush() -> ();
    method Trim(uint64 lba, uint64 count) -> ();
}
```

Note what `ioctl` would have been: `Trim`, `Flush`, and `GetInfo` are *methods
with types*, generated stubs, and a version number. The escape hatch is gone
because there is nothing to escape from — adding an operation is adding a method.

**Rule: there is no generic `Control(uint32 cmd, void *arg)` method in Nyx.
Ever.** Write this in `docs/abi-policy.md` as a hard rule, because the pressure
to add one will be constant and it is the single decision that separates this
design from UNIX's.

### 4.2 Introspection is free

Because the IDL generates everything, each server can expose:

```idl
interface Introspect : 0x0002 version 1 {
    method Describe() -> (InterfaceDescriptor desc);  // ids, versions, methods
    method ListInterfaces() -> (vector<InterfaceId> ids);
}
```

The descriptor is a generated constant, so it cannot drift from the
implementation — which is the failure mode of every hand-written documentation
system. You get:

- `nyxctl describe <cap>` prints exactly what an object can do.
- Generic proxies: a logging, rate-limiting, or recording interposer can be
  written *once*, generically, because it can enumerate methods and forward
  them opaquely. In UNIX this is impossible for `ioctl` — you must know every
  command number and its argument layout. **This is the concrete, practical
  payoff of typed interfaces and it is worth demonstrating early.**
- Compatibility checking at bind time rather than crash time.

### 4.3 Naming: resolvers, not a namespace

There is no global name server (Chapter 11 §3 established why: it is ambient
authority with extra steps). Instead:

- **The initial CSpace is the namespace.** ABI-fixed slots (`include/abi/slots.h`)
  give a process its world. What it does not have, it cannot name.
- **A resolver is a service that maps names to capabilities.** A process is given
  a `Resolver` capability by its parent, and the *parent decides what that
  resolver can see*. This is Plan 9's per-process namespace, done with
  capabilities:

```idl
interface Resolver : 0x0003 version 1 {
    method Resolve(string path, InterfaceId want) -> (cap object);
    method List(string path) -> (vector<Entry> entries);
    method Watch(string path, cap Notification n) -> (cap Subscription s);
}
```

Three properties follow, and they are the whole argument for this design:

1. **A path never confers authority.** `Resolve` can only return capabilities the
   resolver itself holds. Path traversal (`../../etc/shadow`) is not a
   vulnerability class; the worst case is that the resolver returns something it
   was already allowed to hand out. The entire category disappears.
2. **Namespaces compose by construction.** Give a child a resolver that wraps
   yours and filters it — that is a container, a chroot, and a sandbox, in twenty
   lines, with no kernel support.
3. **`Resolve` is type-checked.** Asking for a path *and an interface* means the
   mismatch is caught at resolution, not at first use.

### 4.4 System state: the property model

This is the replacement for `/proc` and `/sys`, and the piece most worth getting
right because it is where the daily pain lives.

```idl
struct PropValue {
    union { bool b; int64 i; uint64 u; double d; string s;
            bytes raw; vector<PropValue> list; }
}

struct PropEntry { string key; PropValue value; uint32 flags; }

interface Properties : 0x0004 version 1 {
    // Query a subtree. Returns a consistent snapshot.
    method Query(string path, string filter, uint32 depth)
        -> (vector<PropEntry> entries, uint64 generation);

    // Subscribe to changes. Pushes, does not poll.
    method Subscribe(string path, string filter, cap Notification n)
        -> (cap Subscription s, cap IoRegion updates);

    method Set(string key, PropValue value) -> ();   // where writable
    method Schema(string path) -> (SchemaDescriptor s);
}
```

The properties that matter, each one a fix for a specific `/proc` failure:

| Property | Fixes |
|---|---|
| **Typed values** | No parsing. `mem.available` is a `uint64`, not a line of text you `sscanf`. |
| **Schema'd** | You can validate, document, and version. Tools can be generic. |
| **Snapshot-consistent with a generation number** | Related values are read atomically. Reading `/proc/meminfo` today gives you a torn view. |
| **Queryable with a filter** | Ask for what you want. Don't read 200 values to use 3. |
| **Subscribable** | Push, not poll. A monitoring agent that polls `/proc` 10×/second is a real, common waste, and it is pure architecture failure. |
| **Served by the owner** | The memory server serves memory properties; the NVMe driver serves its own. No central registry to keep in sync, and no kernel code to enumerate state. |
| **Namespaced by capability** | You see the properties of the components you have a capability to. Container isolation of system state is automatic, not a `/proc` mount trick. |

**The bulk-update region.** `Subscribe` optionally returns an `IoRegion`
containing a lock-free ring of change records. High-frequency telemetry
(scheduler events, packet counters) then costs zero syscalls per update — the
same architecture as Chapter 15, applied to observability. This is how you get
`perf`-quality tracing without a special-purpose subsystem.

**Aggregation.** A `Properties` capability can be implemented by a broker that
merges several servers' trees into one view, with paths prefixed by component.
Because it is just an interface, aggregation is composition. Contrast with
`/proc`, where aggregation requires kernel code.

### 4.5 Device discovery: matching, not paths

Steal IOKit's best idea. A device is an object with properties; a driver declares
what it can bind to.

```c
/* A driver's match description, from its manifest: */
match {
    "bus"        = "pci",
    "class"      = 0x010802,       /* NVMe                                   */
    "vendor"     = any,
    "priority"   = 100,
}
```

The device manager enumerates buses, publishes each device as an object with
properties (`bus`, `vendor`, `device`, `class`, `bar[]`, `irq`), scores drivers
against it, and hands the winning driver exactly the capabilities it matched on:
the BAR `Frame`s (uncached), an `IRQHandler`, an `IommuCtx`, and its `Untyped`
budget. Hotplug is a `Properties` notification, not a `udev` rule parsing
`uevent` text.

The nice consequence: **"what does this driver have access to" is answerable by
printing its CSpace** (Chapter 09 §6). Compare with a Linux kernel module, where
the answer is "everything."

### 4.6 Keeping composability: streams and structured pipes

The one thing we must not lose is `a | b`. Two layers:

1. **`Stream` is a real interface** and `libnyx` provides `stdin`/`stdout`
   equivalents backed by an `IoQueue`. Text pipelines work exactly as expected.
   A shell wires them by handing the child a `Stream` capability. `dup2` becomes
   `cap_copy` into an ABI-fixed slot — which is what it always secretly was.
2. **Structured pipelines**, optionally. Because objects have schemas, a pipeline
   stage can pass *typed records* instead of bytes. PowerShell and nushell
   demonstrate the ergonomics win; the reason they are awkward on UNIX is that the
   OS has no type information, so they must invent it. Here the schema already
   exists. A stage declares its input and output schema; the shell checks
   compatibility at pipeline construction; `sort by mem.rss` needs no `awk`.

Be honest about the cost: text pipelines are universal precisely because text is
the type system everyone already has. A structured pipeline is better *within* a
system that has schemas and worse at the boundary with everything else. Provide
both, make text the fallback, and measure how often people actually reach for the
structured version.

---

## 5. Implementation sketch

```c
/* user/srv/props/props.c — the pattern every server follows. */

struct prop_node {
    const char       *key;
    uint8_t           type;
    uint8_t           flags;        /* PROP_RO, PROP_VOLATILE, PROP_COUNTER  */
    union { uint64_t *u64; int64_t *i64; const char **str;
            uint64_t (*getter)(void *); } src;
    void             *ctx;
};

/* Servers declare their tree statically; no allocation, no registration
 * protocol, and it can be checked against the schema at compile time. */
static const struct prop_node mem_props[] = {
    { "total",     PROP_U64, PROP_RO, .src.u64 = &stat.total },
    { "available", PROP_U64, PROP_RO|PROP_VOLATILE, .src.getter = mem_available },
    { "pressure",  PROP_F64, PROP_RO|PROP_VOLATILE, .src.getter = mem_pressure },
    { NULL }
};

/* Query walks the tree, applies the filter, and serializes into the reply
 * region. The generation counter is bumped by any writer; readers retry if
 * it changed mid-walk (a seqlock over the whole snapshot). */
int props_query(const char *path, const char *filter, uint32_t depth,
                struct reply_buf *out, uint64_t *generation)
{
    uint64_t g;
    do {
        g = seq_read_begin(&props_seq);
        reply_reset(out);
        walk_and_filter(root_for(path), filter, depth, out);
    } while (seq_read_retry(&props_seq, g));
    *generation = g;
    return 0;
}
```

The seqlock-over-a-snapshot pattern gives you the consistency property cheaply
and without blocking writers — worth noting because "atomic read of related
values" is the thing `/proc` cannot do at all.

---

## 6. The honest costs

Do not present this design without them.

| Cost | Reality | Mitigation |
|---|---|---|
| No `cat /sys/class/...` | Real ergonomic loss. Shell one-liners are how people debug. | `nyxctl get mem.*` must be as easy as `cat`, ship it early, and make its output pipe-friendly text by default |
| IDL churn | Every new operation touches the IDL, regenerates stubs, bumps versions | Automate ruthlessly; make regeneration part of the build, not a manual step |
| Version discipline forever | An interface published is a promise | Write the compatibility policy in `docs/abi-policy.md` on day one: additive-only within a major version, method numbers never reused, unknown methods return `-ENOSYS` |
| Tooling must exist before it's usable | With files, `ls` and `cat` come free | Budget real time for `nyxctl` (query, describe, watch, tree). It is not optional; it is the user interface of the OS |
| Discoverability by exploration is worse | You cannot `ls /` and see the world | Introspection + a good `nyxctl tree` recovers most of it — and unlike `ls /`, it shows *your* world, which is more truthful |
| Text remains the universal interchange | Anything crossing to another system needs serialization | Provide a canonical JSON/CBOR projection of any property tree |

The largest risk is the tooling one. A typed system with bad tools is worse than
an untyped system with `cat`. **Write `nyxctl` in parallel with the property
model, not after it.**

---

## 7. Verification

```c
KTEST(resolver_cannot_exceed_its_own_authority) {
    /* Build a resolver over a subset; try every path form including "..",
     * absolute, symlink-ish, and encoded traversal. Assert nothing outside
     * the subset is ever returned. This should be trivially true by
     * construction — the test documents that it IS by construction. */
}

KTEST(introspect_matches_implementation) {
    /* For every registered interface, assert the descriptor's method count
     * and signatures match the dispatch table. Generated from the same IDL,
     * so this catches generator bugs and hand-edits. */
}

KTEST(props_snapshot_is_consistent) {
    /* Writer thread mutates two related values in lockstep (total, used).
     * Reader queries repeatedly; assert the invariant used <= total holds in
     * every snapshot. Without the seqlock this fails within seconds. */
}

KTEST(props_subscribe_delivers_no_loss_or_bounded_loss) {
    /* Flood updates; assert either all are delivered or the overflow counter
     * exactly accounts for the missing ones. Silent loss is the bug. */
}

KTEST(no_control_method_exists) {
    /* Scan all generated interface descriptors for any method with an untyped
     * bytes-in/bytes-out signature and a command-number argument. Fail the
     * build. This test enforces the design rule against future you. */
}
```

That last one is only half a joke. Design rules that are not mechanically
enforced decay within a year.

---

## 8. Open questions

1. **Does the typed model actually reduce bugs?** `ioctl` handlers are a top CVE
   source. Count the classes that generated, typed, length-checked stubs
   eliminate (missing bounds check, wrong struct size, missing copy validation,
   compat-ABI mismatch) and the classes they don't. Quantify.
2. **What is the performance of the property model versus `/proc`?** A monitoring
   agent collecting 500 metrics at 10 Hz: measure syscalls, cycles, cache misses,
   and bytes moved, both ways. I expect the difference to be large enough to be
   surprising.
3. **Can namespaces be verified?** Given a component manifest, prove statically
   that component A can never obtain a capability to object X. This is
   reachability over the capability graph and should be decidable (Chapter 13 D6).
4. **Structured pipelines: do people actually use them?** Build both, then look
   at your own shell history after a month. Report honestly, including if the
   answer is "no".
5. **What is the right schema language?** Protobuf, FIDL, CDDL, and CUE all
   exist. Or define a minimal one. The interesting constraint here is that it
   must be parseable by a small freestanding runtime *and* generate code for C,
   Rust, and a shell tool.
6. **Is there a defensible middle ground where `Stream` is genuinely primary?**
   For a large class of software (compilers, text tools, most of userspace), byte
   streams really are the right abstraction. Characterize that class precisely
   rather than assuming the typed model is better everywhere.

---

## 9. Exercises

1. Take three Linux `ioctl` interfaces you have used (say `TIOCGWINSZ`,
   `BLKGETSIZE64`, and any V4L2 call). Write the equivalent Nyx IDL. Note what
   type information was implicit and where you had to consult the kernel source
   to recover it.
2. Implement `Properties` for one server (the memory server is a good first) and
   write `nyxctl get`. Then implement `Subscribe` and write `nyxctl watch`.
   Measure the cost of watching 100 values versus polling them.
3. Implement a generic logging interposer using only `Introspect`. Insert it
   between a client and a server without either knowing. Then write down why this
   is impossible for `ioctl`-based interfaces.
4. Implement a resolver that presents a filtered view, and use it to sandbox a
   component. Compare the resulting code with a `chroot`-based sandbox and count
   the ways the latter can be escaped.
5. Implement `props_snapshot_is_consistent`, first without the seqlock. Record
   how long it takes to fail.
6. **Argue the other side**: write the strongest possible defence of
   "everything is a file", specifically addressing composability, tooling, and
   the fact that UNIX won. Then say what you would concede and what you would not.
7. **Design exercise**: specify the interface-versioning and compatibility policy
   in one page — what may change within a version, what forces a new one, how a
   client negotiates, and what happens on mismatch. This document will outlive
   most of your code.

---

Next: [17 — System call and API design](17-syscall-design.md)
