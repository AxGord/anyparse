package anyparse.grammar.haxe;

/**
 * New-form (Haxe 4) arrow function type: `(args) -> ret` — a `(`-`,`-`)` parenthesised list
 * of `HxArrowParam` (positional `Type` or named `name:Type`), the `->` separator, then the
 * return type. `() -> Void`, `(Int, String) -> Bool`, `(resolve:Dynamic, reject:Dynamic) ->
 * Void`; `(Int) -> (String) -> Bool` chains right-associatively (each parens cluster is a
 * separate `ArrowFn`, the ret of the outer is itself an `ArrowFn`).
 *
 * Used as the inner shape of `HxType.ArrowFn`, placed BEFORE `HxType.Parens` in the
 * source-order Alt-enum so the parser tries the arrow-fn shape first; when the trailing `->`
 * is missing the branch rolls back and `Parens` (or any other `(`-prefixed atom) takes over.
 *
 * `@:fmt(functionTypeHaxe4)` on `ret` gates the spacing around `->` on
 * `opt.functionTypeHaxe4:WhitespacePolicy`: the default `Both` matches haxe-formatter's
 * `whitespace.functionTypeHaxe4Policy` default and emits `(args) -> ret`; `None` produces
 * the tight `(args)->ret`. The old curried form `Int->Bool` runs through the sibling
 * `@:fmt(functionTypeHaxe3)` on `HxType.Arrow`, so the two arrow shapes are independently
 * configurable.
 *
 * Structurally identical to `HxThinParenLambda` (the expression-form `(params) -> body`
 * lambda) — same Star pattern over an arg list, same `@:lead('->')` commit point; the two
 * diverge only in their element type (`HxArrowParam` vs `HxLambdaParam`) and consumer site.
 *
 * `args` opts into the wrap engine via `@:fmt(wrapRules('functionSignatureWrap'),
 * groupRestProbe)` — the same `functionSignatureWrap` cascade `HxFnDecl.params` uses, because
 * haxe-formatter routes BOTH function declarations and function-TYPE signatures through its
 * `wrapping.functionSignature` class. The cascade's `defaultMode: FillLine` packs the param
 * list inline while it fits and breaks after a `,` on overflow, with
 * `defaultAdditionalIndent: 1` placing the continuation one indent deeper; `groupRestProbe`
 * biases the outer Group toward MBreak when the trailing `-> ReturnType` adds same-line
 * content past the close paren. The function-decl-specific flags (`funcParamParens`,
 * `bodyAwareCompactIndent`, `ignoreSourceNewlinesForWrap`, `trailingComma`) are omitted — a
 * function type has no keyword-to-paren gap, no body-empty signal and no source trailing
 * comma in its param list.
 */
@:peg
typedef HxArrowFnType = {
	@:lead('(') @:trail(')') @:sep(',') @:fmt(wrapRules('functionSignatureWrap'), groupRestProbe) var args: Array<HxArrowParam>;
	@:fmt(functionTypeHaxe4) @:lead('->') var ret: HxType;
}
