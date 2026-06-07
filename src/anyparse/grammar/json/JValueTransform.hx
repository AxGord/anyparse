package anyparse.grammar.json;

/**
 * Marker class for the macro-generated shallow `map` over `JValue` —
 * the `haxe.macro.ExprTools.map` analog for the JSON AST family.
 *
 * The `buildTransform` macro walks the same `ShapeTree` as `buildParser`
 * and `buildWriter` and emits a single:
 *
 * ```haxe
 * public static function map(node:JValue, f:JValue -> JValue):JValue
 * ```
 *
 * `map` rebuilds `node`, applying `f` to each immediate `JValue` child
 * (array elements and the nested `value` of each object entry included)
 * and copying non-family leaves (`JBool`'s `Bool`, the number/string
 * terminals, object keys) unchanged. It is shallow — it never recurses
 * into the result of `f`. Deep traversal is composed by calling `map`
 * inside `f`, exactly as with `ExprTools.map`.
 *
 * The class body is empty on purpose: the `map` field is contributed by
 * the macro. Keep this file untouched and rebuild — grammar edits take
 * effect automatically because the macro re-runs on every compile.
 */
@:build(anyparse.macro.Build.buildTransform(anyparse.grammar.json.JValue))
@:nullSafety(Strict)
class JValueTransform {}
