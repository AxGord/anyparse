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
#   tools/mutation-arm.sh <ARM> [<ARM>...] [--jobs N] [--fast] [--keep]
#   tools/mutation-arm.sh --all [--jobs N] [--fast] [--keep]
#   tools/mutation-arm.sh <ARM>... --check-apply [--jobs N] [--keep]
#   tools/mutation-arm.sh --all --check-apply [--jobs N] [--keep]
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
#   --jobs N passed to tools/mutation-check.sh (default: its own max(1,min(4,cores/2))).
#   --list   print the registry and exit.
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
# worktree at HEAD, captures the result as a git patch, and hands the patch to
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
repo=$(cd -P "$script_dir/.." && pwd)
arms_json="$repo/test/testkit/mutation-arms.json"

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

# read_arm <name> <fragment-payload-out>
# Prints `<kind>\t<type>\t<method>\t<force>`; for a FIND arm the payload file is
# written here, because a multi-line fragment does not survive a shell variable
# round trip intact.
read_arm() {
    node -e '
const fs = require("fs");
const table = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const arm = (table.arms || []).find(a => a.name === process.argv[2]);
if (!arm) {
    process.stderr.write("mutation-arm.sh: no arm named \"" + process.argv[2] + "\" in " + process.argv[1] + "\n");
    process.exit(1);
}
const force = arm.force === undefined || arm.force === null ? "" : String(arm.force);
// `find` / `replace` are one string or a LIST of them. N pairs go into ONE payload,
// which alternates old / new sections, and `Patch` locates every pair against the
// ORIGINAL member text - so a multi-edit cut needs no ordering and no bridge text.
const list = v => v === undefined || v === null ? null : (Array.isArray(v) ? v.map(String) : [String(v)]);
if (force === "") {
    const finds = list(arm.find) || [];
    const replaces = list(arm.replace) || finds.map(() => "");
    if (finds.length === 0 || finds.length !== replaces.length) {
        process.stderr.write("mutation-arm.sh: \"" + arm.name + "\" declares " + finds.length
            + " find fragment(s) against " + replaces.length + " replace(s) - a multi-pair cut pairs them up\n");
        process.exit(1);
    }
    const sections = [];
    for (let i = 0; i < finds.length; i++) sections.push(finds[i], replaces[i]);
    fs.writeFileSync(process.argv[3], sections.join("\n====\n") + "\n");
}
const kind = arm.kind === undefined || arm.kind === null || arm.kind === "" ? "FnMember" : String(arm.kind);
process.stdout.write([force === "" ? "FIND" : "FORCE", arm.type, arm.method, kind, force].join("\t") + "\n");
' "$arms_json" "$1" "$2"
}

# The pins that name <arm>, as `<fq.Class>.<method>` — the expectation set
# `apq mutation-verdict` matches against the failure names. Derived from the
# GENERATED registry, never restated in the arm record: the pin metadata is
# where the arm/fixture pairing is declared, and one copy of a fact is enough.
arm_pins() {
    ( cd "$repo" && node bin/test.js --list-pins ) | awk -F' :: ' -v arm="$1" -v want="$2" '
        {
            n = split($3, killers, ",")
            for (i = 1; i <= n; i++) if (killers[i] == arm) {
                if (want == "class") { sub("#.*", "", $1); print $1 }
                else { sub("#", ".", $1); print $1 }
            }
        }' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ---------------------------------------------------------------- arguments

if [ "$#" -lt 1 ]; then
    echo "usage: mutation-arm.sh <ARM>... | --all | --list [--jobs N] [--fast] [--keep] [--check-apply]" >&2
    exit 2
fi

names=""
jobs=""
filter_mode="all-tests"
want_all=0
keep=0
check_apply=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            ( cd "$repo" && node bin/test.js --list-arms )
            exit 0
            ;;
        --all) want_all=1; shift ;;
        --check-apply) check_apply=1; shift ;;
        --fast) filter_mode="pinned-classes"; shift ;;
        --keep) keep=1; shift ;;
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
# test.js is the generated registry the expectations come from.
for binary in bin/apq.js bin/test.js; do
    if [ ! -f "$repo/$binary" ]; then
        echo "mutation-arm.sh: $repo/$binary missing — build it first (haxe bin/apq-js.hxml && haxe test-js.hxml)" >&2
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
cleanup() {
    local status=$?
    git -C "$repo" worktree remove --force "$gen" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    # `|| true` is load-bearing: a non-zero LAST command in an EXIT trap
    # replaces the script's own exit status, so a refused discard would turn
    # an all-KILLED run into `exit 1`.
    if [ "$keep" -eq 0 ] && [ "$status" -eq 0 ]; then
        tmpl_discard "$workroot" "$repo" || true
    else
        echo "mutation-arm.sh: work files kept in $workroot" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

if ! git -C "$repo" worktree add --detach --quiet "$gen" HEAD 2>"$workroot/gen.log"; then
    echo "mutation-arm.sh: scratch worktree failed: $(tr '\n' ' ' < "$workroot/gen.log")" >&2
    exit 2
fi

export HXQ_BIN="$repo/bin/apq.js"
export APQ_NO_CONFIG_WARN=1

for name in $names; do
    payload="$workroot/$name.payload"
    if ! meta=$(read_arm "$name" "$payload"); then
        exit 2
    fi
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
        gen_fail "$name" "$name names $type, which is under neither src/ nor test/ at HEAD" && continue
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
            gen_fail "$name" "$name: could not read the body brace of $type#$method out of $file — the member's braces do not balance, or its body opens mid-line" && continue
        fi
        {
            cat "$workroot/$name.hdr"
            printf '====\n'
            cat "$workroot/$name.hdr"
            printf '\treturn %s;\n' "$force"
        } > "$payload"
    fi

    if ! ( cd "$gen" && "$repo/bin/hxq" patch "$file" --select "$node_kind:$method" --write - < "$payload" ) \
        > "$workroot/$name.apply.log" 2>&1; then
        gen_fail "$name" "$name: the cut did not apply — $workroot/$name.apply.log" && continue
    fi
    git -C "$gen" diff -- "$file" > "$workroot/$name.patch"
    if [ ! -s "$workroot/$name.patch" ]; then
        gen_fail "$name" "$name: the cut changed nothing — the registry describes the code as it already is" && continue
    fi
    # Safe here and nowhere else: `$gen` is a worktree this script created from
    # HEAD seconds ago, and the only uncommitted thing in it is the cut just
    # made. Never spell this against a tree that holds work.
    git -C "$gen" checkout -- "$file"

    # --check-apply asks the COMPILER, not the suite, so the arm needs no pin
    # yet — which is the whole point: an arm is authored cut-first, and the
    # `@:killer` that names it is written once the cut is known to compile.
    # The manifest still records ALL and no expectation, so the same file can
    # be re-run without --build-only.
    if [ "$check_apply" -eq 1 ]; then
        expected=""
        apq_filter="ALL"
    else
        expected=$(arm_pins "$name" "test")
        if [ -z "$expected" ]; then
            echo "mutation-arm.sh: $name: no @:killer in the generated registry names it — rebuild bin/test.js" >&2
            exit 2
        fi
        if [ "$filter_mode" = "pinned-classes" ]; then
            apq_filter=$(arm_pins "$name" "class")
        else
            apq_filter="ALL"
        fi
    fi
    printf '%s | %s | %s | %s\n' "$name" "$workroot/$name.patch" "$apq_filter" "$expected" >> "$manifest"
done

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
fi
rc=0
if [ -s "$manifest" ]; then
    "$repo/tools/mutation-check.sh" "$manifest" $check_args || rc=$?
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
