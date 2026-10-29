#!/bin/sh
# pre-push hook: refuse a push that would publish text from a private token list — the body is `dev scrub-guard --pre-push`
# (tools/src/dev/ScrubGuard.hx). Install: `ln -s ../../tools/hooks/pre-push-scrub.sh .git/hooks/pre-push`.
dev="$(git rev-parse --show-toplevel)/bin/dev.js"
[ -f "$dev" ] || [ -z "$ANYPARSE_SCRUB_LIST$ANYPARSE_SCRUB_PRIVATE_ROOTS" ] || { echo "pre-push-scrub: $dev is missing; build it with \`haxe tools/dev.hxml\`" >&2; exit 1; }
[ -f "$dev" ] || { echo "pre-push-scrub: no token list and no private root, nothing checked" >&2; exit 0; }
exec node "$dev" scrub-guard --pre-push
