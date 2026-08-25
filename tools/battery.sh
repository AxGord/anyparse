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
#   tools/battery.sh --allow-blast    # accept the blast movement printed above
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
# --- the step graph ----------------------------------------------------
#
# The steps read like a sequence but their dependencies are far sparser, so
# they run as four concurrent BRANCHES:
#
#   build ──┬─ suite ── corpus          corpus reads what the suite wrote
#           ├─ fmt
#           ├─ jvm probe                only when src/ or the probe moved
#           └─ oracle ── lint ── blast  lint reuses the oracle's verdict;
#                                       blast diffs lint's own output
#
# build is first because everything needs the binaries. Inside a branch the
# order is a real dependency; across branches there is none that matters: all
# four read `src`, and each branch's writes are read only by itself — the
# suite's `bin/.last-sweep.json`, its rotated `.prev-sweep.json` and
# `/tmp/anyparse-last-probe.hx` by its own corpus step and by nothing else,
# the jvm probe's `bin/jvm-portability.jar` by nobody. Adding a fifth branch
# means re-checking that, not assuming it: `docs/testing.md` § "The step
# graph: four branches, one join" carries the full rationale, and
# `tools/suite-shard.sh`'s shared-path inventory is written for shard-vs-shard
# only.
#
# What fails the run: any build error, a red or count-diverged suite, a
# non-empty `fmt --list`, a `fmt --verify` divergence, a `--jvm` probe that
# stops compiling, a corpus
# regression (more failures than the base), or any blast-radius change that
# was not explicitly allowed with --allow-blast. A blast comparison that
# could not RUN (a snapshot missing or malformed — `lint-diff` exit 2) fails
# regardless of --allow-blast: that flag waives movement, never a dead gate.
#
# EVERY branch's verdict is collected. A branch that goes red does not stop
# the others and does not stop the run: three broken things are reported as
# three, because "one step failed and three never ran" is the summary this
# script exists to prevent. The same reasoning gives a step three outcomes,
# never two — a step that could not run prints `not run` in the timing table
# and fails the verdict on its own, so it can never be mistaken for a pass.
# Only `skipped` is benign, and only where the script decided the step does
# not apply (the jvm probe on an untouched core).
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
# Interleaved stdout from four concurrent steps is unreadable, so no BRANCH
# prints while they run: each writes to its own pair of log files and the
# driver replays them, in a FIXED order, once every branch has joined. The
# transcript therefore reads exactly like the old sequential one.
#
# Timings here are wall clock with deliberate concurrency — four branches at
# once, two builds inside one of them, two lint arms inside another. The rows
# marked `*` OVERLAP: they sum to far more than the elapsed time, and neither
# a row nor the total measures the code. NEVER quote a battery number as a
# benchmark result: benchmark arms run sequentially, one at a time, on an
# otherwise idle machine — see `docs/testing.md` § "The profiling harness".
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
live_pids=""

cleanup() {
    # A branch is a background subshell of THIS shell, and the EXIT trap is
    # not inherited by one — so on an interrupt they would keep running and
    # keep writing into a $work this trap is about to delete. Killing the
    # SUBSHELL does not reach the haxe/node/java processes it spawned, so the
    # honest response to "a branch was still live" is to keep the directory:
    # an abort mid-join is exactly when the logs are wanted, and removing a
    # directory someone's grandchild is still writing into is the one thing
    # this must not do. After the join `live_pids` is empty and this whole
    # arm is skipped.
    if [ -n "$live_pids" ]; then
        kill $live_pids 2> /dev/null || true
        wait $live_pids 2> /dev/null || true
        echo "battery.sh: stopped with branches still running — logs kept in $work" >&2
        return
    fi
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

run_start=$(now_ms)

# Timings accumulate as "label<TAB>ms<TAB>kind<TAB>note" lines so the closing
# table needs no array plumbing and stays readable when a step is skipped.
# `kind` is one of:
#   seq     ran alone, its time is elapsed time
#   conc    ran inside a branch, OVERLAPPING every other conc row
#   skip    deliberately not applicable — benign, note says why
#   notrun  should have run and did not — never benign, fails the verdict
timings="$work/timings.tsv"
: > "$timings"
step_start=0
step_kind=seq

# Set by branch_init inside a branch subshell; empty in the driver. Every
# helper below is written once and behaves correctly on both sides of that
# fork, which is what keeps a branch's body identical to the sequential code
# it replaced.
tsv="$timings"
fail_file=""

step_begin() {
    printf '\n=== %s ===\n' "$1"
    step_start=$(now_ms)
}

step_end() {
    printf '%s\t%d\t%s\t\n' "$1" "$(( $(now_ms) - step_start ))" "$step_kind" >> "$tsv"
}

# Deliberately not applicable. Benign: reported, never failed.
step_skip() {
    printf '%s\t0\tskip\t%s\n' "$1" "$2" >> "$tsv"
}

# Should have run, could not. Never benign — the driver fails the verdict on
# any such row, because a step that did not run must never read as one that
# passed.
step_notrun() {
    printf '%s\t0\tnotrun\t%s\n' "$1" "$2" >> "$tsv"
}

fail() {
    if [ -n "$fail_file" ]; then
        # Inside a branch: `verdict` here is a copy in a subshell and would be
        # thrown away, so the message is queued for the driver to replay after
        # the join — which is also what keeps four branches' failures from
        # interleaving into each other's output.
        printf '%s\n' "$1" >> "$fail_file"
    else
        echo "battery.sh: FAIL — $1" >&2
        verdict=1
    fi
}

# --- branch plumbing ---------------------------------------------------
#
# Each branch is a background subshell writing six files under $work:
#   <name>.out/.err  the two streams, kept apart so the driver can replay
#                    each onto the stream it came from
#   <name>.tsv       one row per step it actually recorded
#   <name>.fail      one line per failure, replayed by the driver
#   <name>.expect    the step labels the branch PROMISES to record — written
#                    by the DRIVER at launch, so a branch that dies on its
#                    first line still has a contract to be measured against
#   <name>.pid/.rc   the join
#
# The .expect/.tsv difference is the whole safety property: a label that was
# promised and never recorded is a step that could not run, and the driver
# turns it into a `not run` row plus a failed verdict — including when the
# branch aborted somewhere the author never anticipated.
branches=""

branch_init() {
    fail_file="$work/$1.fail"
    tsv="$work/$1.tsv"
    step_kind=conc
}

launch() {
    local name=$1
    shift
    : > "$work/$name.fail"
    : > "$work/$name.tsv"
    printf '%s\n' "$@" > "$work/$name.expect"
    branches="$branches $name"
    "branch_$name" > "$work/$name.out" 2> "$work/$name.err" &
    printf '%s\n' "$!" > "$work/$name.pid"
    live_pids="$live_pids $!"
}

join_branch() {
    local name=$1
    local rc=0
    wait "$(cat "$work/$name.pid")" || rc=$?
    printf '%s\n' "$rc" > "$work/$name.rc"
}

# Replay one branch into the transcript: its own output first, then the
# failures it queued, then the steps it promised and never delivered.
replay_branch() {
    local name=$1
    local rc
    rc=$(cat "$work/$name.rc")
    cat "$work/$name.out"
    if [ -s "$work/$name.err" ]; then
        cat "$work/$name.err" >&2
    fi
    # `|| [ -n "$line" ]` on both loops below: a last line with no trailing
    # newline is otherwise dropped, and on the .fail side a dropped line is a
    # dropped FAIL. Every producer here uses printf with a newline, so this is
    # belt for a brace that has not slipped yet.
    local accounted=0
    local line=''
    while IFS= read -r line || [ -n "$line" ]; do
        echo "battery.sh: FAIL — $line" >&2
        verdict=1
        accounted=1
    done < "$work/$name.fail"
    local label=''
    while IFS= read -r label || [ -n "$label" ]; do
        # awk, not `cut | grep`: under `pipefail` a matching `grep -q` SIGPIPEs
        # the producer, and the pipeline's non-zero status would then read as
        # "no such row" — inverting the very check this line exists for.
        if ! awk -F'\t' -v l="$label" '$1 == l { f = 1 } END { exit f ? 0 : 1 }' "$work/$name.tsv"; then
            printf '%s\t0\tnotrun\tthe %s branch stopped before it (exit %s)\n' \
                "$label" "$name" "$rc" >> "$work/$name.tsv"
        fi
    done < "$work/$name.expect"
    # awk again rather than `IFS=$'\t' read`: a tab in IFS is IFS-WHITESPACE, so
    # `read` COLLAPSES a run of them and an empty middle field would shift the
    # status into the note — silently disarming the notrun half of the whole
    # safety property. The closing table's `awk -F'\t'` does not collapse, so
    # the two would disagree about the same file.
    if awk -F'\t' '$3 == "notrun" { f = 1 } END { exit f ? 0 : 1 }' "$work/$name.tsv"; then
        awk -F'\t' '$3 == "notrun" { printf "battery.sh: NOT RUN — %s (%s)\n", $1, $4 }' \
            "$work/$name.tsv" >&2
        verdict=1
        accounted=1
    fi
    # The residual: a branch that returned non-zero without any step saying so.
    # Collecting the exit code and never asking it would be the one lost result
    # the .expect contract does not cover — it only sees a label that was never
    # RECORDED, not a branch that recorded everything and then died.
    if [ "$rc" -ne 0 ] && [ "$accounted" -eq 0 ]; then
        echo "battery.sh: FAIL — the $name branch exited $rc without failing a step" >&2
        verdict=1
    fi
    cat "$work/$name.tsv" >> "$timings"
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
# Sequential relative to everything else, because everything else executes
# what it produces. The two compiles inside it are parallel: independent
# outputs from independent hxml, and the pair is the single longest stretch
# the concurrency below cannot dissolve.
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
# probe is pure cost — and worse, the branches below would each try to
# rebuild. Setting this BEFORE the build would be the trap the project has
# already hit once: a quiet launcher runs a stale binary and the probe lies.
# It has to be exported before the first branch forks, since a branch that
# inherited the default would rebuild `bin/apq.js` while three others are
# executing it.
export HXQ_QUIET=1

# --- 2. branch: suite → corpus -----------------------------------------
#
# `apq sweep` reads the snapshot the corpus harness just wrote, so there is no
# log to grep and no second parser. It is compared against the CACHED base
# snapshot, never against `bin/.prev-sweep.json`: the harness rotates that
# before every write, so the Δ it reports is "this run vs the previous run of
# the same tree" — Δ0 by construction once you have run twice, and blind to a
# regression introduced two runs ago.
#
# corpus is the one step with a real intra-branch dependency: a red suite has
# not necessarily written the sweep snapshot at all, and reading a stale one
# would report a corpus that was never exercised. So it is recorded `not run`,
# which fails the verdict in its own right rather than hiding behind the
# suite's failure.
branch_suite() {
    branch_init suite
    step_begin "suite"
    local shard_args="-n $shards"
    if [ "$quick" -eq 0 ]; then
        shard_args="$shard_args --verify"
    fi
    local suite_rc=0
    # `<step>-run.log`, not `<step>.log`: the plumbing owns `$work/<branch>.out`
    # and `.err`, so a step log named after its branch would collide with the
    # branch's own stderr and interleave the two.
    # shellcheck disable=SC2086
    tools/suite-shard.sh $shard_args > "$work/suite-run.log" 2> "$work/suite-run.err" || suite_rc=$?
    cat "$work/suite-run.log"
    if [ -s "$work/suite-run.err" ]; then
        cat "$work/suite-run.err" >&2
    fi
    if [ "$suite_rc" -ne 0 ]; then
        fail "the suite is not green (see $work/suite-run.log; suite-shard.sh keeps its own per-shard logs on failure)"
    fi

    read -r now_tests now_asserts <<EOF
$(awk -F'[ /]+' '/^--- suite-shard:/ { for (i = 1; i <= NF; i++) { if ($(i+1) == "tests") t = $i; if ($(i+1) == "assertions") a = $i } } END { print t + 0, a + 0 }' "$work/suite-run.log")
EOF
    printf '%d %d\n' "$now_tests" "$now_asserts" > "$work/suite-counts.txt"
    step_end "suite"

    if [ "$suite_rc" -ne 0 ]; then
        step_notrun "corpus" "the suite was red — the sweep snapshot it writes proves nothing"
        return 0
    fi

    step_begin "corpus"
    local sweep_rc=0
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
    printf '%d %d %d\n' "$now_sweep_pass" "$now_sweep_fail" "$now_sweep_skip" > "$work/sweep-counts.txt"
    # A Δfail line is printed only when a base snapshot was given, so the gate
    # is on the delta the tool computed rather than on a number this script
    # derived. `sweep` signs that delta — `+6` for a regression, a bare `0` for
    # none, `-4` for an improvement — so the `+` is part of the pattern. It was
    # missing until a fault injection proved this gate had never once fired:
    # `Δfail [1-9]` cannot match `Δfail +6`, and a corpus regression rode
    # through as a pass.
    if grep -qE 'Δfail \+[1-9]' "$work/sweep.log"; then
        fail "the corpus regressed against $base_key — see the Δ line above"
    fi
    step_end "corpus"
}

# --- 3. branch: fmt ----------------------------------------------------
branch_fmt() {
    branch_init fmt
    step_begin "fmt"
    local fmt_rc=0
    bin/hxq fmt --list src test tools > "$work/fmt.log" 2>&1 || fmt_rc=$?
    if [ "$fmt_rc" -ne 0 ] || [ -s "$work/fmt.log" ]; then
        cat "$work/fmt.log" >&2
        fail "fmt --list is not empty (or exited $fmt_rc)"
    fi
    # The non-whitespace invariant, on the one tree here that is NOT already
    # canonical. `--verify` can only speak about files the writer would
    # actually rewrite, so pointing it at src/test/tools would give it a
    # denominator of zero and report a clean audit for the wrong reason. The
    # fork tree keeps a handful of drifted files, so the line below carries a
    # real (if small) count — read it, do not just check the exit status.
    local verify_rc=0
    bin/hxq fmt --verify "$ANYPARSE_HXFORMAT_FORK/src" > "$work/fmt-verify.log" 2>&1 || verify_rc=$?
    grep 'fmt --verify:' "$work/fmt-verify.log" >&2 || true
    if grep -q 'formatting changed more than whitespace' "$work/fmt-verify.log"; then
        cat "$work/fmt-verify.log" >&2
        fail "fmt --verify found a non-whitespace divergence in $ANYPARSE_HXFORMAT_FORK/src"
    fi
    step_end "fmt"
}

# --- 4. branch: jvm portability probe ----------------------------------
#
# Only when the core actually moved: the two packages below are the ones whose
# static-target portability has regressed in practice, and the probe costs ~9s
# plus a JVM. See docs/testing.md § "The core stays target-independent".
# Whether it applies is decided in the driver, before the fork, because it
# reads git — but the SKIP is still recorded as a row, so "the probe did not
# apply" and "the probe never ran" stay different words in the table.
branch_jvm() {
    branch_init jvm
    if [ "$run_jvm" -ne 1 ]; then
        step_skip "jvm probe" "$jvm_skip_note"
        return 0
    fi
    step_begin "jvm probe"
    local jvm_rc=0
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
}

# --- 5. branch: oracle → lint → blast ----------------------------------
#
# The `lint` step runs a PROJECT-WIDE `haxe <hxml> --no-output` — ~18s of its
# own as of 2026-08-25 (16s when this was written; it grows with the tree), on an
# hxml the build step already typechecked. `apq oracle` runs that
# typecheck ONCE and records the verdict under a content fingerprint of the
# whole compile input; lint then re-derives the fingerprint and reuses the
# verdict only if it still matches. Nothing is trusted — the record comes from
# a real compiler run, and a tree that moved between the two steps simply
# misses and recompiles.
#
# It leads this branch rather than sitting in the driver as a background job:
# a branch subshell cannot `wait` on a pid that is not its own child, and the
# three steps here are a genuine chain. Starting it first inside the branch
# puts it at exactly the same wall-clock moment as before — the fork happens
# immediately after the build either way. Its exit status is still not a gate:
# the lint step reads the same verdict and fails there, with the compiler's
# error text.
branch_lint() {
    branch_init lint
    step_begin "oracle"
    bin/hxq oracle src > "$work/oracle.log" 2>&1 || true
    step_end "oracle"

    step_begin "lint"
    local lint_new_anyparse="$work/lint-anyparse.json"
    local lint_new_tm="$work/lint-tm.json"
    local anyparse_rc=0
    local tm_rc=0
    bin/hxq lint --format json --all src test > "$lint_new_anyparse" 2> "$work/lint-anyparse.err" &
    local lint_anyparse_pid=$!
    local lint_tm_pid=""
    if [ "$with_tm" -eq 1 ] && [ -d "$tm_tree/src" ]; then
        bin/hxq lint --format json --all "$tm_tree/src" > "$lint_new_tm" 2> "$work/lint-tm.err" &
        lint_tm_pid=$!
        # The driver decides whether to snapshot the TM arm, and it cannot see
        # this subshell's variables.
        : > "$work/lint-tm.used"
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

    # `lint-diff` distinguishes its two non-zero exits and so must this step:
    # 1 is "compared, and the findings moved" (waivable with --allow-blast,
    # which is the whole point of the flag on a slice that adds code), 2 is
    # "could not compare" — a snapshot missing, unreadable or malformed.
    # Treating them alike would make --allow-blast silently accept a gate that
    # never ran.
    step_begin "blast"
    local blast_changed=0
    local blast_ran=0
    # Nested only to document that it reads `blast_changed`/`blast_ran` through
    # bash's DYNAMIC scoping — the nesting itself creates no scope, the
    # definition is global either way.
    blast_run() {
        local rc=0
        blast_ran=1
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
    # A comparison that never happened is not a pass. Without this the step
    # would record a normal row on a first run and read, in the table, exactly
    # like a gate that ran and agreed — the one thing this script exists to
    # make impossible.
    if [ "$blast_ran" -eq 0 ]; then
        step_skip "blast" "no cached baseline at ${base_key:-<none>} — run --snapshot to make one"
        return 0
    fi
    if [ "$blast_changed" -eq 1 ] && [ "$allow_blast" -eq 0 ]; then
        fail "the blast radius changed — explain each line above, then re-run with --allow-blast"
    fi
    step_end "blast"
}

# --- 6. does the jvm probe apply? --------------------------------------
#
# Decided here, before the fork, because it reads git — but the answer is
# still recorded as a row, so "the probe did not apply" and "the probe never
# ran" stay different words in the table.

run_jvm=0
jvm_skip_note=""
case "$jvm_mode" in
    always) run_jvm=1 ;;
    never)  run_jvm=0; jvm_skip_note="--no-jvm" ;;
    auto)
        if [ -n "$base_key" ] && git cat-file -e "$base_key^{commit}" 2> /dev/null; then
            # The probe COMPILES `-cp src -cp tools -main JvmPortability`, so any of that
            # is what can break it — not just the two packages it happens to LINT by
            # default. Narrowing the trigger to query+check made it self-skip on a slice
            # that added a field to a `@:peg` structure typedef, i.e. exactly the
            # structure-unification regression the probe exists to catch (T26, run by
            # hand instead).
            if git diff --quiet "$base_key" -- src tools/JvmPortability.hx tools/jvm-portability.hxml; then
                jvm_skip_note="neither src/ nor the probe moved since $base_key"
            else
                run_jvm=1
            fi
        else
            jvm_skip_note="no baseline commit to diff the core against"
        fi
        ;;
esac
if [ "$run_jvm" -eq 1 ] && ! command -v java > /dev/null 2>&1; then
    run_jvm=0
    jvm_skip_note="src/ moved but java is absent"
fi

# --- 7. run the four branches concurrently -----------------------------

echo "battery.sh: running suite→corpus ∥ fmt ∥ jvm ∥ oracle→lint concurrently — output replays in a fixed order once they join"
parallel_start=$(now_ms)
launch suite "suite" "corpus"
launch fmt   "fmt"
launch jvm   "jvm probe"
launch lint  "oracle" "lint" "blast"

for branch in $branches; do
    join_branch "$branch"
done
live_pids=""
parallel_ms=$(( $(now_ms) - parallel_start ))

for branch in $branches; do
    replay_branch "$branch"
done

# --- 8. verdict --------------------------------------------------------
now_tests=0
now_asserts=0
if [ -f "$work/suite-counts.txt" ]; then
    read -r now_tests now_asserts < "$work/suite-counts.txt"
fi
now_sweep_pass=0
now_sweep_fail=0
now_sweep_skip=0
if [ -f "$work/sweep-counts.txt" ]; then
    read -r now_sweep_pass now_sweep_fail now_sweep_skip < "$work/sweep-counts.txt"
fi

printf '\n'
if [ "$base_tests" -gt 0 ]; then
    printf 'suite  %d tests / %d assertions (base %s: %d / %d, delta %+d / %+d)\n' \
        "$now_tests" "$now_asserts" "$base_key" "$base_tests" "$base_asserts" \
        "$((now_tests - base_tests))" "$((now_asserts - base_asserts))"
else
    printf 'suite  %d tests / %d assertions\n' "$now_tests" "$now_asserts"
fi
if [ -f "$work/sweep-counts.txt" ]; then
    printf 'corpus %d pass / %d fail / %d skip-parse\n' \
        "$now_sweep_pass" "$now_sweep_fail" "$now_sweep_skip"
else
    printf 'corpus not run\n'
fi

printf 'concurrent span\t%d\tseq\t\n' "$parallel_ms" >> "$timings"
printf 'TOTAL (wall)\t%d\tseq\t\n' "$(( $(now_ms) - run_start ))" >> "$timings"

printf '\n'
awk -F'\t' '
    $3 == "skip"   { printf "  %-18s %7s  %s\n", $1, "skipped", $4; next }
    $3 == "notrun" { printf "  %-18s %7s  %s\n", $1, "not run", $4; next }
    $3 == "conc"   { printf "  %-18s %6.1fs  *\n", $1, $2 / 1000; next }
                   { printf "  %-18s %6.1fs\n", $1, $2 / 1000 }
' "$timings"
printf '\n  * these rows OVERLAP — they ran concurrently and sum to more than the\n'
printf '    elapsed time. Battery timings measure the battery, never the code;\n'
printf '    a benchmark arm runs alone and sequentially (docs/testing.md).\n'

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
    cp "$work/lint-anyparse.json" "$cache_dir/$head_key-anyparse.json"
    if [ -f "$work/lint-tm.used" ]; then
        cp "$work/lint-tm.json" "$cache_dir/$head_key-tm.json"
    fi
    bin/hxq sweep --save "$cache_dir/$head_key-sweep.json" > /dev/null
    printf '%d %d\n' "$now_tests" "$now_asserts" > "$cache_dir/$head_key-suite.txt"
    echo "battery.sh: snapshot written for $head_key in $cache_dir"
fi

printf -- '--- battery: PASS ---\n'
