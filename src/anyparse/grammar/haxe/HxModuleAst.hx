package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated deep transform over the Plain
 * `HxModule` AST — the multi-type `haxe.macro.ExprTools.map` analog for
 * the whole Haxe grammar forest.
 *
 * The `buildTransform` macro walks the same `ShapeTree` as
 * `HaxeModuleParser` / `HxModuleWriter` and emits, on this class:
 *
 * ```haxe
 * public static function transform(root:HxModule, visit:HxModuleTransform):HxModule
 * ```
 *
 * plus one `private static _transform<T>(node:T, visit):T` per grammar
 * type reachable from `HxModule` (`HxTopLevelDecl`, `HxDecl`,
 * `HxClassDecl`, the recursive Pratt `HxExpr` / `HxStatement` / `HxType`
 * cycle, every terminal like `HxIdentLit`, ...). `transform` performs a
 * bottom-up walk: every grammar-typed child is recursed via its own
 * `_transform`, the node is rebuilt around the transformed children,
 * then the matching `visit` hook is applied if set.
 *
 * The generated `HxModuleTransform` typedef carries one optional
 * `T -> T` hook per grammar type (camelCased simple name: `hxExpr`,
 * `hxStatement`, `hxIdentLit`, ...). An empty `visit` (`{}`) is a
 * structural identity; setting one hook rewrites every node of that
 * type across the whole tree — e.g. `visit.hxIdentLit = renameFn`
 * renames every identifier.
 *
 * Plain types only — the `*T` trivia/span paired types are NOT
 * transformed over (format-preserving transform is a later slice).
 *
 * `@:keep` forces inclusion even without direct runtime references so
 * the `@:build` pipeline fires regardless of DCE. The class body is
 * empty on purpose: the fields are contributed by the macro. Keep this
 * file untouched and rebuild — grammar edits take effect automatically
 * because the macro re-runs on every compile.
 */
@:keep
@:build(anyparse.macro.Build.buildTransform(anyparse.grammar.haxe.HxModule))
@:nullSafety(Strict)
class HxModuleAst {}
