package anyparse.grammar.haxe;

/**
 * Haxe preprocessor condition atom — the expression consumed right after `#if` / `#elseif`,
 * captured verbatim as the matched substring so the original condition text round-trips.
 *
 * Five shapes cover the idiomatic forms: a bare identifier (`cppia`); a dotted identifier
 * (`target.threaded`, `perf.js` — Haxe's define parser accepts a dot-separated path, and the
 * tail mirrors `HxTypeName`'s; requiring an identifier after each `.` keeps a following float
 * literal or field access out of the condition); an integer literal (`#if 0` is the idiom for
 * commenting out a whole region); a negated identifier or paren atom (`!cppia`, `!!x`,
 * `!(cond)`); and a parenthesised compound (`(neko_v21 || (cpp && !cppia) || flash)`). The
 * digits alternative sits AFTER the identifier one so a leading-letter name is never split.
 *
 * The regex supports parentheses nested up to **four** levels inside the outer group — the
 * std lib's `sys/Http.hx` guard `#if (!no_ssl && (hxssl || hl || cpp || (neko && !(macro ||
 * interp) || eval) || (lua && !lua_vanilla)))` puts its innermost group at depth 4. A deeper
 * condition produces a truncated prefix match, leaving the unmatched inner parens in the
 * stream for the next field to choke on. Deepening costs nothing at match time (the two
 * alternatives inside every level are disjoint on their first character, so the match stays
 * linear), but one more level pushes the `@:re(...)` line past the repo's column limit, and a
 * recursion-free shape is not available (a JS regex has no `(?R)`; a counting scan is not
 * expressible as a terminal `@:re`). Deepen it again when a real grammar site demands it.
 *
 * `@:rawString` routes the matched slice through `TerminalParseLowering.lowerTerminal` as the
 * stored value without the string-unescape loop — a preprocessor condition is not a Haxe
 * string literal, so `\n` etc. stay as literal backslash-n in the captured text.
 */
@:re('!*(?:[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*|[0-9]+|\\((?:[^()]|\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))*\\))')
@:rawString
@:condRegionCondition
@:writeNormalize('condOperatorSpacing')
abstract HxPpCondLit(String) from String to String {}
