package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated TRIVIA-family AST predicates of
 * the Haxe grammar — the typed shape gates the trivia parser and
 * trivia writer call. Bearing rules are typed against their paired
 * `trivia.Pairs.*T` enums (synth-slot-correct pattern arities via
 * `TriviaTypeSynth.extraAltArgs`); non-bearing rules stay plain, same
 * as inside the trivia AST itself. See `AstPreds` for the family
 * overview.
 */
@:build(anyparse.grammar.haxe.HxPredBuild.build({ trivia: true }))
@:nullSafety(Strict)
final class AstPredsT {}
