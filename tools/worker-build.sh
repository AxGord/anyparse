#!/usr/bin/env bash
#
# worker-build.sh — build a PRIVATE pair of engine binaries for one worker.
#
# Problem this solves: `bin/apq.js` and `bin/test.js` are single shared
# artifacts. Two agents working the same repo at once truncate each
# other's binary mid-run, so only one of them can build or run anything
# at a time — the parallelism is lost before it starts. Each worker
# instead builds into its own workdir and never touches bin/.
#
# Recipe:
#   tools/worker-build.sh /tmp/w1            # both binaries
#   tools/worker-build.sh /tmp/w1 test       # just the test runner
#   node /tmp/w1/test.js                     # instead of node bin/test.js
#   APQ_TEST=RemoveParam node /tmp/w1/test.js
#   HXQ_BIN=/tmp/w1/apq.js hxq probe 'class C {}'
#
# Some tests read paths relative to the CWD (bin/.last-sweep.json,
# test/ fixtures, hxformat.json, apqlint.json), so run the private
# test.js with the CWD set to the tree it was built from.
#
# Usage: tools/worker-build.sh <workdir> [both|apq|test]
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: worker-build.sh <workdir> [both|apq|test]" >&2
    exit 2
fi

workdir=$1
target=${2:-both}

if [ -z "$workdir" ]; then
    echo "worker-build.sh: empty <workdir>" >&2
    exit 2
fi

case "$target" in
    both|apq|test) ;;
    *)
        echo "worker-build.sh: unknown target '$target' (expected both|apq|test)" >&2
        exit 2
        ;;
esac

# The repo is resolved from THIS SCRIPT's own location, never from the
# CWD. Load-bearing: a copy of this script inside a git worktree must
# build THAT worktree's src/, so a mutation track measures its own patched
# tree instead of silently rebuilding the main tree.
script_dir=$(cd -P "$(dirname "$0")" && pwd)
repo=$(cd -P "$script_dir/.." && pwd)

# `out` needs the directory to exist before `cd -P` can resolve it, so
# the mkdir precedes the bin/ check below rather than following it. That
# is harmless here: the only path the check rejects is the repo's own
# bin/, which always exists already, so the mkdir is a no-op on it.
mkdir -p "$workdir"
out=$(cd -P "$workdir" && pwd)

# `tools/worker-build.sh bin` would write bin/apq.js and bin/test.js —
# precisely the shared-artifact clobbering this script exists to avoid.
# Compared after resolution, so `bin`, `./bin` and an absolute path are
# all caught.
if [ "$out" = "$repo/bin" ]; then
    echo "worker-build.sh: <workdir> is the repo's own bin/ — that is the shared build this script exists to avoid; pick a private directory" >&2
    exit 2
fi

apq_pid=""
test_pid=""

if [ "$target" = "both" ] || [ "$target" = "apq" ]; then
    ( cd "$repo" && haxe bin/apq-js-common.hxml -js "$out/apq.js" ) > "$out/build-apq.log" 2>&1 &
    apq_pid=$!
fi

if [ "$target" = "both" ] || [ "$target" = "test" ]; then
    ( cd "$repo" && haxe test-js-common.hxml -js "$out/test.js" ) > "$out/build-test.log" 2>&1 &
    test_pid=$!
fi

# bash 3.2 (macOS system bash) has no `wait -n`, so collect each job by
# its own pid and keep going — both logs are more useful than the first.
rc=0
failed=""

if [ -n "$apq_pid" ]; then
    wait "$apq_pid" || { rc=1; failed="$failed apq"; }
fi
if [ -n "$test_pid" ]; then
    wait "$test_pid" || { rc=1; failed="$failed test"; }
fi

if [ "$rc" -ne 0 ]; then
    for job in $failed; do
        echo "worker-build.sh: $job build FAILED — $out/build-$job.log" >&2
        tail -n 30 "$out/build-$job.log" >&2
    done
    exit 1
fi

if [ -n "$apq_pid" ]; then
    echo "apq: $out/apq.js"
fi
if [ -n "$test_pid" ]; then
    echo "test: $out/test.js"
fi
