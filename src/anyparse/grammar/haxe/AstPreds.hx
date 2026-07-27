package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated PLAIN-mode AST predicates of the
 * Haxe grammar — the typed shape gates (`arrayBracketKind`, …) the
 * plain parser and plain writer call at their `@:fmt` gate emission
 * sites. See `AstPredLowering` (naming convention, per-mode pattern
 * machinery) and `HxAstPredLowering` (the predicate tables).
 *
 * Siblings: `AstPredsT` (trivia family), `AstPredsS` (spans family).
 * The class body is empty on purpose — it is generated.
 */
@:build(anyparse.grammar.haxe.HxPredBuild.build())
@:nullSafety(Strict)
final class AstPreds {}
