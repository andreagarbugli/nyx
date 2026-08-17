# 18 — Testing, debugging, tracing, benchmarking

> Goal: build the instrumentation subsystem. By the end of this chapter `make
> test` boots QEMU headless, runs host unit tests, in-kernel self-tests and
> userspace integration tests, exits with a status code, emits a trace you can
> visualize, and prints a benchmark table that CI compares against the last
> commit. This chapter is not optional garnish — it is the difference between a
> workbench and a pile of code.

---

## 1. Theory: instrumentation is a subsystem, not a chore

Three claims, all of which I believe strongly enough to open a chapter with:

**Claim 1: in kernel work, observability *is* the productivity multiplier.** In
application development, the debugger and the stack trace are free, so
productivity is dominated by how fast you can think. In kernel development they
are not free, and productivity is dominated by how fast you can *see*. A
developer with a working trace viewer and 30-second CI is perhaps five times
faster than one printf-debugging into a serial console — not because they type
faster, but because the loop "form hypothesis → get evidence" runs in seconds
instead of minutes.

**Claim 2: if producing a number takes two hours, you will not produce numbers.**
And without numbers you have opinions. Chapters 14–17 committed to several
positions that are only defensible with measurement: that a capability-based
queue can match io_uring, that a passive-server IPC path is competitive, that
your kernel's WCET bound is real. Those claims are checks written against a
measurement harness you have to build.

**Claim 3: tests you have to remember to run do not exist.** Everything here ends
up wired to `make test` and to a CI job. A test that requires the phrase "did you
run the..." is a test that has already failed.

The corollary that people resist: **build this early**. Not at the end. The right
time to build the ktest harness is chapter 02 (you already have the section
trick), the right time to build tracing is chapter 08 (before you optimize IPC,
because you cannot optimize what you cannot see), and the right time to build the
benchmark table is the first time you write a fast path.

### 1.1 The shape of the thing

```
tools/
├── runtest.py         # boots QEMU, applies timeout, parses output, exits status
├── bench.py           # runs benchmark suite, emits JSON, compares to baseline
├── trace/
│   ├── decode.py      # binary trace ring → JSON / Perfetto / Chrome trace
│   └── view.py        # quick text timeline for the terminal
├── cov.py             # merges coverage from QEMU trace
└── baselines/         # committed benchmark results, one JSON per commit tag
kernel/
├── trace/  trace.c    # the event ring
└── test/   ktest.c    # the in-kernel runner
tests/
├── host/              # unit tests compiled for the host
├── kernel/            # KTEST() files
├── user/              # userspace integration tests (real processes, real IPC)
└── chaos/             # fault injection scenarios
```

---

## 2. The test pyramid for a kernel

| Level | What it tests | Runs in | Speed | Build it |
|---|---|---|---|---|
| **Host unit tests** | Pure logic: buddy allocator, CSpace lookup, ring indices, ELF parser, IDL codecs | Host process, ASan+UBSan | ms | Chapter 05 |
| **Host fuzzers** | The same, adversarially | libFuzzer/AFL++ | continuous | Chapter 09 |
| **Model checking** | Concurrency: rings, MPSC inbox, RCU, lock protocols | CBMC / Loom / TLC | seconds–minutes | Chapter 12 |
| **In-kernel tests (KTEST)** | Anything needing real hardware state: paging, IDT, context switch, TLB, APIC | QEMU, ring 0 | ~1 s total | Chapter 02 |
| **Userspace integration** | The actual system: IPC between real processes, server protocols, driver behaviour | QEMU, ring 3 | seconds | Chapter 11 |
| **Chaos / fault injection** | Recovery: does the reincarnation server actually work | QEMU, long-running | minutes | Chapter 11 |
| **Benchmarks** | Performance, tracked over time | QEMU+KVM, ideally bare metal | seconds | Chapter 08 |

The pyramid is inverted from the usual advice in one respect: **push as much as
possible down to the host level**, because host-level tests are 100× faster and
you get ASan, UBSan, valgrind, coverage and fuzzing for free. The design
consequence — worth restating because it shapes your code — is that every
subsystem should have a *pure* core with hardware access behind a small hook
interface.

```c
/* kernel/mm/pmm.c — the arch hooks are the only thing the host can't provide */
struct pmm_arch_ops {
    void  (*zero_frame)(paddr_t p);
    void *(*map_temp)(paddr_t p);
    void  (*unmap_temp)(void *v);
};
extern const struct pmm_arch_ops *pmm_arch;
```

On the host, `pmm_arch` points at an implementation backed by a big `malloc`ed
array. Now `buddy_alloc` is testable under a fuzzer. The same trick applies to
`cap_lookup` (needs no hardware at all), the ring implementations, the ELF
loader, the IDL codecs, and the ACPI/MADT parsers. That is a large fraction of
the code where bugs are subtle.

---

## 3. Host-side testing

### 3.1 The build

```makefile
# tests/host/Makefile
HOSTCC    ?= clang
HOSTFLAGS := -std=c17 -g -O1 -Wall -Wextra -Werror \
             -fsanitize=address,undefined -fno-omit-frame-pointer \
             -DNYX_HOSTTEST=1 \
             -I../../include -I../../kernel/include -Ishim

host-tests: $(TESTS)
	@for t in $(TESTS); do echo "== $$t"; ./$$t || exit 1; done
```

`tests/host/shim/` provides the handful of kernel headers the pure code
includes: `kassert.h` mapping `KASSERT` to `assert`, a `spinlock.h` whose locks
are no-ops (or, better, `pthread_mutex_t` so you can run the same tests
multi-threaded under TSan), `printf.h` mapping `klog` to `fprintf(stderr, ...)`.

Keep the shim small. If it grows past ~200 lines, that is a signal that your
kernel code is too entangled with its environment, which is also a signal about
verifiability and portability. **The shim's size is a design metric.**

### 3.2 Fuzzing the security-critical paths

Three targets pay for themselves within a week:

```c
/* tests/host/fuzz_cap_lookup.c */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < sizeof(uint64_t) + 64) return 0;

    uint64_t cptr;
    memcpy(&cptr, data, sizeof cptr);
    data += sizeof cptr; size -= sizeof cptr;

    /* Build a CSpace whose shape comes from the fuzzer: radix bits, guards,
     * nesting depth, and slot contents are all attacker-controlled, which is
     * exactly the threat model — a process controls its own CSpace. */
    struct cnode *root = fuzz_build_cspace(data, size);

    struct cap out;
    int err = cap_lookup(root, cptr, CAP_DEPTH_MAX, &out);

    /* Invariants that must hold for ANY input: */
    if (err == 0) {
        assert(out.type > CAP_NULL && out.type < CAP_TYPE_MAX);
        assert((out.rights & ~RIGHT_ALL) == 0);
        assert(cap_object_in_bounds(&out));   /* no pointer outside the arena */
    }
    fuzz_free_cspace(root);
    return 0;
}
```

The other two: `fuzz_elf_load` (feed it random bytes and mutated real ELFs —
this is a parser that runs on untrusted input and *every* OS has had bugs here),
and `fuzz_ring_consumer` (feed it adversarial head/tail indices and SQE contents;
the consumer must never index outside the ring or trust a length field).

Run them under `-fsanitize=fuzzer,address,undefined`. A corpus of a few thousand
inputs, checked into the repo and replayed in CI in a second, catches
regressions forever. **This is the single highest value-per-hour testing activity
available to you.**

### 3.3 Model checking the concurrency

The lock-free structures are where reasoning fails and testing is nearly useless
(the bug appears once per 10¹⁰ interleavings, on someone else's machine).

```c
/* tests/host/cbmc_ring.c — verified with:
 *   cbmc --unwind 6 --bounds-check --pointer-check cbmc_ring.c */
void producer(void) { for (int i = 0; i < N; i++) ring_push(&r, i); }
void consumer(void) { int v; while (ring_pop(&r, &v)) observed[v]++; }

int main(void) {
    __CPROVER_ASYNC_1: producer();
    consumer();
    /* Property: no value observed twice, none lost while the ring wasn't full */
    for (int i = 0; i < N; i++) __CPROVER_assert(observed[i] <= 1, "no dup");
}
```

If you write the ring in Rust, `loom` does this better and more ergonomically. If
you want to check the *protocol* rather than the code — "can a client and server
deadlock given these IPC rules?" — write it in TLA+/PlusCal and run TLC.
Chapter 13 §A4 argues this is worth a week of your life; the IPC state machine
and the capability derivation tree are both exactly the right size for it.

---

## 4. The in-kernel harness and QEMU CI

### 4.1 The runner

```c
/* kernel/test/ktest.c */
struct ktest { const char *name; void (*fn)(void); };
extern const struct ktest __ktest_start[], __ktest_end[];

static int  ktest_failures;
static const char *ktest_current;

void ktest_fail(const char *file, int line, const char *expr) {
    klog(LOG_ERR, "KTEST FAIL %s: %s:%d: %s\n",
         ktest_current, file, line, expr);
    ktest_failures++;
    ktest_abort_current();          /* longjmp back into the runner */
}

void ktest_run_all(void) {
    int n = 0;
    uint64_t t0 = rdtsc();
    for (const struct ktest *t = __ktest_start; t < __ktest_end; t++) {
        ktest_current = t->name;
        n++;
        uint64_t s = rdtsc();
        if (!ktest_setjmp_guard())  /* returns 0 on first entry */
            t->fn();
        klog(LOG_INFO, "KTEST %-40s %8llu cycles\n",
             t->name, (unsigned long long)(rdtsc() - s));
    }
    klog(LOG_INFO, "KTEST SUMMARY %d run, %d failed, %llu cycles total\n",
         n, ktest_failures, (unsigned long long)(rdtsc() - t0));
    qemu_exit(ktest_failures == 0 ? EXIT_OK : EXIT_FAIL);
}
```

Two details that matter more than they look:

- **Print the cycle count per test.** You get a free performance-regression
  tripwire, and you will notice the day `vspace_destroy_frees_everything` gets
  40× slower because someone made unmapping quadratic.
- **Recover from a failed assertion rather than panicking.** One broken test
  should not hide the other ninety. `setjmp`/`longjmp` in the kernel is fine
  here if the test guard is the only user; alternatively record the failure and
  return. Failing *fast but not fatally* is the property you want.

### 4.2 Exiting QEMU with a status

```c
#define QEMU_DEBUG_EXIT_PORT 0xf4
/* QEMU exits with status (value << 1) | 1, so pick values that map to
 * something readable: 0x10 -> exit code 33, 0x11 -> 35. */
enum { EXIT_OK = 0x10, EXIT_FAIL = 0x11, EXIT_PANIC = 0x12 };

_Noreturn void qemu_exit(uint32_t code) {
    outl(QEMU_DEBUG_EXIT_PORT, code);
    /* If the device isn't present, hang visibly rather than continuing. */
    klog(LOG_ERR, "isa-debug-exit missing; halting\n");
    for (;;) __asm__ volatile ("cli; hlt");
}
```

Wire `panic()` to `qemu_exit(EXIT_PANIC)` when `CONFIG_KTEST` is on, *after*
dumping registers and the log ring. A panic during tests must be a CI failure,
not a hang that eats the timeout.

### 4.3 The runner script

```python
#!/usr/bin/env python3
# tools/runtest.py — boot the kernel headless, enforce a timeout, parse output.
import re, subprocess, sys, time

QEMU = ["qemu-system-x86_64",
        "-machine", "q35", "-cpu", "max", "-smp", "4", "-m", "512M",
        "-cdrom", sys.argv[1],
        "-serial", "stdio", "-display", "none",
        "-no-reboot", "-no-shutdown",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        "-d", "guest_errors"]

TIMEOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 60

t0 = time.time()
try:
    p = subprocess.run(QEMU, capture_output=True, text=True, timeout=TIMEOUT)
    out, rc = p.stdout, p.returncode
except subprocess.TimeoutExpired as e:
    print(e.stdout or "", end="")
    print(f"\n*** TIMEOUT after {TIMEOUT}s — kernel hung or never exited")
    sys.exit(2)

print(out, end="")
fails = [l for l in out.splitlines() if "KTEST FAIL" in l]
m = re.search(r"KTEST SUMMARY (\d+) run, (\d+) failed", out)

if not m:
    print("*** No test summary — kernel died before finishing"); sys.exit(3)
run, failed = int(m.group(1)), int(m.group(2))
print(f"\n{run} tests, {failed} failed, {time.time()-t0:.1f}s wall, qemu rc={rc}")
sys.exit(0 if (failed == 0 and rc == 33) else 1)
```

Three failure modes, three distinct exit codes: tests failed (1), hung (2), died
early (3). When CI goes red you want to know *which* without reading logs.

**The timeout is the most important line in that script.** Kernel bugs hang. A CI
job that hangs blocks the queue and teaches everyone to ignore CI.

### 4.4 Userspace integration tests

KTESTs run in ring 0 and can therefore cheat. The tests that actually validate
your system run as real processes:

```c
/* tests/user/t_ipc_badge.c — a real user program, spawned by the test init */
int main(void) {
    cap_t ep = nyx_untyped_retype(CAP_UNTYPED, OBJ_ENDPOINT, /*slot=*/20);
    cap_t badged_a = nyx_cap_mint(ep, RIGHT_SEND, /*badge=*/0xAAAA, 21);
    cap_t badged_b = nyx_cap_mint(ep, RIGHT_SEND, /*badge=*/0xBBBB, 22);

    spawn_child("echo_badge", badged_a);
    spawn_child("echo_badge", badged_b);

    for (int i = 0; i < 2; i++) {
        message_t m; word_t badge;
        nyx_recv(ep, &m, &badge);
        TEST_ASSERT(badge == 0xAAAA || badge == 0xBBBB,
                    "badge must identify the sender, got %#lx", badge);
        TEST_ASSERT(m.words[0] == badge, "child echoed its own view");
        nyx_reply(&m);
    }
    return test_done();          /* writes result to the console endpoint */
}
```

A tiny test-init server spawns each `tests/user/t_*` binary in turn, collects
pass/fail over IPC, and calls `qemu_exit`. This layer catches everything the
KTESTs structurally cannot: ABI mistakes, capability-transfer bugs, missing
rights checks, and the "works when the kernel calls it, faults from ring 3"
class.

---

## 5. Tracing: build it before you optimize

### 5.1 Why a ring buffer and not printf

`klog` from the IPC path changes the thing it measures by three orders of
magnitude. You need an event log that costs tens of cycles, not tens of
thousands: a per-CPU lock-free ring of fixed-size binary records, decoded on the
host.

```c
/* include/nyx/trace.h */
enum trace_ev {
    TR_IPC_SEND, TR_IPC_RECV, TR_IPC_REPLY, TR_NOTIFY,
    TR_SWITCH, TR_ENQUEUE, TR_DEQUEUE, TR_PREEMPT,
    TR_FAULT, TR_SYSCALL, TR_IRQ, TR_IOQ_SUBMIT, TR_IOQ_COMPLETE,
    TR_CAP_INVOKE, TR_UNTYPED_RETYPE, TR_TLB_SHOOTDOWN,
    TR_EV_MAX
};

struct trace_rec {          /* 32 bytes — two per cache line, power of two    */
    uint64_t tsc;
    uint16_t ev;
    uint16_t cpu;
    uint32_t tid;           /* current thread                                */
    uint64_t a0, a1;        /* event-specific                                */
} __attribute__((packed));
_Static_assert(sizeof(struct trace_rec) == 32, "trace record size is ABI");

extern uint64_t trace_mask;     /* bit per event type; 0 = tracing off       */

static inline void trace(enum trace_ev ev, uint64_t a0, uint64_t a1) {
    if (__builtin_expect(!(trace_mask & (1ull << ev)), 1)) return;
    trace_emit(ev, a0, a1);     /* out of line, keeps the fast path small    */
}
```

The `trace_mask` check is a load, a test and a predictable branch — about 3
cycles when disabled, which is cheap enough to leave in the IPC fast path
permanently. **Do that.** A tracepoint you have to recompile to enable is a
tracepoint you will not use at 2 a.m.

```c
/* kernel/trace/trace.c */
void trace_emit(enum trace_ev ev, uint64_t a0, uint64_t a1) {
    struct percpu *pc = this_cpu();            /* no lock: per-CPU ring      */
    uint32_t i = pc->trace_head++ & (TRACE_ENTRIES - 1);
    struct trace_rec *r = &pc->trace_ring[i];
    r->tsc = rdtsc();       /* NOT rdtscp: we accept the reordering here     */
    r->ev  = ev;  r->cpu = pc->id;
    r->tid = pc->current ? pc->current->tid : 0;
    r->a0  = a0;  r->a1 = a1;
}
```

Notes on the deliberate choices:

- **Per-CPU, no locking, overwrite on wrap.** Tracing must never block, allocate,
  or synchronize; a trace subsystem that can deadlock is worse than none.
- **`rdtsc` not `rdtscp`.** The serialization costs ~30 cycles and you don't need
  it for a log; you *do* need it for benchmarks (§6).
- **Cross-CPU timestamps need care.** Check `CPUID.80000007H:EDX[8]`
  (invariant TSC) and, if the TSCs aren't synchronized at reset, measure the
  per-CPU offset at boot and subtract it in the decoder. Getting this wrong
  produces traces where a reply precedes its request, and you will spend a day
  on it.
- Expose the ring to userspace as a read-only `IoRegion` and you get a live
  trace viewer with zero syscalls.

### 5.2 What to trace, and the payoff

Instrument these and stop: IPC send/recv/reply (a0 = endpoint object id,
a1 = badge), context switch (a0 = from tid, a1 = to tid), enqueue/dequeue,
faults, IRQs, IoQueue submit/complete (a0 = queue id, a1 = user_token), and
capability invocations. That's enough to reconstruct the whole causal structure
of the system.

Because IPC is *the* structuring mechanism, an IPC trace is something a
monolithic kernel cannot give you: **the complete call graph of the operating
system, across protection domains, with timestamps.** A single `read()` becomes a
visible sequence — app → VFS → FS server → block driver → device → back — with a
duration on every edge. That is the diagnostic capability that makes the
multi-server architecture *easier* to debug than a monolith, not harder, and it
is worth advertising in your docs.

### 5.3 Decoding and viewing

```python
# tools/trace/decode.py → Chrome/Perfetto trace JSON
import struct, json, sys
REC = struct.Struct("<QHHIQQ")
EV  = {0:"ipc_send", 1:"ipc_recv", 2:"ipc_reply", 3:"notify", 4:"switch", ...}

events, khz = [], float(sys.argv[2])          # TSC kHz from the kernel banner
for rec in iter(lambda: sys.stdin.buffer.read(REC.size), b""):
    if len(rec) < REC.size: break
    tsc, ev, cpu, tid, a0, a1 = REC.unpack(rec)
    events.append({"name": EV.get(ev, f"ev{ev}"), "ph": "i", "s": "g",
                   "ts": tsc / khz * 1000.0,     # microseconds
                   "pid": cpu, "tid": tid, "args": {"a0": a0, "a1": a1}})
json.dump({"traceEvents": events}, sys.stdout)
```

Load it in Perfetto (`ui.perfetto.dev`) or `chrome://tracing`. Pairing
send/recv into duration events (`"ph": "X"`) turns it into flame-graph-shaped
spans, which is where it becomes genuinely revealing. An afternoon of work; you
will use it for years.

---

## 6. Benchmarking without lying to yourself

### 6.1 Measuring cycles correctly

```c
static inline uint64_t bench_start(void) {
    uint32_t lo, hi;
    __asm__ volatile ("cpuid\n\t"           /* serialize: no reordering in   */
                      "rdtsc"
                      : "=a"(lo), "=d"(hi) :: "rbx", "rcx", "memory");
    return ((uint64_t)hi << 32) | lo;
}
static inline uint64_t bench_end(void) {
    uint32_t lo, hi;
    __asm__ volatile ("rdtscp\n\t"          /* waits for prior insns to retire */
                      "mov %%eax, %0\n\t"
                      "mov %%edx, %1\n\t"
                      "cpuid"               /* ...and blocks later ones      */
                      : "=r"(lo), "=r"(hi) :: "rax","rbx","rcx","rdx","memory");
    return ((uint64_t)hi << 32) | lo;
}
```

The rules, each of which corresponds to a way people publish wrong numbers:

1. **Warm up.** Run ≥1000 iterations discarded before measuring. The first
   iteration measures cold i-cache, cold TLB, cold branch predictors and page
   faults. It is a real number; it is not the number you are claiming.
2. **Report percentiles, not the mean.** Print min, median, p99, p99.9, max. The
   mean of a distribution with a fat tail is a fiction, and for Chapter 14's
   real-time claims **the max is the only number that matters**.
3. **Pin to a core, disable frequency scaling, and say so.** On the host: 
   `taskset -c 2`, `cpupower frequency-set -g performance`, and consider
   `isolcpus`. Under QEMU without KVM, cycle counts are meaningless — TCG doesn't
   model the pipeline. **Benchmark under KVM, and treat bare metal as the number
   you actually publish.**
4. **Measure the round trip, not the half.** One-way IPC latency requires
   synchronized clocks across cores; a ping-pong divided by two doesn't, and is
   harder to get wrong.
5. **Record the environment with the result**: CPU model, microcode, KVM or
   metal, mitigations status (`/sys/devices/system/cpu/vulnerabilities/*`),
   compiler version, commit hash. A number without an environment is not a
   measurement. Spectre mitigations alone move syscall cost by 5×; two people
   comparing numbers across that boundary will reach opposite conclusions and
   argue for a week.

### 6.2 The benchmark table

Keep this table in `docs/performance.md`, regenerated by `make bench`. The
targets are what a competent implementation on modern hardware should reach; the
seL4 column is roughly what the published numbers look like, as a sanity anchor.

| Benchmark | What it measures | Target (cycles) | seL4 ref |
|---|---|---|---|
| `syscall_null` | `syscall`/`sysret` round trip, no work | 80–150 | — |
| `ipc_call_reply_same_core_same_as` | Fast-path round trip, no CR3 switch | 600–1000 | ~800 |
| `ipc_call_reply_same_core_diff_as` | With address-space switch (PCID) | 900–1500 | ~1100 |
| `ipc_call_reply_cross_core` | IPI + wakeup | 3000–8000 | — |
| `notify_signal_wake` | Async signal to a blocked waiter | 400–800 | — |
| `ctx_switch_same_as` | `context_switch` only | 100–300 | — |
| `ctx_switch_diff_as` | Including CR3 + TLB effects | 400–1200 | — |
| `cap_lookup_1level` | Radix-12 single-level lookup | 10–30 | — |
| `untyped_retype_4k` | Object creation incl. zeroing | 1500–4000 | — |
| `page_fault_to_userspace_pager` | Fault → IPC → map → resume | 3000–6000 | — |
| `ioq_submit_complete_server` | Queue op, userspace consumer, no syscall | 200–600 | — |
| `ioq_submit_complete_device` | Queue op straight to hardware (NVMe) | 100–400 | — |
| `posix_read_via_compat` | The POSIX personality's `read()` | measure it | — |

That last row exists to keep you honest: it's the number a sceptic will ask for,
and Chapter 17 §8 promised a cost table.

### 6.3 Regression tracking

```python
# tools/bench.py compare — fails CI if a benchmark regresses > 5%
THRESHOLD = 0.05
for name, cur in current.items():
    base = baseline.get(name)
    if base is None:
        print(f"NEW      {name}: {cur['median']}"); continue
    delta = (cur["median"] - base["median"]) / base["median"]
    tag = "REGRESS" if delta > THRESHOLD else \
          "IMPROVE" if delta < -THRESHOLD else "ok"
    print(f"{tag:8} {name}: {base['median']} -> {cur['median']} ({delta:+.1%})")
    if delta > THRESHOLD: failures.append(name)
```

Commit the baseline JSON. Update it deliberately, in its own commit, with a
message explaining the change. The point is not to forbid regressions — sometimes
correctness costs cycles, and that's fine — but to make every one of them a
*decision* rather than an accident discovered six months later.

Noise will bite you: 5% is roughly the floor for a QEMU/KVM measurement even with
pinning. If you want a 1% threshold you need bare metal and many repetitions.
Prefer running the benchmark 30 times and comparing medians with a
Mann–Whitney U test over comparing single runs; it's ten lines of `scipy` and it
removes an entire category of false alarms.

---

## 7. Debugging

### 7.1 The instruments, ranked by how often you'll want them

| Tool | Best for | Invocation |
|---|---|---|
| Serial log + panic dump | 80% of everything | always on |
| Trace ring dumped by `panic()` | "what led to this" | §5 |
| QEMU `-d int,cpu_reset,guest_errors` | Triple faults, bad IDT, reset loops | `make run-debug` |
| QEMU monitor `info registers/mem/tlb/mtree` | "is that page actually mapped?" | Ctrl-A c |
| GDB + `target remote :1234` | Stepping, breakpoints, watchpoints | `make debug` |
| GDB **watchpoints on physical memory** | Memory corruption | `watch *(long*)0xffff8000...` |
| QEMU `-icount` + record/replay | Heisenbugs, races | §7.3 |
| lockdep (Ch. 12) | Deadlocks, before they happen | `CONFIG_LOCKDEP` |
| `qemu -trace` | Device-level: what did the NIC actually get | `-trace 'nvme_*'` |

### 7.2 Make `panic()` excellent

The panic handler is the piece of code that repays polish the most, because it
runs exactly when you have the least information. It should print, in this order:
the message; the full register dump with decoded CR0/CR2/CR3/CR4 and #PF error
bits; a page-table walk of the faulting address (`vmm_dump_walk`); the symbolized
backtrace; the current thread's tid, name, priority and state; the per-CPU
runqueue summary; the last N trace records decoded; and the tail of the klog
ring. Then exit QEMU with `EXIT_PANIC`.

Symbolization needs a symbol table in the image:

```make
nyx.sym: nyx.elf
	$(NM) -n $< | grep -E ' [tT] ' | awk '{print $$1" "$$3}' > $@
	$(OBJCOPY) --add-section .ksyms=$@ --set-section-flags .ksyms=alloc,load \
	           nyx.elf nyx-sym.elf
```

Then `ksym_lookup(rip)` is a binary search. Half a day of work; it converts every
future backtrace from a list of hex numbers into a list of function names, which
is the difference between a five-minute diagnosis and an hour.

### 7.3 Deterministic replay — the underused superpower

```bash
# Record: -icount makes execution deterministic (virtual time, no host timing)
qemu-system-x86_64 -icount shift=7,rr=record,rrfile=replay.bin \
    -cdrom nyx.iso -serial stdio -display none

# Replay the identical execution, as many times as you like, under GDB
qemu-system-x86_64 -icount shift=7,rr=replay,rrfile=replay.bin \
    -cdrom nyx.iso -serial stdio -display none -s -S
```

The intermittent race that shows up once in fifty boots becomes a file you can
step through repeatedly, and *backwards* (`reverse-continue` works with the
replay backend). Chapter 13 §C6 makes the case for pushing this further into the
kernel's own design; even without that, `-icount` alone is available to you today
and almost nobody building a hobby kernel knows it exists.

Caveat: `-icount` and KVM are mutually exclusive, and record/replay support for
some devices is incomplete. Use it as a debugging mode, not as your default.

### 7.4 A poor man's KASAN

You already have the pieces from Chapter 05: slab red zones and poison. Add
quarantine (don't reuse a freed object immediately — keep the last 512 frees in a
FIFO) and you catch most use-after-frees within a few thousand operations. Full
shadow-memory KASAN needs compiler support (`-fsanitize=kernel-address` plus a
shadow mapping and `__asan_load*` hooks); it's roughly a week and it's a
reasonable project, but the 90% version is an afternoon.

---

## 8. Fault injection and chaos

Chapter 11 built a reincarnation server. This is how you find out whether it
works.

```c
/* kernel/test/inject.c — deterministic, seeded, controllable from userspace */
struct fault_injector {
    uint32_t seed;
    uint32_t alloc_fail_per_million;   /* pmm/slab allocation failures       */
    uint32_t ipc_delay_per_million;    /* inject a reschedule mid-IPC        */
    uint32_t irq_storm_per_million;    /* extra spurious interrupts          */
};

bool inject_should_fail(uint32_t rate) {
    if (!rate) return false;
    return (prng_next(&injector.seed) % 1000000u) < rate;
}
```

Then in the allocator: `if (inject_should_fail(injector.alloc_fail_per_million))
return 0;`. This tests every error path you wrote and never exercised — which, in
most kernels, is where the bugs live, because error paths are written once and
read never.

The chaos scenario worth running nightly:

1. Boot the full system with 6 servers and a workload generator.
2. Every 500 ms, pick a random non-essential server and kill it (fault-inject a
   #GP, or have the RS `TCB_Suspend` and revoke its Untyped).
3. Assert continuously: the workload still completes; no client hangs forever;
   **and total free memory returns to within 64 KiB of its pre-kill value.**
4. Run for an hour. Graph free memory over time.

That third assertion is the one that finds real bugs. Restart loops leak, and a
leak of 4 KiB per restart is invisible in a 30-second test and fatal in a
week-long deployment. If the graph has a slope, you have a bug.

---

## 9. Coverage

```bash
# QEMU can log every executed translation block; map them back to lines.
qemu-system-x86_64 -d exec -D exec.log ...
tools/cov.py exec.log nyx.elf > coverage.txt
```

Cruder than gcov but it works on a bare-metal kernel with no runtime. Host tests
give you proper `--coverage` for the pure subsystems, which is where you most
want the number anyway.

Do not chase a percentage. Use coverage for one specific question: **which error
paths have never executed?** Sort uncovered lines by "is this an error path", and
you have your fault-injection to-do list.

---

## 10. Continuous integration

| Job | Trigger | Budget | Contents |
|---|---|---|---|
| `quick` | every push | < 2 min | build (clang + gcc, `-Werror`), host unit tests under ASan/UBSan, ABI header grep, ktest suite in QEMU |
| `full` | every PR | < 15 min | quick + userspace integration tests + lockdep build + SMP 1/2/4/8 configs + 60 s fuzz per target |
| `bench` | every merge to main | < 10 min | benchmark suite under KVM, compare to baseline, publish table |
| `nightly` | 02:00 | hours | 1 h chaos, 30 min per fuzz target with corpus update, CBMC/TLC model checks, coverage report, `-icount` replay smoke test |

The `quick` job's two-minute budget is a hard constraint, not an aspiration. Once
the edit-test loop exceeds a few minutes, people stop running it locally and
start pushing to CI to find out — and the moment that happens, CI stops being a
safety net and becomes a queue.

One more CI rule worth adopting: **build with both clang and gcc.** They disagree
about undefined behaviour in ways that surface real bugs, and a kernel that only
builds with one compiler has accidentally encoded that compiler's opinions into
its correctness.

---

## 11. Verification checklist for this chapter

- [ ] `make test` runs host tests, boots QEMU, runs KTESTs and userspace tests, exits 0
- [ ] A deliberately broken test causes exit 1; an infinite loop causes exit 2; an early panic causes exit 3
- [ ] `make bench` prints the table and compares against `tools/baselines/`
- [ ] The trace ring can be dumped and rendered in Perfetto
- [ ] `panic()` prints registers, page walk, symbolized backtrace, trace tail, and log tail
- [ ] Three fuzz targets build and run; corpora are committed
- [ ] The chaos test runs for an hour with flat memory usage
- [ ] CI runs all of the above on a schedule and someone notices when it goes red

---

## 12. Exercises

1. Build the ktest harness and the runner script. Deliberately break three tests
   in different ways (assertion, hang, panic) and confirm you get three distinct
   exit codes and useful output for each.
2. Add tracing to the IPC path with the mask check. Measure the fast path with
   tracing disabled and enabled; report both numbers. If the disabled cost is
   more than ~5 cycles, find out why and fix it.
3. Write the trace decoder and render a full `read()` through your VFS in
   Perfetto. Write down the three largest gaps you see and what causes each.
4. Write the `fuzz_elf_load` target. Run it for one hour. Report what it found.
   If it found nothing, inject a deliberate off-by-one and confirm the fuzzer
   finds it within a minute — otherwise your harness isn't reaching the code.
5. Set up `-icount` record/replay. Record a boot, replay it under GDB, and set a
   watchpoint that fires during the replay. Then reverse-continue from it.
6. Implement fault injection in the allocator and run your existing test suite
   with a 1-in-1000 failure rate. Count how many tests fail. That count is a
   measure of how much of your error handling has never been exercised.
7. **Argue the other side**: make the case that all of this is premature, that a
   solo developer should write the kernel first and the harness later, and that
   instrumentation built before the thing it instruments will be built wrong.
   Then decide honestly which parts of this chapter you'd genuinely defer, and
   write down the trigger condition that says "now build it".

---

Next: [19 — Roadmap, milestones, and the things people forget](19-roadmap-and-gaps.md)
