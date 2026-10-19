#!/usr/bin/env bash
#
# pre-push-scrub.sh — refuse a push that would publish text from a private token list.
#
# Install once per clone:
#
#   ln -s ../../tools/hooks/pre-push-scrub.sh .git/hooks/pre-push
#   export ANYPARSE_SCRUB_LIST=<path outside the repository>
#
# The list lives OUTSIDE the repository (see tools/scrub-guard.py for its format): a list of
# names to keep out would publish them. With ANYPARSE_SCRUB_LIST unset the hook passes and says
# so. For every ref being pushed, the lines the pushed commits add and their messages are
# scanned; a match aborts the push and prints where it is, never the matched text.
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
guard="$repo/tools/scrub-guard.py"
zero=0000000000000000000000000000000000000000
status=0

while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "$zero" ] && continue
    if [ "$remote_sha" = "$zero" ]; then
        # A new remote ref: start below the oldest commit no remote-tracking ref holds yet.
        oldest=$(git rev-list "$local_sha" --not --remotes | tail -n 1)
        [ -n "$oldest" ] || continue
        base=$(git rev-parse --verify --quiet "$oldest^") || {
            echo "pre-push-scrub: $local_ref reaches a root commit no remote holds; run tools/scrub-guard.py on that tree by hand" >&2
            status=1
            continue
        }
    else
        base=$remote_sha
    fi
    python3 "$guard" --range "$base..$local_sha" || status=$?
done

if [ "$status" -ne 0 ]; then
    echo "pre-push-scrub: refusing the push ($remote_ref): scrub the matches above first" >&2
fi
exit "$status"
