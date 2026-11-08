package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Under the compiled defaults an object literal decides its break by FIT, and a ternary or an arrow around it lays
 * itself out in one write as the next write reads that literal back, broken. Each fixture is written once from a flat
 * source and must land on a layout the writer keeps.
 */
@:nullSafety(Strict)
final class HxFitPivotLiteralFixedPointTest extends Test {

	public function new(): Void {
		super();
	}

	/** A ternary branch literal that breaks keeps the ternary on its line: the next write reads the broken literal and glues it. */
	@:pin('control')
	@:killer('M-TERNARY-NAMES-FIT-PIVOT')
	public function testATernaryBranchLiteralGluesOnceItBreaks(): Void {
		final k: String = ''.lpad('k', 100);
		settlesOn(
			statement('return value == null ? null : {first: firstValue, second: secondValue, third: \'$k\'};'),
			statement('return value == null ? null : {\n\t\t\tfirst: firstValue,\n\t\t\tsecond: secondValue,\n\t\t\tthird: \'$k\'\n\t\t};')
		);
	}

	/**
	 * A literal inside a call operand of a ternary breaks the ternary as the literal itself would: the call is multi-line.
	 * Nothing names that literal by fit, so the renderer's own fit decision settles it; naming it in a host the ternary does
	 * not see would leave the ternary flat on the first write.
	 */
	@:pin('guard')
	public function testACallOperandHoldingABreakingLiteralBreaksTheTernary(): Void {
		final k: String = ''.lpad('k', 80);
		final span: String = 'span: lineExtendedSpan(source, new Span(thenSpan.to, nspan.to))';
		settlesOn(
			statement('if (a) {\n\t\t\treturn thenSpan == null ? keep(other) : remove({$span, text: \'$k\'});\n\t\t}'),
			statement(
				'if (a) {\n\t\t\treturn thenSpan == null\n\t\t\t\t? keep(other)\n\t\t\t\t: remove({\n\t\t\t\t\t$span,\n'
				+ '\t\t\t\t\ttext: \'$k\'\n\t\t\t\t});\n\t\t}'
			)
		);
	}

	/** Both branch literals of one ternary break: the ternary is laid out with both broken, not with one of them. */
	@:pin('control')
	@:killer('M-OFFER-COMBINED')
	public function testTwoBreakingBranchLiteralsSettleInOneWrite(): Void {
		final k: String = ''.lpad('k', 150);
		settlesOn(
			statement('inserts.push(args.length == 0 ? {first: firstValue, second: \'$k\'} : {first: otherValue, second: \'$k\'});'),
			statement(
				'inserts.push(args.length == 0\n\t\t\t? {\n\t\t\t\tfirst: firstValue,\n\t\t\t\tsecond: \'$k\'\n\t\t\t}\n'
				+ '\t\t\t: {\n\t\t\t\tfirst: otherValue,\n\t\t\t\tsecond: \'$k\'\n\t\t\t});'
			)
		);
	}

	/** An arrow whose literal body breaks keeps the literal on the arrow's line, where the next write glues it. */
	@:pin('control')
	@:killer('M-ARROW-LITERAL-NAMED')
	public function testAnArrowLiteralBodyGluesOnceItBreaks(): Void {
		final k: String = ''.lpad('k', 100);
		settlesOn(
			statement('check(sources, {sources: () -> {report: report, projectRoots: [], library: \'$k\'}});'),
			statement(
				'check(sources, {\n\t\t\tsources: () -> {\n\t\t\t\treport: report,\n\t\t\t\tprojectRoots: [],\n'
				+ '\t\t\t\tlibrary: \'$k\'\n\t\t\t}\n\t\t});'
			)
		);
	}

	/** `src` written once under the compiled defaults is `expected`, and `expected` is its own fixed point. */
	private static function settlesOn(src: String, expected: String): Void {
		Assert.equals(expected, HxWriteFixture.triviaWrite(src, HxWriteFixture.listsKeepSource('{}')), src);
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, HxWriteFixture.listsKeepSource('{}')));
	}

	private static function statement(s: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$s\n\t}\n}';
	}

}
