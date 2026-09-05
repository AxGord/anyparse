#!/usr/bin/env bash
#
# mutation-check.sh — run mutation tracks in parallel and report which
# ones the test suite actually NOTICES.
#
# The six test layers say what the code does. A mutation check asks the
# opposite question: if the code stopped doing it, would anything go
# red? A track breaks one mechanism on purpose (a git patch), runs a
# narrow slice of the suite against the patched tree, and reports
# whether the suite caught it. SURVIVED is the finding the tool exists
# for — a green suite over a mechanism no fixture reaches.
#
# Each track gets its own git worktree from HEAD plus its own private
# build (tools/worker-build.sh), so tracks run in parallel and never
# touch bin/apq.js or bin/test.js. Because the worktrees come from HEAD,
# uncommitted work in the main tree is NOT seen — commit (or stash into
# the patch) whatever the mutation is supposed to be measured against.
#
# Usage: tools/mutation-check.sh <manifest> [--jobs N]
#
# For a mutation that a `@:killer` in the test tree NAMES, do not write a
# manifest by hand: `tools/mutation-arm.sh <ARM>` renders the arm's record out
# of `test/testkit/mutation-arms.json`, derives the expectation set from the
# arm's own pins, and calls this script. A hand-written manifest is for a
# one-off probe, where the patch is the whole point and no pin refers to it.
#
# Manifest format — line-oriented, `|`-separated, 4 fields, surrounding
# whitespace trimmed. Blank lines and lines whose first non-blank
# character is `#` are ignored.
#
#   <name> | <patch-file> | <APQ_TEST filter> | <expected>[,<expected>...]
#
#   name      track id, [A-Za-z0-9_.-]+, unique in the manifest. Names
#             the worktree dir and the report row.
#   patch     a git patch (`git diff` output), applied with
#             `git -C <worktree> apply`. Resolved relative to the
#             MANIFEST's own directory (absolute paths pass through), so
#             a manifest plus its patches is one movable bundle. The
#             worktree is created from HEAD, so a `git diff` taken
#             against HEAD applies deterministically — authoring a track
#             is: edit the main tree, `git diff > x.patch`, revert.
#   filter    required, non-empty. Passed as APQ_TEST. The literal word
#             ALL runs the whole suite with APQ_TEST unset.
#   expected  comma-separated substrings, may be empty. Each is matched
#             against the collected failure names
#             (`<fq.ClassName>.<testMethod>`).
#
# Verdicts:
#   KILLED     the run went red, and every expectation matched something
#              (no expectations given = any red kills). Failures beyond
#              the expectations do NOT demote this — they are reported
#              as `+extra:` on the row.
#   SURVIVED   the run was GREEN — utest's own `(success: true)`. The
#              vacuum. Note this is stricter than "nothing FAILED": a
#              test that stops asserting is reported as a WARNING, and
#              utest counts that as red.
#   MISMATCH   the run went red, but some expectation matched nothing.
#   NO-TESTS   the filter matched no test class. Loud on purpose: a
#              typo'd filter would otherwise read as SURVIVED.
#   WT-FAIL    `git worktree add` failed — nothing to patch or run.
#   PATCH-FAIL `git apply` failed. Manifest/patch defect.
#   BUILD-FAIL the patched tree does not compile — a useless mutation.
#   RUN-FAIL   no usable transcript, or a red header whose rows the
#              classifier could not name.
#
# Verdicts come from `apq mutation-verdict` (main-tree build), not from
# this script — see `classify` below for why the parser is not here.
#
# Exit 0 only when every track is KILLED; any other verdict exits 1.
#
# Every worktree this script created is removed on exit (including on
# INT/TERM/HUP); a `worktree remove` that itself fails is swallowed so
# one bad entry cannot strand the rest, which does mean a stuck worktree
# can survive as a registered entry — `git worktree list` after a crashed
# run is the check. The workroot is never deleted: its transcripts,
# build logs and .verdict files are the post-mortem, and they accumulate
# in TMPDIR across a long campaign.
set -euo pipefail

script_dir=$(cd -P "$(dirname "$0")" && pwd)
self="$script_dir/$(basename "$0")"
repo=$(cd -P "$script_dir/.." && pwd)

# ---------------------------------------------------------------- parse

# Emit `name<TAB>patch<TAB>filter<TAB>expected` for every data line of a
# manifest, with the patch path already resolved against the manifest's
# directory. Bails on a malformed line.
parse_manifest() {
    local manifest=$1 manifest_dir line name patch filter expected lineno=0
    manifest_dir=$(cd -P "$(dirname "$manifest")" && pwd)
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in
            ''|'#'*) continue ;;
        esac
        name=$(printf '%s' "$line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        patch=$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        filter=$(printf '%s' "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        expected=$(printf '%s' "$line" | cut -d'|' -f4- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ "$(printf '%s' "$line" | tr -cd '|' | wc -c | tr -d ' ')" -lt 3 ]; then
            echo "mutation-check.sh: $manifest:$lineno: expected 4 '|'-separated fields" >&2
            return 1
        fi
        case "$name" in
            *[!A-Za-z0-9_.-]*|'')
                echo "mutation-check.sh: $manifest:$lineno: bad track name '$name' (allowed: A-Za-z0-9_.-)" >&2
                return 1
                ;;
        esac
        if [ -z "$patch" ]; then
            echo "mutation-check.sh: $manifest:$lineno: track '$name' has no patch file" >&2
            return 1
        fi
        case "$patch" in
            /*) ;;
            *) patch="$manifest_dir/$patch" ;;
        esac
        if [ -z "$filter" ]; then
            echo "mutation-check.sh: $manifest:$lineno: track '$name' has an empty APQ_TEST filter (use ALL for the whole suite)" >&2
            return 1
        fi
        printf '%s\t%s\t%s\t%s\n' "$name" "$patch" "$filter" "$expected"
    done < "$manifest"
}

# ---------------------------------------------------------- child mode

# `--track <name> <manifest> <workroot>` — one track, run by xargs. The
# child re-reads the manifest to find its own line so nothing has to
# survive shell quoting. It ALWAYS exits 0, otherwise xargs aborts the
# whole batch on the first failing mutation.
run_track() {
    local name=$1 manifest=$2 workroot=$3
    local row filter expected wt build log verdict_file
    verdict_file="$workroot/$name.verdict"
    wt="$workroot/wt-$name"
    build="$workroot/build-$name"
    log="$workroot/$name.log"

    # awk must NOT `exit` on the first match: under `pipefail` that closes
    # the pipe early, parse_manifest dies of SIGPIPE, and the child aborts
    # without ever writing a verdict.
    row=$(parse_manifest "$manifest" | awk -F'\t' -v n="$name" '$1 == n && !seen { print; seen = 1 }')
    if [ -z "$row" ]; then
        write_verdict "$verdict_file" "RUN-FAIL" "track '$name' vanished from $manifest between the parent's parse and this child's"
        return 0
    fi
    filter=$(printf '%s' "$row" | cut -f3)
    expected=$(printf '%s' "$row" | cut -f4)

    if ! "$wt/tools/worker-build.sh" "$build" test > "$workroot/$name.build.log" 2>&1; then
        write_verdict "$verdict_file" "BUILD-FAIL" "$workroot/$name.build.log"
        return 0
    fi

    if [ "$filter" = "ALL" ]; then
        ( cd "$wt" && env -u APQ_TEST node "$build/test.js" ) > "$log" 2>&1 || true
    else
        ( cd "$wt" && APQ_TEST="$filter" node "$build/test.js" ) > "$log" 2>&1 || true
    fi

    # Captured, not redirected straight into the file: `> "$verdict_file"`
    # truncates before classify runs, so an abort inside it would leave an
    # empty file and the report would print a blank verdict column.
    # write_verdict stays the single owner of the file format.
    local classified v d
    if ! classified=$(classify "$log" "$expected"); then
        write_verdict "$verdict_file" "RUN-FAIL" "classifier aborted on $log"
        return 0
    fi
    { IFS= read -r v; IFS= read -r d; } <<EOF
$classified
EOF
    # The classifier reports WHY it could not judge; only the shell knows
    # WHERE the transcript is, and a RUN-FAIL row is read by someone about
    # to open it.
    if [ "$v" = "RUN-FAIL" ]; then
        d="$d ($log)"
    fi
    write_verdict "$verdict_file" "$v" "$d"
    return 0
}

write_verdict() {
    printf '%s\n%s\n' "$2" "$3" > "$1"
}

# ------------------------------------------------------------- parsing

# classify <log> <expected-csv> -> two lines: verdict, detail.
#
# The whole classifier lives in `apq mutation-verdict`. It used to live
# here, as ~130 lines of awk that re-implemented a utest transcript
# parser `apq test-summary` had already carried for longer than this
# script has existed — and which suite-shard.sh reuses precisely so a
# second, divergent one cannot grow. One grew anyway, and the price is
# on record: both fdb44864 ("a red run can no longer be reported
# SURVIVED") and ff3f20ae ("find the utest header by SHAPE") were bugs
# in the duplicate, 316 changed lines apart, and neither was reachable
# by a test, because a shell function is not testable. The Haxe copy is
# covered by test/unit/MutationVerdictTest.hx.
#
# It runs from the MAIN tree, never from the track's own build: the
# track's engine is compiled FROM the mutated source, so a mutation that
# reached the transcript parser would otherwise grade its own homework.
# `cd "$repo"` is what makes the hxq shim resolve the unmutated tree.
classify() {
    local log=$1 expected=$2
    ( cd "$repo" && "$repo/bin/hxq" mutation-verdict "$log" --expect "$expected" )
}

# --------------------------------------------------- child entry point

if [ "${1:-}" = "--track" ]; then
    if [ "$#" -ne 4 ]; then
        echo "mutation-check.sh: --track needs <name> <manifest> <workroot>" >&2
        exit 2
    fi
    run_track "$2" "$3" "$4"
    exit 0
fi

# -------------------------------------------------------- parent mode

if [ "$#" -lt 1 ]; then
    echo "usage: mutation-check.sh <manifest> [--jobs N]" >&2
    exit 2
fi

manifest=$1
shift
jobs=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --jobs)
            if [ "$#" -lt 2 ]; then
                echo "mutation-check.sh: --jobs needs a number" >&2
                exit 2
            fi
            jobs=$2
            shift 2
            ;;
        *)
            echo "mutation-check.sh: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$manifest" ]; then
    echo "mutation-check.sh: manifest '$manifest' not found" >&2
    exit 2
fi

# The verdict classifier is `apq mutation-verdict` out of the MAIN tree.
# Checked here rather than per track: without it every track would run its
# build and its suite and only then fail to be judged.
if [ ! -f "$repo/bin/apq.js" ]; then
    echo "mutation-check.sh: $repo/bin/apq.js missing — run 'haxe bin/apq-js.hxml' first (the verdict classifier is 'apq mutation-verdict')" >&2
    exit 2
fi

if ! rows=$(parse_manifest "$manifest"); then
    exit 2
fi
if [ -z "$rows" ]; then
    echo "mutation-check.sh: manifest '$manifest' has no tracks" >&2
    exit 2
fi

# Guard clauses before any work: a missing patch or a duplicate name is
# a manifest defect, and finding it after four worktrees and four builds
# wastes minutes.
dupes=$(printf '%s\n' "$rows" | cut -f1 | sort | uniq -d)
if [ -n "$dupes" ]; then
    echo "mutation-check.sh: duplicate track name(s): $(printf '%s' "$dupes" | tr '\n' ' ')" >&2
    exit 2
fi
missing_patch=0
while IFS=$'\t' read -r name patch filter expected; do
    if [ ! -f "$patch" ]; then
        echo "mutation-check.sh: track '$name': patch '$patch' not found" >&2
        missing_patch=1
    fi
done <<EOF
$rows
EOF
if [ "$missing_patch" -ne 0 ]; then
    exit 2
fi

if [ -n "$jobs" ]; then
    # A user-supplied value is validated, never clamped: silently turning
    # `--jobs 0` into 1 contradicts the error message. The zero test is
    # ARITHMETIC, not a literal in the pattern list — `case … |0)` reads
    # only the one spelling, and `--jobs 00` would sail through it into
    # `xargs -P 00`, which means UNBOUNDED parallelism: every track
    # compiling and running at once, exactly what the limit prevents.
    case "$jobs" in
        ''|*[!0-9]*)
            echo "mutation-check.sh: --jobs must be a positive integer, got '$jobs'" >&2
            exit 2
            ;;
    esac
    if [ "$jobs" -lt 1 ]; then
        echo "mutation-check.sh: --jobs must be a positive integer, got '$jobs'" >&2
        exit 2
    fi
else
    # max(1, min(4, cores/2)) — the clamps here bound OUR arithmetic, not
    # a request, so a single-core machine gets 1 rather than an error.
    if [ "$(uname -s)" = "Darwin" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        cores=$(nproc 2>/dev/null || echo 2)
    fi
    jobs=$((cores / 2))
    if [ "$jobs" -gt 4 ]; then
        jobs=4
    fi
    if [ "$jobs" -lt 1 ]; then
        jobs=1
    fi
fi

workroot=$(mktemp -d "${TMPDIR:-/tmp}/anyparse-mutcheck.XXXXXX")
echo "workroot: $workroot"

created=""
cleanup() {
    local wt
    for wt in $created; do
        git -C "$repo" worktree remove --force "$workroot/wt-$wt" >/dev/null 2>&1 || true
    done
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
}
# INT/TERM/HUP exit rather than resuming, which then fires the EXIT trap
# once. HUP matters here because the common way this runs is an agent
# session whose terminal goes away mid-campaign.
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Worktree creation is SERIAL: parallel `git worktree add` races over
# .git/worktrees. The expensive parts (build, test run) are the parallel
# ones.
runnable=""
while IFS=$'\t' read -r name patch filter expected; do
    if ! git -C "$repo" worktree add --detach --quiet "$workroot/wt-$name" HEAD 2>"$workroot/$name.wt.log"; then
        write_verdict "$workroot/$name.verdict" "WT-FAIL" "worktree add failed: $(tr '\n' ' ' < "$workroot/$name.wt.log")"
        continue
    fi
    created="$created $name"
    # `--` so a patch path beginning with `-` is a path, not a flag.
    if ! git -C "$workroot/wt-$name" apply -- "$patch" 2>"$workroot/$name.apply.log"; then
        write_verdict "$workroot/$name.verdict" "PATCH-FAIL" "$(tr '\n' ' ' < "$workroot/$name.apply.log")"
        continue
    fi
    runnable="$runnable$name
"
done <<EOF
$rows
EOF

# Children always exit 0, so xargs failing here means xargs itself broke;
# the report below turns a missing verdict into RUN-FAIL either way.
if [ -n "$runnable" ]; then
    if ! printf '%s' "$runnable" | xargs -P "$jobs" -I{} "$self" --track {} "$manifest" "$workroot"; then
        echo "mutation-check.sh: xargs reported a failure — see the per-track verdicts below" >&2
    fi
fi

# ------------------------------------------------------------- report

killed=0
survived=0
mismatch=0
errors=0
exit_code=0

while IFS=$'\t' read -r name patch filter expected; do
    verdict="RUN-FAIL"
    detail="no verdict written"
    if [ -f "$workroot/$name.verdict" ]; then
        verdict=$(sed -n '1p' "$workroot/$name.verdict")
        detail=$(sed -n '2p' "$workroot/$name.verdict")
    fi
    case "$verdict" in
        KILLED) killed=$((killed + 1)) ;;
        SURVIVED) survived=$((survived + 1)); exit_code=1 ;;
        MISMATCH) mismatch=$((mismatch + 1)); exit_code=1 ;;
        *) errors=$((errors + 1)); exit_code=1 ;;
    esac
    printf '%-10s %-20s filter=%-14s %s\n' "$verdict" "$name" "$filter" "$detail"
done <<EOF
$rows
EOF

total_tracks=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
echo "$total_tracks tracks: $killed killed, $survived survived, $mismatch mismatch, $errors error"
echo "workroot: $workroot (logs and verdicts kept)"
exit "$exit_code"
