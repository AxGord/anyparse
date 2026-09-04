#!/usr/bin/env bash
#
# suite-shard.sh — run the WHOLE utest suite as N parallel `APQ_TEST` shards.
#
# The suite is one `node bin/test.js` process and the profile says its cost
# is a thick head plus a long flat tail: the top 20 of 634 classes are 75 %
# of the wall time, the remaining 614 share the rest. That shape shards well
# — four processes measure ~2.5x faster than one — but only if every
# registered class runs EXACTLY ONCE and the classes that share mutable
# state outside their own process stay in ONE shard.
#
# Both of those are decided by `apq shard-plan`, not by this script. It
# takes the class list the runner itself prints (`--list-classes`), refuses
# a registration it cannot turn into a filter, refuses a name that is a
# substring of another (`APQ_TEST` is a SUBSTRING filter, so such a class
# would run TWICE once the two land on different shards), pins the
# shared-state group to shard 0, splits the rest greedily by measured
# weight, and gates its own plan on covering the class list exactly once.
# The reasoning behind each gate lives at `ShardPlan`, and
# `unit.query.ShardPlanTest` is the cover it never had while it was awk.
#
# Measured on Mac15,9 / 16 CPU at 11423 tests, wall of the parallel region:
# 1 shard 21.8s · 2 shards 13.9s · 4 shards 8.5s · 6 shards 6.9s · 8 shards
# 6.9s. The curve is flat past six — what is left is the sticky group plus
# the ~2.4 s of std/haxelib resolution warm-up every shard re-pays. The
# default is 4 because the extra shards buy ~1.5 s at the price of that
# warm-up multiplied again: ask for -n 6 on a many-core box, do not assume it.
#
# Usage:
#   tools/suite-shard.sh                     # 4 shards, class parity only
#   tools/suite-shard.sh -n 8                # 8 shards
#   tools/suite-shard.sh --verify            # + a monolith run, counts compared
#   tools/suite-shard.sh --expect <T>/<A>    # + compare to YOUR last known-good
#                                            #   pair; the totals grow every
#                                            #   slice, so there is no literal
#                                            #   worth copying out of this file
#   tools/suite-shard.sh --plan-only         # print the shard plan, run nothing
#   tools/suite-shard.sh --bin /tmp/w1/test.js   # a private worker build
#   tools/suite-shard.sh --keep              # keep the work directory on success
#
# --verify and --expect are mutually exclusive. Exit status is 0 only when
# every shard is green AND parity holds. A red shard, an empty shard, a
# substring collision, a registration the parser cannot name, a pinned
# class that no longer exists, a class that landed in no shard or in two,
# and a count mismatch under --verify/--expect all exit 1 or 2. Work files
# are kept on any non-zero exit; on a plan-stage refusal that is the plan,
# on a run-stage failure it is the per-shard logs.
set -euo pipefail

shards=4
verify=0
expect=""
plan_only=0
keep=0
test_js=""

# A value-taking flag given as the LAST argument would otherwise reach
# `shift 2` with one argument left, and bash's own "shift count out of
# range" under `set -e` names neither the flag nor the script.
need_value() {
    if [ "$2" -lt 2 ]; then
        echo "suite-shard.sh: $1 needs a value" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--shards)
            need_value "$1" "$#"
            shards=$2
            shift 2
            ;;
        --verify)
            verify=1
            shift
            ;;
        --expect)
            need_value "$1" "$#"
            expect=$2
            shift 2
            ;;
        --bin)
            need_value "$1" "$#"
            test_js=$2
            shift 2
            ;;
        --plan-only)
            plan_only=1
            shift
            ;;
        --keep)
            keep=1
            shift
            ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -euo/d'
            exit 0
            ;;
        *)
            echo "suite-shard.sh: unknown argument '$1' (try --help)" >&2
            exit 2
            ;;
    esac
done

case "$shards" in
    ''|*[!0-9]*)
        echo "suite-shard.sh: -n expects a positive integer, got '$shards'" >&2
        exit 2
        ;;
esac
if [ "$shards" -lt 1 ]; then
    echo "suite-shard.sh: -n must be >= 1" >&2
    exit 2
fi

if [ "$verify" -eq 1 ] && [ -n "$expect" ]; then
    echo "suite-shard.sh: pass --verify or --expect, not both — --verify measures the pair --expect asserts" >&2
    exit 2
fi

if [ -n "$expect" ]; then
    # `${expect%%/*}` / `${expect##*/}` both yield the whole string when
    # there is no slash, so `11423` would silently compare assertions
    # against the tests count; rebuilding the string is the exact test for
    # "exactly one slash".
    expect_tests=${expect%%/*}
    expect_asserts=${expect##*/}
    case "$expect_tests$expect_asserts" in
        ''|*[!0-9]*) expect_ok=0 ;;
        *) expect_ok=1 ;;
    esac
    if [ "$expect_tests/$expect_asserts" != "$expect" ] || [ "$expect_ok" -eq 0 ]; then
        echo "suite-shard.sh: --expect wants TESTS/ASSERTIONS (two integers, one slash), got '$expect'" >&2
        exit 2
    fi
fi

# The repo comes from THIS SCRIPT's location, never the CWD — same rule as
# worker-build.sh. The CWD then matters for a second reason: test.js reads
# bin/.last-sweep.json, hxformat.json, apqlint.json and its fixtures
# relative to the process CWD, so every shard must run from the tree the
# binary was built from.
script_dir=$(cd -P "$(dirname "$0")" && pwd)
repo=$(cd -P "$script_dir/.." && pwd)
cd "$repo"

if [ -z "$test_js" ]; then
    test_js="$repo/bin/test.js"
fi
if [ ! -f "$test_js" ]; then
    echo "suite-shard.sh: no test runner at $test_js — build it with 'haxe test-js.hxml' (or pass --bin)" >&2
    exit 2
fi
if ! command -v hxq > /dev/null 2>&1; then
    echo "suite-shard.sh: hxq is not on PATH — 'apq shard-plan' computes the whole shard plan" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/apq-suite-shard.XXXXXX")
# `$?` is read at trap entry so that a `set -e` death anywhere — not only
# the explicit `exit 1`s that set `rc` first — keeps the work directory the
# failure messages point at.
cleanup() {
    status=$?
    if [ "$keep" -eq 0 ] && [ "$status" -eq 0 ] && [ "$rc" -eq 0 ]; then
        rm -rf "$work"
    else
        echo "suite-shard.sh: work files kept in $work" >&2
    fi
}
rc=0
trap cleanup EXIT

# --- 1. the shard plan -------------------------------------------------
#
# Everything that COUNTS is `apq shard-plan`: the substring-collision gate,
# the pinned group, the measured weights, the greedy
# longest-processing-time-first split and the parity gates on its result. It
# moved out of this script because a shell function is not testable, and
# those gates are the only thing standing between a silently-shrunken run
# and a green report — `unit.query.ShardPlanTest` is the first cover any of
# them has ever had, and it plans the REAL registry as one of its cases. Why
# each gate exists is documented at `ShardPlan`, next to the code that
# enforces it. What stays here is orchestration: spawning the shards, waiting on
# them, exit codes.
#
# The class list comes from the RUNNER, not from parsing test/RunTests.hx.
# The registration layer is generated (`testkit.TestRegistry`), so the file
# holds no `addCase(new X())` line to read any more, and asking the binary
# that will do the running is the honest question anyway: what shards get
# filtered by is exactly what one process would have registered.
#
# Two invocations because the two formats answer two questions: `lines` is
# the plan as `<shard>\t<class>` rows — the artifact --plan-only points at,
# and the thing to diff when a change is supposed to be plan-neutral —
# while `filters` is the N `APQ_TEST` values, one per line, ready to hand
# to a shard.
if ! node "$test_js" --list-classes > "$work/classes.txt" 2> "$work/classes.err"; then
    cat "$work/classes.err" >&2
    echo "suite-shard.sh: $test_js could not list its registered classes" >&2
    rc=1
    exit 1
fi

plan_or_die() {
    if ! hxq shard-plan --classes "$work/classes.txt" --shards "$shards" --format "$1" \
            > "$2" 2> "$work/plan.err"; then
        cat "$work/plan.err" >&2
        rc=1
        exit 1
    fi
}

plan_or_die lines "$work/assigned.txt"
plan_or_die filters "$work/filters.txt"

total_classes=$(wc -l < "$work/assigned.txt" | tr -d '[:space:]')

# --- producer-side count check ------------------------------------------
#
# Everything above derives from the ONE list `--list-classes` printed, so the
# "class parity OK: N/N" note at the end compares that list with itself and is
# blind to a producer that DROPPED a class — the list simply arrives shorter and
# every downstream check agrees with it. The independent number is the literal
# `REGISTERED_CLASSES` in `unit.TestDiscoveryParityTest`: hand-maintained, bumped
# deliberately when a test class is added or removed, and therefore not derived
# from the generator under test. Compared here, BEFORE any shard runs, so a drop
# names itself in one line instead of arriving minutes later as a red shard —
# and it is caught even when the pin's own class would have landed in a shard
# this invocation is not running.
#
# Advisory when the literal cannot be read: this is a cross-check, and a rename
# in that file must not fail an otherwise green suite. The pin's own assertion
# inside the run stays the authority either way.
registered_pin=$(
    sed -n 's/.*REGISTERED_CLASSES[^=]*= *\([0-9][0-9]*\).*/\1/p' \
        test/unit/TestDiscoveryParityTest.hx 2> /dev/null | sed -n 1p
)
producer_note="producer count not cross-checked (REGISTERED_CLASSES unreadable)"
if [ -n "$registered_pin" ]; then
    if [ "$total_classes" -ne "$registered_pin" ]; then
        echo "suite-shard.sh: the class-list producer printed $total_classes classes, but" >&2
        echo "  unit.TestDiscoveryParityTest pins REGISTERED_CLASSES = $registered_pin." >&2
        echo "  Either discovery dropped a class, or the pin needs bumping — see $work/classes.txt" >&2
        rc=1
        exit 1
    fi
    producer_note="producer count == REGISTERED_CLASSES ($registered_pin)"
fi

# Line s+1 of the filters output IS shard s's APQ_TEST value; the class list
# is that line split back on commas, kept only for the counts this script
# reports. An empty shard cannot reach here — `shard-plan` refuses one,
# because an empty APQ_TEST match makes the runner exit 1.
s=0
while [ "$s" -lt "$shards" ]; do
    sed -n "$((s + 1))p" "$work/filters.txt" > "$work/shard$s.filter"
    tr ',' '\n' < "$work/shard$s.filter" > "$work/shard$s.list"
    s=$((s + 1))
done

if [ "$plan_only" -eq 1 ]; then
    echo "suite-shard.sh: $total_classes classes over $shards shards (class parity OK)"
    echo "  plan: $work/assigned.txt"
    s=0
    while [ "$s" -lt "$shards" ]; do
        echo "  shard $s: $(wc -l < "$work/shard$s.list" | tr -d '[:space:]') classes -> $work/shard$s.list"
        s=$((s + 1))
    done
    keep=1
    exit 0
fi

# --- 2. run ------------------------------------------------------------
now_ms() {
    if command -v perl > /dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
    else
        echo $(($(date +%s) * 1000))
    fi
}

started=$(now_ms)
pids=""
s=0
while [ "$s" -lt "$shards" ]; do
    ( APQ_TEST="$(cat "$work/shard$s.filter")" node "$test_js" > "$work/shard$s.log" 2>&1 ) &
    pids="$pids $s:$!"
    s=$((s + 1))
done

shard_rc=0
for entry in $pids; do
    idx=${entry%%:*}
    pid=${entry##*:}
    if wait "$pid"; then
        echo 0 > "$work/shard$idx.rc"
    else
        echo 1 > "$work/shard$idx.rc"
        shard_rc=1
    fi
done
elapsed_ms=$(( $(now_ms) - started ))

# --- 3. per-shard summaries + aggregate --------------------------------
#
# `hxq test-summary` is the project's own utest-stdout parser (it locates
# the report by SHAPE, since test stdout precedes it) — reusing it keeps
# this script from growing a second, divergent parser, which is also why
# the extraction below is ONE function rather than a copy per call site.
#
# Its stderr is kept OUT of the parsed stream. `test-summary` prints a
# staleness advisory there whenever any `.hx` under src/ or test/ is newer
# than bin/test.js — the ordinary state right after editing a test — and
# merging it ahead of the report made every count parse as zero: the shards
# then failed with "matched nothing", and --verify compared 0/0 against 0/0
# and called itself VERIFIED. The advisory is forwarded, not swallowed: it
# is the only staleness check this script gets.
#
# The report line is selected by SHAPE for the same reason the tool does:
# a failure message quoted into `test-summary`'s stdout could otherwise
# supply a stray "tests" or "assertions" token. No match at all is an
# error, never a silent zero.
summarise() {
    if ! hxq test-summary "$1" > "$2.summary" 2> "$2.err"; then
        echo "suite-shard.sh: could not summarise $1" >&2
        cat "$2.summary" "$2.err" >&2
        echo "0 0 0 0" > "$2.nums"
        return 1
    fi
    if [ -s "$2.err" ]; then
        # Collected rather than printed: the staleness advisory is
        # identical on every shard, and N copies of one warning reads as
        # N problems.
        cat "$2.err" >> "$work/advisories.txt"
    fi
    if ! awk '
        /[0-9]+ tests \/ [0-9]+ assertions \/ [0-9]+ failures \/ [0-9]+ errors/ {
            for (i = 1; i <= NF; i++) {
                if ($(i + 1) == "tests")      t = $i
                if ($(i + 1) == "assertions") a = $i
                if ($(i + 1) == "failures")   f = $i
                if ($(i + 1) == "errors")     e = $i
            }
            found = 1
        }
        END {
            if (!found) exit 3
            print t + 0, a + 0, f + 0, e + 0
        }
    ' "$2.summary" > "$2.nums"; then
        echo "suite-shard.sh: no utest report line in the summary of $1 — see $2.summary" >&2
        echo "0 0 0 0" > "$2.nums"
        return 1
    fi
    return 0
}

sum_tests=0
sum_asserts=0
sum_fail=0
sum_err=0
s=0
while [ "$s" -lt "$shards" ]; do
    if ! summarise "$work/shard$s.log" "$work/shard$s"; then
        echo "suite-shard.sh: shard $s log is at $work/shard$s.log" >&2
        shard_rc=1
    fi

    if ! read -r t a f e < "$work/shard$s.nums"; then
        echo "suite-shard.sh: shard $s produced no counts at all — see $work/shard$s.log" >&2
        shard_rc=1
        t=0
        a=0
        f=0
        e=0
    fi
    classes=$(wc -l < "$work/shard$s.list" | tr -d '[:space:]')
    shard_exit=$(cat "$work/shard$s.rc" 2> /dev/null || echo 1)
    sum_tests=$((sum_tests + t))
    sum_asserts=$((sum_asserts + a))
    sum_fail=$((sum_fail + f))
    sum_err=$((sum_err + e))

    printf 'shard %d: %4d classes / %5d tests / %6d assertions / %d failures / %d errors (exit %s)\n' \
        "$s" "$classes" "$t" "$a" "$f" "$e" "$shard_exit"

    if [ "$t" -eq 0 ]; then
        echo "suite-shard.sh: shard $s reported 0 tests — its filter matched nothing, or the run aborted before the report (see $work/shard$s.log)" >&2
        shard_rc=1
    fi
    if [ "$shard_exit" -ne 0 ]; then
        shard_rc=1
    fi
    s=$((s + 1))
done

printf -- '--- suite-shard: %d classes / %d tests / %d assertions / %d failures / %d errors in %d.%03ds across %d shards ---\n' \
    "$total_classes" "$sum_tests" "$sum_asserts" "$sum_fail" "$sum_err" \
    "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))" "$shards"

if [ "$sum_fail" -ne 0 ] || [ "$sum_err" -ne 0 ]; then
    shard_rc=1
fi

# --- 4. count parity ---------------------------------------------------
#
# Class parity above already forbids a silent loss: every registered class
# is placed exactly once, no name is a substring of another, and no shard
# ran zero tests. Test/assertion totals therefore follow — but the totals
# grow with every slice, so pinning a literal in this script would rot into
# a lie within a day. The cross-check is opt-in instead: --verify pays for
# a monolith run and compares, --expect takes the caller's last known-good
# pair. With neither, the aggregate is reported as un-cross-checked.
parity_note="counts not cross-checked (class parity OK: $total_classes placed; $producer_note)"

if [ "$verify" -eq 1 ]; then
    # `APQ_TEST=` neutralises an exported filter in the caller's shell:
    # RunTests.hx treats an empty value as "run everything", and without
    # this a filtered monolith would be compared against unfiltered shard
    # totals and reported as a parity failure the run did not cause.
    mono_rc=0
    APQ_TEST= node "$test_js" > "$work/mono.log" 2>&1 || mono_rc=$?
    if summarise "$work/mono.log" "$work/mono" && read -r mt ma mf me < "$work/mono.nums"; then
        # The monolith's own verdict is the point of paying for it: it is
        # the only arm that can catch an ordering-dependent failure the
        # shards separated. Comparing counts while discarding its exit
        # status would throw away exactly that signal.
        if [ "$mono_rc" -ne 0 ] || [ "$mf" -ne 0 ] || [ "$me" -ne 0 ]; then
            echo "suite-shard.sh: the monolith run is RED (exit $mono_rc, $mf failures, $me errors) while the shards are green — see $work/mono.log" >&2
            shard_rc=1
            parity_note="monolith run RED ($mt tests / $ma assertions / $mf failures / $me errors)"
        elif [ "$mt" -eq "$sum_tests" ] && [ "$ma" -eq "$sum_asserts" ]; then
            parity_note="counts verified against a monolith run ($mt tests / $ma assertions)"
        else
            echo "suite-shard.sh: COUNT PARITY FAIL — shards $sum_tests/$sum_asserts vs monolith $mt/$ma" >&2
            shard_rc=1
            parity_note="counts DIVERGED from the monolith run ($mt tests / $ma assertions)"
        fi
    else
        echo "suite-shard.sh: could not summarise the monolith run — see $work/mono.log" >&2
        shard_rc=1
        parity_note="monolith run could not be summarised"
    fi
elif [ -n "$expect" ]; then
    if [ "$expect_tests" -eq "$sum_tests" ] && [ "$expect_asserts" -eq "$sum_asserts" ]; then
        parity_note="counts match --expect $expect"
    else
        echo "suite-shard.sh: COUNT PARITY FAIL — shards $sum_tests/$sum_asserts vs --expect $expect_tests/$expect_asserts" >&2
        shard_rc=1
        parity_note="counts DIVERGED from --expect $expect"
    fi
fi

if [ -s "$work/advisories.txt" ]; then
    sort -u "$work/advisories.txt" >&2
fi

echo "parity: $parity_note"

rc=$shard_rc
exit "$rc"
