#!/usr/bin/env bash
#
# battery.sh — the whole per-slice proof battery as one command, timed.
#
# Every slice in this project ends with the same seven checks, and until now
# they were seven to nine hand-typed commands plus a hand-read diff. That is
# not just slow, it is unreliable in a specific way: the step most often
# skipped under time pressure is the one with no cached "before" arm to make
# it cheap, and a skipped step reads exactly like a passed one in a summary.
# So the battery is a script with a single verdict, and it prints where its
# own time went — the only way to know whether the proof-speedup work is
# actually paying off is to measure the proof.
#
#   tools/battery.sh                  # full: build, suite+monolith, fmt, lint,
#                                     #   jvm probe if the core moved, blast
#   tools/battery.sh --quick          # mid-slice: skip the monolith cross-check
#   tools/battery.sh --snapshot       # on green, cache this HEAD as the next
#                                     #   slice's "before" arm
#   tools/battery.sh --base 29011103  # compare blast against a specific snapshot
#
# The cache directory holds, per commit: a lint snapshot of each tree, the
# corpus sweep snapshot, and a two-integer suite line. `--snapshot` writes
# them; every later run reads the newest (or `--base`) and reports the delta.
# Keeping it OUTSIDE the repo is deliberate — the snapshots are machine-local
# measurement state, not source, and a committed one would conflict on every
# slice.
#
# Every format-aware step is delegated to the CLI this project already builds
# (`apq lint-diff`, `apq sweep`, `apq test-summary` via suite-shard.sh) rather
# than re-implemented here. Shell orchestrates processes; anything that has to
# UNDERSTAND a file is a subcommand, testable in the suite and dogfooding our
# own JSON parser. That is why this script needs no jq and no python.
#
# What fails the run: any build error, a red or count-diverged suite, a
# non-empty `fmt --list`, a `--jvm` probe that stops compiling, a corpus
# regression (more failures than the base), or any blast-radius change that
# was not explicitly allowed with --allow-blast. A blast comparison that
# could not RUN (a snapshot missing or malformed — `lint-diff` exit 2) fails
# regardless of --allow-blast: that flag waives movement, never a dead gate.
#
# What is only REPORTED, never failed: suite totals growing (a slice that adds
# tests is the normal case) and corpus totals improving.
#
# A slice that ADDS code moves the blast radius too, and that is NOT an
# automatic pass: the findings its new files bring print through `lint-diff`
# exactly like any other change, and accepting them is a deliberate
# --allow-blast after reading each line. There is no new-file exemption, by
# design — "the finding is on a file I just wrote" is the same sentence as
# "I have not read it yet".
#
# Timings here are wall-clock with deliberate concurrency (two builds at once,
# two lint arms at once). They measure the battery, not the code — never quote
# them as benchmark numbers; benchmark arms run sequentially, see
# `docs/testing.md`.
set -euo pipefail

shards=4
quick=0
snapshot=0
with_tm=1
allow_blast=0
jvm_mode=auto
base_key=""
cache_dir="${ANYPARSE_BLAST_CACHE:-$HOME/anyparse-blast-cache}"
tm_tree="${ANYPARSE_TM_TREE:-/Users/axg/dev/soccertutor/TM-Haxe4}"

need_value() {
    if [ "$2" -lt 2 ]; then
        echo "battery.sh: $1 needs a value" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--shards)   need_value "$1" "$#"; shards=$2; shift 2 ;;
        --base)        need_value "$1" "$#"; base_key=$2; shift 2 ;;
        --cache)       need_value "$1" "$#"; cache_dir=$2; shift 2 ;;
        --tm)          need_value "$1" "$#"; tm_tree=$2; shift 2 ;;
        --quick)       quick=1; shift ;;
        --snapshot)    snapshot=1; shift ;;
        --no-tm)       with_tm=0; shift ;;
        --allow-blast) allow_blast=1; shift ;;
        --jvm)         jvm_mode=always; shift ;;
        --no-jvm)      jvm_mode=never; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -euo/d'
            exit 0
            ;;
        *)
            echo "battery.sh: unknown argument '$1' (try --help)" >&2
            exit 2
            ;;
    esac
done

# The repo comes from THIS SCRIPT's location, never the CWD — same rule as
# suite-shard.sh and worker-build.sh. Everything below then runs from the repo
# root, because the runner and the CLI both resolve fixtures, hxformat.json and
# apqlint.json against the process CWD.
script_dir=$(cd -P "$(dirname "$0")" && pwd)
repo=$(cd -P "$script_dir/.." && pwd)
cd "$repo"

work=$(mktemp -d "${TMPDIR:-/tmp}/apq-battery.XXXXXX")
verdict=0

cleanup() {
    if [ "$verdict" -eq 0 ]; then
        rm -rf "$work"
    else
        echo "battery.sh: logs kept in $work" >&2
    fi
}
trap cleanup EXIT

now_ms() {
    if command -v perl > /dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
    else
        echo $(($(date +%s) * 1000))
    fi
}

# Timings accumulate as "label<TAB>ms" lines so the closing table needs no
# array plumbing and stays readable when a step is skipped.
timings="$work/timings.tsv"
: > "$timings"
step_start=0

step_begin() {
    printf '\n=== %s ===\n' "$1"
    step_start=$(now_ms)
}

step_end() {
    printf '%s\t%d\n' "$1" "$(( $(now_ms) - step_start ))" >> "$timings"
}

fail() {
    echo "battery.sh: FAIL — $1" >&2
    verdict=1
}

# --- preflight ---------------------------------------------------------

if ! command -v hxq > /dev/null 2>&1; then
    echo "battery.sh: hxq is not on PATH — suite-shard.sh reads test/RunTests.hx through it" >&2
    exit 2
fi

# The corpus round-trip layer is silent when this is unset: the suite still
# reports green, just with ~950 fewer fixtures exercised. A battery that
# cannot tell "corpus clean" from "corpus not run" is worse than no corpus
# gate at all, so this is a refusal rather than a warning.
if [ -z "${ANYPARSE_HXFORMAT_FORK:-}" ]; then
    echo "battery.sh: ANYPARSE_HXFORMAT_FORK is unset — the corpus layer would skip silently" >&2
    exit 2
fi

head_key=$(git rev-parse --short=8 HEAD)

mkdir -p "$cache_dir"
if [ -z "$base_key" ]; then
    # Newest by mtime, not by name: the keys are commit hashes and sort in no
    # meaningful order.
    base_suite_file=$(ls -1t "$cache_dir"/*-suite.txt 2> /dev/null | head -1 || true)
    if [ -n "$base_suite_file" ]; then
        base_key=$(basename "$base_suite_file" -suite.txt)
    fi
fi

if [ -n "$base_key" ]; then
    echo "battery.sh: repo $repo at $head_key, comparing against $base_key"
else
    echo "battery.sh: repo $repo at $head_key, no cached baseline (first run — use --snapshot)"
fi

# A baseline is four plain files per commit: two lint snapshots, one corpus
# sweep snapshot, and a two-integer suite line. No JSON is parsed in shell —
# `apq lint-diff` and `apq sweep` read their own formats, which is the whole
# reason those live in the CLI instead of in a helper script.
base_suite="$cache_dir/$base_key-suite.txt"
base_sweep="$cache_dir/$base_key-sweep.json"
base_tests=0
base_asserts=0
if [ -n "$base_key" ] && [ -f "$base_suite" ]; then
    read -r base_tests base_asserts < "$base_suite"
fi

# --- 1. builds ---------------------------------------------------------
#
# Parallel because they are independent outputs from independent hxml, and
# the pair is the single longest serial stretch of the old hand-run battery.
step_begin "build (parallel)"
apq_rc=0
test_rc=0
haxe bin/apq-js.hxml > "$work/build-apq.log" 2>&1 &
build_apq_pid=$!
haxe test-js.hxml > "$work/build-test.log" 2>&1 &
build_test_pid=$!
wait "$build_apq_pid" || apq_rc=$?
wait "$build_test_pid" || test_rc=$?
if [ "$apq_rc" -ne 0 ]; then
    cat "$work/build-apq.log" >&2
    fail "bin/apq-js.hxml did not build"
fi
if [ "$test_rc" -ne 0 ]; then
    cat "$work/build-test.log" >&2
    fail "test-js.hxml did not build"
fi
step_end "build (parallel)"
if [ "$verdict" -ne 0 ]; then
    echo "battery.sh: stopping — nothing below can be trusted against a failed build" >&2
    exit 1
fi

# Both binaries are provably fresh from here on, so the launcher's staleness
# probe is pure cost — and worse, two concurrent lint arms would each try to
# rebuild. Setting this BEFORE the build would be the trap the project has
# already hit once: a quiet launcher runs a stale binary and the probe lies.
export HXQ_QUIET=1

# --- 1b. compiler oracle, in the background ----------------------------
#
# The `lint` step below runs a PROJECT-WIDE `haxe <hxml> --no-output` — 16s of
# its own, on an hxml the build step above just typechecked. `apq oracle` runs
# that typecheck ONCE, cold, and records the verdict under a content
# fingerprint of the whole compile input; the lint step then re-derives the
# fingerprint and reuses the verdict only if it still matches. Nothing is
# trusted — the record comes from a real compiler run, and a tree that moved
# between the two steps simply misses and recompiles.
#
# Backgrounded so it overlaps the suite/corpus/fmt/jvm steps instead of the
# lint step's critical path. Its exit status is NOT a gate: the lint step
# reads the same verdict and fails there, with the compiler's error text.
oracle_pid=""
if [ -x bin/hxq ]; then
    bin/hxq oracle src > "$work/oracle.log" 2>&1 &
    oracle_pid=$!
fi

# --- 2. suite ----------------------------------------------------------
step_begin "suite"
shard_args="-n $shards"
if [ "$quick" -eq 0 ]; then
    shard_args="$shard_args --verify"
fi
suite_rc=0
# shellcheck disable=SC2086
tools/suite-shard.sh $shard_args > "$work/suite.log" 2> "$work/suite.err" || suite_rc=$?
cat "$work/suite.log"
if [ -s "$work/suite.err" ]; then
    cat "$work/suite.err" >&2
fi
if [ "$suite_rc" -ne 0 ]; then
    fail "the suite is not green (see $work/suite.log; suite-shard.sh keeps its own per-shard logs on failure)"
fi

read -r now_tests now_asserts <<EOF
$(awk -F'[ /]+' '/^--- suite-shard:/ { for (i = 1; i <= NF; i++) { if ($(i+1) == "tests") t = $i; if ($(i+1) == "assertions") a = $i } } END { print t + 0, a + 0 }' "$work/suite.log")
EOF
step_end "suite"

if [ "$verdict" -ne 0 ]; then
    echo "battery.sh: stopping — a red suite makes every check below noise" >&2
    exit 1
fi

# --- 3. corpus ---------------------------------------------------------
#
# `apq sweep` reads the snapshot the corpus harness just wrote, so there is no
# log to grep and no second parser. It is compared against the CACHED base
# snapshot, never against `bin/.prev-sweep.json`: the harness rotates that
# before every write, so the Δ it reports is "this run vs the previous run of
# the same tree" — Δ0 by construction once you have run twice, and blind to a
# regression introduced two runs ago.
sweep_rc=0
if [ -n "$base_key" ] && [ -f "$base_sweep" ]; then
    bin/hxq sweep --prev "$base_sweep" > "$work/sweep.log" 2>&1 || sweep_rc=$?
else
    bin/hxq sweep > "$work/sweep.log" 2>&1 || sweep_rc=$?
fi
cat "$work/sweep.log"
if [ "$sweep_rc" -ne 0 ]; then
    fail "could not read the corpus sweep snapshot — did the corpus layer run?"
fi
read -r now_sweep_pass now_sweep_fail now_sweep_skip <<EOF
$(awk '/pass \// { for (i = 1; i <= NF; i++) { if ($(i+1) == "pass") p = $i; if ($(i+1) == "fail") f = $i; if ($(i+1) == "skip-parse") s = $i } } END { print p + 0, f + 0, s + 0 }' "$work/sweep.log")
EOF
# A Δfail line is printed only when a base snapshot was given, so the gate is
# on the delta the tool computed rather than on a number this script derived.
if grep -qE 'Δfail [1-9]' "$work/sweep.log"; then
    fail "the corpus regressed against $base_key — see the Δ line above"
fi

# --- 4. fmt ------------------------------------------------------------
step_begin "fmt"
fmt_rc=0
bin/hxq fmt --list src test tools > "$work/fmt.log" 2>&1 || fmt_rc=$?
if [ "$fmt_rc" -ne 0 ] || [ -s "$work/fmt.log" ]; then
    cat "$work/fmt.log" >&2
    fail "fmt --list is not empty (or exited $fmt_rc)"
fi
step_end "fmt"

# --- 5. jvm portability probe -----------------------------------------
#
# Only when the core actually moved: the two packages below are the ones whose
# static-target portability has regressed in practice, and the probe costs ~9s
# plus a JVM. See docs/testing.md § "The core stays target-independent".
run_jvm=0
case "$jvm_mode" in
    always) run_jvm=1 ;;
    never)  run_jvm=0 ;;
    auto)
        if [ -n "$base_key" ] && git cat-file -e "$base_key^{commit}" 2> /dev/null; then
            if ! git diff --quiet "$base_key" -- src/anyparse/query src/anyparse/check; then
                run_jvm=1
            fi
        fi
        ;;
esac
if [ "$run_jvm" -eq 1 ] && ! command -v java > /dev/null 2>&1; then
    echo "battery.sh: the core moved but java is absent — skipping the portability probe" >&2
    run_jvm=0
fi
if [ "$run_jvm" -eq 1 ]; then
    step_begin "jvm probe"
    jvm_rc=0
    haxe tools/jvm-portability.hxml > "$work/jvm.log" 2>&1 || jvm_rc=$?
    if [ "$jvm_rc" -ne 0 ]; then
        cat "$work/jvm.log" >&2
        fail "the core no longer compiles for --jvm"
    else
        java -jar bin/jvm-portability.jar > "$work/jvm-run.log" 2>&1 || jvm_rc=$?
        cat "$work/jvm-run.log"
        if [ "$jvm_rc" -ne 0 ] || grep -q 'threw=[1-9]' "$work/jvm-run.log"; then
            fail "the portability probe threw (a parse failure or a comment loss, never a formatting difference)"
        fi
    fi
    step_end "jvm probe"
fi

# --- 6. lint, both trees at once --------------------------------------
#
# The backgrounded oracle above must have landed its verdict before the lint
# arms derive their fingerprint, or they simply compile it themselves.
if [ -n "$oracle_pid" ]; then
    wait "$oracle_pid" || true
fi
step_begin "lint"
lint_new_anyparse="$work/lint-anyparse.json"
lint_new_tm="$work/lint-tm.json"
anyparse_rc=0
tm_rc=0
bin/hxq lint --format json --all src test > "$lint_new_anyparse" 2> "$work/lint-anyparse.err" &
lint_anyparse_pid=$!
lint_tm_pid=""
if [ "$with_tm" -eq 1 ] && [ -d "$tm_tree/src" ]; then
    bin/hxq lint --format json --all "$tm_tree/src" > "$lint_new_tm" 2> "$work/lint-tm.err" &
    lint_tm_pid=$!
fi
wait "$lint_anyparse_pid" || anyparse_rc=$?
if [ -n "$lint_tm_pid" ]; then
    wait "$lint_tm_pid" || tm_rc=$?
fi
if [ "$anyparse_rc" -ne 0 ]; then
    cat "$work/lint-anyparse.err" >&2
    fail "lint of src+test exited $anyparse_rc"
fi
if [ -n "$lint_tm_pid" ] && [ "$tm_rc" -ne 0 ]; then
    cat "$work/lint-tm.err" >&2
    fail "lint of $tm_tree/src exited $tm_rc"
fi
step_end "lint"

# --- 7. blast radius ---------------------------------------------------
#
# `lint-diff` distinguishes its two non-zero exits and so must this step: 1 is
# "compared, and the findings moved" (waivable with --allow-blast, which is the
# whole point of the flag on a slice that adds code), 2 is "could not compare"
# — a snapshot missing, unreadable or malformed. Treating them alike would make
# --allow-blast silently accept a gate that never ran.
step_begin "blast"
blast_changed=0
blast_run() {
    local rc=0
    bin/hxq lint-diff --old "$1" --new "$2" --root "$3" --label "$4" || rc=$?
    case "$rc" in
        0) ;;
        1) blast_changed=1 ;;
        *) fail "lint-diff could not compare the $4 snapshots (exit $rc) — the blast gate did not run" ;;
    esac
}
if [ -n "$base_key" ] && [ -f "$cache_dir/$base_key-anyparse.json" ]; then
    blast_run "$cache_dir/$base_key-anyparse.json" "$lint_new_anyparse" "$repo" anyparse
else
    echo "blast anyparse: no cached baseline at $base_key — nothing to compare"
fi
if [ -n "$lint_tm_pid" ] && [ -f "$cache_dir/$base_key-tm.json" ]; then
    blast_run "$cache_dir/$base_key-tm.json" "$lint_new_tm" "$tm_tree" tm
elif [ -n "$lint_tm_pid" ]; then
    echo "blast tm: no cached baseline at $base_key — nothing to compare"
fi
if [ "$blast_changed" -eq 1 ] && [ "$allow_blast" -eq 0 ]; then
    fail "the blast radius changed — explain each line above, then re-run with --allow-blast"
fi
step_end "blast"

# --- 8. verdict --------------------------------------------------------
printf '\n'
if [ "$base_tests" -gt 0 ]; then
    printf 'suite  %d tests / %d assertions (base %s: %d / %d, delta %+d / %+d)\n' \
        "$now_tests" "$now_asserts" "$base_key" "$base_tests" "$base_asserts" \
        "$((now_tests - base_tests))" "$((now_asserts - base_asserts))"
else
    printf 'suite  %d tests / %d assertions\n' "$now_tests" "$now_asserts"
fi
printf 'corpus %d pass / %d fail / %d skip-parse\n' \
    "$now_sweep_pass" "$now_sweep_fail" "$now_sweep_skip"

printf '\n'
awk -F'\t' '
    { total += $2; printf "  %-18s %6.1fs\n", $1, $2 / 1000 }
    END { printf "  %-18s %6.1fs\n", "TOTAL", total / 1000 }
' "$timings"

if [ "$verdict" -ne 0 ]; then
    printf -- '--- battery: FAIL ---\n'
    exit 1
fi

# --- 9. snapshot -------------------------------------------------------
#
# Only on green, and only when asked: the snapshot becomes the next slice's
# "before" arm, so caching a red or half-run tree would silently move the
# baseline under the next comparison.
if [ "$snapshot" -eq 1 ]; then
    cp "$lint_new_anyparse" "$cache_dir/$head_key-anyparse.json"
    if [ -n "$lint_tm_pid" ]; then
        cp "$lint_new_tm" "$cache_dir/$head_key-tm.json"
    fi
    bin/hxq sweep --save "$cache_dir/$head_key-sweep.json" > /dev/null
    printf '%d %d\n' "$now_tests" "$now_asserts" > "$cache_dir/$head_key-suite.txt"
    echo "battery.sh: snapshot written for $head_key in $cache_dir"
fi

printf -- '--- battery: PASS ---\n'
