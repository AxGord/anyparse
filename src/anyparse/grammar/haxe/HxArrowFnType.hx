package anyparse.grammar.haxe;

/**
 * New-form (Haxe 4) arrow function type: `(args) -> ret`.
 *
 * Structure: a `(`-`,`-`)` parenthesised list of `HxArrowParam`
 * (positional `Type` or named `name:Type`), then the `->` separator,
 * then the return type.
 *
 * Examples:
 *  - `() -> Void`                                — empty arg list
 *  - `(Int) -> String`                           — single positional
 *  - `(Int, String) -> Bool`                     — multi positional
 *  - `(name:String) -> Void`                     — single named
 *  - `(resolve:Dynamic, reject:Dynamic) -> Void` — multi named
 *  - `(Int) -> (String) -> Bool`                 — right-associative
 *    chained new-form arrows (each parens cluster is a separate
 *    `ArrowFn`, ret of the outer is itself an `ArrowFn`).
 *
 * Used as the inner shape of `HxType.ArrowFn`, placed BEFORE
 * `HxType.Parens` in the source-order Alt-enum so the parser tries the
 * arrow-fn shape first. When the trailing `->` is missing the branch
 * rolls back and `Parens` (or any other `(`-prefixed atom) takes over.
 *
 * `@:fmt(functionTypeHaxe4)` on `ret` gates the spacing around the
 * `->` separator on `opt.functionTypeHaxe4:WhitespacePolicy`. Default
 * `Both` matches haxe-formatter's
 * `whitespace.functionTypeHaxe4Policy: @:default(Around)` — emits
 * `(args) -> ret`. Setting the runtime policy to `None` produces the
 * tight `(args)->ret` shape. The old (curried) form `Int->Bool` runs
 * through the sibling `@:fmt(functionTypeHaxe3)` on `HxType.Arrow`
 * gated by `opt.functionTypeHaxe3` (haxe-formatter's
 * `functionTypeHaxe3Policy: @:default(None)`), so the two arrow shapes
 * are independently configurable.
 *
 * Structurally identical to `HxThinParenLambda` (the expression-form
 * `(params) -> body` arrow lambda) — same `(`-`,`-`)` Star pattern over
 * an arg list, same `@:lead('->')` body commit point. The two diverge
 * only in their inner element type (`HxArrowParam` vs `HxLambdaParam`)
 * and consumer site (`HxType` vs `HxExpr`).
 *
 * `args` opts into the wrap engine via
 * `@:fmt(wrapRules('functionSignatureWrap'), groupRestProbe)` — the same
 * `functionSignatureWrap` cascade `HxFnDecl.params` uses, because
 * haxe-formatter routes BOTH function declarations and function-TYPE
 * signatures through its `wrapping.functionSignature` class (verified by
 * the `issue_531_conditional_typedef*` fixtures, whose configs override
 * `functionSignature`). The cascade's `defaultMode: FillLine` packs the
 * param list inline while it fits and breaks after a `,` on overflow,
 * with `defaultAdditionalIndent: 1` placing the continuation one indent
 * deeper. `groupRestProbe` biases the outer Group toward MBreak when
 * the trailing `-> ReturnType` adds same-line content past the close
 * paren. The function-decl-specific flags (`funcParamParens`,
 * `bodyAwareCompactIndent`, `ignoreSourceNewlinesForWrap`,
 * `trailingComma`) are intentionally omitted — a function type has no
 * keyword-to-paren gap, no body-empty signal, and no source trailing
 * comma in its param list.
 */
@:peg
typedef HxArrowFnType = {
	@:lead('(') @:trail(')') @:sep(',') @:fmt(wrapRules('functionSignatureWrap'), groupRestProbe) var args:Array<HxArrowParam>;
	@:fmt(functionTypeHaxe4) @:lead('->') var ret:HxType;
}
