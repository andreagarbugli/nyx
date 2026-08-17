# Docs

The guide is the specification. These files are the *current* system:
what was decided, what the ABI actually is, what is still open. If a
file here disagrees with `docs/guide/`, one of them is wrong — log it,
do not silently pick.

## Start here

| File | What it is |
|---|---|
| [`../ROADMAP.md`](../ROADMAP.md) | Milestones. A thing is done only when its `done-when` is verified. |
| [`../NEXT`](../NEXT) | The single next thing. |
| [`guide/README.md`](guide/README.md) | The book. Theory, mechanism, construction. Start at 00, then **00.5** before writing any code. |
| [`decisions/`](decisions/) | ADRs. Append-only. Accepted ones are not edited. |
| [`architecture.md`](architecture.md) | The system as it is: objects, levels, what exists. |
| [`abi.md`](abi.md) | Prose restatement of `include/abi/`. The headers are the spec. |
| [`abi-policy.md`](abi-policy.md) | How the ABI is allowed to change. |
| [`invariants.md`](invariants.md) | Never-violate. A broken invariant is a bug, not a tradeoff. |
| [`open-questions.md`](open-questions.md) | Decisions that are still owed, with a “decide before”. |
| [`verticals.md`](verticals.md) | How B/C/D happen later without forking the kernel. |
| [`evaluation.md`](evaluation.md) | Outside reading of ideas, design, and code (dated). |
| [`retrospective.md`](retrospective.md) | End of P4: what the design bought, what it cost, what a V2 changes, what the numbers allow the verticals. |
| [`evaluation-2.md`](evaluation-2.md) | Hot paths, hardware floors, determinism, trim vs feature. After M4.3. |
| [ADR-0011](decisions/0011-ipc-off-the-bkl.md) | IPC off the BKL; fast path. |
| [`performance.md`](performance.md) | Measured numbers. Not estimates. |
| [`bench/`](bench/) | `make bench` harvest: `latest.json`, history, plot. |
| [`realtime.md`](realtime.md) | Guide 14 §6.2's table: every kernel region, its bound, its measured cost, and what a VM cannot measure. |
| [`locking.md`](locking.md) | Lock ranks, what each subsystem takes, what is not there. |
| [`tracing.md`](tracing.md) | Trace overhead and event schema. |
| [`spikes/`](spikes/) | Throwaway questions. The branch never merges. |

Not written yet, on purpose:

- `security.md` — the threat model is still “the CSpace is the authority.”
  Expand when there is a second userspace component.
