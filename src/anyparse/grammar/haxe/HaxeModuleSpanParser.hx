package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated span-mode parser of `HxModule`.
 *
 * Sibling to `HaxeModuleParser` (Fast-mode, no spans). Drives the
 * `Build.buildParser(..., {spans:true})` codegen path: identical grammar
 * traversal, plus `SpanTypeSynth`-synthesised paired `*S` types in
 * `anyparse.grammar.haxe.spans.Pairs`. Each paired Alt ctor gains a
 * trailing positional `_span:Span` arg the parser fills with
 * `Span(_start, ctx.pos)` at every ctor build site.
 *
 * The public `parse(source)` returns `HxModuleS` directly — the paired
 * Seq type whose Ref fields propagate through to the paired Alt enums
 * carrying spans on every value.
 *
 * Downstream consumer is the `apq` query plugin (`HaxeQueryPlugin`):
 * it reads each enum value's span via `Type.enumParameters` last arg,
 * attaching it to the language-agnostic `QueryNode` tree it builds for
 * the engine. Span attribution is structural, not order-dependent, so
 * Reflect field ordering across targets can no longer desynchronise
 * spans from their carrier nodes.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxModule, { spans: true }))
@:nullSafety(Strict)
class HaxeModuleSpanParser {}
