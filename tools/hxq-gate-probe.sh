#!/bin/sh
#
# Acceptance matrix for the hxq edit/read gate hook.
#
# The hook itself lives at `.claude/hooks/hxq-gate.sh`, which `.gitignore`
# excludes wholesale — it is a per-machine harness file, so it cannot carry a
# unit test and nothing in the suite exercises it. This script is the net: 25
# commands, each with the verdict the hook must return, varying ONE thing at a
# time so a regression names itself.
#
# It exists because the hook classified a command by scanning its whole text.
# `hxq comment-rewrite 'we grep the tree' … src/F.hx --write` was DENIED as a
# grep of a parseable file, `hxq set-doc … 'reads the head then walks'` was
# warned about a `| head` that was not there, and `git -C <dir> diff -- F.hx`
# — the spelling this project's own worktree rule mandates — was denied as
# text extraction. Five of these cases failed before that fix; all 25 pass
# after it, and the deny/warn cases are here so the fix cannot be widened into
# a hole.
#
#   sh tools/hxq-gate-probe.sh                       # against the installed hook
#   HXQ_GATE_HOOK=/path/to/other.sh sh tools/…       # against another copy
#
# Exits with the number of failing cases (0 = green), 77 when no hook is
# installed — an absent per-machine file is not a failure.
#
HOOK=${HXQ_GATE_HOOK:-$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/hxq-gate.sh}
if [ ! -f "$HOOK" ]; then
  echo "no hook at $HOOK — nothing to probe (set HXQ_GATE_HOOK to point at one)"
  exit 77
fi
command -v jq > /dev/null 2>&1 || { echo "jq is required"; exit 77; }
fails=0
probe() { # $1 expected (allow|warn|deny)  $2 command
  out=$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" 2>&1)
  if [ -z "$out" ]; then v=allow
  else v=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "warn"'); fi
  if [ "$v" = "$1" ]; then printf 'ok   %-5s %s\n' "$v" "$2"
  else printf 'FAIL want=%s got=%s  %s\n' "$1" "$v" "$2"; fails=$((fails+1)); fi
}

H=head; G=grep; S=sed; X=.hx

echo "-- T470: payload text is DATA, not a command --"
probe allow "hxq comment-rewrite 'the $H of the list' 'the front of the list' src/anyparse/query/Cli$X --write"
probe allow "hxq comment-rewrite 'we $G the tree' 'we walk the tree' src/anyparse/query/Cli$X --write"
probe allow "hxq set-doc src/anyparse/check/NullFlow$X --select 'FnMember:x' 'reads the $H then walks'"
probe allow "hxq patch src/anyparse/query/Cli$X --select 'FnMember:x' --write 'a $S b'"
probe allow "hxq lit '$H' src/anyparse/query/ShardPlan$X --limit 3"

echo "-- git -C is VCS inspection --"
probe allow "git -C /tmp/w diff -- src/anyparse/query/Cli$X"
probe allow "rtk proxy git -C /tmp/w diff -- src/anyparse/query/Cli$X | $H -60"
probe allow "git --no-pager log -p -- src/anyparse/query/Cli$X"
probe allow "git diff -- src/anyparse/query/Cli$X"

echo "-- real readers must stay denied --"
probe deny "cat src/anyparse/query/Cli$X"
probe deny "cat 'src/anyparse/query/Cli$X'"
probe deny "$H -5 src/anyparse/query/Cli$X"
probe deny "$S -n '1,20p' src/anyparse/query/Cli$X"
probe deny "$G -n 'foo' src/anyparse/query/Cli$X"
probe deny "awk 'NR<5' src/anyparse/query/Cli$X"
probe deny "$G -rn 'foo' src/"
probe deny "$S -n '141,148p' /Users/axg/dev/libs/Pony/src/pony/text/ParseBoy$X"
probe deny "find src -name '*$X' -exec cat {} +"

echo "-- hxq output truncation must stay a warning --"
probe warn "hxq source src/anyparse/query/Cli$X --range 1:20 | $H -3"
probe warn "hxq ast src/anyparse/query/Cli$X | $H -3"

echo "-- other allowed shapes --"
probe allow "find src -name '*$X' | $H -5"
probe allow "cat /tmp/scratch$X"
probe allow "git ls-files | $G '$X\$' | $H -5"
probe allow "hxq patch src/anyparse/query/Cli$X --select 'FnMember:f' --write - <<'EOF'"

echo "fails=$fails"
exit $fails
