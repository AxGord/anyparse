# Compacts `hxq changed` output: files whose change is layout / imports / renamed only collapse into counts
# (moves grouped by directory, from → to); other files keep their detail lines, at most 12 each.
function dir(p) { sub(/\/[^\/]*$/, "", p); return p }
function flushDetail() { if (extra > 0) printf "    … +%d more line(s)\n", extra; extra = 0 }
NR == 1 { print; next }
/^[A-Z] / {
  flushDetail()
  kind = $(NF - 2)
  if (kind == "layout" || kind == "imports" || kind == "renamed") {
    quiet = 1; count[kind]++
    if ($1 == "R" && $3 == "<-") moves[dir($4) " → " dir($2)]++
    next
  }
  quiet = 0; shown = 0; print; next
}
/^ / { if (quiet) next; if (shown < 12) { print; shown++ } else extra++; next }
{ flushDetail(); print }
END {
  flushDetail()
  for (k in count) printf "%d file(s) %s only — not listed one by one (full list: changed.txt)\n", count[k], k
  n = 0; for (m in moves) order[++n] = m
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (moves[order[j]] > moves[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
  for (i = 1; i <= n && i <= 25; i++) printf "  moved %d: %s\n", moves[order[i]], order[i]
  if (n > 25) printf "  … +%d more move group(s)\n", n - 25
}
