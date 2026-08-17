# 29 — Virtualization as a first-class concept

> Goal: stop treating virtualization as a subsystem bolted onto an OS. A
> microkernel and a hypervisor are the same thing at different interface levels;
> unify them. A VM becomes a component whose ABI happens to be "virtual hardware"
> instead of "syscalls", and the convergence between a microkernel component and a
> unikernel turns out to be nearly total.

---

## 1. The thesis: a hypervisor is a microkernel with a different ABI

Both isolate mutually distrusting computations. Both multiplex CPU, memory, and
devices. Both mediate communication. The differences:

| | Microkernel | Hypervisor |
|---|---|---|
| Isolation unit | Process / component | Virtual machine |
| Interface offered | Syscalls / capability invocations | Virtual hardware (CPUID, MSRs, MMIO, interrupts) |
| Address translation | Page tables | Nested page tables (EPT/NPT) |
| Communication | IPC | Virtual devices, shared memory |
| Scheduling unit | Thread | vCPU |

That's a difference of *interface*, not of *structure*. NOVA (Steinberg & Kauer,
EuroSys 2010) made this argument concrete: a ~9 kLOC microhypervisor with the VMM
in userspace, one per VM. seL4 later added VM support the same way. Both are
microkernels that also do virtualization, with essentially no additional kernel
mechanism.

**The Nyx position:** add exactly two object types and change nothing else.

```
VCPU     — a schedulable entity whose execution context is a guest state area
           (VMCS/VMCB). Invoking VCPU_Run enters the guest.
VSpace   — extended with a "guest" variant backed by EPT/NPT instead of ordinary
           page tables. Frame_Map into it works identically.
```

A VM exit is delivered as a **message to the VMM's endpoint**, containing the exit
reason and the relevant guest state. The VMM is an ordinary userspace component
holding a `VCPU` capability. It handles the exit — emulating a device, injecting an
interrupt, mapping a page — and resumes the guest.

Consequences that fall out for free:

- The VMM is **restartable** (Chapter 11 §6). A crash in device emulation doesn't
  take the VM with it, if the VMM keeps its state externally.
- The VMM is **confined** by capabilities: it can touch exactly the memory and
  devices it was given. Compare QEMU, which historically ran with far more
  authority than the guest it emulated, and produced a long CVE list to match.
- The VM is **schedulable like anything else**: a `SchedContext` (Chapter 14)
  applies to a vCPU, so real-time guarantees extend into guests.
- Device passthrough is the IOMMU work from Chapter 11 §5.3, unchanged.

Estimated kernel cost: a few thousand lines for VMX/SVM setup, exit decoding, and
guest state save/restore. That's a very small price for what §2 buys.

---

## 2. Why it's worth doing early

**You get software.** Running Linux as a guest means your OS has a browser, a
compiler, and a package manager on day one. Every serious new OS project either
does this or spends years porting userland. It also gives you a credibility
milestone that people understand instantly.

**You get a comparison baseline.** Appendix E §E1 wants an honest microkernel-cost
measurement. Running the *same* workload native and in a guest on the same kernel
gives you a controlled comparison that no cross-system benchmark can.

**You get the compatibility story without polluting the design.** Chapter 13 §D5
worries about how much POSIX to provide. With virtualization, the answer can be
"none in the native ABI; run Linux in a VM for legacy software, and provide
high-bandwidth channels between the two." That keeps the native interface clean —
which is exactly the mistake Windows NT avoided and then made anyway with its
subsystems.

**It's the datacenter's unit of deployment.** Chapter 28's cluster nodes will run
guests whether you like it or not.

---

## 3. The convergence: components and unikernels

Here's the observation that makes this chapter more than "add a hypervisor."

A **unikernel** is an application linked with a minimal library OS, running alone
in a VM: no processes, no syscalls, one address space, one purpose. MirageOS,
IncludeOS, OSv, Unikraft.

A **Nyx component** is an application with a minimal library (libnyx), running
alone in an address space, with capabilities instead of ambient authority: no
processes inside it, one purpose.

These are the same shape. The differences:

| | Unikernel | Nyx component |
|---|---|---|
| Interface | Virtual hardware (virtio) | Capability invocations (IPC) |
| Isolation | Nested page tables | Page tables |
| Boot | A hypervisor loads an image | The root task instantiates it |
| Communication | Virtual NICs, shared memory | IPC, rings |
| Size | 1–20 MB | 50 KB–5 MB |
| Startup | ~10–100 ms | ~1 ms |

**So a unikernel is a component with a worse interface and a fatter boot path.**
The reason unikernels exist is that the *only* isolation primitive available in a
cloud is the VM, so people made VMs cheap and small. Given a real component model
with real isolation, the VM wrapper is unnecessary overhead.

This is worth stating as a claim because it's testable: implement the same service
as a unikernel guest and as a native component, and measure startup time, memory,
and per-request latency. If the component wins substantially, that's an argument
about how the cloud should be built.

### 3.1 Which suggests a spectrum, not a binary

Make the isolation mechanism a *deployment-time choice* over one component model:

| Mechanism | Isolation | Cost | Use when |
|---|---|---|---|
| Language / verified bytecode (WASM) | Compiler-enforced | ~0 (function call) | Trusted-ish, dense multi-tenancy, untrusted plugins |
| Same address space, MPU | Coarse hardware | ~0 | N0 (Chapter 27) |
| Address space + capabilities | Full hardware | ~1 µs IPC | Default |
| Address space + IOMMU + no shared cache | Full + side-channel | Higher | Hostile tenants |
| VM (nested paging) | Full + different ABI | ~10 µs, MB of memory | Legacy software, or a foreign OS |
| VM + confidential computing (SEV-SNP/TDX) | Full + host-opaque | Higher still | You don't trust the operator |

**One component, one manifest, six possible enforcement mechanisms, chosen at
deployment.** That's a genuinely novel systems capability, and I don't know of a
system that offers it. It's also the natural answer to Appendix E §E20 ("what
replaces the process?"): the unit is a component, and isolation strength is a
deployment parameter rather than a design-time commitment.

---

## 4. Virtio, in both directions

Adopt virtio as the device interface, and notice that you need it *twice*:

- **Frontends** (drivers), so Nyx runs as a guest under QEMU/KVM/cloud
  hypervisors. This is how you actually deploy anywhere.
- **Backends** (device emulation), so Nyx hosts guests.

Both sides are the same protocol: virtqueues are SPSC rings with a notification —
i.e. exactly Chapter 15's model. So a virtio backend is a component consuming a
ring, and a virtio frontend is a component producing one. **Much of the code is
shared, and all of it is code you already wrote.**

This is a good example of an abstraction paying off: choosing rings as the I/O
primitive in Chapter 15 makes virtio, RDMA (Chapter 28 §5.1), io_uring-style
submission, and device emulation all instances of one thing.

**vhost-user** deserves a look: it moves virtio backends into separate processes
communicating over shared memory. That's a microkernel design, invented inside
Linux, because people needed isolation for device emulation. It's evidence for the
architecture, and its protocol is a reasonable model to copy.

---

## 5. Nyx as a guest

Being a good guest matters more than being a good host, for a project at this
stage — it's how you run on any cloud, any laptop, any CI runner.

What it requires:

- **Detect virtualization** (CPUID leaf 0x40000000) and identify the hypervisor.
- **Paravirtual time**: don't calibrate the TSC against the PIT under a
  hypervisor; read the KVM/Hyper-V clock page. Guest TSC can be scaled, offset,
  and can jump across migration.
- **Paravirtual interrupts, spinlocks, and IPIs.** A guest spinning on a lock
  whose holder is descheduled wastes an entire timeslice — the classic "lock
  holder preemption" problem. Use PV spinlocks (yield to the hypervisor) or
  measure how badly it hurts.
- **Ballooning and memory hotplug**, if you want to be a well-behaved cloud
  tenant.
- **Virtio drivers** for block, net, gpu, input, console, rng, and vsock. This is
  the practical minimum and it's also a nice, well-specified driver-writing
  exercise.
- **Kexec-style boot** or direct kernel boot so you don't need a bootloader in a
  cloud image.

Also: **use the guest's `rng` device to seed your CSPRNG** (Appendix D §3), and
handle the VM-generation-ID change on clone or snapshot restore, or two clones
generate identical keys.

---

## 6. Live migration

Migrating a running VM (or component — Chapter 28 §6) between machines:

1. Pre-copy memory while it runs, iterating on dirty pages.
2. When the dirty rate is low enough, pause, copy the remainder plus device and
   CPU state, resume on the target.
3. Or post-copy: resume immediately on the target and fault pages across on
   demand — lower downtime, but a network failure now kills the VM.

What you need from the kernel: **dirty-page tracking** (the D bit in EPT, or
write-protect and count faults) and a way to serialize vCPU and device state.

The capability angle: a *component's* migration (Chapter 28 §6) is easier than a
VM's, because its external references are enumerable capabilities rather than an
opaque tangle of kernel state. Demonstrating "component migration is 10× simpler
and 10× faster than VM migration" would be a clean, convincing result.

---

## 7. Confidential computing

Chapter 13 §B3 introduced it; here's where it lands architecturally.

AMD SEV-SNP, Intel TDX, and Arm CCA all let a guest run such that the *hypervisor*
cannot read its memory, with remote attestation of what's running. Structurally
these are all **microkernel-shaped**: a tiny trusted layer isolating parties who
distrust each other, with the large legacy component moved outside the TCB.

For Nyx, two roles:

- **As a guest**: run inside a confidential VM, so the cloud operator can't read
  you. Requires handling the encryption bit in physical addresses (Appendix B §6 —
  it breaks naive `P2V`/`V2P`), a validated memory model, and attestation.
- **As a host**: offer confidential components. This is where it gets
  interesting — a capability system can attest not just *what code* is running but
  *what authority it holds*, which is a strictly stronger and more useful statement
  than a code measurement alone. No existing attestation scheme can express "this
  component can only reach these three services," and it's exactly what a
  capability manifest is.

That's a real research opportunity (Appendix E §E4 extended across machines).

---

## 8. Verification

| Test | Asserts |
|---|---|
| `guest_boots` | A minimal guest (or Linux) boots to userspace under your VMM |
| `vmexit_roundtrip_cycles` | Exit → VMM → resume, measured; expect 2–10 µs. Track in CI. |
| `vmm_crash_isolated` | Kill the VMM mid-execution; the kernel and other VMs are unaffected |
| `vmm_confinement` | The VMM cannot touch memory outside the guest's frames; attempt it |
| `nested_paging_correct` | Guest-physical → host-physical mappings; fuzz them |
| `nyx_guest_under_kvm` | Nyx boots and passes its own test suite as a KVM guest. **Run this in CI on every commit** — it's how you stay deployable. |
| `pv_clock_monotonic` | Guest time never goes backwards across a migration |
| `component_vs_unikernel` | The §3 measurement: same service, both ways, startup/memory/latency |
| `isolation_spectrum` | The same component runs under each mechanism in §3.1 and passes its tests |

That last one is the ambitious one and it's the proof of the chapter's thesis. If
one component binary (or one source tree) runs as a WASM module, a native
component, and a VM guest, and passes identical tests in all three, you have
something nobody else has.

---

## 9. Exercises

1. Implement `VCPU` and a guest `VSpace`. Boot a guest that does nothing but
   `hlt`, and observe the exit in your VMM.
2. Extend it until a Linux kernel boots to a serial console. Note how much of the
   work was device emulation rather than CPU virtualization.
3. Measure `vmexit_roundtrip_cycles` and compare to KVM's. Explain any difference.
4. Get Nyx booting as a guest under QEMU/KVM with virtio drivers, and wire that
   into CI.
5. Implement one virtio device as both frontend and backend. Measure how much code
   is shared.
6. Do the §3 unikernel-vs-component measurement for a simple HTTP service. Write
   up the result honestly.
7. **Argue the other side:** make the case that adding virtualization to the
   kernel violates minimality (Chapter 00) — that VMX handling is policy, that it
   doubles the kernel's attack surface, and that a hypervisor should instead run
   *as* a component on top. What would that even look like, and what does it cost?

---

Next: [30 — Deployment: what containers are actually for](30-deployment.md)
