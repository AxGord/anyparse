package unit.lowering;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AccessorClause;

/**
 * The span-only capture mode (`@:spanCapture`): `HxAccessClause` gets a `_span` from the rule entry to past its
 * closing `)`, and `AccessorClause.span` carries it — keyed, like the clause, by the declaring member's span start.
 */
@:nullSafety(Strict)
final class AccessClauseSpanCaptureTest extends Test {

	/** The clause span covers the accessors and the closing paren; the opening `(` is the declaration's lead. */
	@:pin('control')
	@:killer('M-ACCESS-CLAUSE-SPAN-DROPPED')
	public function testTheClauseSpanCoversAccessorsAndClosingParen(): Void {
		Assert.same(['get, never)'], clauseTexts('class P {\n\tvar x(get, never): Int;\n}'));
	}

	/**
	 * The span starts at the first accessor: the blank after the `(` is already skipped at the rule entry, so the
	 * opening paren is not at `span.from - 1` and a consumer needing it reads the declaration's lead.
	 */
	@:pin('control')
	@:killer('M-SPAN-CAPTURE-START-SHIFTED')
	public function testTheClauseSpanStartsAfterTheBlankAfterTheParen(): Void {
		Assert.same(['get , never )'], clauseTexts('class P {\n\tvar x(  get , never ):Int;\n}'));
	}

	/** The source text under each clause span, in source order. */
	private static function clauseTexts(src: String): Array<String> {
		final clauses: Map<Int, AccessorClause> = new HaxeQueryPlugin().accessorClauses(src);
		final keys: Array<Int> = [for (k in clauses.keys()) k];
		keys.sort((a, b) -> a - b);
		final out: Array<String> = [];
		for (k in keys) {
			final c: Null<AccessorClause> = clauses[k];
			if (c != null) out.push(src.substring(c.span.from, c.span.to));
		}
		return out;
	}

}
