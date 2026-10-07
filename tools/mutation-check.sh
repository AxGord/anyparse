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
# Each track runs in a git worktree reset to a base commit (HEAD, unless
# --base names another — see below) with its own private build
# (tools/worker-build.sh), so tracks run in parallel and never touch
# bin/apq.js or bin/test.js. Because the worktrees come from that ONE
# commit, uncommitted work in the main tree is NOT seen unless --base
# points at a snapshot that carries it — commit (or stash into the patch,
# or pass --base) whatever the mutation is supposed to be measured against.
#
# Speed, and what each lever may not change (docs/testing.md § "Mutation
# runs: slots, servers and the fixture cache"): one worktree per JOB SLOT,
# not per track, each with a warm `haxe --wait` server, so a track's build
# re-types only what its patch touched; and a content-addressed replay of
# the reach probes' fixture compiles, shared by every track of the run.
# `APQ_MUTATION_NO_SERVER=1` / `APQ_MUTATION_NO_FIXTURE_CACHE=1` turn either
# off — the A/B arms a verdict comparison needs.
#
# Usage: tools/mutation-check.sh <manifest> [--jobs N] [--keep] [--build-only] [--killer-first] [--schema <dir>] [--base <ref>]
#
# --schema <dir>
#               the composed build `tools/mutation-arm.sh` makes (docs/testing.md
#               § "Mutation runs: killer-first, batched render, schemata"): a
#               track named in `<dir>/candidates` waits for `<dir>/state`, and
#               when that reads `ready` and `<dir>/map` holds the track, runs
#               `<dir>/test.js` with `APQ_MUTANT=<id>` instead of building —
#               still in its own slot, its patch applied, so a test that reads
#               the tree from disk reads the cut. Any other candidate is built
#               as a track always was. Candidates are dealt last.
#
# --killer-first
#               run a track's EXPECTED tests alone first (`APQ_TEST=test:<e>,…`)
#               and take a KILLED reading of that run as the verdict; any other
#               reading is answered by the track's own filter, as without the
#               flag. The verdict cannot differ (killer_tokens says why); what a
#               killer-first row loses is its `+extra:` collateral. A track with
#               no expectations runs its filter only.
#
# --jobs N      job slots (default min(cores - 2, memory / 5 GiB), at least 1).
#
# --base <ref>  build every track worktree from <ref> instead of HEAD.
#               `tools/mutation-arm.sh --working-tree` (T694) passes the
#               `git stash create` commit it built the manifest's patches
#               against here — a track built from plain HEAD would either
#               PATCH-FAIL (the patch's context lines came from the
#               snapshot) or silently apply while missing whatever ELSE
#               the snapshot carried, which reads as a false SURVIVED.
#
# `--build-only` stops after the build: each track is applied, compiled and
# reported as APPLIES or BUILD-FAIL, and no suite runs. That is not a weaker
# mutation check, it is a different question — "can this cut even be compiled"
# is what an arm being AUTHORED needs answered, and the whole suite is the
# wrong instrument for it. `tools/mutation-arm.sh --check-apply` is the caller.
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
#   BUILD-FAIL the patched tree does not compile — a useless mutation. The
#              row names WHY, out of `apq mutation-verdict --build`:
#              null-safety-structure / null-safety / inline-return /
#              arm-registry / syntax / type / other.
#   APPLIES    --build-only: the patched tree compiles. Nothing is claimed
#              about any fixture — that is what a full track is for.
#   RUN-FAIL   no usable transcript, or a red header whose rows the
#              classifier could not name.
#
# Verdicts come from `apq mutation-verdict` (main-tree build), not from
# this script — see `classify` below for why the parser is not here.
#
# Exit 0 only when every track is KILLED; any other verdict exits 1.
#
# Every worktree this script created is removed on exit (including on
# INT/TERM/HUP), and every slot server stopped — a server also stops itself
# within seconds of a SIGKILLed parent (slot_server's watchdog); a
# `worktree remove` that itself fails is swallowed so one bad entry cannot
# strand the rest, which does mean a stuck worktree can survive as a
# registered entry — `git worktree list` after a crashed run is the check.
#
# The workroot follows the run: removed when every track was KILLED,
# kept — with its path printed — on any other exit or under `--keep`,
# because then the transcripts, build logs and .verdict files are the
# post-mortem. It used to be kept unconditionally, and the price is on
# record: each track leaves a private 23 MB build beside its transcripts,
# so one `--all` sweep of the 208 declared arms is ~4.8 GB, and on
# 2026-09-05 125 of these directories held 46.6 GB — one of them from a
# crashed run still holding 105 REGISTERED worktrees at a dead commit.
# What no trap can cover is SIGKILL, so the next run of any of these
# tools sweeps what a killed one left; the predicate that keeps that safe
# while sibling workers are running is in tools/tmp-lifecycle.sh.
set -euo pipefail

script_dir=$(cd -P "$(dirname "$0")" && pwd)
self="$script_dir/$(basename "$0")"
repo=$(cd -P "$script_dir/.." && pwd)

# Scratch-directory lifecycle: creation, the startup sweep for what a
# SIGKILL left behind, and the predicate that keeps a sibling's live run
# safe from it. Sourced above the `--track` child entry point, which uses
# none of it — the child is handed the parent's workroot.
. "$script_dir/tmp-lifecycle.sh"
. "$script_dir/fixture-cache.sh"

# ---------------------------------------------------------------- parse

# Emit `name<TAB>patch<TAB>filter<TAB>expected` for every data line of a
# manifest, with the patch path already resolved against the manifest's
# directory. Bails on a malformed line.
parse_manifest() {
    local manifest=$1 manifest_dir
    manifest_dir=$(cd -P "$(dirname "$manifest")" && pwd)
    # One awk pass. The shell loop it replaces forked ~8 processes per line, and
    # every track re-parsed the whole manifest to find its own row: 43 s per
    # parse of a 2051-arm manifest, paid once per track.
    awk -v manifest="$manifest" -v dir="$manifest_dir" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        {
            line = $0
            if (trim(line) == "" || substr(trim(line), 1, 1) == "#") next
            n = split(line, f, "|")
            if (n < 4) { printf "mutation-check.sh: %s:%d: expected 4 '"'"'|'"'"'-separated fields\n", manifest, NR > "/dev/stderr"; bad = 1; exit 1 }
            name = trim(f[1]); patch = trim(f[2]); filter = trim(f[3])
            expected = f[4]
            for (i = 5; i <= n; i++) expected = expected "|" f[i]
            expected = trim(expected)
            if (name == "" || name ~ /[^A-Za-z0-9_.-]/) { printf "mutation-check.sh: %s:%d: bad track name '"'"'%s'"'"' (allowed: A-Za-z0-9_.-)\n", manifest, NR, name > "/dev/stderr"; bad = 1; exit 1 }
            if (patch == "") { printf "mutation-check.sh: %s:%d: track '"'"'%s'"'"' has no patch file\n", manifest, NR, name > "/dev/stderr"; bad = 1; exit 1 }
            if (substr(patch, 1, 1) != "/") patch = dir "/" patch
            if (filter == "") { printf "mutation-check.sh: %s:%d: track '"'"'%s'"'"' has an empty APQ_TEST filter (use ALL for the whole suite)\n", manifest, NR, name > "/dev/stderr"; bad = 1; exit 1 }
            printf "%s\t%s\t%s\t%s\n", name, patch, filter, expected
        }
        END { exit bad }
    ' "$manifest"
}

# ---------------------------------------------------------- child mode

# `--track <name> <manifest> <workroot>` — one track, run by xargs. The
# child re-reads the manifest to find its own line so nothing has to
# survive shell quoting. It ALWAYS exits 0, otherwise xargs aborts the
# whole batch on the first failing mutation.
#
# The track runs in a SLOT (§ "Slots" in the parent section): the first
# free worktree of the ones the parent created, taken with an atomic
# `mkdir` and given back when the track is done. The slot is reset to the
# base commit before the patch goes in, so the track sees the fresh
# worktree it always had; what is reused is the PATH, and with it the
# slot's warm compiler server.
run_track() {
    local name=$1 manifest=$2 workroot=$3 build_only=${4:-0}
    local slot="" s
    while [ -z "$slot" ]; do
        for s in $(cat "$workroot/slots"); do
            if mkdir "$workroot/slot-$s.lock" 2>/dev/null; then
                slot=$s
                break
            fi
        done
        [ -n "$slot" ] || sleep 1
    done
    run_in_slot "$name" "$manifest" "$workroot" "$build_only" "$slot"
    rmdir "$workroot/slot-$slot.lock" 2>/dev/null || true
    return 0
}

run_in_slot() {
    local name=$1 manifest=$2 workroot=$3 build_only=$4 slot=$5
    local row patch filter expected wt build log verdict_file path
    verdict_file="$workroot/$name.verdict"
    wt="$workroot/slot-$slot"
    build="$workroot/build-$name"
    log="$workroot/$name.log"

    # The parent's parse of the manifest (`<workroot>/rows`), read, not redone.
    row=$(awk -F'\t' -v n="$name" '$1 == n && !seen { print; seen = 1 }' "$workroot/rows")
    if [ -z "$row" ]; then
        write_verdict "$verdict_file" "RUN-FAIL" "track '$name' vanished from $manifest between the parent's parse and this child's"
        return 0
    fi
    patch=$(printf '%s' "$row" | cut -f2)
    filter=$(printf '%s' "$row" | cut -f3)
    expected=$(printf '%s' "$row" | cut -f4)

    # Back to the base commit: the previous track's patch and everything its
    # run wrote, ignored files included, go. git rewrites only the files that
    # DIFFER, so every other file keeps the mtime the slot's server cached it
    # under.
    if ! { git -C "$wt" reset --hard -q && git -C "$wt" clean -fdxq; } > "$workroot/$name.wt.log" 2>&1; then
        write_verdict "$verdict_file" "WT-FAIL" "slot $slot could not be reset: $(tr '\n' ' ' < "$workroot/$name.wt.log")"
        return 0
    fi
    # `--` so a patch path beginning with `-` is a path, not a flag.
    if ! git -C "$wt" apply -- "$patch" 2>"$workroot/$name.apply.log"; then
        write_verdict "$verdict_file" "PATCH-FAIL" "$(tr '\n' ' ' < "$workroot/$name.apply.log")"
        return 0
    fi

    local started built mutant="" kind
    started=$(date +%s)
    # A schema track (--schema) runs the composed build with its arm switched
    # on, and builds nothing; one the composed build left out is built here.
    if mutant=$(schema_track "$workroot" "$name"); then
        # Candidates are dealt last, so a slot that reaches one is done
        # building: its server's gigabytes go back to the machine.
        stop_slot_server "$workroot" "$slot"
        build="$(cat "$workroot/schema")"
        kind=schema
    elif ! build_track "$workroot" "$slot" "$wt" "$build" "$workroot/$name.build.log"; then
        write_verdict "$verdict_file" "BUILD-FAIL" "$(build_detail "$workroot/$name.build.log")"
        return 0
    else
        kind=$(build_kind "$workroot/$name.build.log")
    fi
    built=$(date +%s)
    # `<build kind> <build s> <run s>`, summed by the parent's report.
    printf '%s %s ' "$kind" "$((built - started))" > "$workroot/$name.timing"

    # `--build-only` asks whether the cut COMPILES and stops there. It claims
    # nothing about any fixture, which is why the verdict is not KILLED: an arm
    # being authored has no fixture yet, and the suite would be answering a
    # question nobody asked at ~2.5x the cost.
    if [ "$build_only" -eq 1 ]; then
        write_verdict "$verdict_file" "APPLIES" "the patched tree compiles"
        return 0
    fi

    # The fixture cache's `haxe` shim goes first on the PATH when the parent
    # built one (§ "The fixture cache" in the parent section).
    path=$PATH
    if [ -x "$workroot/fixture-cache/bin/haxe" ]; then
        path="$workroot/fixture-cache/bin:$PATH"
    fi

    # --killer-first: the tests the expectations name, alone, first. Their run
    # answers the verdict whenever it matched an expectation (killer_tokens
    # says why); only one that matched NONE needs the filtered run, which is
    # then dealt into FALLBACK_SLICES slices run at once (fallback_tokens).
    local classified v d full phase=filtered
    if [ -f "$workroot/killer-first" ] && [ -n "$expected" ]; then
        run_suite "$wt" "$build" "$(killer_tokens "$expected")" "$path" "$mutant" > "$log.killers" 2>&1 || true
        if classified=$(classify "$expected" "$log.killers") && matched_any "$classified" "$expected"; then
            mv "$log.killers" "$log"
            phase=killers
        else
            phase=sliced
        fi
    fi
    local slices="" slice tokens
    if [ "$phase" = "sliced" ] && slices=$(fallback_tokens "$filter"); then
        slice=0
        while IFS= read -r tokens; do
            run_suite "$wt" "$build" "$tokens" "$path" "$mutant" > "$log.slice$slice" 2>&1 &
            slice=$((slice + 1))
        done <<SLICES
$slices
SLICES
        wait
    elif [ "$phase" != "killers" ]; then
        phase=filtered
        run_suite "$wt" "$build" "$filter" "$path" "$mutant" > "$log" 2>&1 || true
    fi
    # `<run s> <phase>`: `killers` when the killer-first run gave the verdict,
    # `sliced` when the filtered run answered it in slices.
    printf '%s %s\n' "$(($(date +%s) - built))" "$phase" >> "$workroot/$name.timing"
    # Captured, not redirected straight into the file: `> "$verdict_file"`
    # truncates before classify runs, so an abort inside it would leave an
    # empty file and the report would print a blank verdict column.
    # write_verdict stays the single owner of the file format.
    if [ "$phase" = "sliced" ]; then
        if ! classified=$(classify "$expected" "$log".slice*); then
            write_verdict "$verdict_file" "RUN-FAIL" "classifier aborted on $log.slice*"
            return 0
        fi
        # one transcript to open, the slices in order
        cat "$log".slice* > "$log"
    elif [ "$phase" = "filtered" ] && ! classified=$(classify "$expected" "$log"); then
        write_verdict "$verdict_file" "RUN-FAIL" "classifier aborted on $log"
        return 0
    fi
    full=""
    { IFS= read -r v; IFS= read -r d; IFS= read -r full || true; } <<VERDICT
$classified
VERDICT
    # The classifier reports WHY it could not judge; only the shell knows
    # WHERE the transcript is, and a RUN-FAIL row is read by someone about
    # to open it.
    if [ "$v" = "RUN-FAIL" ]; then
        d="$d ($log)"
    fi
    # T703: an optional third line is the SAME row, every name-list uncapped
    # — `MutationVerdict.classify` emits it only when `cap` actually elided
    # something. Appended to the transcript itself (not the report row,
    # which stays capped) so a name a flake pushed past the ten-item window
    # is findable without re-deriving it from the raw utest dump; a command
    # this script does not own writing to (it only reports) is deliberately
    # kept read-only, so the write lives here rather than in the classifier.
    if [ -n "$full" ]; then
        printf '\n--- mutation-verdict: uncapped %s ---\n%s\n' "$v" "$full" >> "$log"
    fi
    write_verdict "$verdict_file" "$v" "$d"
    return 0
}

# run_suite <worktree> <build-dir> <APQ_TEST filter | ALL> <PATH> [<arm id>] —
# one suite run of the track's build, its transcript on stdout. The arm id
# switches a composed build's arm on (`APQ_MUTANT`); a per-arm build has no
# switch, and no track ever inherits one from the caller.
run_suite() {
    if [ "$3" = "ALL" ]; then
        ( cd "$1" && env -u APQ_TEST -u APQ_MUTANT ${5:+APQ_MUTANT=$5} PATH="$4" node "$2/test.js" )
    else
        ( cd "$1" && env -u APQ_MUTANT ${5:+APQ_MUTANT=$5} APQ_TEST="$3" PATH="$4" node "$2/test.js" )
    fi
}

# schema_track <workroot> <name> — `<arm id>` when the
# composed build (--schema) stands for this track, else a non-zero status.
# A candidate waits here for the build to answer; one the build left out, or
# every candidate of a build that failed, is built per arm.
schema_track() {
    local dir
    [ -f "$1/schema" ] || return 1
    dir=$(cat "$1/schema")
    grep -qxF "$2" "$dir/candidates" || return 1
    while [ ! -f "$dir/state" ]; do
        sleep 2
    done
    [ "$(cat "$dir/state")" = "ready" ] || return 1
    awk -v n="$2" '$1 == n { print $2; found = 1 } END { exit found ? 0 : 1 }' "$dir/map"
}

# killer_tokens <expected-csv> -> the APQ_TEST filter running exactly the
# tests that can answer the expectations: `test:<e>` selects every test whose
# `<fq.Class>.<method>` contains `<e>`, the very substring rule `apq
# mutation-verdict` matches an expectation against a failure name with.
#
# Why this run can answer for the filtered run: each expectation is matched
# by a failure of one of the tests carrying it, and this run holds all of
# those tests and nothing else, so an expectation is matched here exactly when
# it is matched there — and the filtered run is red whenever one is. So a
# KILLED reading is KILLED there, and a MISMATCH that matched at least one
# expectation is the same MISMATCH (matched_any). A reading that matched none
# (SURVIVED, a MISMATCH red only elsewhere, RUN-FAIL…) depends on tests this
# run left out, so it is never used: the filtered run answers. What a
# killer-first row loses is the `+extra:` census of the filtered set — the
# collateral `--fast` already narrows to the pinned classes.
killer_tokens() {
    printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d; s/^[[:space:]]*/test:/; s/[[:space:]]*$//' | paste -sd, -
}

# matched_any <classified> <expected-csv> — whether a killer-first reading
# answers the verdict: KILLED, or MISMATCH with at least one expectation
# matched. Every test carrying an expectation ran, so an expectation matched
# here is matched in the filtered run and one missing here is missing there:
# the filtered run is red and its verdict is the same MISMATCH. Only a run
# that matched NOTHING leaves the filtered run's own question open — green
# (SURVIVED) or red somewhere else (MISMATCH).
matched_any() {
    local verdict missing
    verdict=$(printf '%s\n' "$1" | sed -n '1p')
    [ "$verdict" = "KILLED" ] && return 0
    [ "$verdict" = "MISMATCH" ] || return 1
    # The uncapped third line when the row was capped, else the row itself.
    missing=$(printf '%s\n' "$1" | sed -n '3p')
    [ -n "$missing" ] || missing=$(printf '%s\n' "$1" | sed -n '2p')
    missing=$(printf '%s' "$missing" | sed -n 's/.*(missing: \(.*\))$/\1/p')
    [ -n "$missing" ] || return 1
    [ "$(printf '%s' "$missing" | awk -F', ' '{ print NF }')" -lt "$(printf '%s' "$2" | awk -F',' '{ print NF }')" ]
}

# fallback_tokens <filter> — FALLBACK_SLICES lines, each the APQ_TEST filter
# of one slice of the filtered run (`<class>#<i>/<k>` for every class of it);
# non-zero when the filter is not a plain class list. Slices are disjoint and
# cover each class (ShardFilter), so their union is the filtered run, read as
# one by `apq mutation-verdict`; a slice is an own process because the one
# class that falls back is almost always the heaviest of the suite.
fallback_tokens() {
    local i
    case "$1" in
        ALL|*'#'*|*'test:'*|'') return 1 ;;
    esac
    for i in $(seq 0 $((FALLBACK_SLICES - 1))); do
        printf '%s\n' "$1" | tr ',' '\n' | sed "s|\$|#$i/$FALLBACK_SLICES|" | paste -sd, -
    done
}

# build_track <workroot> <slot> <worktree> <build-dir> <log> — the track's
# private test.js, through the slot's warm server when there is one.
#
# A server answer is trusted only as a SUCCESS. Its known failure modes are
# all failures, never a wrong success: a stale synthesized type after a
# grammar module changed (`Type name … is redefined from module …`), stale
# null-safety diagnostics, a silent hang (test-js.hxml's header; the
# timeout). A failed warm build restarts the server and is repeated through
# the FRESH one, whose first build compiles everything from scratch — and
# leaves the slot warm again. Only when that fails too is the build repeated
# with a plain cold `haxe`, and that compile's answer is the verdict: a
# BUILD-FAIL row never rests on a server.
build_track() {
    local workroot=$1 slot=$2 wt=$3 build=$4 log=$5 port pid rss attempt
    for attempt in warm restarted; do
        port=$(slot_server "$workroot" "$slot")
        [ -n "$port" ] || break
        if APQ_HAXE_SERVER="127.0.0.1:$port" run_with_timeout "$BUILD_TIMEOUT" "$wt/tools/worker-build.sh" "$build" test > "$log" 2>&1; then
            # A server grows with every build it answers; past the cap it is
            # restarted before the next one rather than left to swap.
            pid=$(slot_server_pid "$workroot" "$slot")
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
            if [ -n "$rss" ] && [ "$rss" -gt "$SERVER_MAX_RSS_KB" ]; then
                stop_slot_server "$workroot" "$slot"
            fi
            echo "$attempt" > "$log.kind"
            return 0
        fi
        stop_slot_server "$workroot" "$slot"
        mv "$log" "$log.$attempt"
    done
    # The log stays the compiler's own: `apq mutation-verdict --build` reads it.
    echo cold > "$log.kind"
    env -u APQ_HAXE_SERVER "$wt/tools/worker-build.sh" "$build" test > "$log" 2>&1
}

# How the track's build went, as build_track left it: `warm`, `restarted` (a
# failed warm build repeated through a fresh server), or `cold`.
build_kind() {
    cat "$1.kind" 2>/dev/null || echo cold
}

# run_with_timeout <seconds> <cmd>... — <cmd> in its own process group,
# killed WHOLE (the haxe client worker-build.sh backgrounds included) when
# it outlives <seconds>; exit 124 then. Perl, because macOS ships no
# `timeout`.
run_with_timeout() {
    perl -e '
        my $t = shift;
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
        local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
        alarm $t;
        waitpid($pid, 0);
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$@"
}

# `slot-<n>.server` holds `<pid> <port>` while the slot's server runs.
slot_server_pid() {
    awk '{ print $1 }' "$1/slot-$2.server" 2>/dev/null || true
}

stop_slot_server() {
    local pid
    pid=$(slot_server_pid "$1" "$2")
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$1/slot-$2.server"
}

# slot_server <workroot> <slot> -> the port of the slot's live server,
# started on first use; empty when servers are off or none would start (the
# build is then cold, which is only slower).
slot_server() {
    local workroot=$1 slot=$2 pid port try wait owner
    [ -f "$workroot/servers" ] || return 0
    owner=$(cat "$workroot/servers")
    pid=$(slot_server_pid "$workroot" "$slot")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        awk '{ print $2 }' "$workroot/slot-$slot.server"
        return 0
    fi
    for try in 1 2 3; do
        port=$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')
        haxe --wait "127.0.0.1:$port" > "$workroot/slot-$slot.server.log" 2>&1 &
        pid=$!
        # The server must not outlive the run: the parent's EXIT trap stops
        # it, and this watchdog covers the SIGKILL no trap sees.
        (
            while kill -0 "$owner" 2>/dev/null && kill -0 "$pid" 2>/dev/null; do sleep 5; done
            kill "$pid" 2>/dev/null
        ) > /dev/null 2>&1 &
        for wait in 1 2 3 4 5 6 7 8 9 10; do
            if node -e 'const c = require("net").connect(+process.argv[1], "127.0.0.1"); c.on("connect", () => process.exit(0)); c.on("error", () => process.exit(1));' "$port" 2>/dev/null; then
                printf '%s %s\n' "$pid" "$port" > "$workroot/slot-$slot.server"
                printf '%s\n' "$port"
                return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill "$pid" 2>/dev/null || true
    done
    return 0
}

write_verdict() {
    printf '%s\n%s\n' "$2" "$3" > "$1"
}

# ------------------------------------------------------------- parsing

# classify <expected-csv> <log>... -> two lines: verdict, detail. Several logs
# are the slices of one run, classified as their union.
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
    local expected=$1
    shift
    ( cd "$repo" && "$repo/bin/hxq" mutation-verdict "$@" --expect "$expected" )
}

# build_detail <build-log> -> one report-row cell naming WHY the build failed.
#
# A BUILD-FAIL row used to be a log path, so the reading always stopped there.
# The cause comes from the same command as the verdict, and for the same reason:
# the alternative is a `case` ladder in a shell function, which nothing can test.
build_detail() {
    local log=$1 classified cause line
    if ! classified=$( cd "$repo" && "$repo/bin/hxq" mutation-verdict "$log" --build ); then
        printf '%s' "$log"
        return 0
    fi
    { IFS= read -r cause; IFS= read -r line; } <<EOF
$classified
EOF
    printf '%s | %s (%s)' "$cause" "$line" "$log"
}

# --------------------------------------------------- child entry point

# A warm build that has not answered in this many seconds is a hung server
# (a cold build under full load takes about a minute); it is killed and the
# build repeated cold.
BUILD_TIMEOUT=${APQ_MUTATION_BUILD_TIMEOUT:-300}
# The slices a killer-first track's fallback run is dealt into.
FALLBACK_SLICES=${APQ_MUTATION_FALLBACK_SLICES:-4}
# A slot's server is restarted once its resident set passes this (KiB).
SERVER_MAX_RSS_KB=${APQ_MUTATION_SERVER_MAX_RSS_KB:-6291456}
# The memory one default job is budgeted (GiB): see the `--jobs` default.
GIB_PER_JOB=5

if [ "${1:-}" = "--track" ]; then
    if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
        echo "mutation-check.sh: --track needs <name> <manifest> <workroot> [build-only]" >&2
        exit 2
    fi
    run_track "$2" "$3" "$4" "${5:-0}"
    exit 0
fi

# -------------------------------------------------------- parent mode

if [ "$#" -lt 1 ]; then
    echo "usage: mutation-check.sh <manifest> [--jobs N] [--keep] [--build-only] [--killer-first] [--schema <dir>] [--base <ref>]" >&2
    exit 2
fi

manifest=$1
shift
jobs=""
keep=0
build_only=0
killer_first=0
schema=""
# The commit every track worktree is built from. Always HEAD except when
# `tools/mutation-arm.sh --working-tree` (T694) rendered the manifest's
# patches against a `git stash create` snapshot instead — a track built
# from plain HEAD then either PATCH-FAILs (the patch's context lines came
# from the snapshot) or, worse, silently applies while missing whatever
# ELSE the snapshot carried (a new fixture the patch does not touch but the
# arm's expectation set already names), which reads as a false SURVIVED.
base_ref="HEAD"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep)
            keep=1
            shift
            ;;
        --build-only)
            build_only=1
            shift
            ;;
        --killer-first)
            killer_first=1
            shift
            ;;
        --schema)
            if [ "$#" -lt 2 ]; then
                echo "mutation-check.sh: --schema needs a directory" >&2
                exit 2
            fi
            schema=$(cd -P "$2" && pwd)
            shift 2
            ;;
        --base)
            if [ "$#" -lt 2 ]; then
                echo "mutation-check.sh: --base needs a ref" >&2
                exit 2
            fi
            base_ref=$2
            shift 2
            ;;
        --jobs)
            if [ "$#" -lt 2 ]; then
                echo "mutation-check.sh: --jobs needs a number" >&2
                exit 2
            fi
            jobs=$2
            shift 2
            ;;
        *)
            echo "mutation-check.sh: unknown argument '$1' (expected --jobs N, --keep, --build-only, --killer-first, --schema <dir> or --base <ref>)" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$manifest" ]; then
    echo "mutation-check.sh: manifest '$manifest' not found" >&2
    exit 2
fi

# The verdict classifier is `apq mutation-verdict`, run through `$repo/bin/hxq`
# — the shim itself honours HXQ_BIN (T725) when a caller (mutation-arm.sh, or
# a worker driving this script directly) has one set, so `classify`/
# `build_detail` below need no change. This guard only has to stop pointing
# at $repo/bin/apq.js unconditionally, or a worker with an empty $repo/bin/
# (T710/T739) is refused here before the shim ever gets a chance to use its
# own private engine.
apq_bin="$repo/bin/apq.js"
if [ -n "${HXQ_BIN:-}" ]; then
    if [ ! -f "$HXQ_BIN" ]; then
        echo "mutation-check.sh: HXQ_BIN=$HXQ_BIN not found" >&2
        exit 2
    fi
    # Canonicalised, like mutation-arm.sh does for the same variable — a
    # relative HXQ_BIN would otherwise resolve against whatever CWD this
    # script happens to be invoked from, which this script never controls.
    apq_bin=$(cd -P "$(dirname "$HXQ_BIN")" && pwd)/$(basename "$HXQ_BIN")
fi
if [ ! -f "$apq_bin" ]; then
    echo "mutation-check.sh: $apq_bin missing — run 'haxe bin/apq-js.hxml' first, or point HXQ_BIN at a private engine (tools/worker-build.sh <dir> && export HXQ_BIN=<dir>/apq.js) — the verdict classifier is 'apq mutation-verdict'" >&2
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
    # min(cores - 2, memory / GIB_PER_JOB), at least 1 — the clamps bound
    # OUR arithmetic, not a request, so a small machine gets 1 rather than
    # an error. A job is one warm compiler server (~3-5 GB resident) plus a
    # suite process, so memory is the binding term on a 16-core / 64 GB Mac;
    # two cores stay free for the parent, git and the machine's other work.
    # The old default, max(1, min(4, cores/2)), is what made a 139-arm
    # `--fast` sweep take 45 minutes (docs/testing.md § "Mutation runs").
    if [ "$(uname -s)" = "Darwin" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
        mem_gib=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))
    else
        cores=$(nproc 2>/dev/null || echo 2)
        mem_gib=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 8388608) / 1048576 ))
    fi
    jobs=$((cores - 2))
    if [ "$jobs" -gt $((mem_gib / GIB_PER_JOB)) ]; then
        jobs=$((mem_gib / GIB_PER_JOB))
    fi
    if [ "$jobs" -lt 1 ]; then
        jobs=1
    fi
fi
# More slots than tracks would only start servers nothing uses.
track_count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
if [ "$jobs" -gt "$track_count" ]; then
    jobs=$track_count
fi

# The sweep runs BEFORE the claim so this run's own directory is never one
# of its candidates, and after the argument parsing so a usage error costs
# nothing.
tmpl_sweep "$repo"
workroot=$(tmpl_claim anyparse-mutcheck)
echo "workroot: $workroot"

slots=""
exit_code=1
cleanup() {
    local s
    for s in $slots; do
        stop_slot_server "$workroot" "$s"
        git -C "$repo" worktree remove --force "$workroot/slot-$s" >/dev/null 2>&1 || true
    done
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    # `exit_code` is 1 until the report has computed the real one, so every
    # abort BEFORE the report — a bad manifest, an interrupt, a `set -e`
    # death — keeps the directory. Only an all-KILLED run drops it.
    # `|| true` is load-bearing: a non-zero LAST command in an EXIT trap
    # replaces the script's own exit status, so a refused discard would turn
    # an all-KILLED run into `exit 1`.
    if [ "$keep" -eq 0 ] && [ "$exit_code" -eq 0 ]; then
        tmpl_discard "$workroot" "$repo" || true
    elif [ "$keep" -eq 1 ]; then
        # T738: an EXPLICIT --keep gets the permanent marker — without it,
        # tmpl_is_orphan reads this directory as abandoned the moment this
        # process exits (the owner pid is dead either way), indistinguishable
        # from a crashed run, and a LATER run's startup sweep reclaims it
        # despite --keep having asked to retain it. A directory kept only
        # because exit_code != 0 (no --keep) is deliberately left off the
        # marker and ages out through the ordinary grace-period sweep, same
        # as before this fix — a blanket "any non-KILLED run" grant would
        # reintroduce the unbounded accumulation this file's own header
        # records paying for.
        tmpl_mark_keep "$workroot" || true
    fi
}
# INT/TERM/HUP exit rather than resuming, which then fires the EXIT trap
# once. HUP matters here because the common way this runs is an agent
# session whose terminal goes away mid-campaign.
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Slots. A track used to get a worktree of its own, and so a build that
# shared nothing with any other: 36 s of a cold `haxe test-js-common.hxml`
# per track. Now `jobs` worktrees are created once, each track takes a free
# one (run_track) and resets it to the base before applying its patch, and
# each slot keeps one `haxe --wait` server across its tracks: the server's
# module cache is keyed by file PATH, and a slot's paths are its own, so a
# track re-types only what its patch touched and what depends on it.
# `APQ_MUTATION_NO_SERVER=1` builds every track cold (the A/B arm).
#
# Worktree creation is SERIAL: parallel `git worktree add` races over
# .git/worktrees. The expensive parts (build, test run) are the parallel
# ones.
: > "$workroot/slots"
for s in $(seq 1 "$jobs"); do
    if git -C "$repo" worktree add --detach --quiet "$workroot/slot-$s" "$base_ref" 2>"$workroot/slot-$s.wt.log"; then
        slots="$slots $s"
        printf '%s\n' "$s" >> "$workroot/slots"
    fi
done
if [ -z "$slots" ]; then
    while IFS=$'\t' read -r name patch filter expected; do
        write_verdict "$workroot/$name.verdict" "WT-FAIL" "worktree add failed: $(tr '\n' ' ' < "$workroot/slot-1.wt.log")"
    done <<EOF
$rows
EOF
fi
if [ "$killer_first" -eq 1 ]; then
    : > "$workroot/killer-first"
fi
if [ -n "$schema" ]; then
    printf '%s\n' "$schema" > "$workroot/schema"
fi
# Every track reads its own row off the parent's parse (run_in_slot).
printf '%s\n' "$rows" > "$workroot/rows"
if [ -z "${APQ_MUTATION_NO_SERVER:-}" ]; then
    # The owner every slot server's watchdog follows (slot_server).
    printf '%s\n' "$$" > "$workroot/servers"
fi

# The fixture cache. A track pinning MemberReachFactsTest spent 63 of its 66
# seconds in ~290 real compiles of tiny fixtures (the facts and defines
# probes), the same fixtures in every track. `testkit.FixtureCompileCache`
# replays such a compile from a content-addressed record — every input by
# content, every path placeheld — shared by every track of this run AND by
# every run and every suite-shard.sh run before it (the store
# tools/fixture-cache.sh keeps; why keeping it is sound is documented there).
# A mutated facts macro is a different key, so it compiles for real. The
# replay program is built from THIS tree, never from a track's: the tracks'
# sources are the mutated ones. Its `haxe` shim goes first on each suite
# run's PATH and hands every compile that is not a probe compile straight to
# the real compiler. `APQ_MUTATION_NO_FIXTURE_CACHE=1` runs every compile for
# real.
if [ -z "${APQ_MUTATION_NO_FIXTURE_CACHE:-}" ] && [ "$build_only" -eq 0 ]; then
    cache="$workroot/fixture-cache"
    fc_entries="${APQ_SUITE_FIXTURE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/anyparse/fixture-cache}"
    fc_prune "$fc_entries"
    mkdir -p "$cache"
    if ! fc_shim "$repo" "$fc_entries" "$cache/bin" "$cache/tally"; then
        echo "mutation-check.sh: the fixture cache could not be set up — every fixture compile runs for real" >&2
    fi
fi

# Children always exit 0, so xargs failing here means xargs itself broke;
# the report below turns a missing verdict into RUN-FAIL either way.
if [ -n "$slots" ]; then
    # The order tracks are dealt to slots in: a schema candidate last, behind
    # every track that needs a build of its own — it waits on the composed
    # build, and the per-arm builds are the long pole.
    order=$(printf '%s\n' "$rows" | cut -f1)
    if [ -n "$schema" ]; then
        order=$( { printf '%s\n' "$order" | grep -vxFf "$schema/candidates" || true; printf '%s\n' "$order" | grep -xFf "$schema/candidates" || true; } )
    fi
    if ! printf '%s\n' "$order" | xargs -P "$(wc -l < "$workroot/slots" | tr -d " ")" -I{} "$self" --track {} "$manifest" "$workroot" "$build_only"; then
        echo "mutation-check.sh: xargs reported a failure — see the per-track verdicts below" >&2
    fi
fi
# Where the time went: per build kind, how many tracks and their mean build
# seconds, and the mean suite run. `restarted` counts a server failing a
# build its fresh successor accepted — see build_track.
if ls "$workroot"/*.timing > /dev/null 2>&1; then
    cat "$workroot"/*.timing | awk '
        { n[$1]++; b[$1] += $2; if ($3 != "") { runs++; r += $3 } if ($4 == "killers") killers++ }
        END {
            printf "timing:"
            for (k in n) printf " %s builds %d (mean %.0fs),", k, n[k], b[k] / n[k]
            printf " suite runs %d (mean %.0fs)", runs, runs ? r / runs : 0
            if (killers) printf ", %d answered killer-first", killers
            printf "\n"
        }'
fi
if [ -f "$workroot/fixture-cache/tally" ]; then
    echo "fixture cache: $(fc_tally "$workroot/fixture-cache/tally")"
fi

# ------------------------------------------------------------- report

killed=0
applies=0
survived=0
mismatch=0
errors=0
exit_code=0

while IFS=$'\t' read -r name patch filter expected; do
    verdict="RUN-FAIL"
    detail="no verdict written"
    if [ -f "$workroot/$name.verdict" ]; then
        # builtin reads: two `sed`s per row were seconds of a 2051-row report
        { IFS= read -r verdict || true; IFS= read -r detail || true; } < "$workroot/$name.verdict"
    fi
    case "$verdict" in
        KILLED) killed=$((killed + 1)) ;;
        APPLIES) applies=$((applies + 1)) ;;
        SURVIVED) survived=$((survived + 1)); exit_code=1 ;;
        MISMATCH) mismatch=$((mismatch + 1)); exit_code=1 ;;
        *) errors=$((errors + 1)); exit_code=1 ;;
    esac
    printf '%-10s %-20s filter=%-14s %s\n' "$verdict" "$name" "$filter" "$detail"
done <<EOF
$rows
EOF

total_tracks=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
if [ "$build_only" -eq 1 ]; then
    echo "$total_tracks tracks: $applies applies, $errors did not build"
else
    echo "$total_tracks tracks: $killed killed, $survived survived, $mismatch mismatch, $errors error"
fi
if [ "$keep" -eq 0 ] && [ "$exit_code" -eq 0 ]; then
    echo "workroot: $workroot (removed — every track passed; --keep to keep it)"
else
    echo "workroot: $workroot (logs and verdicts kept)"
fi
exit "$exit_code"
