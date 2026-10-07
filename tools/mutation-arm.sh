#!/usr/bin/env bash
#
# mutation-arm.sh — run a DECLARED mutation arm and report whether it still
# kills the fixtures that name it.
#
# `@:pin('control')` + `@:killer('<arm>')` made the SHAPE of a pin's claim
# machine-checkable — a control naming no arm does not build. The substance was
# still prose: the arm name was free text, and nothing said the named arm
# existed, still addressed live code, or still killed anything. The registry is
# `test/testkit/mutation-arms.json`, one record per arm — layer, member, cut —
# and `testkit.TestDiscovery` cross-checks it against the tree at build time in
# both directions. This script is the other half: it turns a name into a run.
#
# Usage:
#   tools/mutation-arm.sh <ARM> [<ARM>...] [--jobs N] [--fast] [--keep] [--working-tree]
#   tools/mutation-arm.sh --all [--jobs N] [--fast] [--keep] [--working-tree]
#   tools/mutation-arm.sh <ARM>... --check-apply [--jobs N] [--keep] [--working-tree]
#   tools/mutation-arm.sh --all --check-apply [--jobs N] [--keep] [--working-tree]
#   tools/mutation-arm.sh --list
#
#   --all    every arm the registry declares.
#   --keep   keep the scratch directories of this run AND of the
#            mutation-check.sh it drives. Both are otherwise removed when
#            every arm was KILLED, and kept with their paths printed on any
#            other outcome.
#   --fast   run only the test classes that pin the arm, instead of the whole
#            suite. Cheap, and it forfeits the collateral census — an arm cuts
#            shared engine code, so what ELSE went red is part of the reading.
#            And killer-first (`mutation-check.sh --killer-first`): the pinned
#            TESTS alone run first, and the pinned classes only when that run
#            is not a KILLED reading — same verdict, a fraction of the run.
#            `APQ_MUTATION_NO_KILLER_FIRST=1` runs the pinned classes only.
#   --jobs N passed to tools/mutation-check.sh (default: its own min(cores-2, memory/5GiB)).
#   --list   print the registry and exit.
#   --working-tree
#            build the scratch worktree (and, since T694's mutation-check.sh
#            --base companion, every track worktree) from a `git stash
#            create` snapshot of the CURRENT working tree instead of HEAD,
#            for an arm authored alongside the still-uncommitted source it
#            targets. Refuses on any untracked file, and on a dirty tree whose
#            snapshot `git stash create` declines to make — an intent-to-add
#            entry (`git add -N`) is enough, and the old silent fall back to
#            HEAD measured the last commit while reporting this flag. Prints
#            every included change otherwise. Full rationale:
#            `docs/testing.md` § "Declared arms" — one copy of this fact is
#            enough.
#   --check-apply
#            AUTHORING mode: apply the cut and BUILD, no suite. Each arm is
#            reported APPLIES or BUILD-FAIL with the cause named
#            (`apq mutation-verdict --build`), and an arm whose cut cannot be
#            RENDERED at all is a row rather than an abort, so `--all
#            --check-apply` censuses the whole registry in one pass.
#
#            It exists because FOUR of the five known arm-authoring blind
#            spots are answered by the tree — `unit.MutationArmAddressTest`
#            walks the fragment half, the forced half and, since S147, the
#            `inline` modifier — and the fifth is answered only by a COMPILER.
#            S147 measured it: a `replace` that puts a
#            narrowed nullable into an anonymous-structure literal builds
#            nowhere and is visible to no walk over the record and the tree
#            (`Null safety: Cannot unify { region : Null<Span>, … }`).
#            Running the arm answers it, and this is the build half of that run
#            alone. What it buys is NOT speed — measured on M-ADMITS-TRUE,
#            whole suite 55.2 s, --fast 18.5 s, --check-apply 17.6 s, so
#            dropping the suite saves 0.9 s and the haxe build is the whole
#            cost. What it buys is that it does NOT require the arm to have a
#            `@:killer` yet — the pin is written after the cut is known to
#            compile — and that a failure is NAMED rather than handed over as
#            a log path.
#
# What it does per arm: takes the arm's record, renders it into an
# `hxq patch --select '<kind>:<method>'` payload, applies it inside a scratch
# worktree at HEAD (or a `--working-tree` snapshot), captures the result as a git patch, and hands the patch to
# `tools/mutation-check.sh` with the arm's OWN pins as the expectation set. The
# kind is `FnMember` unless the record spells another: a grammar DECLARATION has
# no method to cut, and its `@:re` terminal is a module-level `MetaCall`. Only a
# `find`/`replace` cut can address one — a forced `return` is spliced after a
# function signature, so `MutationArms.rowErrors` refuses `force` with any other
# kind before this script ever sees it.
#
# A `find`/`replace` cut is one string or a LIST of them, and a list becomes N
# pairs in ONE payload rather than N calls: `hxq patch` alternates old / new
# sections and locates every pair against the ORIGINAL member text. That is what
# lets an arm PERMUTE two statements — delete here, re-insert there — instead of
# widening one fragment until it bridges both edits. `rowErrors` refuses a row
# whose two lists are not the same length, so a payload with an odd section count
# cannot be rendered.
#
# Nothing here classifies a transcript — `apq mutation-verdict` does, out of the
# unmutated tree, exactly as it already did for a hand-written manifest.
#
# The verdict vocabulary is that classifier's, and it already draws the three
# distinctions an arm needs:
#
#   KILLED (no `+extra`)   every fixture naming this arm went red, and nothing
#                          else did. The narrowest reading, and not one every
#                          arm can have.
#   KILLED … +extra: …     its own pins went red AND other fixtures did. This is
#                          the EXPECTED reading for an arm that cuts shared
#                          engine code — S94 measured M-BUILDMACRO-TRUE moving
#                          409 assertions across 21 classes — so collateral is
#                          reported, never a demotion.
#   MISMATCH               the run went red but at least one of the arm's own
#                          pins survived it; the row names which. The arm killed
#                          something ELSE, which is a defect in the pin, the
#                          fixture or the arm — not a pass.
#   SURVIVED               the run was green. The vacuum: the fixture that
#                          claims this arm breaks it does not notice.
#
# A SURVIVED or MISMATCH row is evidence about the FIXTURE, not noise to retry
# past: S86 deleted a helper because an arm survived, and S92 rewrote two
# fixtures that could not tell their arm from the base tree.
#
# `ANYPARSE_HXFORMAT_FORK` is unset for the run on purpose. The corpus harness
# is not what an arm measures, and an arm's verdict must not depend on whether
# a fork path happens to be exported in the caller's shell.
set -euo pipefail

script_dir=$(cd -P "$(dirname "$0")" && pwd)
self="$script_dir/$(basename "$0")"
repo=$(cd -P "$script_dir/.." && pwd)
arms_json="$repo/test/testkit/mutation-arms.json"

# Engine binaries — HXQ_BIN (a parallel worker's private build: the wave
# protocol's `cd <worktree> && haxe bin/apq-js.hxml && haxe test-js.hxml`, or
# `tools/worker-build.sh <dir>`) is honoured before falling back to the
# repo's own shared `bin/` (T725). Without this a worker whose OWN `bin/` is
# empty — on purpose, T710/T739, so `git status --porcelain` stays clean —
# could not run this script at all, and both error texts pointed at
# `haxe bin/apq-js.hxml`, exactly what building in the worker's own worktree
# is meant to avoid. `test.js` is assumed to sit beside `apq.js`: every
# build recipe that produces one produces the other in the same directory.
apq_bin="$repo/bin/apq.js"
test_bin="$repo/bin/test.js"
if [ -n "${HXQ_BIN:-}" ]; then
    if [ ! -f "$HXQ_BIN" ]; then
        echo "mutation-arm.sh: HXQ_BIN=$HXQ_BIN not found" >&2
        exit 2
    fi
    apq_bin=$(cd -P "$(dirname "$HXQ_BIN")" && pwd)/$(basename "$HXQ_BIN")
    test_bin="$(dirname "$apq_bin")/test.js"
fi

# Scratch-directory lifecycle — creation, the startup sweep for what a
# SIGKILL left behind, and the predicate that keeps a sibling's live run
# safe from it — all live in one place. See tools/tmp-lifecycle.sh.
. "$script_dir/tmp-lifecycle.sh"

# ------------------------------------------------------------------ registry

# Every declared arm name, in registry order.
arm_names() {
    node -e '
const fs = require("fs");
const table = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const arm of table.arms || []) console.log(arm.name);
' "$arms_json"
}

# read_arms <names-file> — every named arm's record, read in ONE pass over the
# registry: `<workroot>/<name>.meta` holds `<FIND|FORCE>\t<type>\t<method>\t<kind>\t<force>`,
# and a FIND arm's payload is written to `<name>.payload` here, because a
# multi-line fragment does not survive a shell variable round trip intact. An arm
# the registry does not hold, or whose pairs do not pair up, gets the reason in
# `<name>.unknown` instead. (One node process per arm used to read the whole
# registry once per arm: 2051 reads of it in a full sweep.)
read_arms() {
    node -e '
const fs = require("fs");
const table = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const byName = new Map((table.arms || []).map(a => [a.name, a]));
const dir = process.argv[2];
// `find` / `replace` are one string or a LIST of them. N pairs go into ONE payload,
// which alternates old / new sections, and `Patch` locates every pair against the
// ORIGINAL member text - so a multi-edit cut needs no ordering and no bridge text.
const list = v => v === undefined || v === null ? null : (Array.isArray(v) ? v.map(String) : [String(v)]);
for (const name of fs.readFileSync(process.argv[3], "utf8").split("\n").filter(n => n !== "")) {
    const arm = byName.get(name);
    if (!arm) {
        fs.writeFileSync(dir + "/" + name + ".unknown", "mutation-arm.sh: no arm named \"" + name + "\" in " + process.argv[1] + "\n");
        continue;
    }
    const force = arm.force === undefined || arm.force === null ? "" : String(arm.force);
    if (force === "") {
        const finds = list(arm.find) || [];
        const replaces = list(arm.replace) || finds.map(() => "");
        if (finds.length === 0 || finds.length !== replaces.length) {
            fs.writeFileSync(dir + "/" + name + ".unknown", "mutation-arm.sh: \"" + arm.name + "\" declares " + finds.length
                + " find fragment(s) against " + replaces.length + " replace(s) - a multi-pair cut pairs them up\n");
            continue;
        }
        const sections = [];
        for (let i = 0; i < finds.length; i++) sections.push(finds[i], replaces[i]);
        fs.writeFileSync(dir + "/" + name + ".payload", sections.join("\n====\n") + "\n");
    }
    const kind = arm.kind === undefined || arm.kind === null || arm.kind === "" ? "FnMember" : String(arm.kind);
    fs.writeFileSync(dir + "/" + name + ".meta", [force === "" ? "FIND" : "FORCE", arm.type, arm.method, kind, force].join("\t") + "\n");
}
' "$arms_json" "$workroot" "$1"
}

# The pins that name <arm>, as `<fq.Class>.<method>` — the expectation set
# `apq mutation-verdict` matches against the failure names. Derived from the
# GENERATED registry, never restated in the arm record: the pin metadata is
# where the arm/fixture pairing is declared, and one copy of a fact is enough.
# pin_tables — `<workroot>/pins.test` and `pins.class`, `<arm>\t<csv>` each.
pin_tables() {
    # No `cd` needed: `--list-pins` is a compile-time-embedded registry dump
    # with no CWD-relative read, measured (`cd /tmp && node <abs>/test.js
    # --list-pins` matches the in-repo count byte-for-byte) — which is what
    # lets this honour a private `$test_bin` living anywhere. Dumped ONCE per
    # run: loading the 27 MB runner costs ~0.3 s, and two lookups per arm
    # made it a minute and a half of a 139-arm sweep's serial render phase.
    # Answered for every arm in the same one pass (`<workroot>/pins.test` /
    # `pins.class`, `<arm>\t<csv>`): an awk over the dump per lookup was
    # still ~40 s of a 2051-arm sweep.
    if [ ! -s "$workroot/pins" ]; then
        node "$test_bin" --list-pins > "$workroot/pins"
        awk -F' :: ' -v dir="$workroot" '
            {
                n = split($3, killers, ",")
                cls = $1; sub("#.*", "", cls)
                test = $1; sub("#", ".", test)
                for (i = 1; i <= n; i++) { print killers[i] "\t" test > (dir "/pins.test.raw"); print killers[i] "\t" cls > (dir "/pins.class.raw") }
            }' "$workroot/pins"
        for want in test class; do
            sort -u "$workroot/pins.$want.raw" | awk -F'\t' '
                $1 != arm { if (arm != "") print arm "\t" csv; arm = $1; csv = $2; next }
                { csv = csv "," $2 }
                END { if (arm != "") print arm "\t" csv }' > "$workroot/pins.$want"
        done
    fi
}

# render_arm <name> <workroot> <gen> <base-ref> — one arm's cut, PREPARED
# read-only against the scratch worktree: the file its type lives in, its
# payload (a FORCE arm's is built here, off the member's own signature), and
# the `<name>.row` that `apq patch --batch` applies (render_cuts), or the
# reason it could not be prepared in `<name>.renderfail`. Read-only is what
# lets every arm render at once: the batch prints each patched file —
# byte-identical to what `hxq patch --write` writes, measured — and `diff -u`
# against the untouched file is the patch `git apply` takes in each track.
render_fail() {
    printf '%s\n' "$2" > "$workroot/$1.renderfail"
}

render_arm() {
    local name=$1 payload meta cut_kind type method node_kind force file root candidate
    workroot=$2
    gen=$3
    base_ref=$4
    payload="$workroot/$name.payload"
    [ -f "$workroot/$name.meta" ] || return 0
    meta=$(cat "$workroot/$name.meta")
    cut_kind=$(printf '%s' "$meta" | cut -f1)
    type=$(printf '%s' "$meta" | cut -f2)
    method=$(printf '%s' "$meta" | cut -f3)
    node_kind=$(printf '%s' "$meta" | cut -f4)
    force=$(printf '%s' "$meta" | cut -f5)
    # The two classpath roots `test-js.hxml` declares, in its order. An arm may
    # cut the suite's own infrastructure as readily as the engine's, and both
    # are addressed by type path rather than by a stored file name.
    file=""
    for root in src test; do
        candidate="$root/$(printf '%s' "$type" | tr '.' '/').hx"
        if [ -f "$gen/$candidate" ]; then
            file="$candidate"
            break
        fi
    done
    if [ -z "$file" ]; then
        render_fail "$name" "$name names $type, which is under neither src/ nor test/ at $base_ref" && return 0
    fi

    if [ "$cut_kind" = "FORCE" ]; then
        # The member's signature, verbatim, up to and including the line the
        # BODY opens on — the fragment `hxq patch` matches, and the anchor the
        # forced `return` is spliced after. Taken from the tree rather than
        # stored, so a signature change cannot silently stale the arm.
        #
        # The body brace is found by BALANCING the member's own braces, not by
        # "the first line that ends in an open brace": a RETURN TYPE may open a
        # brace of its own — `Null<{ … }>`, an inline anonymous structure — and
        # the line-shape heuristic stopped at THAT brace, so the forced `return`
        # landed inside the type and `hxq patch` refused the result as
        # unparseable. S104 hit it twice and worked around it with
        # `find`/`replace` both times. The body's brace is the LAST one that opens
        # at depth 0, and its match has to be the member's final one; a member
        # whose braces do not balance, or whose body opens mid-line, is refused BY
        # NAME rather than rendered wrong.
        ( cd "$gen" && "$repo/bin/hxq" show "$file" --select "$node_kind:$method" ) > "$workroot/$name.node"
        if ! node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
// Braces inside a comment, a string, a char or a regex literal are not code —
// a doc line naming a closing brace, a one-character literal, a regex class —
// so those runs are skipped rather than counted. Char codes throughout: the
// snippet is carried inside a single-quoted shell argument.
const SL = 47, ST = 42, BS = 92, TL = 126, SQ = 39, DQ = 34, OB = 123, CB = 125;
let depth = 0, open = -1, close = -1;
for (let i = 0; i < src.length; i++) {
    const c = src.charCodeAt(i), d = src.charCodeAt(i + 1);
    if (c === SL && d === SL) { i = src.indexOf("\n", i); if (i < 0) break; continue; }
    if (c === SL && d === ST) { const e = src.indexOf("*/", i + 2); i = e < 0 ? src.length : e + 1; continue; }
    if (c === TL && d === SL) { i++; while (++i < src.length) { const r = src.charCodeAt(i); if (r === BS) i++; else if (r === SL) break; } continue; }
    if (c === SQ || c === DQ) { while (++i < src.length) { const q = src.charCodeAt(i); if (q === BS) i++; else if (q === c) break; } continue; }
    if (c === OB) { if (depth === 0) open = i; depth++; }
    else if (c === CB) { depth--; if (depth === 0) close = i; }
}
if (open < 0 || depth !== 0 || close !== src.replace(/\s+$/, "").length - 1) process.exit(1);
const nl = src.indexOf("\n", open);
if (nl < 0 || src.slice(open + 1, nl).trim() !== "") process.exit(1);
process.stdout.write(src.slice(0, nl + 1));
' "$workroot/$name.node" > "$workroot/$name.hdr"; then
            render_fail "$name" "$name: could not read the body brace of $type#$method out of $file — the member's braces do not balance, or its body opens mid-line" && return 0
        fi
        {
            cat "$workroot/$name.hdr"
            printf '====\n'
            cat "$workroot/$name.hdr"
            printf '\treturn %s;\n' "$force"
        } > "$payload"
    fi

    # The file and the address the cut is made at: the batch row, and what the
    # schema plan needs of the arm (schema_plan).
    printf '%s\t%s\n' "$file" "$node_kind:$method" > "$workroot/$name.target"
    printf '%s\t%s\t%s\t%s\n' "$file" "$node_kind:$method" "$payload" "$workroot/$name.new" > "$workroot/$name.row"
    return 0
}

# render_cuts <names...> — every prepared arm's cut applied by `apq patch
# --batch` (render_arm wrote the rows), then diffed into `<name>.patch`. One
# process per arm used to start `apq`, re-read and re-canonical-check the file
# for every arm cut in it: 396 s of a 2051-arm sweep's render under load,
# against ~60 s batched. The rows are dealt to one batch per core, a file's
# rows in chunks of at most RENDER_CHUNK so the file most arms cut in (151 in
# one) does not hold one batch for the rest — each batch canonical-checks a
# file once.
RENDER_CHUNK=16

render_cuts() {
    local name file shard
    for name in "$@"; do
        [ -f "$workroot/$name.row" ] && cat "$workroot/$name.row"
    done | sort -t$'\t' -k1,1 -s | awk -F'\t' -v n="$render_jobs" -v chunk="$RENDER_CHUNK" -v dir="$workroot" '
        { rows[$1] = rows[$1] $0 "\n"; count[$1]++ }
        END {
            # longest file first, each chunk to the batch with the fewest rows
            k = 0
            for (f in count) order[++k] = f
            for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (count[order[j]] > count[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
            for (i = 1; i <= k; i++) {
                m = split(rows[order[i]], lines, "\n")
                for (start = 1; start < m; start += chunk) {
                    best = 0
                    for (b = 1; b < n; b++) if (load[b] < load[best]) best = b
                    for (r = start; r < start + chunk && r < m; r++) { print lines[r] > (dir "/render-batch." best); load[best]++ }
                }
            }
        }'
    for shard in "$workroot"/render-batch.*; do
        [ -f "$shard" ] || continue
        ( cd "$gen" && node "$apq_bin" patch --batch "$shard" ) 2> "$shard.log" &
    done
    wait
    printf '%s\n' "$@" | xargs -P "$render_jobs" -I{} "$self" --diff {} "$workroot" "$gen"
}

# render_diff <name> — the batch's answer for one arm made its patch, or the
# reason it could not be (run in parallel by render_cuts).
render_diff() {
    local name=$1 file
    [ -f "$workroot/$name.row" ] || return 0
    file=$(cut -f1 "$workroot/$name.row")
    if [ -f "$workroot/$name.new.err" ]; then
        render_fail "$name" "$name: the cut did not apply — $(tr '\n' ' ' < "$workroot/$name.new.err")"
        return 0
    fi
    if [ ! -f "$workroot/$name.new" ]; then
        render_fail "$name" "$name: the cut did not apply — its batch wrote nothing ($workroot/render-batch.*.log)"
        return 0
    fi
    diff -u --label "a/$file" --label "b/$file" "$gen/$file" "$workroot/$name.new" > "$workroot/$name.patch" || true
    if [ ! -s "$workroot/$name.patch" ]; then
        render_fail "$name" "$name: the cut changed nothing — the registry describes the code as it already is"
    fi
}

if [ "${1:-}" = "--render" ]; then
    render_arm "$2" "$3" "$4" "$5"
    exit 0
fi
if [ "${1:-}" = "--diff" ]; then
    workroot=$3
    gen=$4
    render_diff "$2"
    exit 0
fi

# ---------------------------------------------------------------- arguments

if [ "$#" -lt 1 ]; then
    echo "usage: mutation-arm.sh <ARM>... | --all | --list [--jobs N] [--fast] [--keep] [--check-apply] [--working-tree]" >&2
    exit 2
fi

names=""
jobs=""
filter_mode="all-tests"
want_all=0
keep=0
check_apply=0
working_tree=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            # Checked here too, not just in the shared existence loop below
            # (which --list runs ahead of): otherwise a missing $test_bin
            # surfaces as a raw node stack trace instead of the same
            # friendly message every other path gets.
            if [ ! -f "$test_bin" ]; then
                echo "mutation-arm.sh: $test_bin missing — build it first (haxe test-js.hxml), or point HXQ_BIN at a private engine (tools/worker-build.sh <dir> && export HXQ_BIN=<dir>/apq.js — test.js must sit beside it)" >&2
                exit 2
            fi
            node "$test_bin" --list-arms
            exit 0
            ;;
        --all) want_all=1; shift ;;
        --check-apply) check_apply=1; shift ;;
        --fast) filter_mode="pinned-classes"; shift ;;
        --keep) keep=1; shift ;;
        --working-tree) working_tree=1; shift ;;
        --jobs)
            if [ "$#" -lt 2 ]; then
                echo "mutation-arm.sh: --jobs needs a number" >&2
                exit 2
            fi
            jobs=$2
            shift 2
            ;;
        -*)
            echo "mutation-arm.sh: unknown option '$1'" >&2
            exit 2
            ;;
        *) names="$names $1"; shift ;;
    esac
done

if [ ! -f "$arms_json" ]; then
    echo "mutation-arm.sh: no arm registry at $arms_json" >&2
    exit 2
fi
# Both binaries are read from the UNMUTATED tree: apq.js is the hxq engine that
# renders the cut and the verdict classifier mutation-check.sh shells out to,
# test.js is the generated registry the expectations come from. "Unmutated"
# means unmutated relative to the CUT under test, which for a worker with its
# own HXQ_BIN is its own private engine, not necessarily $repo's.
for binary_path in "$apq_bin" "$test_bin"; do
    if [ ! -f "$binary_path" ]; then
        echo "mutation-arm.sh: $binary_path missing — build it first (haxe bin/apq-js.hxml && haxe test-js.hxml), or point HXQ_BIN at a private engine (tools/worker-build.sh <dir> && export HXQ_BIN=<dir>/apq.js — test.js must sit beside it)" >&2
        exit 2
    fi
done

if [ "$want_all" -eq 1 ]; then
    names="$names $(arm_names | tr '\n' ' ')"
fi
if [ -z "$(printf '%s' "$names" | tr -d ' ')" ]; then
    echo "mutation-arm.sh: no arm named (pass names, or --all)" >&2
    exit 2
fi

# The commit the scratch worktree is built from — HEAD, unless --working-tree
# asked for a snapshot of the current working tree instead (see the flag's
# doc above).
base_ref="HEAD"
if [ "$working_tree" -eq 1 ]; then
    # sed, not `awk '{print $2}'`: an untracked path containing a space
    # would otherwise print truncated at the first space in the refusal
    # text below (the refusal itself still fires correctly either way).
    untracked=$(git -C "$repo" status --porcelain | sed -n 's/^?? //p')
    if [ -n "$untracked" ]; then
        echo "mutation-arm.sh: --working-tree refuses — untracked file(s) would be silently dropped from the snapshot: $(printf '%s' "$untracked" | tr '\n' ' ')" >&2
        exit 2
    fi
    stash_commit=$(git -C "$repo" stash create 2>/dev/null) || stash_commit=""
    dirty=$(git -C "$repo" status --porcelain --untracked-files=no)
    # A snapshot that did not happen used to fall back to HEAD in silence, so the run
    # measured the last commit while reporting `--working-tree` — a gate that cannot tell
    # "your uncommitted work" from "HEAD" is worse than no gate, and it bites hardest while
    # verifying a control pin, where a false green is most expensive. An INTENT-TO-ADD entry
    # (`git add -N`, which a new test file often sits in) is enough to make `stash create`
    # fail. So this refuses, and it names git's own reason: `stash create` writes a dangling
    # commit and touches neither the index nor the worktree, so re-running it for the message
    # is free and changes nothing. A CLEAN tree legitimately yields no commit, and there HEAD
    # IS the working tree — hence the `dirty` half of the guard.
    # A tree dirty only in a SUBMODULE refuses too: `stash create` snapshots no submodule change.
    if [ -z "$stash_commit" ] && [ -n "$dirty" ]; then
        echo "mutation-arm.sh: --working-tree refuses — the tree is dirty but \`git stash create\` produced no snapshot, so the run would silently measure HEAD instead:" >&2
        # `|| true` because the whole point is that this git call FAILS, and `set -o pipefail`
        # would otherwise abort the refusal half way — before the remedy below and before the
        # exit status that says which kind of failure this was.
        git -C "$repo" stash create 2>&1 >/dev/null | sed 's/^/mutation-arm.sh:   /' >&2 || true
        intent=$(git -C "$repo" diff-files --name-only --diff-filter=A)
        if [ -n "$intent" ]; then
            echo "mutation-arm.sh: intent-to-add path(s) are the usual cause — stage them (\`git add <path>\`) or drop the intent (\`git reset <path>\`):" >&2
            printf '%s\n' "$intent" | sed 's/^/mutation-arm.sh:   /' >&2
        fi
        exit 2
    fi
    base_ref=${stash_commit:-HEAD}
    if [ -n "$dirty" ]; then
        echo "mutation-arm.sh: --working-tree base = $base_ref, folding in $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') uncommitted change(s) beyond HEAD:" >&2
        printf '%s\n' "$dirty" | sed 's/^/mutation-arm.sh:   /' >&2
    fi
fi

# ---------------------------------------------------------------- generation

tmpl_sweep "$repo"
workroot=$(tmpl_claim anyparse-mutarm)
gen="$workroot/gen"
manifest="$workroot/manifest"
: > "$manifest"
applyfail="$workroot/apply-fail"
: > "$applyfail"

# A cut that could not be RENDERED — the type resolves to no file, the body
# offers no brace, `hxq patch` refuses, or the cut changes nothing.
#
# Outside --check-apply that is fatal, and deliberately so: a sweep of named
# arms that silently skipped one would report a verdict for a set the caller
# did not ask for. Under --check-apply it is a ROW — the mode exists to census
# the registry, and the first unrenderable arm must not hide the other 225.
gen_fail() {
    if [ "$check_apply" -eq 1 ]; then
        printf 'APPLY-FAIL  %-20s %s\n' "$1" "$2" >> "$applyfail"
        return 0
    fi
    echo "mutation-arm.sh: $2" >&2
    exit 2
}

# This directory used to survive every run, successful ones included: the
# script `exec`ed into mutation-check.sh, which replaces the process and
# takes the EXIT trap with it, while the manifest and the rendered patches
# had to outlive the handoff because the child reads them. Running the
# child as a CHILD keeps the trap, and it is also the honest signal
# behaviour — an INT reaches the whole process group either way.
# kill_tree <pid> — <pid> and every process below it, children first.
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill "$1" 2>/dev/null || true
}

cleanup() {
    local status=$?
    if [ -n "${schema_pid:-}" ]; then
        kill_tree "$schema_pid"
    fi
    git -C "$repo" worktree remove --force "${schema_dir:-$workroot/schema}/tree" >/dev/null 2>&1 || true
    git -C "$repo" worktree remove --force "$gen" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    # `|| true` is load-bearing: a non-zero LAST command in an EXIT trap
    # replaces the script's own exit status, so a refused discard would turn
    # an all-KILLED run into `exit 1`.
    if [ "$keep" -eq 0 ] && [ "$status" -eq 0 ]; then
        tmpl_discard "$workroot" "$repo" || true
    else
        # T738: an EXPLICIT --keep gets the permanent marker — without it,
        # `tmpl_is_orphan` reads a finished --keep run identically to a
        # crashed one (the owner pid is dead either way) and a LATER run's
        # startup sweep reclaims it despite the ask to retain it. A run kept
        # only because it FAILED (no --keep) is deliberately left off the
        # marker: that directory is meant to age out through the ordinary
        # grace-period sweep, same as before this fix — the marker is not a
        # blanket "any non-zero exit" grant, or it reintroduces the
        # unbounded accumulation this file's own header records paying for.
        if [ "$keep" -eq 1 ]; then
            tmpl_mark_keep "$workroot" || true
        fi
        echo "mutation-arm.sh: work files kept in $workroot" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

if ! git -C "$repo" worktree add --detach --quiet "$gen" "$base_ref" 2>"$workroot/gen.log"; then
    echo "mutation-arm.sh: scratch worktree failed: $(tr '\n' ' ' < "$workroot/gen.log")" >&2
    exit 2
fi

# $apq_bin already resolved HXQ_BIN if the caller set one (else the repo's
# own bin/apq.js) — exporting it here (rather than a caller's raw HXQ_BIN)
# is what stops this line from CLOBBERING a worker's private engine, which
# is what it did unconditionally before T725.
export HXQ_BIN="$apq_bin"
export APQ_NO_CONFIG_WARN=1

if [ "$(uname -s)" = "Darwin" ]; then
    render_jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
else
    render_jobs=$(nproc 2>/dev/null || echo 2)
fi
# Every arm renders at once — the registry read once (read_arms), each cut
# prepared (render_arm) and the cuts applied in batches (render_cuts); the
# manifest is then written in the order the arms were named, so a refusal
# reads exactly as the serial loop's did.
printf '%s\n' $names > "$workroot/names"
read_arms "$workroot/names"
printf '%s\n' $names | xargs -P "$render_jobs" -I{} "$self" --render {} "$workroot" "$gen" "$base_ref" || true
render_cuts $names
for name in $names; do
    if [ ! -s "$workroot/$name.patch" ] && [ ! -f "$workroot/$name.renderfail" ] && [ ! -s "$workroot/$name.unknown" ]; then
        render_fail "$name" "$name: rendering the cut died before it said why"
    fi
    if [ -s "$workroot/$name.unknown" ]; then
        cat "$workroot/$name.unknown" >&2
        exit 2
    fi
    if [ -f "$workroot/$name.renderfail" ]; then
        gen_fail "$name" "$(cat "$workroot/$name.renderfail")" && continue
    fi

    # --check-apply asks the COMPILER, not the suite, so the arm needs no pin
    # yet — which is the whole point: an arm is authored cut-first, and the
    # `@:killer` that names it is written once the cut is known to compile.
    # The manifest still records ALL and no expectation, so the same file can
    # be re-run without --build-only.
    printf '%s\n' "$name" >> "$workroot/manifest.names"
done
if [ -s "$workroot/manifest.names" ]; then
    if [ "$check_apply" -eq 1 ]; then
        awk -v dir="$workroot" '{ print $0 " | " dir "/" $0 ".patch | ALL | " }' "$workroot/manifest.names" > "$manifest"
    else
        pin_tables
        awk -F'\t' -v dir="$workroot" -v fast="$([ "$filter_mode" = "pinned-classes" ] && echo 1 || echo 0)" '
            FILENAME == ARGV[1] { test[$1] = $2; next }
            FILENAME == ARGV[2] { cls[$1] = $2; next }
            !($0 in test) { print $0 > "/dev/stderr"; missing = 1; next }
            { print $0 " | " dir "/" $0 ".patch | " (fast ? cls[$0] : "ALL") " | " test[$0] }
            END { exit missing }
        ' "$workroot/pins.test" "$workroot/pins.class" "$workroot/manifest.names" > "$manifest" 2> "$workroot/unpinned" || true
        if [ -s "$workroot/unpinned" ]; then
            echo "mutation-arm.sh: $(head -1 "$workroot/unpinned"): no @:killer in the generated registry names it — rebuild $test_bin" >&2
            exit 2
        fi
    fi
fi

# ------------------------------------------------------------------ schemata
#
# Mutant schemata (docs/testing.md § "Mutation runs: schemata"). Every arm a
# copy can stand for is compiled into ONE build — `apq mutation-schema` copies
# the arm's mutated method in beside the original and opens the original with
# a switch on `APQ_MUTANT` — so such an arm costs a suite run and no build.
# Built in the background while the per-arm tracks (everything else) run;
# mutation-check.sh holds a candidate's track until the build answers, and a
# candidate the build left out is built per arm, as before.
#
# A composed build means its per-arm build only where nothing tells the two
# apart, and the build itself is asked where something could:
#   - a file a `@:build` macro reads is left alone: a copy is a field the
#     macro would see (`hxq meta '@:build'`); so is anyparse.macro, which is
#     compile-time code — built per arm from the start, not after waiting for
#     the composed build to say what the macro log below says of it;
#   - test/ is left alone: the suite registers what it finds there;
#   - a switch REACHED at compile time (`APQ_MUTANT_MACRO_LOG`) is a method
#     the cut could have changed the generated code through — per arm;
#   - a switch whose source the build EMBEDS as text (the facts macro, which a
#     child compiler re-compiles under the suite's environment) is the arm's
#     own in that child too; the fixture cache records which switches a
#     compile ran and never replays one that ran the live arm's. And since
#     the build never types those modules, they are typed in the macro
#     context after it (schema_check_embedded): a copy that breaks there
#     would break every arm's child compiles;
#   - an arm whose copy does not compile is named by the compiler's position
#     and left out, and the rest built again (at most SCHEMA_ROUNDS times).
# Tests that read the tree from disk still read the arm's own cut: a schema
# track resets its slot and applies the arm's patch exactly as a per-arm one,
# and only skips the build.
schema_dir="$workroot/schema"
schema_pid=""
SCHEMA_ROUNDS=${APQ_MUTATION_SCHEMA_ROUNDS:-6}
# How many times one round re-checks the embedded modules after leaving culprits out.
SCHEMA_CHECKS=20

# The plan rows of every rendered arm under src/ outside a `@:build` file:
# `<id>\t<file>\t<selector>\t<mutated-file>`, ids in manifest order, and the
# id -> name table beside it.
schema_plan() {
    local built
    : > "$schema_dir/plan"
    : > "$schema_dir/names"
    built=$( cd "$gen" && "$repo/bin/hxq" meta '@:build' src --flat --limit 100000 2>/dev/null | sed -n 's/^\(src\/[^:]*\.hx\):.*/\1/p' | sort -u )
    # One awk over the manifest's names and their targets: a shell loop forked
    # per arm, seconds of serial work in a 2051-arm sweep.
    cut -d'|' -f1 "$manifest" | tr -d ' ' | awk -F'\t' -v dir="$workroot" -v out="$schema_dir" '
        FILENAME == ARGV[1] { built[$0] = 1; next }
        {
            name = $0
            target = dir "/" name ".target"
            if ((getline line < target) <= 0) next
            close(target)
            split(line, t, "\t")
            # anyparse.macro is compile-time code: its arms change what the build
            # generates (every one of them is reached at compile time, measured),
            # so they are built per arm from the start rather than after the
            # composed build has said so — a candidate waits for that answer.
            if (t[1] !~ /^src\// || t[1] ~ /^src\/anyparse\/macro\// || (t[1] in built)) next
            id++
            print id "\t" t[1] "\t" t[2] "\t" dir "/" name ".new" > (out "/plan")
            print id " " name > (out "/names")
            print name > (out "/candidates")
        }
    ' <(printf '%s\n' "$built") -
}

# The ids a failed build's errors name: an error inside an arm's copy, or on
# its dispatch line, names that arm; one anywhere else in a composed file names
# every arm of that file.
schema_culprits() {
    awk -F'\t' '
        FNR == NR {
            if ($2 == "ok") { file[$1] = $3; dispatch[$1] = $4; from[$1] = $5; to[$1] = $6; composed[$3] = 1 }
            next
        }
        match($0, /^[^:]+\.hx:[0-9]+:/) {
            split(substr($0, RSTART, RLENGTH), p, ":")
            f = p[1]; l = p[2] + 0
            sub(/^\.\//, "", f)
            hit = 0
            for (id in file) if (file[id] == f && ((l >= from[id] && l <= to[id]) || l == dispatch[id])) { print id; hit = 1 }
            if (!hit && (f in composed)) for (id in file) if (file[id] == f) print id
        }
    ' "$schema_dir/placements" "$1" | sort -un
}

# The build, answered in `$schema_dir/state` (`ready` | `failed`); the
# worktree it composed in goes as soon as it has.
schema_build() {
    schema_compose_and_build
    git -C "$repo" worktree remove --force "$schema_dir/tree" >/dev/null 2>&1 || true
}

schema_compose_and_build() {
    local tree="$schema_dir/tree" round culprits
    if ! git -C "$repo" worktree add --detach --quiet "$tree" "$base_ref" 2> "$schema_dir/why"; then
        echo failed > "$schema_dir/state"
        return 0
    fi
    for round in $(seq 1 "$SCHEMA_ROUNDS"); do
        if ! schema_compose; then
            echo failed > "$schema_dir/state"
            return 0
        fi
        rm -f "$schema_dir/macro-log"
        if ( cd "$tree" && APQ_MUTANT_MACRO_LOG="$schema_dir/macro-log" haxe test-js-common.hxml -js "$schema_dir/test.js" ) \
                > "$schema_dir/build-$round.log" 2>&1; then
            # `<name> <id>` for every arm the build stands for.
            # An arm whose dispatch line, as `apq mutation-schema` spliced it,
            # occurs verbatim in the output is one whose source the build
            # embeds as TEXT — compiled code spells the call `Type.__mutOn(…)`
            # and never carries the `return __mut<id>_<name>(` that follows.
            # A string literal that merely looks like one costs a check, never
            # a wrong answer.
            # ONE regex over the output, then an exact compare against the plan:
            # `grep -F -f` with one pattern per arm ran for minutes on BSD grep.
            grep -oE '\(__mutOn\([0-9]+\)\) return __mut[0-9]+_[A-Za-z0-9_]+\(' "$schema_dir/test.js" \
                | awk -F'\t' '
                    FILENAME == ARGV[1] { m = $3; sub(/^[^:]*:/, "", m); want["(__mutOn(" $1 ")) return __mut" $1 "_" m "("] = $1; next }
                    $0 in want { print want[$0] }
                ' "$schema_dir/plan" - | sort -un > "$schema_dir/embedded" || true
            # An embedded module is compiled again by a child compiler, under
            # the suite, in the macro context — and nothing in this build typed
            # its copies there (a `#if macro` module contributes no type to it).
            # A copy that does not compile there would break every child compile
            # of every arm, so the embedded modules are typed in that context
            # here, and a culprit is left out like any copy the build refused.
            # The check is seconds and the build minutes, so the check is
            # repeated alone, recomposing after each drop, until it passes;
            # the build is then redone once over the cleaned plan.
            if [ -s "$schema_dir/embedded" ] && ! schema_check_embedded "$round"; then
                local check=0
                while [ "$check" -lt "$SCHEMA_CHECKS" ]; do
                    check=$((check + 1))
                    culprits=$(schema_culprits "$schema_dir/embedded-$round.log")
                    [ -n "$culprits" ] || culprits=$(cat "$schema_dir/embedded")
                    schema_drop "$culprits"
                    printf '%s\n' "$culprits" | awk 'FNR == NR { out[$1] = 1; next } !($1 in out)' - "$schema_dir/embedded" \
                        > "$schema_dir/embedded.next"
                    mv "$schema_dir/embedded.next" "$schema_dir/embedded"
                    schema_compose || break
                    if [ ! -s "$schema_dir/embedded" ] || schema_check_embedded "$round"; then
                        break
                    fi
                done
                continue
            fi
            touch "$schema_dir/macro-log"
            awk -F'\t' '
                FILENAME == ARGV[1] { name[$1] = $2; next }
                FILENAME == ARGV[2] { macro[$1] = 1; next }
                FILENAME == ARGV[3] { embedded[$1] = 1; next }
                $2 == "ok" && !($1 in macro) { print name[$1], $1 }
            ' <(tr ' ' '\t' < "$schema_dir/names") "$schema_dir/macro-log" "$schema_dir/embedded" "$schema_dir/placements" \
                > "$schema_dir/map"
            echo ready > "$schema_dir/state"
            return 0
        fi
        culprits=$(schema_culprits "$schema_dir/build-$round.log")
        if [ -z "$culprits" ]; then
            break
        fi
        schema_drop "$culprits"
    done
    echo failed > "$schema_dir/state"
}

# schema_compose — the tree reset and the plan composed into it.
schema_compose() {
    git -C "$schema_dir/tree" checkout -q -- . 2>> "$schema_dir/why" \
        && ( cd "$schema_dir/tree" && "$repo/bin/hxq" mutation-schema "$schema_dir/plan" ) > "$schema_dir/placements" 2>> "$schema_dir/why"
}

# schema_drop <ids> — the arms left out of the next round's plan.
schema_drop() {
    printf '%s\n' "$1" | awk -F'\t' 'FNR == NR { out[$1] = 1; next } !($1 in out)' - "$schema_dir/plan" > "$schema_dir/plan.next"
    mv "$schema_dir/plan.next" "$schema_dir/plan"
    printf '%s\n' "$1" >> "$schema_dir/culprits"
}

# schema_check_embedded <round> — type every module holding an embedded arm
# in the macro context, through `--macro <type>.__mutOn(0)` over the composed
# tree; the log's paths are rewritten to the tree-relative ones schema_culprits
# names arms by.
schema_check_embedded() {
    local probe="$schema_dir/probe" file owner rel module macros=""
    rm -rf "$probe"
    mkdir -p "$probe"
    printf 'class AnyparseSchemaCheck {\n\tstatic function main() {}\n}\n' > "$probe/AnyparseSchemaCheck.hx"
    awk -F'\t' 'FILENAME == ARGV[1] { e[$1] = 1; next } $2 == "ok" && ($1 in e) { print $3 "\t" $7 }' \
        "$schema_dir/embedded" "$schema_dir/placements" | sort -u > "$schema_dir/embedded-owners"
    while IFS=$'\t' read -r file owner; do
        rel=${file#src/}
        module=$(printf '%s' "${rel%.hx}" | tr '/' '.')
        [ "$(basename "$rel" .hx)" = "$owner" ] || module="$module.$owner"
        macros="$macros --macro $module.__mutOn(0)"
    done < "$schema_dir/embedded-owners"
    if ( cd "$schema_dir/tree" && haxe -cp src -cp "$probe" -main AnyparseSchemaCheck --interp --no-output $macros ) \
            > "$schema_dir/embedded-$1.log" 2>&1; then
        return 0
    fi
    return 1
}

schema_args=""
if [ "$check_apply" -eq 0 ] && [ -z "${APQ_MUTATION_NO_SCHEMA:-}" ]; then
    mkdir -p "$schema_dir"
    : > "$schema_dir/candidates"
    schema_plan
    if [ -s "$schema_dir/plan" ]; then
        echo "schema: $(wc -l < "$schema_dir/plan" | tr -d ' ') arm(s) composed into one build"
        schema_build &
        schema_pid=$!
        schema_args="--schema $schema_dir"
    fi
fi

# The scratch worktree has done its job — the patches are rendered. Removed
# here rather than at exit so it is not held for the length of the run; the
# EXIT trap repeats the removal harmlessly.
git -C "$repo" worktree remove --force "$gen" >/dev/null 2>&1 || true
git -C "$repo" worktree prune >/dev/null 2>&1 || true

echo "manifest: $manifest"
unset ANYPARSE_HXFORMAT_FORK
check_args=""
if [ -n "$jobs" ]; then
    check_args="--jobs $jobs"
fi
if [ "$keep" -eq 1 ]; then
    check_args="$check_args --keep"
fi
if [ "$check_apply" -eq 1 ]; then
    check_args="$check_args --build-only"
elif [ "$filter_mode" = "pinned-classes" ] && [ -z "${APQ_MUTATION_NO_KILLER_FIRST:-}" ]; then
    check_args="$check_args --killer-first"
fi
if [ "$base_ref" != "HEAD" ]; then
    # --working-tree (T694): the patches above were rendered against a
    # snapshot of the working tree, not HEAD — each track's OWN worktree
    # has to come from that same snapshot, or the patch context lines
    # mismatch (PATCH-FAIL) or, worse, silently apply against a HEAD that
    # is missing whatever else the snapshot carried (a false SURVIVED).
    check_args="$check_args --base $base_ref"
fi
rc=0
if [ -s "$manifest" ]; then
    "$repo/tools/mutation-check.sh" "$manifest" $check_args $schema_args || rc=$?
elif [ "$check_apply" -eq 0 ]; then
    echo "mutation-arm.sh: nothing to run" >&2
    rc=2
fi
# Printed AFTER the report so the two halves read as one census: a cut that
# never became a patch is as much a defect of the record as one that did not
# compile, and under --check-apply it is the only place it is reported.
if [ -s "$applyfail" ]; then
    cat "$applyfail"
    rc=1
fi
exit "$rc"
