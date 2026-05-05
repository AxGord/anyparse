package anyparse.grammar.haxe;

/**
 * Paren-bearing metadata payload — `@:name(args)`. Two-field Seq
 * because Haxe enum-constructor argument positions don't accept
 * field-level metas (`@:lead`, `@:trail`, `@:sep`); the typedef gives
 * the per-field meta surface the macro pipeline needs.
 *
 * The `name:HxMetaNameTight` regex requires an immediately-following
 * `(` via positive lookahead — whitespace between name and `(` makes
 * the regex fail, the enclosing `MetaCall` branch rolls back via
 * `tryBranch`, and parsing falls through to the paren-less
 * `Meta(name:HxMetaName)` branch. This is how `@:privateAccess (X)`
 * (paren is a separate expression) and `@:keep(foo)` (paren is meta
 * args) get disambiguated structurally.
 *
 * `args:Array<HxExpr>` parses through the standard `HxExpr` pipeline
 * — same code path as `HxExpr.Call.args` — so format-driven knobs
 * (`anonFuncParens`, `typeHintColon`, `funcParamParens`,
 * `callParens`) apply uniformly to function-expression args without
 * per-meta grammar.
 *
 * Trivia: bearing transitively through `Array<HxExpr>` whenever any
 * `HxExpr` ctor is bearing — `TriviaTypeSynth` synthesises
 * `HxMetaCallArgsT` automatically.
 */
@:peg
typedef HxMetaCallArgs = {
	var name:HxMetaNameTight;
	@:lead('(') @:trail(')') @:sep(',') var args:Array<HxExpr>;
}
