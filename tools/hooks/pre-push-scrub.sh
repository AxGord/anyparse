#!/usr/bin/env bash
#
# pre-push-scrub.sh — refuse a push that would publish text from a private token list.
#
# Install once per clone:
#
#   ln -s ../../tools/hooks/pre-push-scrub.sh .git/hooks/pre-push
#   export ANYPARSE_SCRUB_LIST=<path outside the repository>
#
# The list lives OUTSIDE the repository (see tools/src/dev/ScrubGuard.hx for its format): a list
# of names to keep out would publish them. With ANYPARSE_SCRUB_LIST unset the hook passes and says
# so. The guard is `node bin/dev.js scrub-guard`; build it once with `haxe tools/dev.hxml`. For every ref being pushed, the lines the pushed commits add and their messages are
# scanned; a match aborts the push and prints where it is, never the matched text.
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
guard="$repo/bin/dev.js"
if [ ! -f "$guard" ]; then
    if [ -z "${ANYPARSE_SCRUB_LIST:-}" ]; then
        echo "pre-push-scrub: no token list (ANYPARSE_SCRUB_LIST), nothing checked" >&2
        exit 0
    fi
    echo "pre-push-scrub: $guard is missing; build it with \`haxe tools/dev.hxml\` from $repo" >&2
    exit 1
fi
zero=0000000000000000000000000000000000000000
status=0
refused=""

while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "$zero" ] && continue
    if [ "$remote_sha" = "$zero" ]; then
        # A new remote ref: start below the oldest commit no remote-tracking ref holds yet.
        oldest=$(git rev-list "$local_sha" --not --remotes | tail -n 1)
        [ -n "$oldest" ] || continue
        base=$(git rev-parse --verify --quiet "$oldest^") || {
            echo "pre-push-scrub: $local_ref reaches a root commit no remote holds; run \`node bin/dev.js scrub-guard\` on that tree by hand" >&2
            status=1
            continue
        }
    else
        base=$remote_sha
    fi
    node "$guard" scrub-guard --range "$base..$local_sha" || { status=$?; refused="$refused $remote_ref"; }
done

if [ "$status" -ne 0 ]; then
    echo "pre-push-scrub: refusing the push of${refused:- the refs above}: scrub the matches above first" >&2
fi
exit "$status"
