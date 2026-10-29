#!/bin/sh
# PostToolUse hook (matcher Bash): after an hxq op that WROTE, the lint findings that edit added — the body is
# `dev lint-warn` (tools/src/dev/LintWarn.hx). Install: `ln -sf ../../tools/hooks/hxq-lint-warn.sh .claude/hooks/`.
# It runs after every Bash call, so the early exit is pure shell; no built bin/dev.js beside this file is silence.
input=$(cat)
case "$input" in *': wrote '* | *': rewrote '*) ;; *) exit 0 ;; esac
self=$0
while [ -L "$self" ]; do link=$(readlink "$self"); case "$link" in /*) self=$link ;; *) self=$(dirname "$self")/$link ;; esac; done
dev="$(cd -P "$(dirname "$self")/../.." && pwd)/bin/dev.js"
[ -f "$dev" ] && printf '%s' "$input" | node "$dev" lint-warn
exit 0
