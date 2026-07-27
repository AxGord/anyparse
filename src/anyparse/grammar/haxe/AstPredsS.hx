package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated SPANS-family AST predicates of
 * the Haxe grammar — the typed shape gates the spans parser calls
 * (parser-side statement-terminator gates). Typed against the paired
 * `spans.Pairs.*S` enums; every Alt pattern carries the trailing
 * `_span` wildcard. See `AstPreds` for the family overview.
 */
@:build(anyparse.grammar.haxe.HxPredBuild.build({ spans: true }))
@:nullSafety(Strict)
final class AstPredsS {}
