# Spikes

A spike is throwaway code written to answer a question. Claude may write spike
code; Claude may not write production code.

## Protocol

1. **Write the question first**, in `docs/spikes/NNNN-question.md`, before any
   code. One sentence, and what answer would settle it. If you can't write that,
   you don't have a spike, you have a vague urge.
2. Branch: `spike/NNNN-short-name`. Never branch a spike off a spike.
3. Claude implements, freely and fast. Normal rules are suspended — no tests, no
   style, no `MUST_USE`, hardcode whatever. Speed is the point.
4. **Run it. Record the answer** in the spike doc: what happened, the numbers,
   what surprised you.
5. **Delete the branch.** `git branch -D`. The doc stays; the code does not.
6. If the answer changes a design, write an ADR citing the spike.

## Rules

- **The spike branch never merges.** Not "usually doesn't" — never. If it merged,
  it was production code written by the wrong process, and it carries none of the
  invariants in `CLAUDE.md`.
- **Time-box it.** Write the box in the doc (a session, an evening). A spike that
  overruns has become a project and should be re-scoped as a milestone.
- **Multiple spikes in parallel are good** when comparing designs — one branch
  each, same question, same measurement. That comparison is the main reason this
  workflow is worth having.
- **A spike answers a question; it does not "try an approach to see if it's
  nice."** Aesthetic questions are answered by writing the interface, not the
  implementation.
- Copying a *snippet* out of a spike is fine. Copying a *file* is the failure
  mode — you'll import assumptions you never examined.

## Good spike questions

- Does the untyped-memory migration actually let me delete `kmalloc`, or do 30
  call sites need it? (Count them.)
- Is the patched-nop tracepoint measurably cheaper than the branch? (Guide 32 §4.2)
- Does an SPSC ring over a socket transport pass the component test suite
  unchanged? (Guide 28 §8)
- How many MPU regions does a realistic component actually need? (Guide 27)
- Does PCID cut the cross-address-space switch cost enough to matter? (Guide 06 §6)

## Template

```md
# SPIKE-NNNN — <question>

- date:
- time-box:
- settles: <what answer would decide what>
- branch: spike/NNNN-...

## Answer
<what happened, with numbers>

## Surprises
<the part you didn't predict — usually the valuable bit>

## Follow-up
ADR-NNNN, or "no change".
```
