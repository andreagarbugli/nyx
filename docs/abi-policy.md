# ABI policy

Written before there are users, because after there are users it is
too late (guide 17 §7).

`include/abi/` is the contract. The guide is prose. `docs/abi.md` is
prose. A stub generator, when it exists, reads the headers.

## Rules

1. **Numbers are permanent.** Syscall numbers, debug sub-ops, invoke
   method numbers, error codes. A removed operation’s number is never
   reused; it returns `E_NOSYS` (or the equivalent) forever.
2. **Append only, never insert, never reorder.** Enums that cross
   this boundary follow appendix A §5 the same way structs do.
   Learned at M3.0.5, not hypothetically.
3. **Within a major version, changes are additive.** New methods, new
   appended fields, new flag bits. Never a semantic change to an
   existing method.
4. **Unknown flags are rejected (`E_INVAL`), not ignored.** Ignoring
   them means you can never define them safely later. Reserved fields
   must be zero, and this is checked, for the same reason.
5. **The syscall list stays tiny.** A new `SYS_*` requires a written
   argument — in the commit message, and usually an ADR — for why the
   operation cannot be a `SYS_INVOKE` method. “A shell would be
   nicer” is not an argument.
6. **No pointers. No strings.** A capability index is not a pointer.
   `make abi-check` greps for `char *` and for includes of
   `nyx/` from `include/abi/`.
7. **Every ABI change is its own commit**, touching only
   `include/abi/` (and the matching prose in `docs/abi.md` in the
   same commit). Make it feel heavy, because it is.
8. **Do not publish a number you do not honour.** An unimplemented
   `SYS_SEND` in the enum is a stub someone will write. Add the
   number in the commit that implements it.

## Major versions

Not invented yet. When they are: a new major version is a new
interface id, servers may implement both during a window, and
introspection reports both. Do not invent a version field on the
syscall itself until an IDL exists to put it in.

## What this does not cover

In-kernel structs (`struct tcb`, `struct cap`, …) are not ABI.
Changing them is a kernel patch, not an ABI event. The exception is
anything whose offset is hardcoded in asm (`struct cpu`, `struct
regs`, the syscall return block): those need `_Static_assert`s
against the asm, which they have.
