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
#   tools/mutation-arm.sh <ARM> [<ARM>...] [--jobs N] [--fast]
#   tools/mutation-arm.sh --all [--jobs N] [--fast]
#   tools/mutation-arm.sh --list
#
#   --all    every arm the registry declares.
#   --fast   run only the test classes that pin the arm, instead of the whole
#            suite. Cheap, and it forfeits the collateral census — an arm cuts
#            shared engine code, so what ELSE went red is part of the reading.
#   --jobs N passed to tools/mutation-check.sh (default: its own max(1,min(4,cores/2))).
#   --list   print the registry and exit.
#
# What it does per arm: takes the arm's record, renders it into an
# `hxq patch --select 'FnMember:<method>'` payload, applies it inside a scratch
# worktree at HEAD, captures the result as a git patch, and hands the patch to
# `tools/mutation-check.sh` with the arm's OWN pins as the expectation set.
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
if (force === "") {
    const replace = arm.replace === undefined || arm.replace === null ? "" : String(arm.replace);
    fs.writeFileSync(process.argv[3], String(arm.find) + "\n====\n" + replace + "\n");
}
process.stdout.write([force === "" ? "FIND" : "FORCE", arm.type, arm.method, force].join("\t") + "\n");
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
    echo "usage: mutation-arm.sh <ARM>... | --all | --list [--jobs N] [--fast]" >&2
    exit 2
fi

names=""
jobs=""
filter_mode="all-tests"
want_all=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            ( cd "$repo" && node bin/test.js --list-arms )
            exit 0
            ;;
        --all) want_all=1; shift ;;
        --fast) filter_mode="pinned-classes"; shift ;;
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

workroot=$(mktemp -d "${TMPDIR:-/tmp}/anyparse-mutarm.XXXXXX")
gen="$workroot/gen"
manifest="$workroot/manifest"
: > "$manifest"

cleanup_gen() {
    git -C "$repo" worktree remove --force "$gen" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
}
trap cleanup_gen EXIT
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
    kind=$(printf '%s' "$meta" | cut -f1)
    type=$(printf '%s' "$meta" | cut -f2)
    method=$(printf '%s' "$meta" | cut -f3)
    force=$(printf '%s' "$meta" | cut -f4)
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
        echo "mutation-arm.sh: $name names $type, which is under neither src/ nor test/ at HEAD" >&2
        exit 2
    fi

    if [ "$kind" = "FORCE" ]; then
        # The member's signature, verbatim, up to and including the line the
        # body opens on — the fragment `hxq patch` matches, and the anchor the
        # forced `return` is spliced after. Taken from the tree rather than
        # stored, so a signature change cannot silently stale the arm.
        ( cd "$gen" && "$repo/bin/hxq" show "$file" --select "FnMember:$method" ) > "$workroot/$name.node"
        awk '{ print } /\{$/ { exit }' "$workroot/$name.node" > "$workroot/$name.hdr"
        if [ ! -s "$workroot/$name.hdr" ]; then
            echo "mutation-arm.sh: $name: could not read $type#$method out of $file" >&2
            exit 2
        fi
        {
            cat "$workroot/$name.hdr"
            printf '====\n'
            cat "$workroot/$name.hdr"
            printf '\treturn %s;\n' "$force"
        } > "$payload"
    fi

    if ! ( cd "$gen" && "$repo/bin/hxq" patch "$file" --select "FnMember:$method" --write - < "$payload" ) \
        > "$workroot/$name.apply.log" 2>&1; then
        echo "mutation-arm.sh: $name: the cut did not apply — $workroot/$name.apply.log" >&2
        exit 2
    fi
    git -C "$gen" diff -- "$file" > "$workroot/$name.patch"
    if [ ! -s "$workroot/$name.patch" ]; then
        echo "mutation-arm.sh: $name: the cut changed nothing — the registry describes the code as it already is" >&2
        exit 2
    fi
    # Safe here and nowhere else: `$gen` is a worktree this script created from
    # HEAD seconds ago, and the only uncommitted thing in it is the cut just
    # made. Never spell this against a tree that holds work.
    git -C "$gen" checkout -- "$file"

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
    printf '%s | %s | %s | %s\n' "$name" "$workroot/$name.patch" "$apq_filter" "$expected" >> "$manifest"
done

cleanup_gen
trap - EXIT

echo "manifest: $manifest"
unset ANYPARSE_HXFORMAT_FORK
if [ -n "$jobs" ]; then
    exec "$repo/tools/mutation-check.sh" "$manifest" --jobs "$jobs"
fi
exec "$repo/tools/mutation-check.sh" "$manifest"
