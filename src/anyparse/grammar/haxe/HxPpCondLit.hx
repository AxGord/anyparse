package anyparse.grammar.haxe;

/**
 * Haxe preprocessor condition atom — the expression consumed right after
 * `#if` / `#elseif`.
 *
 * Captured verbatim as the matched substring, preserving the original
 * condition text across round-trip. Three shapes cover the idiomatic
 * Haxe forms:
 *
 *  - Bare identifier: `cppia`, `neko_v21`.
 *  - Negated identifier or paren atom: `!cppia`, `!!x`, `!(cond)`.
 *  - Parenthesised compound: `(cppia && !flash)`, `(neko_v21 || (cpp && !cppia) || flash)`.
 *
 * The regex supports parentheses nested up to **two** levels inside the
 * outer group — enough for every `#if` condition in the haxe-formatter
 * fixtures (max observed: 2 levels in `issue_332_conditional_modifiers`).
 * A depth-3 condition produces a truncated prefix match (the regex
 * greedily consumes what it can at depth ≤ 2 and stops), leaving the
 * unmatched inner parens in the stream for the next field to choke on;
 * downstream parse fails one way or another. Deepen the regex when a
 * real grammar site demands it.
 *
 * `@:rawString` routes the matched slice through `Lowering.lowerTerminal`
 * as the stored value without running the string-unescape loop — a
 * preprocessor condition is not a Haxe string literal, so `\n` etc.
 * stay as literal backslash-n in the captured text.
 */
@:re('!*(?:[A-Za-z_][A-Za-z0-9_]*|\\((?:[^()]|\\([^()]*\\))*\\))')
@:rawString
abstract HxPpCondLit(String) from String to String {}
