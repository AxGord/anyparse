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
#   RUN-FAIL   no usable transcript, or a red header whose rows this
#              parser could not name.
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
    write_verdict "$verdict_file" "$v" "$d"
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
    local header assertions failures exp_list matcher_out
    local results_line missing extra joined nfail detail

    # The header block is found by SHAPE, not by position — the same
    # technique the "No tests executed." probe below uses, and for a
    # sharper reason than it looks. utest emits this block LAST, at
    # completion, so everything the tests themselves printed to stdout
    # comes FIRST: a real unfiltered run of this suite puts ~1700 lines
    # of CLI chatter ahead of it. Taking the first `^results:` in the
    # file would therefore read a line the TESTS control, and one
    # `results: … (success: true)` in that region would report a red run
    # as SURVIVED — the one verdict this classifier exists to never get
    # wrong. Requiring `assertations:` immediately followed by
    # `successes:` opens the block, and the counts and `results:` are
    # taken from inside it, so neither end can be spoofed.
    #
    # `assertations` is read directly rather than summed from the four
    # category lines: ResultStats counts ignores in the total too, and
    # the report does not print an `ignores:` line, so a sum would be
    # short by them. The unit is ASSERTIONS, not test methods — the
    # report row labels it as such.
    header=$(awk '
        /^assertations:[[:space:]]+[0-9]+$/ { a = $2; open = 1; next }
        open == 1 && /^successes:[[:space:]]+[0-9]+$/ { open = 2; next }
        open >= 2 && /^(errors|failures|warnings):[[:space:]]+[0-9]+$/ { next }
        open >= 2 && /^results:/ { print a; print $0; exit }
        { if (open == 1) open = 0 }
    ' "$log" 2>/dev/null || true)
    if [ -z "$header" ]; then
        printf 'RUN-FAIL\n%s\n' "$log"
        return 0
    fi
    { IFS= read -r assertions; IFS= read -r results_line; } <<EOF
$header
EOF

    # "No tests executed." arrives as an ordinary assertion-detail row,
    # so match that row's shape. An unanchored search of the whole log
    # would also fire on a test whose own message quotes the phrase.
    if grep -q '^[[:space:]]*line: [0-9]*, No tests executed\.$' "$log"; then
        printf 'NO-TESTS\nfilter matched no test class (%s)\n' "$log"
        return 0
    fi

    # The HEADER decides red/green; the rows below only NAME what went
    # red. utest keys this line and its exit code on the same predicate,
    # ResultStats.isOk = !(hasFailures || hasErrors || hasWarnings), and
    # ITestHandler auto-adds Warning('no assertions') to any test that
    # completes without asserting. So a mutation that stops a test
    # asserting produces `failures: 0, warnings: N` — a red run the suite
    # genuinely noticed, which a FAILURE|ERROR row scan would have called
    # SURVIVED. Reading the verdict from the header cannot miss a marker
    # utest adds later; the worst such a marker can do is leave the run
    # unnamed, which lands as RUN-FAIL below.
    case "$results_line" in
        *'(success: true)'*)
            printf 'SURVIVED\n0 tests failed / %s assertions\n' "$assertions"
            return 0
            ;;
    esac

    # A class line is a bare identifier at column 0 — but so is any line
    # of a multi-line assertion message, which PlainTextReport splices in
    # raw. Promoting a candidate only once the NEXT line is an indented
    # result row narrows that, it does not close it: a message whose last
    # line is a bare identifier at column 0, immediately followed by the
    # next failing method's row, still hijacks the class name. The damage
    # is bounded to a mis-attributed name — KILLED can degrade to
    # MISMATCH — and never to a wrong red/green call, because that comes
    # from the header above.
    #
    # The marker slot matches ANY uppercase word rather than the four
    # utest emits today: a whitelist there would drop an unknown marker
    # to the `pending = ""` arm, which clears the class binding and
    # orphans the NEXT failure as `.method`. Generic slot + "anything not
    # OK is failing" means a marker added by a future utest is named and
    # counted instead. It cannot misfire on a real row — the marker slot
    # only ever holds letters, and a method literally named `OK` reads
    # `OK: FAILURE F`, which the inner test still classifies correctly.
    failures=$(awk '
        /^[A-Za-z_][A-Za-z0-9_.]*$/ { pending = $0; next }
        /^[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*:[[:space:]]+[A-Z]+([[:space:]]|$)/ {
            if (pending != "") { cls = pending; pending = "" }
            if ($0 !~ /:[[:space:]]+OK([[:space:]]|$)/) {
                m = $1; sub(/:$/, "", m); print cls "." m
            }
            next
        }
        { pending = "" }
    ' "$log" | sort -u)

    if [ -z "$failures" ]; then
        printf 'RUN-FAIL\nheader reports a red run but no result row parsed (%s)\n' "$log"
        return 0
    fi

    # ONE normalisation of the expectation CSV, then ONE matcher. The two
    # earlier passes answered the same "does this expectation match this
    # name" question twice and had already diverged: the `missing` pass
    # ran `printf | grep -q`, where grep exits at the first match and
    # SIGPIPEs the printf on a long failure list (status 141, inverted by
    # `!` into "missing" for an expectation that DID match), and the
    # `extra` pass re-trimmed every expectation inside the inner loop —
    # two forks per failure per expectation.
    exp_list=$(printf '%s' "$expected" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)

    # Passed through the environment, not `-v`: awk applies escape
    # processing to a `-v` value, which would mangle a backslash.
    matcher_out=$(printf '%s\n' "$failures" | MUTCHECK_EXPS="$exp_list" awk '
        function join_capped(a, n,   i, s) {
            s = ""
            for (i = 1; i <= n && i <= 10; i++) s = s (i > 1 ? ", " : "") a[i]
            if (n > 10) s = s ", …+" (n - 10) " more"
            return s
        }
        BEGIN {
            exps = ENVIRON["MUTCHECK_EXPS"]
            ne = (exps == "" ? 0 : split(exps, E, "\n"))
        }
        {
            all[++nf] = $0
            if (ne == 0) next
            matched = 0
            for (i = 1; i <= ne; i++) if (index($0, E[i]) > 0) { hit[i] = 1; matched = 1 }
            if (!matched) extra[++nx] = $0
        }
        END {
            for (i = 1; i <= ne; i++) if (!(i in hit)) miss[++nm] = E[i]
            print join_capped(miss, nm + 0)
            print join_capped(extra, nx + 0)
            print join_capped(all, nf + 0)
            print nf + 0
        }
    ')

    { IFS= read -r missing; IFS= read -r extra; IFS= read -r joined; IFS= read -r nfail; } <<EOF
$matcher_out
EOF

    if [ -n "$missing" ]; then
        printf 'MISMATCH\n%s tests failed / %s assertions: %s (missing: %s)\n' \
            "$nfail" "$assertions" "$joined" "$missing"
        return 0
    fi

    # Failures the expectations did not name are reported, not penalised:
    # the question a track asks is "does the suite notice", and a wider
    # blast radius still answers yes.
    detail="$nfail tests failed / $assertions assertions: $joined"
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
