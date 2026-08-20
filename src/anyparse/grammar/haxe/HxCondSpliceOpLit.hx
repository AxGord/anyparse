package anyparse.grammar.haxe;

/**
 * The operator that ENDS one term of a token-splice conditional's
 * fragment — every binary `@:infix` literal of `HxExpr` plus the
 * ternary's own `?` and `:` punctuation.
 *
 * A fragment such as `#if flash "a" + x + #end` is not an expression:
 * it is a run of complete operands, each followed by an operator whose
 * right operand is elsewhere (the last one's lives after the `#end`).
 * `HxCondSpliceOpTerm` pairs one operand with one of these, and
 * `HxCondSpliceOpExpr` repeats the pair — so this terminal is the
 * separator that makes the run parseable without the Pratt loop.
 *
 * The alternation is written LONGEST-FIRST because a JS regex
 * alternation is first-match: `>=` must be attempted before `>`, `??=`
 * before `??` before `?`, `=>` and `==` before `=`. Every symbolic
 * operator of `HxExpr` is present at its own length rank; the two
 * WORD-like ones (`is`, `in`) carry a `(?![A-Za-z0-9_])` guard so
 * `island` and `index` are not read as an operator followed by a
 * suffix — the terminal twin of the `matchKw` word-boundary dispatch
 * `Lowering.endsWithWordChar` gives them inside the Pratt loop.
 *
 * The TERNARY's `?` and `:` are deliberately NOT here, and the
 * omission is measured rather than assumed. Adding them makes the
 * ninth census region — TM `popups/fileDialog/FileDialog.hx:91`'s
 * `#if FEATURE_SHARE share ? new A(…) : #end new B(…)` — parse
 * perfectly, as two terms `(share, ?)` and `(new A(…), :)`; every
 * operand becomes a node and the rename stops refusing. What it also
 * does is move the file's bytes. That region is hand-indented on the
 * TERNARY's two-level convention (`share` one nest under the
 * assignment, `?` / `:` one nest under `share`), and a FLAT term run
 * has one indent level to give, so `hxq fmt` starts rewriting a file
 * it left alone before:
 *
 * ```
 * $ apq fmt popups/fileDialog/FileDialog.hx --list   # base: nothing
 * $ apq fmt popups/fileDialog/FileDialog.hx --list   # with ? and :
 * popups/fileDialog/FileDialog.hx
 * ```
 *
 * Byte round-trip of an unchanged region outranks one more modelled
 * site, so the ternary keeps `HxCondSpliceRaw`'s verbatim capture and
 * its rename refusal. Restoring the two operators is a one-token edit
 * the day the writer can reproduce a per-element nest.
 *
 * `,` is not here either — a comma-separated splice is
 * `HxConditionalArgs`' shape, and it is dispatched before this one.
 *
 * `@:rawString` — the matched slice is stored verbatim, no
 * string-unescape pass; the writer re-emits it byte for byte.
 */
@:re('(?:>>>=|>>>|>>=|>>|>=|>|<<=|<<|<=|<|\\?\\?=|\\?\\?|&&=|&&|&=|&|\\|\\|=|\\|\\||\\|=|\\||\\.\\.\\.|==|=>|=|!=|\\+=|\\+|-=|->|-|\\*=|\\*|/=|/|%=|%|\\^=|\\^|(?:is|in)(?![A-Za-z0-9_]))')
@:rawString
abstract HxCondSpliceOpLit(String) from String to String {}
