package anyparse.grammar.haxe;

/**
 * Raw byte capture of a CALL-OPENING token-splice region: every branch leaves exactly one `(` open,
 * and the shared argument tail plus its `)` live after the `#end` — `#if haxe4 TNamed(a.name,
 * #else ( #end toComplexType(a.t))`. Captured from after the `#if` keyword through the `#end`.
 *
 * The shape is fixed by the regex rather than by a gate: each branch is directive-free text whose
 * parentheses balance to one level deep, followed by one unmatched `(` and more such text, and the
 * region must carry an `#else` (with any `#elseif`s before it). A branch opening zero or two
 * parentheses, or holding a nested directive, does not match and falls through to
 * `HxCondSpliceExpr`, whose tail cannot close the extra `)` — so a region this terminal refuses
 * fails to parse as before instead of being misread.
 */
@:re('(?:[^()#]|\\((?:[^()#])*\\))*\\((?:[^()#]|\\((?:[^()#])*\\))*(?:#elseif\\b(?:[^()#]|\\((?:[^()#])*\\))*\\((?:[^()#]|\\((?:[^()#])*\\))*)*#else\\b(?:[^()#]|\\((?:[^()#])*\\))*\\((?:[^()#]|\\((?:[^()#])*\\))*#end')
@:rawString
@:condRegionRaw
abstract HxCondSpliceCallOpenRaw(String) from String to String {}
