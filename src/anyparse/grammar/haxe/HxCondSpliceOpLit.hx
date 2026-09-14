package anyparse.grammar.haxe;

/**
 * The operator that ENDS one term of a token-splice conditional's fragment — every binary
 * `@:infix` literal of `HxExpr`.
 *
 * A fragment such as `#if flash "a" + x + #end` is not an expression: it is a run of complete
 * operands, each followed by an operator whose right operand is elsewhere (the last one's
 * lives after the `#end`). `HxCondSpliceOpTerm` pairs one operand with one of these, and
 * `HxCondSpliceOpExpr` repeats the pair — so this terminal is the separator that makes the
 * run parseable without the Pratt loop.
 *
 * The alternation is written LONGEST-FIRST because a JS regex alternation is first-match:
 * `>=` must be attempted before `>`, `??=` before `??` before `?`, `=>` and `==` before `=`.
 * The two WORD-like operators (`is`, `in`) carry a `(?![A-Za-z0-9_])` guard so `island` and
 * `index` are not read as an operator followed by a suffix — the terminal twin of the
 * `matchKw` word-boundary dispatch `ParseDispatchLowering.endsWithWordChar` gives them inside
 * the Pratt loop.
 *
 * The TERNARY's `?` and `:` are deliberately NOT here: a hand-indented `#if X share ? new A(…)
 * : #end new B(…)` region follows the ternary's two-level convention, and a FLAT term run has
 * one indent level to give, so modelling it would make `fmt` rewrite bytes it left alone
 * before. Byte round-trip of an unchanged region outranks one more modelled site, so the
 * ternary keeps `HxCondSpliceRaw`'s verbatim capture and its rename refusal; restoring the
 * two operators is a one-token edit the day the writer can reproduce a per-element nest.
 * `,` is not here either — a comma-separated splice is `HxConditionalArgs`' shape, dispatched
 * before this one.
 *
 * `@:rawString` — the matched slice is stored verbatim, no string-unescape pass; the writer
 * re-emits it byte for byte.
 */
@:re('(?:>>>=|>>>|>>=|>>|>=|>|<<=|<<|<=|<|\\?\\?=|\\?\\?|&&=|&&|&=|&|\\|\\|=|\\|\\||\\|=|\\||\\.\\.\\.|==|=>|=|!=|\\+=|\\+|-=|->|-|\\*=|\\*|/=|/|%=|%|\\^=|\\^|(?:is|in)(?![A-Za-z0-9_]))')
@:rawString
@:condRegionRaw
abstract HxCondSpliceOpLit(String) from String to String {}
