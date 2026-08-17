# Decisions

Append-only. Never edit an accepted ADR — supersede it with a new one.

Copy `0000-template.md`. Number sequentially. Every non-obvious choice with real
alternatives gets one; the guide names roughly a dozen that will come up.

| # | Title | Status |
|---|---|---|
| [0001](0001-ipc-no-timeouts.md) | IPC has no timeouts | accepted |
| [0002](0002-p5-vertical.md) | P5 is track A (real-time + TSN) | accepted |
| [0003](0003-object-teardown.md) | Object teardown and `E_PEERGONE` | accepted |
| [0004](0004-scheduler-shape.md) | Fixed-priority is the mechanism; MCS layers on | accepted |
| [0005](0005-static-linking.md) | Userspace links statically, revisit at M4.0 | accepted |
| [0006](0006-verticals-are-manifests.md) | Verticals are manifests, not kernels | accepted |
| [0007](0007-bound-notifications.md) | Bind a Notification to a TCB | accepted |
| [0008](0008-frame-finalizer.md) | Frames live until their Untyped is reclaimed | accepted |
| [0009](0009-capability-transfer-in-message-words.md) | Capabilities travel in message words | accepted |
| [0010](0010-page-cache-lives-with-the-pager.md) | The page cache lives with the pager | accepted |
| [0011](0011-ipc-off-the-bkl.md) | IPC off the BKL; endpoint+CSpace locks; fast path | accepted |
