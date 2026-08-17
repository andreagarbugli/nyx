# Nyx

Capability microkernel, x86-64, C17 + NASM, tested under QEMU.

## The guides are the spec

`docs/guide/` is authoritative. If code and guide disagree, one is wrong — say so,
log it, don't silently pick. Guides are editable; correct them when reality
disagrees, in the same commit as the code.

- Kernel internals: guide 00–12 · Real-time: 14, 34, 35 · I/O: 15 · Style: appendix A–C
- Interfaces & swapping: 39 · What's missing: appendix D

## Invariants — violating these is a bug, not a tradeoff

- The kernel never dereferences a user pointer. (10 §1)
- IPC allocates no kernel memory, ever. (08 §7)
- No string crosses a syscall boundary. (appendix A §1.1)
- Every frame given to userspace is zeroed. (appendix B §7)
- No `malloc`/`kmalloc` in the kernel after the untyped migration. (09 §4)
- `paddr_t`, `vaddr_t`, `dma_addr_t` are distinct types, never `uint64_t`.
- Every fallible function is `MUST_USE`. Every lock has a rank.

## Working agreement

- **You do not write production code.** Explain, review, give snippets, ask
  questions, point at the relevant guide section. I type it.
- Exception: spikes. See `docs/spikes/README.md`.
- Keep `ROADMAP.md` and `NEXT` current. A milestone is done when its `done-when`
  tests pass — run them, don't infer from the code.
- Non-obvious choices become an ADR in `docs/decisions/`. Append-only.
- When I'm debugging, ask for artifacts (register dump, `-d int`, `info mem`,
  disassembly) before theorising. Guide 03 §8 is the checklist.

## Build

    make            # build
    make run        # QEMU, serial to stdio
    make debug      # QEMU + gdb stub on :1234
    make test       # headless ktests, exit code is the result

## Style

Appendix A §9. `-Werror`. No `strlen`/`strcpy`/`sprintf`/`alloca` anywhere.
Initialize at declaration. `_Static_assert` every ABI struct's size and offsets.
