package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated span-mode parser of `HxModule`.
 *
 * Sibling to `HaxeModuleParser` (Fast-mode, no spans). Drives the
 * `Build.buildParser(..., {spans:true})` codegen path: identical grammar
 * traversal, plus a side-channel `Array<Span>` populated in source
 * post-order at every enum-ctor / struct-Seq return site. The public
 * `parse(source)` returns `{ast:HxModule, spans:Array<Span>}` instead of
 * the bare `HxModule` shape of the Fast-mode marker.
 *
 * Downstream consumer is the `apq` query plugin (`HaxeQueryPlugin`):
 * it walks the typed AST in post-order and pops spans from the parallel
 * array in lockstep, attaching them to the language-agnostic `QueryNode`
 * tree it builds for the engine.
 *
 * Span-mode parses traverse exactly the same grammar paths as Fast-mode —
 * the only difference is the side-channel `parseSpans` push and the
 * wrapped return type. The Fast-mode `HaxeModuleParser` stays the
 * preferred entry point for batch / non-positional consumers.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxModule, {spans: true}))
@:nullSafety(Strict)
class HaxeModuleSpanParser {}
