#!/bin/sh
#
# Acceptance matrix for the hxq lint-warn nudge hook.
#
# Sibling of `tools/hxq-gate-probe.sh`, and for the same reason: the copy the
# harness runs lives under `.claude/hooks/`, which `.gitignore` excludes
# wholesale, so nothing in the suite exercises it. The DELTA arithmetic the hook
# now depends on does have a unit pin (`unit.query.LintBaselineTest`, over
# `LintBaseline.added`); what has none is the shell around it — the early exits,
# the tree resolution, and the `--baseline` capability probe added in S197.
# Those are what this script covers, one varying thing per case.
#
# The hook under test defaults to the TRACKED copy, `tools/hooks/
# hxq-lint-warn.sh`, which is the one to edit; `.claude/hooks/
# hxq-lint-warn.sh` should be a symlink to it. Point HXQ_LINT_WARN_HOOK at the
# installed path to prove the two have not drifted.
#
#   sh tools/hxq-lint-warn-probe.sh
#   HXQ_LINT_WARN_HOOK=~/dev/lab/anyparse/.claude/hooks/hxq-lint-warn.sh sh tools/…
#
# Exits with the number of failing cases (0 = green), 77 when there is no hook
# or no jq.
#
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK=${HXQ_LINT_WARN_HOOK:-$REPO/tools/hooks/hxq-lint-warn.sh}
if [ ! -f "$HOOK" ]; then
  echo "no hook at $HOOK — nothing to probe (set HXQ_LINT_WARN_HOOK to point at one)"
  exit 77
fi
command -v jq > /dev/null 2>&1 || { echo "jq is required"; exit 77; }
fails=0

# One payload, shaped like the Bash PostToolUse event: the merged capture lands
# under `stdout`, which is the thing the hook had to be taught (a command that
# wrote only to stderr arrives with `.tool_response.stderr` empty).
run() { # $1 command  $2 tool output  $3 cwd  -> the nudge body, or empty
  jq -nc --arg c "$1" --arg o "$2" --arg d "$3" \
    '{session_id:"probe-session",cwd:$d,tool_name:"Bash",tool_input:{command:$c},
      tool_response:{stdout:$o,stderr:""}}' \
    | sh "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""'
}

probe() { # $1 silent|speaks  $2 label  $3 command  $4 output
  body=$(run "$3" "$4" "$REPO")
  if [ -z "$body" ]; then v=silent; else v=speaks; fi
  if [ "$v" = "$1" ]; then printf 'ok   %-6s %s\n' "$v" "$2"
  else printf 'FAIL want=%s got=%s  %s\n' "$1" "$v" "$2"; fails=$((fails + 1)); fi
}

X=.hx
F="$REPO/src/anyparse/query/Cli$X"

echo "-- early exit: the response never says a write happened --"
probe silent "a read-only query"        "hxq refs foo src/"            "src/a$X:1:1: foo"
probe silent "an op that changed nothing" "hxq fmt src/ --write"       "apq fmt: rewrote 0 file(s)"
probe silent "the word 'wrote' in PROSE" "hxq lit 'wrote' src/"        "apq lit: 3 hits"
probe silent "a git command that printed a path" "git diff -- $F"      "diff --git a/src b/src"

echo "-- early exit: nothing resolvable to lint --"
probe silent "a write to a path outside every worktree" \
  "hxq patch /elsewhere/Z$X --write" "apq patch: wrote /elsewhere/Z$X"
probe silent "a write to a file that no longer exists" \
  "hxq patch $REPO/src/NoSuchFileAtAll$X --write" "apq patch: wrote $REPO/src/NoSuchFileAtAll$X"
probe silent "a non-.hx write" \
  "hxq new docs/x.md --write" "apq new: wrote docs/x.md"

echo "-- the nudge itself (needs a built engine in this tree) --"
if [ -f "$REPO/bin/apq.js" ]; then
  # `Cli.hx` carries standing findings on any tree, so a FIRST nudge in a fresh
  # session speaks; the second, against the snapshot the first wrote, must not
  # repeat them. That pair is the whole point of the S197 rewrite.
  # The snapshot is keyed by session id and this probe's is a CONSTANT, so the
  # PREVIOUS run of this probe would otherwise be the thing the "first touch" case
  # compares against: without the clear the matrix is green once and fails on every
  # run after it.
  probe_digest() {
    if command -v shasum > /dev/null 2>&1; then shasum | cut -c1-16
    else cksum | tr -d ' ' | cut -c1-16; fi
  }
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/hxq/lint-warn/$(printf '%s' probe-session | probe_digest)"

  first=$(run "hxq patch $F --write" "apq patch: wrote $F")
  second=$(run "hxq patch $F --write" "apq patch: wrote $F")
  if [ -n "$first" ]; then printf 'ok   %-6s %s\n' speaks "a first touch shows what is standing"
  else printf 'FAIL want=speaks got=silent  a first touch shows what is standing\n'; fails=$((fails + 1)); fi
  if [ -z "$second" ]; then printf 'ok   %-6s %s\n' silent "a second touch with no new finding says nothing"
  else printf 'FAIL want=silent got=speaks  a second touch with no new finding says nothing:\n%s\n' "$second"; fails=$((fails + 1)); fi

  # The floor under the whole S197 rewrite. A hook that went PERMANENTLY silent
  # after its first touch passes every case above, so one case has to prove the
  # other direction: a finding the snapshot does not carry still reaches the
  # reader, and the standing ones beside it do not come back with it.
  P="$REPO/.hxq-probe-lint-warn"
  trap 'rm -rf "$P"' EXIT INT TERM
  mkdir -p "$P"
  body='class Probe197 {\n\n\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\treturn 7777%s;\n\t}\n\n}\n'
  # shellcheck disable=SC2059
  printf "$body" '' > "$P/Probe197$X"
  run "hxq patch $P/Probe197$X --write" "apq patch: wrote $P/Probe197$X" > /dev/null
  # shellcheck disable=SC2059
  printf "$body" ' + 4242' > "$P/Probe197$X"
  third=$(run "hxq patch $P/Probe197$X --write" "apq patch: wrote $P/Probe197$X")
  rm -rf "$P"
  trap - EXIT INT TERM
  case "$third" in
    *'magic number 4242'*'1 finding(s) this edit added'*)
      printf 'ok   %-6s %s\n' speaks "a NEW finding reaches the reader, and only it" ;;
    '') printf 'FAIL want=speaks got=silent  a NEW finding reaches the reader, and only it\n'; fails=$((fails + 1)) ;;
    *) printf 'FAIL want=speaks got=other   a NEW finding reaches the reader, and only it:\n%s\n' "$third"; fails=$((fails + 1)) ;;
  esac
else
  echo "skip        no $REPO/bin/apq.js — build it to probe the nudge itself"
fi

echo "fails=$fails"
exit $fails
