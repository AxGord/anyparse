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
 * tight `(args)->ret` shape. The old (curried) form `Int->Bool` keeps
 * its own `@:fmt(tight)` on `HxType.Arrow` and is unaffected by this
 * knob, mirroring haxe-formatter's separate
 * `functionTypeHaxe3Policy: @:default(None)` default.
 *
 * Structurally identical to `HxThinParenLambda` (the expression-form
 * `(params) -> body` arrow lambda) — same `(`-`,`-`)` Star pattern over
 * an arg list, same `@:lead('->')` body commit point. The two diverge
 * only in their inner element type (`HxArrowParam` vs `HxLambdaParam`)
 * and consumer site (`HxType` vs `HxExpr`).
 */
@:peg
typedef HxArrowFnType = {
	@:lead('(') @:trail(')') @:sep(',') var args:Array<HxArrowParam>;
	@:fmt(functionTypeHaxe4) @:lead('->') var ret:HxType;
}
