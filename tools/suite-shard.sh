#!/usr/bin/env bash
#
# suite-shard.sh — run the WHOLE utest suite as N parallel `APQ_TEST` shards.
#
# The suite is one `node bin/test.js` process and the profile says its cost
# is a thick head plus a long flat tail: the top 20 of 634 classes are 75 %
# of the wall time, the remaining 614 share the rest. That shape shards well
# — four processes measure ~2.5x faster than one — but only if two things
# hold, and both are gates in this script rather than advice in a doc:
#
#   1. Every registered class runs EXACTLY ONCE. `APQ_TEST` is a SUBSTRING
#      filter over the fully-qualified class name, so a class whose filter
#      string is a substring of another class's runs in two shards (counts
#      inflate) and a class missing from every shard list runs in none
#      (counts shrink, silently, and the run still reports green). The
#      generator therefore reads the REAL `addCase(new X())` list out of
#      test/RunTests.hx — never a name heuristic. Nine registered classes
#      do not end in `Test` (five end in `Probe`, four begin with it), and
#      a suffix filter drops them and 43 tests with them. Every extracted
#      name must also be a plain identifier, so a registration shape the
#      parser cannot turn into a filter is a hard error rather than a
#      filter that matches nothing. The run then refuses to start unless
#      the union of the shard lists equals the extracted list exactly.
#
#   2. Classes that share MUTABLE STATE outside their own process stay in
#      ONE shard. Two such paths are fixed constants, not per-test temps:
#      `/tmp/anyparse-last-probe.hx` (`Cli.STAGE_PROBE_PATH`, a single slot
#      that `apq probe` overwrites and the Tier-5 tests read back
#      byte-for-byte) and `bin/.last-sweep.json` (the corpus Δ-baseline,
#      rewritten by HxFormatterCorpusTest and read by ApqDxTier5CliTest).
#      The classes that touch them are pinned to shard 0 as one group, and
#      every pinned name must still be registered or the run refuses —
#      otherwise a rename un-pins a class in silence. Everything else uses
#      unique per-test temp directories and random compiler-server ports,
#      so it parallelises freely.
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
    echo "suite-shard.sh: hxq is not on PATH — it reads the registered class list out of test/RunTests.hx" >&2
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

# --- 1. the registered class list --------------------------------------
#
# Structural, not textual: `addCase(new X())` is an AST pattern, so a
# reformat or a comment cannot change what this sees. Output goes to a file
# rather than a pipe — hxq's own gate refuses a `.hx` path inside a piped
# grep/sed command line.
hxq search 'addCase(new $x())' test/RunTests.hx --flat --limit 99999 \
    > "$work/addcase.txt" 2> "$work/addcase.err" || {
    echo "suite-shard.sh: reading test/RunTests.hx failed:" >&2
    cat "$work/addcase.err" >&2
    rc=1
    exit 1
}

# The pattern's `()` does NOT constrain arity — `addCase(new X(1))` matches
# it too, and the naive strip would yield the filter string `unit.X(1))`,
# which matches no class: the shard silently runs fewer tests while class
# parity still passes, because the bogus name is in the plan. So every
# extracted name must be a plain (optionally dotted) identifier, and
# anything else stops the run and is printed verbatim.
awk -F'x=new ' '
    NF > 1 {
        n = $2
        sub(/\(\)\)$/, "", n)
        if (n !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/) {
            print "suite-shard.sh: cannot derive an APQ_TEST filter from: " $0 > "/dev/stderr"
            bad = 1
            next
        }
        # A dotted name is already qualified; a bare one is package `unit`.
        print (index(n, ".") ? n : "unit." n)
    }
    END { if (bad) exit 3 }
' "$work/addcase.txt" > "$work/classes.txt" || {
    echo "suite-shard.sh: test/RunTests.hx holds a registration this generator cannot name — fix the shape or teach the parser" >&2
    rc=1
    exit 1
}

total_classes=$(awk 'END { print NR }' "$work/classes.txt")
if [ "$total_classes" -eq 0 ]; then
    echo "suite-shard.sh: found no addCase(new X()) registrations in test/RunTests.hx" >&2
    rc=1
    exit 1
fi

sort -u "$work/classes.txt" > "$work/classes.sorted"
unique_classes=$(awk 'END { print NR }' "$work/classes.sorted")
if [ "$unique_classes" -ne "$total_classes" ]; then
    echo "suite-shard.sh: test/RunTests.hx registers the same class twice ($total_classes registrations, $unique_classes distinct) — a sharded run cannot reproduce that" >&2
    rc=1
    exit 1
fi

# --- 2. substring-collision gate ---------------------------------------
#
# `APQ_TEST=unit.Foo` also selects `unit.FooBar`. With one process that is
# harmless (the class runs once either way); split across shards it runs
# TWICE and the aggregate count silently exceeds the monolith's. O(n^2)
# over ~600 names is a few milliseconds.
awk '
    { name[NR] = $0; n = NR }
    END {
        for (i = 1; i <= n; i++)
            for (j = 1; j <= n; j++)
                if (i != j && index(name[j], name[i]) > 0)
                    print name[i] " is a substring of " name[j]
    }
' "$work/classes.sorted" > "$work/collisions.txt"

if [ -s "$work/collisions.txt" ]; then
    echo "suite-shard.sh: APQ_TEST filter collision — these names cannot be split across shards without double-running:" >&2
    cat "$work/collisions.txt" >&2
    rc=1
    exit 1
fi

# --- 3. the plan -------------------------------------------------------
#
# Weights are the measured in-suite self-times from the suite profile
# (2026-08-17, HEAD ff3f20ae), in milliseconds. In-suite rather than
# isolated: an isolated run re-pays the ~2.4 s resolution warm-up that the
# monolith pays once, which overstates every class that touches the
# resolution library and produces a worse split. The tail is flat — the
# overwhelming majority of classes are under 100 ms — so one default covers
# it. Stale weights cost balance, never correctness: no gate reads them.
#
# The sticky list is derived, not remembered. Every class holding an exact
# `probe` string leaf calls the subcommand that writes the single staging
# slot: `hxq lit 'probe' test/ --kind Literal`, then READ each hit — one of
# them is a fixture method named `probe`, not a subcommand. `hxq lit
# '.last-sweep.json' test/` finds the corpus baseline's users. Re-derive
# when adding a test that stages a probe or touches that baseline: a writer
# left outside the group does not fail, it races a byte-for-byte read-back
# in a sub-millisecond window and surfaces later as an unreproducible flake.
sticky_list="unit.HxFormatterCorpusTest unit.ApqDxTier5CliTest unit.ApqDxTier4CliTest unit.ApqProbeCliTest unit.ApqReconCliTest unit.ApqWriterProbeCliTest unit.ApqAstTypeRefsCliTest unit.ApqHxtestSection1ConfigTest"

# A pinned class that no longer exists is the silent failure mode of a
# hand-maintained list: a rename un-pins it, nothing complains, and the
# race comes back. Cheap to forbid.
for sticky in $sticky_list; do
    if ! grep -qxF "$sticky" "$work/classes.sorted"; then
        echo "suite-shard.sh: pinned class $sticky is not registered in test/RunTests.hx — renamed or removed? update the sticky list" >&2
        rc=1
        exit 1
    fi
done

awk -v sticky_list="$sticky_list" '
    BEGIN {
        split(sticky_list, s, " ")
        for (i in s) sticky[s[i]] = 1

        # 4510 in the profile: testSelfStatusSourceFlagAccepted walked the
        # whole src/ to assert one exit code. Scoped to a fixture since.
        w["unit.ApqDxTier5CliTest"] = 40
        w["unit.LintConfigCliTest"] = 2370
        w["unit.CompilerOracleE2ETest"] = 2100
        w["unit.ExplicitLocalTypeOracleE2ETest"] = 1900
        w["unit.HxFormatterCorpusTest"] = 1400
        w["unit.ExplicitTypeReturnOracleTest"] = 1310
        w["unit.ApqDxTier4CliTest"] = 1180
        w["unit.AvoidDynamicBagOracleE2ETest"] = 950
        w["unit.PreferInlineOracleTest"] = 730
        w["unit.LintFixFixedPointCliTest"] = 530
        w["unit.FixVerifierGroupE2ETest"] = 520
        w["unit.ResolutionScopeCliTest"] = 500
        w["unit.LintPerFileConfigCliTest"] = 350
        w["unit.PreferCaseGuardOracleE2ETest"] = 280
        w["unit.AvoidDynamicRiskyFixE2ETest"] = 280
        w["unit.ResolutionLibraryCacheTest"] = 250
        w["unit.ImplicitStdScopeTest"] = 210
        w["unit.GuardContinueCheckTest"] = 190
        w["unit.FixVerifierScopeE2ETest"] = 170
        w["unit.PreferStaticExtensionCheckTest"] = 150
        default_weight = 30
    }
    {
        weight = ($0 in w) ? w[$0] : default_weight
        # Sticky first at any weight, so the group lands on shard 0 before
        # the greedy pass starts filling it.
        printf "%d\t%d\t%s\n", (($0 in sticky) ? 1 : 0), weight, $0
    }
' "$work/classes.sorted" | sort -k1,1nr -k2,2nr -k3,3 > "$work/weighted.txt"

# Longest-processing-time-first: the sticky group is dealt onto shard 0 as
# one block, then every other class goes to whichever shard is lightest so
# far. Greedy LPT is within 4/3 of optimal and needs no search.
awk -v shards="$shards" '
    { is_sticky[NR] = $1; weight[NR] = $2; name[NR] = $3; n = NR }
    END {
        for (s = 0; s < shards; s++) load[s] = 0
        for (i = 1; i <= n; i++) {
            if (is_sticky[i]) {
                target = 0
            } else {
                target = 0
                for (s = 1; s < shards; s++) if (load[s] < load[target]) target = s
            }
            load[target] += weight[i]
            print target "\t" name[i]
        }
    }
' "$work/weighted.txt" > "$work/assigned.txt"

# --- 4. parity gates on the plan ---------------------------------------
assigned_total=$(awk 'END { print NR }' "$work/assigned.txt")
awk -F'\t' '{ print $2 }' "$work/assigned.txt" | sort -u > "$work/assigned.sorted"
assigned_unique=$(awk 'END { print NR }' "$work/assigned.sorted")

if [ "$assigned_total" -ne "$total_classes" ] || [ "$assigned_unique" -ne "$total_classes" ]; then
    echo "suite-shard.sh: PARITY FAIL — $total_classes registered classes, $assigned_total placements, $assigned_unique distinct" >&2
    diff "$work/classes.sorted" "$work/assigned.sorted" >&2 || true
    rc=1
    exit 1
fi

if ! diff -q "$work/classes.sorted" "$work/assigned.sorted" > /dev/null; then
    echo "suite-shard.sh: PARITY FAIL — the shard plan does not cover the registered class list:" >&2
    diff "$work/classes.sorted" "$work/assigned.sorted" >&2 || true
    rc=1
    exit 1
fi

s=0
while [ "$s" -lt "$shards" ]; do
    awk -F'\t' -v s="$s" '$1 == s { print $2 }' "$work/assigned.txt" > "$work/shard$s.list"
    count=$(awk 'END { print NR }' "$work/shard$s.list")
    if [ "$count" -eq 0 ]; then
        # An empty APQ_TEST match makes the runner exit 1, so an empty
        # shard is a hard error rather than a wasted process.
        echo "suite-shard.sh: shard $s is empty — reduce -n below $shards" >&2
        rc=1
        exit 1
    fi
    awk 'NR > 1 { printf "," } { printf "%s", $0 } END { print "" }' "$work/shard$s.list" > "$work/shard$s.filter"
    s=$((s + 1))
done

if [ "$plan_only" -eq 1 ]; then
    echo "suite-shard.sh: $total_classes classes over $shards shards (class parity OK)"
    s=0
    while [ "$s" -lt "$shards" ]; do
        echo "  shard $s: $(awk 'END { print NR }' "$work/shard$s.list") classes -> $work/shard$s.list"
        s=$((s + 1))
    done
    keep=1
    exit 0
fi

# --- 5. run ------------------------------------------------------------
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

# --- 6. per-shard summaries + aggregate --------------------------------
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
    classes=$(awk 'END { print NR }' "$work/shard$s.list")
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

# --- 7. count parity ---------------------------------------------------
#
# Class parity above already forbids a silent loss: every registered class
# is placed exactly once, no name is a substring of another, and no shard
# ran zero tests. Test/assertion totals therefore follow — but the totals
# grow with every slice, so pinning a literal in this script would rot into
# a lie within a day. The cross-check is opt-in instead: --verify pays for
# a monolith run and compares, --expect takes the caller's last known-good
# pair. With neither, the aggregate is reported as un-cross-checked.
parity_note="counts not cross-checked (class parity OK: $total_classes/$total_classes)"

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
