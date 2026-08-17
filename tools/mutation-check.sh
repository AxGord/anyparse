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
#   KILLED     the suite failed, and every expectation matched something
#              (no expectations given = any failure kills). Failures
#              beyond the expectations do NOT demote this — they are
#              reported as `+extra:` on the row.
#   SURVIVED   the suite ran and nothing failed. The vacuum.
#   MISMATCH   the suite failed, but some expectation matched nothing.
#   NO-TESTS   the filter matched no test class. Loud on purpose: a
#              typo'd filter would otherwise read as SURVIVED.
#   PATCH-FAIL `git apply` failed. Manifest/patch defect.
#   BUILD-FAIL the patched tree does not compile — a useless mutation.
#   RUN-FAIL   the runner produced no usable transcript.
#
# Exit 0 only when every track is KILLED; any other verdict exits 1.
#
# Worktrees are always removed on exit. The logs and .verdict files in
# the workroot are deliberately KEPT for post-mortem.
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

    classify "$log" "$expected" > "$verdict_file"
    return 0
}

write_verdict() {
    printf '%s\n%s\n' "$2" "$3" > "$1"
}

# ------------------------------------------------------------- parsing
# utest 1.13.2 plain-text transcript:
#   header rows (`successes: N`, …, `results: ALL TESTS OK (success: true)`)
#   then, per class, a bare fully-qualified class name on its own line,
#   followed by two-space-indented `  testMethod: OK|FAILURE|ERROR|WARNING …`
#   rows and further-indented detail rows.

# classify <log> <expected-csv> -> two lines: verdict, detail.
classify() {
    local log=$1 expected=$2
    local total failures missing extra detail first

    if ! grep -q '^results:' "$log" 2>/dev/null; then
        printf 'RUN-FAIL\n%s\n' "$log"
        return 0
    fi
    if grep -q 'No tests executed\.' "$log"; then
        printf 'NO-TESTS\nfilter matched no test class (%s)\n' "$log"
        return 0
    fi

    # The tests-run count comes from the HEADER, not from counting rows:
    # once a run has a failure utest stops listing the passing tests, so
    # the per-class rows are the failures alone and a row count would
    # report every killed track as "3/3 failed".
    total=$(awk '
        /^successes:[[:space:]]+[0-9]+$/ { s = $2 }
        /^failures:[[:space:]]+[0-9]+$/  { f = $2 }
        /^errors:[[:space:]]+[0-9]+$/    { e = $2 }
        END { print (s + f + e) + 0 }
    ' "$log")

    # A class line is a bare identifier at column 0 — but so is any line
    # of a multi-line assertion message, which utest splices in raw. A
    # candidate is only promoted once the NEXT line is an indented result
    # row, which is the one thing a message body cannot fake.
    failures=$(awk '
        /^[A-Za-z_][A-Za-z0-9_.]*$/ { pending = $0; next }
        /^[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*:[[:space:]]+(OK|FAILURE|ERROR|WARNING)([[:space:]]|$)/ {
            if (pending != "") { cls = pending; pending = "" }
            if ($0 ~ /:[[:space:]]+(FAILURE|ERROR)([[:space:]]|$)/) {
                m = $1; sub(/:$/, "", m); print cls "." m
            }
            next
        }
        { pending = "" }
    ' "$log" | sort -u)

    if [ -z "$failures" ]; then
        printf 'SURVIVED\n0/%s failed\n' "$total"
        return 0
    fi

    missing=""
    if [ -n "$expected" ]; then
        local exp rest
        rest=$expected
        while [ -n "$rest" ]; do
            exp=${rest%%,*}
            if [ "$exp" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
            exp=$(printf '%s' "$exp" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$exp" ] && ! printf '%s\n' "$failures" | grep -qF -- "$exp"; then
                missing="$missing${missing:+, }$exp"
            fi
        done
    fi

    first=$(printf '%s\n' "$failures" | awk '{ printf "%s%s", sep, $0; sep = ", " } END { print "" }')
    if [ -n "$missing" ]; then
        printf 'MISMATCH\n%s/%s failed: %s (missing: %s)\n' \
            "$(printf '%s\n' "$failures" | wc -l | tr -d ' ')" "$total" "$first" "$missing"
        return 0
    fi

    # Failures the expectations did not name are reported, not penalised:
    # the question a track asks is "does the suite notice", and a wider
    # blast radius still answers yes.
    extra=""
    if [ -n "$expected" ]; then
        local f rest2 exp2 hit
        while IFS= read -r f; do
            hit=0
            rest2=$expected
            while [ -n "$rest2" ]; do
                exp2=${rest2%%,*}
                if [ "$exp2" = "$rest2" ]; then rest2=""; else rest2=${rest2#*,}; fi
                exp2=$(printf '%s' "$exp2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                if [ -n "$exp2" ]; then
                    case "$f" in *"$exp2"*) hit=1 ;; esac
                fi
            done
            if [ "$hit" -eq 0 ]; then
                extra="$extra${extra:+, }$f"
            fi
        done <<EOF
$failures
EOF
    fi

    detail=$(printf '%s/%s failed: %s' \
        "$(printf '%s\n' "$failures" | wc -l | tr -d ' ')" "$total" "$first")
    if [ -n "$extra" ]; then
        detail="$detail +extra: $extra"
    fi
    printf 'KILLED\n%s\n' "$detail"
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

if [ -z "$jobs" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        cores=$(nproc 2>/dev/null || echo 2)
    fi
    jobs=$((cores / 2))
    if [ "$jobs" -gt 4 ]; then
        jobs=4
    fi
fi
case "$jobs" in
    ''|*[!0-9]*)
        echo "mutation-check.sh: --jobs must be a positive integer, got '$jobs'" >&2
        exit 2
        ;;
esac
if [ "$jobs" -lt 1 ]; then
    jobs=1
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
# INT/TERM exit rather than resuming, which then fires the EXIT trap once.
trap cleanup EXIT
trap 'exit 130' INT TERM

# Worktree creation is SERIAL: parallel `git worktree add` races over
# .git/worktrees. The expensive parts (build, test run) are the parallel
# ones.
runnable=""
while IFS=$'\t' read -r name patch filter expected; do
    if ! git -C "$repo" worktree add --detach --quiet "$workroot/wt-$name" HEAD 2>"$workroot/$name.wt.log"; then
        write_verdict "$workroot/$name.verdict" "PATCH-FAIL" "worktree add failed: $(tr '\n' ' ' < "$workroot/$name.wt.log")"
        continue
    fi
    created="$created $name"
    if ! git -C "$workroot/wt-$name" apply "$patch" 2>"$workroot/$name.apply.log"; then
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
