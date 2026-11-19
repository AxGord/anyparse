# Queue line difficulty: anchors (the plan stage runs sonnet/high whatever the line says; its agent executes ≤6, opus/high executes ≥7; a slice spawned without a plan stage takes model_table: 1–6 sonnet/high, 7–10 opus/high)

Score the WORK, not the sentence. Take the highest anchor that applies. A `touches:` in src/anyparse/macro, or a line saying its symptom was not reproduced, is anchor 7 as written.

- 2  one function and its test; the owner is named and exists.
- 3  one file or a small change at one known owner; no new type, no config key.
- 4  a few files around one known owner; a gate row or CLI flag following an existing pattern.
- 5  a new lint rule or command on existing components; a change that re-records a fixture set or a kit.
- 6  a NEW shared component or config key; a change several callers move onto; a grammar change without a writer change.
- 7  writer layout or macro lowering with corpus or Pony blast; typing or name resolution across files; a cause not yet known.
- 8  several owners change together; a contract moves (a registry format, a protocol) across packages.
- 9–10 a whole-tree sweep or a redesign: the plan stage splits it into lines and stops, no opus run (slice-worker `orient`). A line that removes a type, enum case or config value read across packages AND re-records tests or sweeps the tree (`fmt --write`, a `--fix` over src/test) is 9 as written. The same holds for a line that joins a whole-tree write (`fmt --write`, a `--fix` over src/test) with a change of another kind: a new tool, rule or config key. A writer, default or config change that moves this repo's own formatted output, taken with the `fmt --write` it forces, is ONE line (`exclusive: yes`), scored by the change: the gate's fmt row refuses a land whose tree is not canonical. A split is cut by behaviour, never by step (code, then tests, then sweep): each proposed line lands green alone on the main its `after:` leaves, so it re-records the tests, kit rows and arms its own change moves, and a change that moves the tree either carries its sweep in the same commit or lands first with defaults that keep today's output and leaves the flip plus the sweep to the next line. A single rule's `--fix` alone is not this; recon scores it.

How to cut a split, by what the work is (user yes 2026-11-12, measured in .claude/backups/research/SPLIT-STRATEGY-MEASURE/report.md); each proposed line names its type:
- sweep — the same mechanical edit over many files, done by one op or one rule's `--fix`: ONE line whose op does the whole sweep, scored by the op's work, not the file count. Never cut by file range: each piece pays its own land and review (pieces $2.96 each, run in series).
- migration — add the new contract, move the callers, delete the old: serial lines chained by `after:`, each landing green.
- flip — a default or writer change with the sweep it forces: never split (the ONE-line rule above).
- independent — features under one theme that share no `touches:`: separate lines with no `after:` between them, so they run in parallel; an `after:` only where their touches overlap.
- re-score — a line scored 3 or more above its number: cut into lines of ≤6 at once, so no piece needs a second split (3 of 12 did).

Add 1 when the line's premise is a measurement older than a week, or its cause is a hypothesis.

Before writing a line: `touches:` and `owner:` name paths and types that exist on main (`ls`, `hxq owner "<question>" src`); a file the slice creates says `(new)`. A wrong path means the line was written blind, which is the signal to score it again.

The plan stage (slice-worker `orient`, always on sonnet) scores the work: ≤6 and the same agent executes, ≥7 and an opus agent executes its plan. The line's number is the first guess; it no longer picks the first agent's model.

Calibration, each curator run: difficulty band vs review rounds and $ per slice from `git log` trailers and token-audit. A slice at more than twice its band's median names which anchor was missed; a repeated miss changes this file.
