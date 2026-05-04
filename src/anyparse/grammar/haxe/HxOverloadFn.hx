package anyparse.grammar.haxe;

/**
 * Function-decl shape inside an `@:overload(function ...)` metadata
 * arg. Mirrors `HxFnDecl` minus the leading `name:HxIdentLit` field —
 * `@:overload` arg has no function name, the rest of the signature
 * (type params, params, return type, body) is identical.
 *
 * The `function` keyword is consumed at the enclosing
 * `HxMetadata.OverloadMeta` ctor via field-level `@:kw('function')`
 * on the `fn` Ref — this typedef only describes what comes after the
 * keyword.
 *
 * Routing the `@:overload(...)` arg through a structural typedef lets
 * format-driven writer knobs apply: `typeHintColon` on `returnType`
 * tightens the spaces around `:`, the `params` Star inherits the
 * default `tightLeads(':')` policy from the format so each
 * `name:Type` param renders without spaces, etc. Any wrap-rules,
 * trailing-comma, or fitline policies the regular `HxFnDecl` consumes
 * are deferred to follow-up slices — the minimum surface here is
 * what `issue_184_type_hint_in_overload.hxtest` exercises.
 *
 * Trivia: `body:HxFnBody` is bearing through `BlockBody(HxFnBlock)`,
 * so `HxOverloadFn` is bearing transitively. `TriviaTypeSynth`
 * synthesises `HxOverloadFnT` automatically.
 */
@:peg
typedef HxOverloadFn = {
	@:optional @:lead('<') @:trail('>') @:sep(',') var typeParams:Null<Array<HxTypeParamDecl>>;
	@:lead('(') @:trail(')') @:sep(',') var params:Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType:Null<HxType>;
	var body:HxFnBody;
}
