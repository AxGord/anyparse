package anyparse.grammar.haxe;

/**
 * Raw byte capture of a TOKEN-SPLICE conditional-compilation region: everything after the
 * dispatching `#if` keyword up to AND INCLUDING the closing `#end` — the condition atom plus
 * an arbitrary token fragment that is NOT a balanced expression/statement subtree: an operand
 * run with a dangling `+` (`"a" + #if !flash "b" + x + #end "c"`), a POST-operand fragment
 * neither `HxCondSpliceOpTail` nor `HxCondSpliceListTail` can read (`a #if m + b #else - b
 * #end`, reached through `HxCondSpliceTailBody.RawTail`), half a ternary (`#if share cond ?
 * new A(...) : #end new B(...)`), or an if-head whose else branch lives outside the region
 * (`#if x if (c) g(); else #end h();`).
 *
 * The `#end` is swallowed INTO the raw match (rather than living on a `@:trail`) so the
 * enclosing ctors can parse their continuation tail immediately after this terminal with no
 * mid-struct keyword field.
 *
 * NESTING. The regex is a three-branch alternation. The FIRST branch skips over BALANCED inner
 * `#if ... #end` regions nested up to four deep (a regex has no recursion, so the depth is
 * unrolled) and stops at the first UNMATCHED `#end`, so a splice fragment may itself contain
 * complete nested conditionals — a dangling-else if-head whose body holds a region that holds
 * another one. The SECOND branch is the one-level reading (an inner `#if` runs to its first
 * `#end`), kept so every fragment it matched still matches when the deep reading fails. The
 * THIRD is the stop-at-the-first-`#end` rule, kept as a fallback so an UNBALANCED inner `#if`
 * (one whose `#end` also closes the outer region) still matches — the nesting-aware branches
 * cannot represent that shape and would otherwise scan forward to an unrelated `#end`. Branch
 * order matters: regex alternation is first-match, so the deepest balanced reading wins
 * whenever it applies. Every branch ends at a `#end`, so the terminal's contract (byte-verbatim
 * capture through the closing directive) holds either way.
 *
 * The whole alternation is wrapped in a non-capturing group because `Codegen.eregField`
 * prepends a bare `^`, and `^A|B` parses as `(^A)|B` — the second alternative would otherwise
 * be free to match mid-buffer. `@:rawString` — byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*#end|(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end|(?:(?!#end)[\\s\\S])*#end)')
@:rawString
@:condRegionRaw
abstract HxCondSpliceRaw(String) from String to String {}
