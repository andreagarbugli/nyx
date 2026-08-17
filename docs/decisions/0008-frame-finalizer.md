# ADR-0008 — Frames live until their Untyped is reclaimed

- date: 2026-08-14
- status: accepted (2026-08-14)
- guide: 09 §3, 09 §4; ADR-0003

## Context

A Frame is a physical page. There is nowhere to put a `struct kobject`
header without stealing a cache line from every page given to
userspace, or adding a side table the size of the frame database.
ADR-0003 left Frame finalization open. M3.2 will create and drop
Frames as a matter of course (MMIO, scratch, DMA).

## Decision

A Frame capability is a name, not a refcounted object. Unmapping
removes a PTE; deleting the last Frame cap does **not** free the
page. The page returns when its parent Untyped is reclaimed
(`untyped_reclaim` after a revoke of all children).

`VSPACE_UNMAP` is the operation that drops a mapping. It does not
delete the Frame capability; the cap still names the page and can
be mapped again.

## Alternatives rejected

- **Header prefix on every frame.** Wastes 16+ bytes and alignment
  on every userspace page, including DMA buffers a device will
  read. The device would see the header.
- **Side table of refcounts.** A second frame database, indexed by
  PFN, that must stay consistent with `struct page`. Real work, and
  the payoff is "delete last cap ⇒ free page" which Untyped reclaim
  already expresses more honestly: memory is accounted to a
  principal, not to a cap count.

## Consequences

Makes easy: unmap and remap without losing the page; DMA buffers
with no header; Untyped remains the one allocator userspace sees.

Makes hard: a leaked Frame cap is a leaked page until the Untyped
is revoked. Servers must revoke or reclaim, not hope delete frees.
The root task's per-component Untyped already gives that handle.

Forecloses: "the last Frame cap frees the page" as a programming
model. That is the intended foreclosure.

## Revisit when

A measurement shows Untyped-granularity reclaim is too coarse for
a real driver (e.g. a compositor that must free individual buffers
without revoking the client's whole heap). Then a side table, not
a prefix.
