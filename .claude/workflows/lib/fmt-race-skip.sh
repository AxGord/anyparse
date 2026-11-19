#!/bin/sh
# Decides whether a fix round answering a land `fmt-race` verdict may skip the re-review (user yes 2026-11-10).
#   fmt-race-skip.sh patch <wt> "<files>"            prints the patch-id of the slice's own diff without <files>
#                                                     (the parent runs it at triage, on the tip the review judged)
#   fmt-race-skip.sh check <wt> "<files>" <patch-id>  exit 0: skip, go to land; exit 10: the normal re-review
# Skip only when BOTH hold: the slice's own diff (base..HEAD without <files>) has the patch-id the review judged,
# and `hxq changed base..HEAD <files>` classes every one of <files> `layout`.
mode=$1; WT=$2; FILES=$3; PID=${4:-}
cd "$WT" 2>/dev/null || { echo "fmt-race skip: no worktree $WT: review"; exit 10; }
base=$(git merge-base HEAD main) || { echo "fmt-race skip: no merge base with main: review"; exit 10; }
own_patch() {
  set -f
  set --
  for f in $FILES; do set -- "$@" ":(exclude)$f"; done
  git diff "$base..HEAD" -- . "$@" | git patch-id --stable | cut -d' ' -f1
  set +f
}
case "$mode" in
  patch)
    [ -n "$FILES" ] || { echo "usage: fmt-race-skip.sh patch <wt> \"<files>\"" >&2; exit 2; }
    own_patch; exit 0;;
  check) ;;
  *) echo "usage: fmt-race-skip.sh patch|check <wt> \"<files>\" [<patch-id>]" >&2; exit 2;;
esac
[ -n "$FILES" ] && [ -n "$PID" ] || { echo "fmt-race skip: not a fmt-race round: review"; exit 10; }
now=$(own_patch)
[ "$now" = "$PID" ] || { echo "fmt-race skip: the slice's own diff changed since the review (patch-id $PID -> ${now:-none}): review"; exit 10; }
set -f
out=$(HXQ_BIN="${HXQ_BIN:-$WT/bin/apq.js}" hxq changed "$base..HEAD" $FILES 2>&1) || { echo "fmt-race skip: hxq changed exited $?: $out: review"; exit 10; }
set +f
n=0; bad=""
for f in $FILES; do
  cls=$(printf '%s\n' "$out" | awk -v p="$f" '$1 ~ /^[MADR]$/ && $2 == p { print $3; exit }')
  n=$((n + 1))
  [ "$cls" = "layout" ] || bad="$bad $f=${cls:-unchanged}"
done
[ -z "$bad" ] || { echo "fmt-race skip: not layout-only:$bad: review"; exit 10; }
echo "fmt-race skip: $n file(s) layout-only, the slice's own diff as reviewed (patch-id $PID): land without a re-review"
exit 0
