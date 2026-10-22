#!/usr/bin/env bash
# PostToolUse hook (matcher Bash) — lint backstop for hxq write ops: after an
# hxq operation that WROTE, lint what it wrote and show the findings THIS edit
# added. The body is `node bin/dev.js lint-warn` (tools/src/dev/LintWarn.hx);
# this file is only the entry the harness runs and the early exit below.
#
# INSTALLATION. `.claude/hooks/` is gitignored wholesale, so the copy the
# harness runs lives outside the repo. Keep ONE copy — symlink it:
#   ln -sf ../../tools/hooks/hxq-lint-warn.sh .claude/hooks/hxq-lint-warn.sh
# `node bin/dev.js lint-warn-probe` is its acceptance matrix and defaults to
# this file.
#
# WHY THIS EXISTS. The writer round-trip proves an op's edit is canonical, and
# `fmt --list` plus the suite prove it re-emits and behaves. None of the three
# reads the code the way the LINTER does: a hand-wrapped string literal that
# would fit on one line is byte-stable through the writer and irrelevant to the
# suite, so `fold-adjacent-string-literals` first spoke at the end-of-slice
# battery. This hook makes the five-second lint step automatic.
#
# IT SHOWS THE DELTA, NOT THE STANDING SET. The lint runs with
# `apq lint --baseline <snapshot>`, per SESSION and per FILE SET: the first
# touch of a file in a session shows what is standing on it, every later touch
# only what changed. It SHOWS, it never fixes and never blocks.
#
# WORKTREES. The `cwd` the payload carries is the SESSION's, never the shell's,
# so the tree an op wrote into is derived from EVIDENCE in the command and the
# op's output (an absolute path under a registered worktree, or a pinned
# `HXQ_BIN=`), and the lint runs with THAT tree's engine — none ⇒ silence.
#
# COST. The matcher is `Bash`, so this runs after EVERY bash command: the early
# exit is pure shell string matching with no subprocess, and only a response
# that already says "wrote" starts node. No built `bin/dev.js` ⇒ silence
# (fail-open: never spam mid-rebuild).

input=$(cat)

# ---- early exit: nothing was written. Pure bash, no fork. -----------------
case "$input" in
  *': wrote '* | *': rewrote '*) ;;
  *) exit 0 ;;
esac

# The tree this file sits in, through the `.claude/hooks/` symlink: its
# `bin/dev.js` is the body, so a copy inside a worktree runs that worktree's.
self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case "$link" in
    /*) self=$link ;;
    *) self=$(dirname "$self")/$link ;;
  esac
done
dev="$(cd -P "$(dirname "$self")/../.." && pwd)/bin/dev.js"
[ -f "$dev" ] || exit 0

printf '%s' "$input" | node "$dev" lint-warn
exit 0
