# ADR-0010 — The page cache lives with the pager

- Status: accepted
- Date: 2026-08-14
- Milestone: M4.0 (VFS slice)
- Guide: 11 §4.3, 00 §6.4, appendix D §5, 39 §11

## Context

Guide 11 chose VFS design (b): `open()` returns a capability to the
FS server's file object, and `read` never touches the VFS again.
Appendix D §5 and guide 39 §11 both say the page-cache location
must be written down *before* that VFS is built — it is the leak
that grades the VFS/FS boundary B−, and it constrains every
filesystem and the memory server.

The options D §5 names: the filesystem server, the memory server,
or distributed per-file. Monolithic kernels unify the page cache
and the buffer cache so `mmap` and `read` stay coherent. A
multi-server system has to pick which component *is* that
coherence, or it will grow two copies of every hot file.

Ramfs already exists and has no cache: the archive is in RAM, and
caching it would be a RAM-to-RAM copy to avoid 32-byte IPC. That
optimisation is the ring (guide 08 §6c), already deferred.

## Decision

**There is no page cache until something mmaps a file.** When one
exists, it lives in the **memory server** — the pager — as Frames
it already holds. The VFS never caches file data. A filesystem
server may keep private metadata; it does not own the coherent
copy of file bytes.

Until the memory server exists, every `read` is a call through to
the FS (and the ramdisk under it). That is the v0 cost, stated.

## Alternatives rejected

- **Cache in the VFS.** Puts the VFS back in the data path, which
  is design (a), already rejected. A name resolver that serves
  cached pages is a file server.
- **Cache in the filesystem server.** `mmap` is the pager's job
  (guide 11 §4.1). An FS-side cache is a second copy of the same
  bytes, and every FS would have to speak the same cache protocol
  for `mmap` to stay coherent. That is the leak guide 39 is
  grading: the cache location would be an implicit part of the
  FS interface.
- **Distributed per-file, in the file object.** Isolation looks
  good until two processes open the same file, or one of them
  `mmap`s it. The coherent case is "the file object *is* a set of
  Frames from the pager" — which is the memory-server answer with
  extra steps.
- **Build a cache in ramfs now.** The data is already in RAM.
  The thing a hot read wants is a ring, not a second buffer.

## Consequences

Makes easy: the VFS stays a mount table; a second filesystem does
not inherit a cache protocol; `read`/`mmap` coherence has one
owner (the pager) when those two operations first coexist.

Makes hard: a hot `read` of a cold page is still an IPC, until
the ring or the pager's cache exists. Track A can live with that
— a shared cache is also a timing channel, and a real-time
partition should not take a cache miss in someone else's working
set.

Forecloses: "the VFS is where files live in memory." That is the
intended foreclosure.

## Revisit when

The first `mmap` of a file, or a measurement that 32-byte IPC on a
hot file is the bottleneck (then the ring, still not an FS cache).
A second filesystem that wants a private write-back cache for
metadata does not reopen this: that cache is not the page cache.
