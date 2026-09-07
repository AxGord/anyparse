#!/usr/bin/env bash
#
# tmp-lifecycle.sh — one owner for the scratch directories tools/ creates.
#
# Sourced by every tool that calls `mktemp -d`, and runnable on its own as
# `tools/tmp-lifecycle.sh --list | --sweep`.
#
# WHY THIS EXISTS, measured. On 2026-09-05 this machine reached 99% full —
# 51 GiB free of 3.6 TiB — and the biggest single consumer was this
# project's own tooling: 125 `anyparse-mutcheck.*` directories holding
# 46.6 GB, one of them from a crashed run still holding 105 REGISTERED git
# worktrees at a long-dead commit, plus 20 orphaned `apq-battery.*`
# directories at ~2.8 GB. Three consecutive campaign slices were told in
# their briefs to clean up by hand. That is a workaround standing in for a
# fix.
#
# The recorded blame was half wrong, which is why it was reproduced before
# it was believed. battery.sh and suite-shard.sh were already correct: they
# delete their scratch directory on a green run and keep it, saying so, on a
# red one — those 20 `apq-battery.*` were failed or killed runs behaving
# exactly as documented. The two that leaked on EVERY run, green ones
# included, were mutation-check.sh (its own header said the workroot is
# "never deleted") and mutation-arm.sh, which `exec`ed into mutation-check
# and so replaced the process holding its EXIT trap. Measured on a fully
# KILLED single-arm run: two directories left, 23 MB and 16 KB.
#
# The two halves of the fix, and why neither alone is enough:
#
#   1. LIFECYCLE. Each tool now deletes its own scratch directory when the
#      run it belongs to succeeded, and keeps it — saying so — when the run
#      failed or `--keep` was passed. An EXIT trap plus `trap 'exit 130'
#      INT TERM HUP` makes that fire on an interrupt too. Measured on bash
#      3.2.57 (macOS system bash) on a MINIMAL probe — two scripts
#      identical but for the signal-trap line, target run in the foreground
#      so its SIGINT disposition is the default one:
#
#        signal   EXIT trap only          + trap 'exit 130' INT TERM HUP
#        SIGINT   NOT RUN, and the        cleaned, rc 130
#                 script did not even
#                 stop — it had to be
#                 SIGKILLed (rc 137)
#        SIGTERM  cleaned                 cleaned
#        SIGHUP   cleaned                 cleaned
#        SIGKILL  LEAKED                  LEAKED
#
#      The SIGINT row is bash deferring a pending signal until the
#      foreground child returns and then resuming, because the child (a
#      `sleep`) had not itself died of SIGINT. It does NOT generalise to
#      every shape: interrupted during its plan stage, suite-shard.sh
#      stopped in BOTH arms, differing only in exit status (bash's own 129
#      against the trap's 130). So the trap is a guarantee and a
#      determinism, not a reproduced leak — and in battery.sh it is also
#      what kills the branch subshells still writing into the directory.
#
#      An async child of a shell WITHOUT job control inherits SIGINT set to
#      IGNORE, and a script cannot trap a signal that was ignored on entry.
#      Any A/B of this has to run the target in the foreground or turn job
#      control on (`set -m`), or both arms measure nothing. The first run of
#      this measurement did neither and read as "the trap changes nothing".
#
#   2. STALE SWEEP at startup, because of that last row. SIGKILL cannot be
#      trapped, and the agent harness that runs this campaign kills a
#      session outright — four workers were killed mid-flight by an account
#      limit during the very slice that wrote this file, three of them with
#      one of these tools running. A trap can never close that hole; only a
#      later run can.
#
# THE SWEEP PREDICATE, and why it is safe with siblings running. Several
# workers run these tools concurrently — that is the normal state here, not
# an edge case — so a sweep that deletes by age alone would delete live
# work. Instead every claimed directory carries a stamp naming the PID of
# the shell that created it, and a directory is a candidate only when:
#
#   * its basename is one of THIS project's prefixes plus mktemp's six
#     template characters, directly under the scratch root (nothing else in
#     TMPDIR is ever considered — `tmpl_is_ours` refuses out loud), AND
#   * its stamped owner is gone (`kill -0` fails). A REUSED pid reads as
#     alive, so pid reuse can only ever make the sweep keep too much, never
#     delete too much, AND
#   * nothing has written into it for TMPL_GRACE_SECONDS. A SIGKILLed
#     script leaves grandchildren (haxe, node) that keep appending to track
#     logs; the newest mtime among the directory's TOP-LEVEL entries is
#     what answers that, because a child appending to a file does not move
#     the directory's own mtime.
#
# A directory with no stamp is from before this file existed. Age is then
# all there is, so it needs TMPL_LEGACY_SECONDS (6h) of silence — longer
# than any run this project has (the whole 208-arm sweep is 335s at
# --jobs 4).
#
# DEREGISTRATION, not just deletion. `git worktree prune` only forgets
# entries whose directory is GONE, so a leaked directory keeps its
# registration alive indefinitely — that is how one crashed run left 105
# entries on `git worktree list` for every worker and every merge. The
# removal therefore comes first and the prune second, never the reverse.
#
# GOTCHAS this file is written around (all paid for on macOS):
#   * `date -r <path>` does NOT print a file's mtime — BSD `date -r` takes
#     seconds since epoch, silently ignores a path and prints the CURRENT
#     time, which would make every directory look fresh. Use `stat -f %m`.
#   * BSD `sed` BRE has no `\|`.
#   * TMPDIR carries a trailing slash on macOS, so a path built naively
#     from it reads `.../T//apq-battery.xxxxxx` and compares unequal to
#     git's own spelling of the same path.

# The scratch prefixes this project creates, one per tool. `apq-suite` is the SUITE
# PROCESS's own private temp root (`unit.cli.CliFixture.isolateTempDir`), which every
# `node bin/test.js` claims so two concurrent runs cannot name the same fixture; the
# runner removes it on completion, and this sweep is what covers a SIGKILLed one.
TMPL_PREFIXES=${TMPL_PREFIXES:-'anyparse-mutcheck anyparse-mutarm apq-battery apq-suite-shard apq-suite'}

# The stamp a claimed directory carries. Dotted so no tool's own glob or
# report ever sees it.
TMPL_STAMP=${TMPL_STAMP:-.apq-owner}

# Silence required before a DEAD owner's directory is swept.
TMPL_GRACE_SECONDS=${TMPL_GRACE_SECONDS:-300}

# Silence required before an UNSTAMPED (pre-fix) directory is swept.
TMPL_LEGACY_SECONDS=${TMPL_LEGACY_SECONDS:-21600}

# The marker a KEPT directory carries — written by a caller's `--keep` (or by
# a non-zero exit that already kept the directory) so a LATER run's startup
# sweep leaves it alone regardless of owner-pid or idle time (T738). Without
# this, `tmpl_is_orphan`'s "owner pid is dead" reads identically for a
# CRASHED run and a `--keep` run that finished normally — its process exits
# either way — so a kept workroot was reclaimed by the next campaign's sweep
# exactly like an abandoned one: measured 2026-09-06 (S155), a saved workroot
# with 10 transcripts was gone by the time the wave's finalists started.
TMPL_KEEP_MARKER=${TMPL_KEEP_MARKER:-.apq-keep}

# `${TMPDIR:-/tmp}` with every trailing slash removed.
tmpl_root() {
    local r=${TMPDIR:-/tmp}
    while [ "$r" != "/" ] && [ "${r%/}" != "$r" ]; do
        r=${r%/}
    done
    printf '%s\n' "$r"
}

# The only paths this file will ever remove: a direct child of the scratch
# root whose basename is one of our prefixes plus mktemp's six characters.
# Anything else is refused with a reason on stderr rather than skipped
# quietly — a caller handing this a wrong path has a bug worth seeing.
tmpl_is_ours() {
    local dir=$1 root base prefix
    root=$(tmpl_root)
    case "$dir" in
        "$root"/*) ;;
        *)
            echo "tmp-lifecycle: refusing '$dir' — not under $root" >&2
            return 1
            ;;
    esac
    base=${dir#"$root"/}
    case "$base" in
        */*)
            echo "tmp-lifecycle: refusing '$dir' — not a direct child of $root" >&2
            return 1
            ;;
    esac
    for prefix in $TMPL_PREFIXES; do
        case "$base" in
            "$prefix".??????) return 0 ;;
        esac
    done
    echo "tmp-lifecycle: refusing '$dir' — '$base' is not one of this project's scratch prefixes" >&2
    return 1
}

# tmpl_claim <prefix> -> the new directory on stdout, stamped with our pid.
tmpl_claim() {
    local prefix=$1 dir
    dir=$(mktemp -d "$(tmpl_root)/$prefix.XXXXXX") || return 1
    printf 'pid %s\ntool %s\nstarted %s\n' "$$" "$prefix" "$(date +%s)" > "$dir/$TMPL_STAMP"
    printf '%s\n' "$dir"
}

# The newest mtime among a directory and its top-level entries.
tmpl_newest_mtime() {
    local dir=$1
    {
        stat -f '%m' "$dir" 2> /dev/null || true
        find "$dir" -maxdepth 1 -mindepth 1 -exec stat -f '%m' {} + 2> /dev/null || true
    } | sort -n | tail -1
}

# The stamped owner pid, empty when there is no stamp.
tmpl_owner_pid() {
    local dir=$1
    [ -f "$dir/$TMPL_STAMP" ] || return 0
    awk '$1 == "pid" { print $2; exit }' "$dir/$TMPL_STAMP" 2> /dev/null || true
}

# tmpl_mark_keep <dir> — flag a claimed directory as kept: every LATER run's
# startup sweep skips it regardless of owner-pid or idle time, until someone
# removes it by hand. Callers that already print the kept path (mutation-arm.sh
# / mutation-check.sh on `--keep` or a non-zero exit) call this alongside that
# print — the marker is what makes the print true past the owner process's own
# exit.
tmpl_mark_keep() {
    local dir=$1
    [ -n "$dir" ] || return 0
    : > "$dir/$TMPL_KEEP_MARKER"
}

# tmpl_is_orphan <dir> — true when no live run owns it. See the predicate
# discussion in the header; every uncertainty resolves toward KEEPING.
tmpl_is_orphan() {
    local dir=$1 pid limit newest now
    [ -f "$dir/$TMPL_KEEP_MARKER" ] && return 1
    pid=$(tmpl_owner_pid "$dir")
    if [ -f "$dir/$TMPL_STAMP" ]; then
        if [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; then
            return 1
        fi
        limit=$TMPL_GRACE_SECONDS
    else
        limit=$TMPL_LEGACY_SECONDS
    fi
    newest=$(tmpl_newest_mtime "$dir")
    [ -n "$newest" ] || return 1
    now=$(date +%s)
    [ "$((now - newest))" -ge "$limit" ]
}

# tmpl_discard <dir> [<repo>] — remove one of OUR directories and let git
# forget whatever was registered inside it. Removal first, prune second.
tmpl_discard() {
    local dir=$1 repo=${2:-}
    [ -n "$dir" ] || return 0
    [ -e "$dir" ] || return 0
    tmpl_is_ours "$dir" || return 1
    rm -rf "$dir"
    if [ -n "$repo" ]; then
        git -C "$repo" worktree prune > /dev/null 2>&1 || true
    fi
}

# tmpl_sweep [<repo>] — the startup half of the fix. Silent unless it
# actually removed something. `APQ_TMP_NO_SWEEP=1` turns it off.
tmpl_sweep() {
    local repo=${1:-} root prefix dir swept=0 noun
    if [ -n "${APQ_TMP_NO_SWEEP:-}" ]; then
        return 0
    fi
    root=$(tmpl_root)
    for prefix in $TMPL_PREFIXES; do
        for dir in "$root/$prefix".??????; do
            [ -d "$dir" ] || continue
            tmpl_is_orphan "$dir" || continue
            tmpl_is_ours "$dir" || continue
            rm -rf "$dir"
            swept=$((swept + 1))
        done
    done
    [ "$swept" -gt 0 ] || return 0
    if [ -n "$repo" ]; then
        git -C "$repo" worktree prune > /dev/null 2>&1 || true
    fi
    if [ "$swept" -eq 1 ]; then noun="directory"; else noun="directories"; fi
    echo "tmp-lifecycle: swept $swept orphaned scratch $noun under $root" >&2
}

# ------------------------------------------------------------- standalone
#
# Sourced, this file defines functions and does nothing. Run directly it is
# the hand tool three campaign slices had to improvise.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    tmpl_main_repo=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    case "${1:---list}" in
        --list)
            printf '%-10s %-9s %-8s %6s  %s\n' "OWNER" "STATE" "IDLE" "SIZE" "DIRECTORY"
            tmpl_list_root=$(tmpl_root)
            for tmpl_p in $TMPL_PREFIXES; do
                for tmpl_d in "$tmpl_list_root/$tmpl_p".??????; do
                    [ -d "$tmpl_d" ] || continue
                    tmpl_pid=$(tmpl_owner_pid "$tmpl_d")
                    [ -n "$tmpl_pid" ] || tmpl_pid="-"
                    if [ -f "$tmpl_d/$TMPL_KEEP_MARKER" ]; then
                        tmpl_state="KEEP"
                    elif tmpl_is_orphan "$tmpl_d"; then
                        tmpl_state="ORPHAN"
                    else
                        tmpl_state="live/young"
                    fi
                    tmpl_new=$(tmpl_newest_mtime "$tmpl_d")
                    printf '%-10s %-9s %7ss %6s  %s\n' "$tmpl_pid" "$tmpl_state" \
                        "$(( $(date +%s) - ${tmpl_new:-0} ))" \
                        "$(du -sh "$tmpl_d" 2> /dev/null | cut -f1)" "$tmpl_d"
                done
            done
            ;;
        --sweep)
            tmpl_sweep "$tmpl_main_repo"
            echo "tmp-lifecycle: sweep done"
            ;;
        --help|-h)
            # Range-free on purpose: a hardcoded line span goes stale the
            # first time the header grows, and prints half a sentence.
            awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            ;;
        *)
            echo "usage: tmp-lifecycle.sh [--list|--sweep|--help]" >&2
            exit 2
            ;;
    esac
fi
