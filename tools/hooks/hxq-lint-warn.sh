#!/usr/bin/env bash
# PostToolUse hook (matcher Bash) — lint backstop for hxq write ops.
#
# INSTALLATION. `.claude/hooks/` is gitignored wholesale, so the copy the
# harness runs lives outside the repo. Keep ONE copy — symlink it:
#   ln -sf ../../tools/hooks/hxq-lint-warn.sh .claude/hooks/hxq-lint-warn.sh
# `tools/hxq-lint-warn-probe.sh` is its acceptance matrix and defaults to this
# file, so a drifted second copy is a probe nobody ran.
#
# WHY THIS EXISTS. The writer round-trip proves an op's edit is canonical, and
# `fmt --list` plus the suite prove it re-emits and behaves. None of the three
# reads the code the way the LINTER does: a hand-wrapped string literal that
# would fit on one line is byte-stable through the writer and irrelevant to the
# suite, so `fold-adjacent-string-literals` first spoke at the end-of-slice
# battery — one wasted commit and one wasted battery run past the five-second
# step that would have caught it. This hook makes that step automatic: after an
# hxq operation that WROTE, lint what it wrote and show the findings.
#
# IT SHOWS THE DELTA, NOT THE STANDING SET (S197). It used to print every
# finding on the file an op touched, with a footer saying so — 17 lines on
# `HaxeQueryPlugin.hx`, 14 on `PreferInline.hx`, 500-900 tokens per op, most of
# it the same list the previous op printed. What a nudge is for is the finding
# THIS edit introduced, so the lint runs with `apq lint --baseline <snapshot>`:
# it reports only what the snapshot does not already carry and then refreshes
# the snapshot with everything it found. The comparison is `lint-diff`'s
# multiset over (file, rule, severity, message), which is why an edit that
# shifts line numbers does not manufacture a delta — a text diff of two reports
# would report every finding below the edit.
#
# The snapshot is per SESSION and per FILE SET (`session_id` from the payload,
# plus a digest of the resolved paths). So the FIRST touch of a file in a
# session still shows what is standing on it — useful once, and the fail-open
# direction — and every later touch shows only what changed. An engine with no
# `--baseline` (a tree older than S197) is detected and gets the old whole-set
# behaviour rather than silence.
#
# It SHOWS, it never fixes and never blocks (sibling apq-canon-warn.sh's rule).
# Autofix stays a deliberate `hxq lint <file> --fix`: folding a rewrite into a
# write op would silently rewrite code behind an edit whose whole contract is
# that it only moves bytes the author typed.
#
# COST. The matcher is `Bash`, so this runs after EVERY bash command; the early
# exit below is pure shell string matching with no subprocess, and only a
# response that already says "wrote" gets as far as jq. A lint that does run
# costs ~5s (`--no-oracle`; with the compiler oracle it would be ~24s, and a
# nudge must never spawn a project-wide build).
#
# WORKTREES (T726, 2026-09-07). The `cwd` this hook receives is the SESSION's
# working directory, never the shell's — measured: `cd /private/tmp && echo
# 'apq patch: wrote src/…/SingleStmtBraces.hx'` nudged 95 findings on the MAIN
# tree's file. A wave worker editing inside `/tmp/hxqb-SNNN` with relative paths
# therefore got every finding addressed to a file it never touched. So the tree
# an op wrote into is derived from EVIDENCE in the command and the op's own
# output — an absolute path under a registered `git worktree`, or the
# `HXQ_BIN=` the worker pins — and the lint runs in THAT tree with THAT tree's
# engine (`<tree>/bin/apq.js`, else the pinned `HXQ_BIN`). No engine for the
# tree ⇒ silence: a nudge from the main tree's engine over a worktree's files
# is the phantom-findings hazard this project pins `HXQ_BIN` to avoid.

input=$(cat)

# ---- early exit #1: nothing was written. Pure bash, no fork. --------------
case "$input" in
  *': wrote '* | *': rewrote '*) ;;
  *) exit 0 ;;
esac

PROJECT="/Users/axg/dev/lab/anyparse"

# How many delta lines are shown before the tail counts the rest. Lower than the
# old whole-set cap of 40 on purpose: a delta of more than this many findings is
# not a nudge any more, it is a `hxq lint` the reader should run themselves.
SHOWN_MAX=25

# Snapshots older than this many days are swept on the way past. They are one
# lint report each and a long campaign accumulates them per session.
CACHE_DAYS=2

emit() { # $1 = body
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("hxq lint-warn (nudge — nothing was fixed):\n" + $r)
    }
  }'
  exit 0
}

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // "default"')
[ -d "$cwd" ] || cwd="$PROJECT"
# The ops report on STDERR, but the Bash tool hands the hook one merged capture
# and files it under `stdout` — reading `.tool_response.stderr` alone finds an
# empty string and every write looks like a no-op. Read both.
say=$(printf '%s' "$input" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")')

# ---- early exit #2: the "wrote" text was not an op reporting its own write.
# The ops say `apq <op>: wrote <path>` or `apq <op>: (re)wrote <n> file(s)`.
# A zero count is an op reporting it changed nothing, so it is not a write.
wrote=$(printf '%s\n' "$say" | grep -E '^apq [a-z-]+: (re)?wrote ' | grep -Ev '(re)?wrote 0 file\(s\)')
[ -n "$wrote" ] || exit 0

# ---- which tree did the op write into? -----------------------------------
# Registered worktrees of the project, main first; `git worktree list` prints
# REAL paths (`/private/tmp/…`), commands say `/tmp/…` — normalise before
# comparing.
trees=$(git -C "$PROJECT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
[ -n "$trees" ] || trees="$PROJECT"
norm() { case "$1" in /tmp/*) printf '/private%s' "$1" ;; *) printf '%s' "$1" ;; esac; }
tree_of() { # $1 = absolute path → the worktree root containing it, or nothing
  local p t
  p=$(norm "$1")
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$p" in "$t" | "$t"/*) printf '%s' "$t"; return 0 ;; esac
  done <<TREES
$trees
TREES
  return 1
}
strip() { printf '%s' "$1" | sed "s/^[\"']//; s/[\"']$//"; }

tree=""
hxqbin=""
# noglob for the rest of the script: an unquoted `$cmd` split would otherwise
# PATHNAME-EXPAND a quoted glob the op never expanded itself, and
# `hxq fmt 'src/**/*.hx' --write` would turn a nudge into a whole-tree lint.
set -f
for tok in $cmd; do
  tok=$(strip "$tok")
  case "$tok" in
    HXQ_BIN=/*) hxqbin=${tok#HXQ_BIN=} ;;
    /*) [ -n "$tree" ] || tree=$(tree_of "${tok%%:[0-9]*}") ;;
  esac
done
if [ -z "$tree" ] && [ -n "$hxqbin" ]; then
  # A pinned private engine whose tree the command never names: the op ran
  # somewhere this hook cannot see. Silence beats a phantom.
  tree=$(tree_of "$hxqbin") || exit 0
fi
[ -n "$tree" ] || tree=$(tree_of "$cwd") || tree="$PROJECT"

if [ "$tree" = "$PROJECT" ]; then
  ENGINE="$PROJECT/bin/apq.js"
  [ -f "$ENGINE" ] || exit 0   # fail-open: never spam mid-rebuild
elif [ -f "$tree/bin/apq.js" ]; then
  ENGINE="$tree/bin/apq.js"
elif [ -n "$hxqbin" ] && [ -f "$hxqbin" ]; then
  ENGINE="$hxqbin"
else
  exit 0   # a worktree with no engine of its own: no nudge rather than a wrong one
fi

# ---- collect candidate paths ---------------------------------------------
# Two sources, unioned, because neither is complete alone:
#  (a) the paths the ops PRINTED — the only source for a write whose target the
#      command line never spells (`hxq new` driven by a spec, a fan-out);
#  (b) the `.hx` tokens of the command line — the only source for the ops that
#      report a COUNT and no names (`move`, `comment-rewrite`, `fmt`).
candidates=$(printf '%s\n' "$wrote" | sed -n 's/^apq [a-z-]*: \(re\)\{0,1\}wrote \(.*\.hx\)\( (.*)\)\{0,1\}$/\2/p')
for tok in $cmd; do
  case "$tok" in *.hx | *.hx[!A-Za-z]*) ;; *) continue ;; esac
  candidates="$candidates
$(strip "$tok" | sed "s/:[0-9].*$//")"
done

# ---- resolve against the op's tree, keep existing files there, dedupe -----
# A relative path is resolved against the TREE ROOT (the shell's own cwd is
# unknowable here); one that does not exist there is dropped, never retried
# against another tree.
files=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in /*) p=$(norm "$p") ;; *) p="$tree/$p" ;; esac
  case "$p" in "$tree"/*.hx) ;; *) continue ;; esac   # that tree, Haxe only
  [ -f "$p" ] || continue
  case "
$files" in *"
$p
"*) continue ;; esac
  files="$files$p
"
done <<CANDIDATES
$candidates
CANDIDATES
[ -n "$files" ] || exit 0

# ---- the per-session snapshot this file set compares against --------------
# Keyed by SESSION so a fresh session starts from what is standing (shown once,
# then subtracted), and by the sorted FILE SET so an op that writes two files
# has its own baseline rather than colliding with the single-file one. The tree
# joins the digest because two worktrees hold the same relative paths.
digest() { # stdin → a short stable hex token
  if command -v shasum > /dev/null 2>&1; then shasum | cut -c1-16
  else cksum | tr -d ' ' | cut -c1-16; fi
}
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hxq/lint-warn/$(printf '%s' "$session" | digest)"
key=$(printf '%s\n%s' "$tree" "$(printf '%s' "$files" | LC_ALL=C sort)" | digest)
snapshot="$CACHE_DIR/$key.json"
mkdir -p "$CACHE_DIR" 2>/dev/null || snapshot=""
[ -z "$snapshot" ] || find "$CACHE_DIR" -type f -name '*.json' -mtime "+$CACHE_DAYS" -delete 2>/dev/null

# An engine older than S197 has no `--baseline`; passing it would make the whole
# lint exit EXIT_USAGE and the nudge would go silent, which is the one failure
# mode worse than being verbose. Ask once.
baseline=""
if [ -n "$snapshot" ] \
  && node "$ENGINE" lint --help 2>/dev/null | grep -q -- '--baseline'; then
  baseline="--baseline $snapshot"
fi

# ---- one lint process over every written file ----------------------------
# `--flat` so each finding carries its own path (a nudge is read, not scrolled).
# `--all` is LOAD-BEARING, not a style choice: the rule this hook exists for,
# `fold-adjacent-string-literals`, is severity INFO, and the text report hides
# info advisories without it — measured on the reconstructed incident, dropping
# `--all` makes the hook silent on the exact finding it was built to catch.
# The engine is invoked directly rather than through the `hxq` shim so a stale
# `src/` can never start a Haxe build inside a hook.
# shellcheck disable=SC2086
out=$(cd "$tree" && APQ_NO_CONFIG_WARN=1 node "$ENGINE" lint $files --all --no-oracle --flat $baseline 2>/dev/null \
  | grep -E ':[0-9]+:[0-9]+:')
[ -n "$out" ] || exit 0

count=$(printf '%s\n' "$out" | grep -c .)
shown=$(printf '%s\n' "$out" | head -"$SHOWN_MAX")
[ "$count" -gt "$SHOWN_MAX" ] && shown="$shown
… $((count - SHOWN_MAX)) more finding(s) not shown"

if [ -n "$baseline" ]; then
  tail_line="$count finding(s) this edit added, against the last nudge on these file(s)."
else
  tail_line="$count finding(s) on the file(s) that op wrote — standing ones included (this engine has no --baseline)."
fi

emit "$shown

$tail_line A mechanically-rewritable one is fixed with
  hxq lint <file> --rule <id> --fix
and never by hand."
