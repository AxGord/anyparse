package anyparse.grammar.json;

/**
 * Marker class for the macro-generated deep transform over the `JValue`
 * family — the multi-type `haxe.macro.ExprTools.map` analog.
 *
 * The `buildTransform` macro walks the same `ShapeTree` as `buildParser`
 * and `buildWriter` and emits, on this class:
 *
 * ```haxe
 * public static function transform(root:JValue, visit:JValueTransform):JValue
 * ```
 *
 * plus one `_transform<T>` per reachable grammar type (`JValue`,
 * `JEntry`, `JNumberLit`, `JStringLit`). `transform` performs a
 * bottom-up walk: every grammar-typed child is recursed via its own
 * `_transform`, the node is rebuilt around the transformed children,
 * then the matching `visit` hook is applied if set. An empty `visit`
 * (`{}`) is a structural identity; setting one hook (e.g.
 * `visit.jNumber...`) rewrites every node of that type across the tree.
 *
 * The generated `JValueTransform` typedef carries one optional `T -> T`
 * hook per grammar type (`jValue`, `jEntry`, `jNumberLit`, `jStringLit`).
 *
 * The class body is empty on purpose: the fields are contributed by the
 * macro. Keep this file untouched and rebuild — grammar edits take
 * effect automatically because the macro re-runs on every compile.
 */
@:build(anyparse.macro.Build.buildTransform(anyparse.grammar.json.JValue))
@:nullSafety(Strict)
class JValueAst {}
