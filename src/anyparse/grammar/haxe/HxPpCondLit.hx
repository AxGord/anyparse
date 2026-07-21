package anyparse.grammar.haxe;

/**
 * Haxe preprocessor condition atom — the expression consumed right after
 * `#if` / `#elseif`.
 *
 * Captured verbatim as the matched substring, preserving the original
 * condition text across round-trip. Five shapes cover the idiomatic
 * Haxe forms:
 *
 *  - Bare identifier: `cppia`, `neko_v21`.
 *  - Dotted identifier: `target.threaded`, `perf.js` — Haxe's define
 *    parser accepts a dot-separated path, and `std/sys/thread/*.hx` /
 *    lime's `perf.js` guards use the bare (unparenthesised) form.
 *    `#if (target.threaded)` already parsed before this shape was added
 *    — the dot path only extends the BARE identifier alternative, mirroring
 *    `HxTypeName`'s `(?:\.[A-Za-z_][A-Za-z0-9_]*)*` tail. Requiring an
 *    identifier after each `.` keeps a following float literal or field
 *    access out of the condition.
 *  - Integer literal: `#if 0` / `#if 1` — Haxe's macro-condition parser
 *    accepts a constant, and openfl uses `#if 0` to comment out whole
 *    regions (`utils/_internal/Lib.hx`, `AssetsMacro.hx`, `ShaderMacro.hx`).
 *  - Negated identifier or paren atom: `!cppia`, `!!x`, `!(cond)`.
 *  - Parenthesised compound: `(cppia && !flash)`, `(neko_v21 || (cpp && !cppia) || flash)`.
 *
 * The digits alternative sits AFTER the identifier one so a leading-letter
 * name is never split — the identifier branch already claims anything
 * starting with `[A-Za-z_]`, and a bare `0`/`1` cannot start an identifier.
 *
 * The regex supports parentheses nested up to **four** levels inside the
 * outer group. Two levels covered every `#if` condition in the
 * haxe-formatter fixtures (max observed: 2 levels in
 * `issue_332_conditional_modifiers`), but the std lib demands four:
 * `sys/Http.hx` guards a branch with `#if (!no_ssl && (hxssl || hl ||
 * cpp || (neko && !(macro || interp) || eval) || (lua &&
 * !lua_vanilla)))`, whose innermost `(macro || interp)` sits at depth 4.
 * A condition deeper than the cap produces a truncated prefix match (the
 * regex greedily consumes what it can at the supported depth and stops),
 * leaving the unmatched inner parens in the stream for the next field to
 * choke on; downstream parse fails one way or another.
 *
 * Deepening costs nothing at match time: the two alternatives inside
 * every level are disjoint on their first character (`[^()]` vs `\(`),
 * so the engine never backtracks across them and the match stays linear
 * in the condition length. Depth 5 was written out and rejected only
 * because the resulting `@:re(...)` line runs 154 columns, past the
 * repo's 140-column limit; a recursion-free shape is not available
 * either (a JS regex has no `(?R)`, and a counting scan is not
 * expressible as a terminal `@:re`), so depth-limited nesting stays the
 * only option. Deepen it again when a real grammar site demands it.
 *
 * `@:rawString` routes the matched slice through `Lowering.lowerTerminal`
 * as the stored value without running the string-unescape loop — a
 * preprocessor condition is not a Haxe string literal, so `\n` etc.
 * stay as literal backslash-n in the captured text.
 */
@:re('!*(?:[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*|[0-9]+|\\((?:[^()]|\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))*\\))')
@:rawString
abstract HxPpCondLit(String) from String to String {}
