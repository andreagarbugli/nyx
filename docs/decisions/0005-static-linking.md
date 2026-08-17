# ADR-0005 — Userspace links statically, revisited at M4.0

- date: 2026-08-13
- status: accepted (2026-08-13)
- guide: 10 §5, §6; appendix D §7; ROADMAP.md open questions

## Context

`ROADMAP.md` has carried "static vs dynamic linking — decide before M3.1"
since M0.2. It is M3.1's question because the answer determines the initrd
layout and how much of a loader the root task needs: a dynamic loader must
process relocations, resolve symbols, and define its own ABI, all before the
first server runs.

The system this will eventually carry is a handful of servers (init, pm, vfs,
rd, con, rs) plus applications, not a general-purpose userland. `libnyx` does
not exist yet.

## Decision

Userspace links **statically**. `libnyx` is a static archive; each server and
application is a self-contained ELF in the initrd. The root task's loader
maps program headers and does nothing else — no relocation processing, no
symbol resolution, no shared-object lifetime.

**Revisit at M4.0**, with a concrete trigger rather than a vague intention:
when the core servers exist, measure the total resident bytes duplicated
across them. If duplicated text exceeds roughly 15% of userspace RSS, or if
patching `libnyx` without relinking every component becomes an operational
need, reopen this.

## Alternatives rejected

- **Dynamic with a shared `libnyx.so` now.** Saves memory across components
  and allows patching one library rather than relinking everything. Rejected
  on cost and sequencing: it requires a dynamic loader — relocation
  processing, symbol resolution, and a loader ABI — as a prerequisite to the
  *first* server running. That is a substantial piece of userspace built
  before there is any userspace to validate it against, and guide 10 §5's
  loader sketch is program-header mapping precisely because that is the part
  that must exist either way.
- **Static forever, no revisit.** Rejected because the tradeoff is genuinely
  quantitative and the quantity does not exist yet. Closing the question with
  no trigger is how a defensible early decision becomes an indefensible late
  one.

## Consequences

Makes easy:

- The root task's loader stays close to guide 10 §5: validate the ELF header,
  map `PT_LOAD` segments with W^X, done. That is also the code guide 18 §3.2
  wants fuzzed (`fuzz_elf_load`), and a smaller parser is a smaller target.
- Each component's authority and code are both self-contained, which suits a
  manifest-driven system (guide 11) where a component is a binary plus a
  capability list.
- No shared-library lifetime questions interacting with ADR-0003's object
  teardown.

Makes hard:

- Duplicated text across servers. Expected to be small at this scale, and
  that expectation is exactly what the M4.0 revisit measures rather than
  assumes.
- Patching `libnyx` means relinking every component. Acceptable while the
  build is one `make`; an operational problem only if components are shipped
  independently, which is itself an M4.0-and-later question.

Forecloses: nothing. Dynamic linking is additive later — the static path
remains valid for components that want it, and a dynamic loader is a
userspace program, not a kernel change.

## Revisit when

At **M4.0**, when init/pm/vfs/rd/con/rs exist, whichever comes first:

- duplicated text across resident components exceeds ~15% of userspace RSS,
  measured, not estimated; or
- independent shipping of components becomes a requirement, making
  relink-everything untenable.
