# 10 — Crossing the ring: syscalls, userspace, and the ELF loader

> Goal: a user process, loaded from an ELF in the initrd, running in ring 3, that
> makes a syscall, receives a reply, and page-faults into a userspace pager. Plus
> the stub generator that keeps your IPC protocols from becoming a swamp.

---

## 1. Theory: the kernel/user boundary as a trust boundary

Everything that crosses from ring 3 to ring 0 is attacker-controlled. The design
goal is to make the surface as small and as *shallow* as possible:

- **Small**: few syscalls, few arguments.
- **Shallow**: the kernel should not *dereference* what userspace supplies. In
  Nyx, syscall arguments are register values and capability indices. A capability
  index is validated by a bounds check against a kernel-owned table — it is not a
  pointer. This eliminates the entire "user pointer" vulnerability class.

Compare: Linux has ~350 syscalls, many taking pointers to variable-sized
structures with union members and flags that change interpretation. That's where
its kernel CVEs come from. Nyx has ~13 syscalls, all register-only.

### The one place we do touch user memory

The IPC buffer, if you implement long messages. Consider *not* implementing them:
if all IPC is register-only plus shared frames that userspace maps itself, the
kernel never dereferences a user address. That's a strong property. It costs you
some convenience in servers. **Recommendation: try to hold this line.** If you
break it, document exactly where and why.

---

## 2. Setting up `syscall`/`sysret`

```c
/* arch/x86_64/syscall.c */
#define MSR_STAR   0xC0000081
#define MSR_LSTAR  0xC0000082
#define MSR_FMASK  0xC0000084

extern void syscall_entry(void);

void syscall_init(void) {
    /* EFER.SCE was set in the boot stub. */

    /* STAR[47:32] = kernel CS for syscall (SS = that + 8)
       STAR[63:48] = base for sysret: user CS = base+16, user SS = base+8 */
    wrmsr(MSR_STAR, ((uint64_t)SEL_KCODE << 32) |
                    ((uint64_t)(SEL_UDATA - 8) << 48));

    wrmsr(MSR_LSTAR, (uint64_t)syscall_entry);

    /* Bits cleared in RFLAGS on entry. Clearing IF is essential (we have no
       kernel stack yet at the first instruction). Clearing DF is required by
       the SysV ABI. Clear AC too, or a malicious user could set it and defeat
       SMAP for the whole syscall. */
    wrmsr(MSR_FMASK, RFLAGS_IF | RFLAGS_DF | RFLAGS_AC | RFLAGS_TF | RFLAGS_NT);

    /* Per-CPU pointer in KERNEL_GS_BASE; swapgs brings it into GS. */
    wrmsr(MSR_KERNEL_GS_BASE, (uint64_t)this_cpu());
}
```

Note `SEL_UDATA - 8`: since `SEL_UDATA` is 0x18 and `sysret` computes SS as
`base + 8`, base must be 0x10. And user CS = 0x10 + 16 = 0x20 = `SEL_UCODE`. The
RPL bits (|3) are added by the CPU. Verify with a `_Static_assert`.

### The entry stub

```nasm
; arch/x86_64/entry.asm
;
; On entry from `syscall`:
;   RCX = user RIP (saved by the CPU)
;   R11 = user RFLAGS (saved by the CPU)
;   RSP = still the USER stack — we must switch immediately
;   Interrupts are OFF (FMASK cleared IF)
;
; Our syscall ABI:
;   RAX = syscall number
;   RDI = capability pointer
;   RSI = message info (label | nwords | ncaps)
;   RDX, R10, R8, R9 = message words 0..3
;   R12, R13 = message words 4..5   (callee-saved in SysV, so libc stubs
;                                     must save them; worth it for 6 words)

global syscall_entry
syscall_entry:
    swapgs                              ; GS now points at per-CPU data
    mov     [gs:CPU_USER_RSP], rsp
    mov     rsp, [gs:CPU_KERNEL_RSP]    ; = current TCB's kernel stack top

    ; Build a partial frame. We do NOT push everything: SysV says
    ; caller-saved registers are already dead from the caller's perspective,
    ; so a syscall only needs to preserve callee-saved ones plus RCX/R11
    ; (the return address and flags).
    push    qword [gs:CPU_USER_RSP]
    push    r11                         ; user RFLAGS
    push    rcx                         ; user RIP
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    cld

    ; --- Try the IPC fast path (Ch.08) before doing anything expensive. ---
    cmp     eax, SYS_CALL
    je      ipc_fastpath_call
    cmp     eax, SYS_REPLYRECV
    je      ipc_fastpath_replyrecv

.slow:
    mov     rcx, r10                    ; SysV 4th arg (syscall clobbered RCX)
    ; args now: rdi, rsi, rdx, rcx, r8, r9  → matches syscall_dispatch()
    call    syscall_dispatch

.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    pop     rcx                         ; user RIP
    pop     r11                         ; user RFLAGS
    pop     rsp                         ; user RSP

    swapgs
    o64 sysret                          ; `sysretq`
```

### Hazards, each of which is a real CVE class

1. **`sysret` and non-canonical RIP.** On Intel, `sysret` with a non-canonical
   RCX causes a #GP **in ring 0 with the user stack loaded** — a privilege
   escalation (CVE-2012-0217, affecting Xen, FreeBSD, NetBSD, Windows). If any
   path lets userspace control the return RIP (e.g. after `ptrace`-like register
   setting), you must check canonicality and fall back to `iretq`:

   ```nasm
       mov     rdx, rcx
       sar     rdx, 47
       inc     rdx                 ; 0 or 1 if canonical
       cmp     rdx, 1
       ja      .use_iretq
   ```

2. **`swapgs` imbalance.** Every path out must `swapgs` exactly once. Use a
   single exit label; don't scatter `sysret`s.

3. **`sysret` doesn't restore SS's descriptor cache correctly on some CPUs.**
   In practice, load SS explicitly if you're paranoid, or use `iretq` for
   non-fast paths.

4. **Not clearing scratch registers on exit.** R10, R8, R9, RDX, RSI, RDI hold
   kernel values when you return. That's an information leak (kernel pointers →
   defeats KASLR). Zero them on exit unless they carry a return value.

5. **`RFLAGS.AC` set by userspace** persists into the kernel and disables SMAP.
   Clearing it in FMASK closes this.

---

## 3. Dispatch

```c
long syscall_dispatch(long nr, long a1, long a2, long a3, long a4, long a5) {
    struct tcb *t = current;
    t->syscall_count++;

    switch (nr) {
    case SYS_CALL:      return ipc_call(t, a1, msg_from_regs(a2, a3, a4, a5));
    case SYS_SEND:      return ipc_send(t, a1, ...);
    case SYS_RECV:      return ipc_recv(t, a1, ...);
    case SYS_REPLYRECV: return ipc_replyrecv(t, a1, ...);
    case SYS_NBSEND:    return ipc_nbsend(t, a1, ...);
    case SYS_SIGNAL:    return notify_signal_cap(t, a1, a2);
    case SYS_WAIT:      return notify_wait_cap(t, a1);
    case SYS_POLL:      return notify_poll_cap(t, a1);
    case SYS_YIELD:     sched_yield(); return 0;
    case SYS_INVOKE:    return cap_invoke(t, a1, a2, a3, a4, a5);
#ifdef CONFIG_DEBUG_SYSCALLS
    case SYS_DEBUG:     return debug_syscall(t, a1, a2);
#endif
    default:            return -ENOSYS;
    }
}
```

> **`include/abi/syscall.h` is the specification, not the list above.** This
> chapter is prose about a design; that header is what a userspace stub
> actually compiles against, so where the two differ the header wins and this
> chapter is the thing to patch. The list is the intended *end state*: a
> kernel implements the subset it can currently honour and adds numbers as
> the objects behind them arrive. Publishing a number for something
> unimplemented is worse than omitting it, because a stub will be written
> against it.
>
> The same applies to §2's register mapping. It names six message words
> (`RDX/R10/R8/R9/R12/R13`), but R12 and R13 are callee-saved under SysV, so
> carrying words there obliges every stub to save and restore them. A
> transport that carries **four** words, all in caller-saved registers, is a
> defensible choice — and note that the transport width is *not* the same
> number as `MSG_MAX_WORDS`: the kernel's message buffer may be larger than
> what a syscall can carry, with the remainder simply unreachable from ring 3
> until something needs it enough to pay for the saves. Whichever you pick,
> the number lives in the ABI header, and a mismatch with this chapter is a
> bug in the chapter.

`SYS_INVOKE` is the escape hatch that keeps the syscall count low: object-specific
methods are dispatched on the *capability type*, not on a syscall number.

```c
long cap_invoke(struct tcb *t, cptr_t cp, word_t method, word_t a, word_t b, word_t c) {
    struct cap *cap = cap_lookup(t->cspace_root, cp, 64);
    if (!cap) return -EBADCAP;

    switch (cap_type(cap)) {
    case CAP_UNTYPED:   return untyped_invoke(t, cap, method, a, b, c);
    case CAP_TCB:       return tcb_invoke(t, cap, method, a, b, c);
    case CAP_CNODE:     return cnode_invoke(t, cap, method, a, b, c);
    case CAP_FRAME:     return frame_invoke(t, cap, method, a, b, c);
    case CAP_PAGETABLE: return pt_invoke(t, cap, method, a, b, c);
    case CAP_IRQCTRL:   return irqctrl_invoke(t, cap, method, a, b, c);
    case CAP_IRQHANDLER:return irqhandler_invoke(t, cap, method, a, b, c);
    case CAP_IOPORT:    return ioport_invoke(t, cap, method, a, b, c);
    default:            return -EINVAL;
    }
}
```

---

## 4. Building the first user thread

```c
struct tcb *user_thread_create(struct vspace *as, vaddr_t entry, vaddr_t stack,
                               struct cnode *cspace, struct endpoint *fault_ep) {
    struct tcb *t = tcb_alloc();
    t->vspace      = as;
    t->cspace_root = cspace;
    t->fault_ep    = fault_ep;

    /* The frame that iretq will consume to enter ring 3. */
    uint8_t *sp = t->kstack_top;
    sp -= sizeof(struct iret_frame);
    struct iret_frame *f = (void *)sp;
    f->ss     = SEL_UDATA | 3;
    f->rsp    = stack;
    f->rflags = 0x202;            /* IF set, reserved bit 1 set */
    f->cs     = SEL_UCODE | 3;
    f->rip    = entry;

    /* Then the switch frame, so context_switch() `ret`s into the trampoline. */
    sp -= sizeof(struct switch_frame);
    struct switch_frame *sf = (void *)sp;
    memset(sf, 0, sizeof(*sf));
    sf->rip = (uint64_t)enter_userspace;
    t->ksp = sp;

    t->state = TS_INACTIVE;       /* explicit resume required */
    return t;
}
```

```nasm
global enter_userspace
enter_userspace:
    ; The iret frame is exactly at RSP now (the switch frame was popped).
    xor     eax, eax              ; scrub registers so we leak nothing
    xor     ebx, ebx
    xor     ecx, ecx
    xor     edx, edx
    xor     esi, esi
    xor     edi, edi
    xor     ebp, ebp
    xor     r8d, r8d
    ; ... r9-r15 ...
    swapgs
    iretq
```

**Scrubbing registers before entering ring 3 is not optional.** Whatever was in
them is kernel state.

---

## 5. Loading an ELF

### The initrd

The simplest useful format is a **CPIO newc archive** or a tiny custom one. CPIO
is well-supported (`find . | cpio -o -H newc > initrd.img`), or write 40 lines:

```c
struct nyxfs_hdr  { char magic[8]; uint32_t count; uint32_t reserved; };
struct nyxfs_ent  { char name[56]; uint64_t offset, size; };
```

GRUB loads it as a Multiboot2 module; Limine as a module. It lands in physical
memory; you map it (read-only) and parse.

### The loader

```c
/* Runs in the root task (userspace!) in the final design.
   During bring-up you may do it in the kernel; plan to move it. */

int elf_load(const void *img, size_t len, struct vspace *as,
             vaddr_t *out_entry) {
    const Elf64_Ehdr *eh = img;

    if (memcmp(eh->e_ident, "\x7f""ELF", 4)) return -ENOEXEC;
    if (eh->e_ident[EI_CLASS] != ELFCLASS64) return -ENOEXEC;
    if (eh->e_machine != EM_X86_64)          return -ENOEXEC;
    if (eh->e_type != ET_EXEC && eh->e_type != ET_DYN) return -ENOEXEC;
    if (eh->e_phoff + eh->e_phnum * sizeof(Elf64_Phdr) > len) return -ENOEXEC;

    const Elf64_Phdr *ph = (const void *)((const char *)img + eh->e_phoff);

    for (unsigned i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type != PT_LOAD) continue;
        if (ph[i].p_offset + ph[i].p_filesz > len) return -ENOEXEC;
        if (ph[i].p_filesz > ph[i].p_memsz)        return -ENOEXEC;
        if (!canonical_user(ph[i].p_vaddr))        return -ENOEXEC;

        uint64_t flags = PTE_P | PTE_U;
        if (ph[i].p_flags & PF_W) flags |= PTE_W;
        if (!(ph[i].p_flags & PF_X)) flags |= PTE_NX;
        if ((flags & PTE_W) && !(flags & PTE_NX)) return -EPERM;  /* W^X */

        vaddr_t start = ALIGN_DOWN(ph[i].p_vaddr, PAGE_SIZE);
        vaddr_t end   = ALIGN_UP(ph[i].p_vaddr + ph[i].p_memsz, PAGE_SIZE);

        for (vaddr_t v = start; v < end; v += PAGE_SIZE) {
            paddr_t f = pmm_alloc();                    /* zeroed → .bss free */
            size_t off_in_seg = v - ph[i].p_vaddr;
            if (off_in_seg < ph[i].p_filesz) {
                size_t n = MIN(PAGE_SIZE, ph[i].p_filesz - off_in_seg);
                memcpy(P2V(f), (const char *)img + ph[i].p_offset + off_in_seg, n);
            }
            vspace_map(as, v, f, flags);
        }
    }
    *out_entry = eh->e_entry;
    return 0;
}
```

Note every bounds check. An ELF loader that trusts its input is a remote code
execution vulnerability. Since ours runs in userspace (the root task) rather than
the kernel, a bug is contained — which is itself a nice illustration of the
architecture's value.

**Handle the partial page at the end of a segment**: `p_memsz > p_filesz` means
the tail is `.bss`. If you allocate zeroed frames you get this free, *but* the
partial page where file data ends mid-page must have its remainder zeroed — it
will be, if the frame came zeroed and you only copied `p_filesz` bytes.

---

## 6. The user runtime: `libnyx`

Keep it minimal. It is not a libc; it is a syscall and IPC layer.

```c
/* user/libnyx/include/nyx.h */

static inline long nyx_call(cptr_t ep, message_t *m) {
    register long rax __asm__("rax") = SYS_CALL;
    register long rdi __asm__("rdi") = ep;
    register long rsi __asm__("rsi") = msginfo_pack(m);
    register long rdx __asm__("rdx") = m->w[0];
    register long r10 __asm__("r10") = m->w[1];
    register long r8  __asm__("r8")  = m->w[2];
    register long r9  __asm__("r9")  = m->w[3];

    __asm__ volatile("syscall"
        : "+r"(rax), "+r"(rsi), "+r"(rdx), "+r"(r10), "+r"(r8), "+r"(r9)
        : "r"(rdi)
        : "rcx", "r11", "memory");

    m->label = rax; m->badge = rsi;
    m->w[0] = rdx; m->w[1] = r10; m->w[2] = r8; m->w[3] = r9;
    return rax;
}
```

The `register ... __asm__("...")` form is the reliable way to pin values to
specific registers. `"rcx", "r11"` in the clobber list is mandatory — `syscall`
destroys them.

Beyond that, `libnyx` provides:

- `nyx_send/recv/replyrecv/signal/wait/poll`
- Capability operations: `nyx_cnode_copy`, `nyx_untyped_retype`, ...
- A tiny allocator over a memory-server-provided heap
- `printf` routed to the console server (or, in early bring-up, to a debug
  syscall)
- Thread creation helpers
- The generated IPC stubs (§7)

**Do not port glibc or musl yet.** Adding POSIX is a Chapter-13 decision with big
consequences. Start with your own minimal surface; you'll understand what POSIX
actually requires far better afterward.

---

## 7. The IDL and stub generator — build this early

Hand-writing message marshalling is how microkernel projects rot. Every server
invents its own convention, argument order drifts between client and server, and
you get silent corruption.

Define a tiny IDL:

```
// user/idl/vfs.idl
interface VFS {
    method open(string path, u32 flags) -> (cap handle, i32 err);
    method read(cap handle, u64 offset, u32 len) -> (buf data, i32 err);
    method close(cap handle) -> (i32 err);
    method stat(cap handle) -> (u64 size, u32 mode, i32 err);
}
```

A ~300-line Python generator emits:

- `vfs_client.h` — `int vfs_open(cptr_t ep, const char *path, uint32_t flags, cptr_t *out)`
- `vfs_server.h` — a dispatch function that decodes the message, calls your
  `vfs_impl_open(...)`, and encodes the reply
- A method-number enum shared by both
- `_Static_assert`s that arguments fit in the available words

Rules the generator enforces:

- Every method gets a unique, *stable* number. Never renumber; only append.
- Arguments that don't fit in 6 words must be declared as `buf`, which the
  generator implements via a shared-frame ring or a grant — chosen by an
  annotation, not by whoever writes the server that day.
- The server dispatcher validates `nwords` and `ncaps` before touching anything.
- An interface version word in the label, checked on both sides.

This is a half-day of work that pays back within two weeks and prevents an entire
category of bug. Do it before you have three servers, not after.

---

## 8. Bootstrapping the system: the root task

Once the kernel can create user threads, it does one more thing and then never
allocates again: it constructs the **root task**.

```c
void start_root_task(void) {
    struct vspace *as = vspace_create(boot_src);
    vaddr_t entry;
    elf_load(initrd_find("root"), &as, &entry);

    struct cnode *cs = cnode_create(12);     /* 4096 slots */

    /* Hand over the world. */
    unsigned slot = 1;
    cap_init(&cs->slots[slot++], as,  CAP_VSPACE, RIGHTS_ALL);
    cap_init(&cs->slots[slot++], cs,  CAP_CNODE,  RIGHTS_ALL);
    cap_init(&cs->slots[slot++], tcb, CAP_TCB,    RIGHTS_ALL);
    cap_init(&cs->slots[slot++], irq_control,  CAP_IRQCTRL, RIGHTS_ALL);
    cap_init(&cs->slots[slot++], io_port_all,  CAP_IOPORT,  RIGHTS_ALL);

    /* Every free physical region becomes an Untyped capability. */
    for (each free buddy block b)
        cap_init(&cs->slots[slot++], untyped_from(b), CAP_UNTYPED, RIGHTS_ALL);

    /* And a description of what we just gave it, in a mapped page. */
    struct bootinfo_user *bi = map_bootinfo_page(as);
    bi->untyped_start = ...; bi->untyped_count = ...;
    bi->initrd_frames_start = ...; /* so root can load other servers */

    thread_resume(tcb);
}
```

The root task then:

1. Reads `bootinfo` to learn what it holds.
2. Sets up its own allocator over its Untypeds.
3. Loads the other servers from the initrd (each gets a VSpace, CSpace, TCB,
   Untyped budget, and endpoint capabilities).
4. Wires the system together: gives the VFS an endpoint to the ramdisk driver,
   gives applications endpoints to the VFS, etc.
5. Becomes the reincarnation server, or hands that role over.

**This program is the security policy of your entire system**, expressed as code
that distributes capabilities. It deserves as much design care as the kernel. In
a mature system it's often driven by a declarative description (seL4's CAmkES
does exactly this — a component description language that generates the
initialization code and the CSpace layout, statically). Consider generating it
from a manifest:

```toml
[server.vfs]
binary = "vfs.elf"
untyped = "4M"
priority = 200
endpoints_out = ["ramdisk", "console"]
endpoints_in  = ["app.*"]
```

That manifest *is* your system architecture, machine-readable and diffable.

---

## 9. Verification

- [ ] A user program executes `syscall` and gets a reply.
- [ ] The program cannot execute `cli` (gets #GP → fault message to its pager).
- [ ] The program cannot read kernel memory (gets #PF, not data).
- [ ] The program cannot write to its own `.text` (W^X enforced).
- [ ] A null dereference produces a fault IPC to the pager, which resolves it,
      and the program continues.
- [ ] Registers are scrubbed: dump every register at the start of `main`, and
      confirm no kernel addresses.
- [ ] Two user processes cannot see each other's memory (map the same virtual
      address in both, write different values, check).
- [ ] A user process that spins is preempted (a second process makes progress).

```c
KTEST(syscall_roundtrip_cycles) {
    uint64_t t0 = rdtsc();
    for (int i = 0; i < 100000; i++) nyx_yield();
    uint64_t t1 = rdtsc();
    kprintf("null syscall: %lu cycles\n", (t1 - t0) / 100000);
    /* Expect 80-200 under KVM. If it's 2000, find out why. */
}
```

---

## 10. Exercises

1. Implement the `sysret` canonical-RIP check and write a test that a user
   program setting a non-canonical RIP (via a fault handler that modifies its own
   context) does not escalate.
2. Compare the cost of `syscall`/`sysret` against `int 0x80`/`iretq` by
   implementing both entry paths. Report the cycle difference.
3. Write the IDL generator. Start with 100 lines of Python that handles only
   fixed-size scalar arguments; extend from there.
4. Move the ELF loader from the kernel to the root task. What capabilities does
   the root task need to do it? (Answer: Untyped, a VSpace capability for the
   target, Frame capabilities, and read access to the initrd frames.)
5. Design the manifest format for system composition and write the generator that
   turns it into root-task initialization code. This is your CAmkES.

---

Next: [11 — Servers and userspace drivers](11-servers-and-drivers.md)
