package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated Fast-mode parser of
 * `HxClassDecl` (the root of the Phase 3 Haxe skeleton grammar).
 *
 * The `@:build` metadata invokes `anyparse.macro.Build.buildParser`
 * with `HxClassDecl` as the grammar root; the macro walks the root
 * type's meta, recursively shapes every referenced sub-rule
 * (`HxClassMember`, `HxVarDecl`, `HxFnDecl`, `HxTypeRef`, `HxIdentLit`),
 * and fills this class with a `parse(source):HxClassDecl` entry point
 * plus the private `parseXxx(ctx)` recursive-descent helpers. The
 * class body is empty on purpose — editing it would just be clobbered
 * on the next compile.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxClassDecl))
@:nullSafety(Strict)
class HaxeFastParser {}
