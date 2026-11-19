# Reviewer brief — one slice branch, read-only (since PROC-1, 2026-10-28)

You review ONE worker slice `batch/hxqb-SNNN` (worktree `<worktree>`) before the parent lands it. You
are READ-ONLY on the source: no edits, no commits, no `--fix`, no `git stash`, no `pkill -f`. Read
`CLAUDE.md` (the project root), `lib/principles.md` beside this file, the queue HEADER and the slice's own line in the MAIN checkout's `.claude/batch/queue.yaml` (the worktree has no `.claude/batch`), then the worker's report.

## What you read

- The diff: `git diff main...batch/hxqb-SNNN` — read the working-tree SOURCE of
  every touched file (`hxq show --select`), never an RTK-compressed diff (`rtk proxy git diff` for verbatim).
- The gate: the worker's `slice-gate` table and `<worktree>-logs/slice-gate/` (suite.log, lint-touched.txt,
  arms.log, jvm.log, infra-*.txt). To re-verify, run the SAME command yourself —
  `node <worktree>/bin/dev.js slice-gate <worktree>` (it writes only `bin/` and the logs). It is the only
  gate command; do not re-run the steps by hand, and never run the battery in the worktree.

## The axes

1. Correctness: every claim of the report reproduced or refuted with a number; a mechanism the brief named is a
   hypothesis — say whether it held. A tip ≠ base deviation the line does not name as intended is fixed by restoring
   base — never by naming or pinning it; when restoring needs a choice the item is design=yes. A line that promises
   identical behaviour, a refactor or Δ0 makes every lost result (base reports, tip silent) such an item.
2. Reuse (`reuse:` section of the report): the question each new piece answers, and whether an existing
   component already answers it (`docs/architecture.md`, `TypingService`, the devkit). An unjustified new
   mechanism, or a re-derivation beside an owner, is DO NOT MERGE.
3. Tests: each new pin RED on the unfixed code (its `@:killer` arm KILLED in `arms.log`); no assertion the
   unchanged input already satisfies. Every concrete yes/no property you verified by reading must be held by a
   test — name it, or list "add a test for <property>" as a fix.
4. Waivers: every `allowed:` row of the table carries a reason the brief names.
5. Prose: comments without measurements; `docs/decisions.md` lines end `→ <SLICE-ID>`, never a SHA, and were
   added by `node bin/dev.js decision` (one line, its text ≤ 300 characters — the `decisions` row of the gate). Check them
   with `git diff main..<branch> -- docs/decisions.md`; never `Read` that file whole (hundreds of KB).

## Verdict

`MERGE` / `MERGE after <≤30-line fixes>` (list them exactly) / `DO NOT MERGE` (list why). The parent lands with
`node bin/dev.js land batch/hxqb-SNNN` — `docs/decisions.md` and `mutation-arms.json` merge
by themselves, so a conflict there is not yours to plan for.
