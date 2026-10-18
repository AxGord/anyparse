#!/bin/zsh
# Interleaved A/B over several builds of the parse/writer harness.
#
# Usage: tools/bench-ab.sh [--config <hxformat.json>] <mode> <target> <rounds> <reps> <label>:<binary>...
#   tools/bench-ab.sh tparse tools/bench-corpus.txt 5 6 base:bin/parse-prof.js after:/tmp/after.js
#
# An arm whose path ends in `.js` runs under `node`; anything else is executed
# directly, so a native hxcpp build of the same harness (tools/bench-hxcpp.hxml)
# is just another arm:
#   tools/bench-ab.sh tparse tools/bench-corpus.txt 5 6 \
#     js:bin/parse-prof.js cpp:bin/parse-prof-cpp/ParseProf
#
# --config names the formatter config every arm runs under (default: the repo-root hxformat.json). Measure a foreign
# tree under ITS config: `hxq fmt` discovers the nearest hxformat.json, so the default measures the wrong settings there.
#
# <mode> and <target> are ParseProf's (see tools/ParseProf.hx). <reps> is the
# in-process repetition count: on the ~100-file calibrated corpus one pass is
# dominated by JIT tier-up, so repeat inside the process and read msPerRep.
#
# MEASUREMENT HYGIENE - do not relax, all three were paid for:
#  * Arms run SEQUENTIALLY and interleaved round by round, and the MEDIAN is the
#    result. Parallel arms share caches and turbo; the spread reached 45% on the
#    reference machine, which is larger than most wins being measured.
#  * Never a single before/after pair - a lone pair cannot tell a 10% win from
#    machine drift.
#  * `ps -o nice` of the runner is logged. A normal-niced background shell is
#    harmless (measured 14.6s vs 14.7s); a background-QoS clamp
#    (`taskpolicy -b`, LaunchAgent ProcessType Background) is not - it cost 4.3x
#    - so anything measured must never run under one.
set -u
CONFIG=hxformat.json
if [[ ${1:-} == --config ]]; then
  (( $# >= 2 )) || { print -u2 "$0: --config needs a path"; exit 2; }
  CONFIG=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
  shift 2
fi
if (( $# < 5 )); then
  print -u2 "usage: $0 [--config <hxformat.json>] <mode> <target> <rounds> <reps> <label>:<binary>..."
  exit 2
fi
[[ -f $CONFIG || $CONFIG == hxformat.json ]] || { print -u2 "$0: config $CONFIG not found"; exit 2; }
MODE=$1; TARGET=$2; ROUNDS=$3; REPS=$4; shift 4
ROOT=$(git rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1
print "# config=$CONFIG mode=$MODE target=$TARGET rounds=$ROUNDS reps=$REPS nice=$(ps -o nice= -p $$) $(date +%T)"
typeset -A acc
for r in $(seq 1 $ROUNDS); do
  for arm in "$@"; do
    label=${arm%%:*}
    bin=${arm#*:}
    if [[ $bin == *.js ]]; then
      line=$(node "$bin" "$MODE" "$TARGET" "$REPS" "$CONFIG" 2>/dev/null | tail -1)
    else
      line=$("$bin" "$MODE" "$TARGET" "$REPS" "$CONFIG" 2>/dev/null | tail -1)
    fi
    ms=$(print -r -- "$line" | sed -E 's/.* msPerRep=([0-9.]+) .*/\1/')
    print "round=$r arm=$label ms=$ms | $line"
    acc[$label]="${acc[$label]:-} $ms"
  done
done
print "\n# medians (ms per rep)"
for arm in "$@"; do
  label=${arm%%:*}
  print -r -- "${acc[$label]}" | tr ' ' '\n' | grep -v '^$' | sort -n | awk -v L="$label" '
    { v[NR] = $1 }
    END { printf "%-16s median=%9.1f  n=%d  min=%9.1f  max=%9.1f\n", L, v[int((NR + 1) / 2)], NR, v[1], v[NR] }'
done
