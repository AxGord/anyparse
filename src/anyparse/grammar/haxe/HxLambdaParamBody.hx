package anyparse.grammar.haxe;

/**
 * Body shape for a single lambda/anon-fn parameter slot — the
 * `name [: Type]` portion shared by both the required and optional
 * branches of `HxLambdaParam`.
 *
 * Lifted out of the original `HxLambdaParam` typedef when the optional
 * marker `?name:Type` (Slice 31) was added: the marker dispatches at
 * the Alt-enum level (`@:lead('?') Optional(body:HxLambdaParamBody)`
 * vs the fallthrough `Required(body:HxLambdaParamBody)`), and both
 * branches share the same name / type body without duplicating the
 * field declarations. Mirror of the `HxParam` / `HxParamBody` split.
 *
 * Unlike `HxParamBody`, no `defaultValue` slot — arrow / anon-function
 * lambdas in Haxe do not support per-parameter default values at the
 * syntactic level.
 */
@:peg
typedef HxLambdaParamBody = {
	var name:HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type:Null<HxType>;
}
