package anyparse.grammar.haxe;

#if macro
import haxe.macro.Expr;
import anyparse.macro.AstPredLowering;

/**
 * Haxe-grammar AST-predicate tables — the domain knowledge behind the
 * writer/parser shape gates, generated as TYPED per-mode functions on
 * the `AstPreds` / `AstPredsT` / `AstPredsS` marker classes (see
 * `HxPredBuild`). Replaces the runtime-introspection predicates of
 * `HxExprUtil` (`Type.enumConstructor` / `Reflect.field` over
 * `Dynamic`): each predicate keeps its knowledge here as ctor tables
 * and operand indices, and the `AstPredLowering` base turns them into
 * pattern matches of the correct per-mode constructor path and arity.
 */
final class HxAstPredLowering extends AstPredLowering {

	private static inline final HX_EXPR: String = 'anyparse.grammar.haxe.HxExpr';

	/** All generated predicate fields for this lowering's mode. */
	public function generate(): Array<Field> {
		return [arrayBracketKindField()];
	}

	/**
	 * Classify a `HxExpr.ArrayExpr` by its first element so the writer
	 * picks the matching `whitespace.bracketConfig.*` inner-padding
	 * policy. One grammar ctor covers three fork bracket kinds; the
	 * distinction lives in the first element's shape (mirrors the
	 * fork's token-based `TokenTreeCheckUtils.getBkOpenType`):
	 *
	 *  - `Arrow` (`k => v`) → map literal (1);
	 *  - `ForExpr` / `WhileExpr` (`[for …]` / `[while …]`) →
	 *    comprehension (2);
	 *  - anything else, or a null first element (empty list) → array
	 *    literal (0) — the default tight bracket has no padding either
	 *    way.
	 *
	 * Consumed by `@:fmt(bracketKindPad)` emission
	 * (`WriterLowering.arrayBracketInsidePolicySpace`), whose runtime
	 * switch maps 1 → `mapLiteralBrackets*`, 2 → `comprehensionBrackets*`,
	 * default → `arrayLiteralBrackets*`.
	 */
	private function arrayBracketKindField(): Field {
		final body: Expr = nullSwitch(ident('e'), macro 0, [
			caseOf(HX_EXPR, ['Arrow'], macro 1),
			caseOf(HX_EXPR, ['ForExpr', 'WhileExpr'], macro 2),
		], macro 0);
		return predField('arrayBracketKind', [valueArg('e', HX_EXPR)], macro : Int, body,
			'Bracket kind of an array-`[…]` ctor by its first element: 1 map literal, 2 comprehension, 0 array literal.');
	}

}
#end
