package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.common.control.PreferIfExpressionChain;
import anyparse.check.common.control.PreferIfExpressionReturn;
import anyparse.check.haxe.expressions.PreferReflectCompare;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;

/**
 * The `prefer-reflect-compare` check: a sort callback spelling a three-way comparison of two `Int` or two `String` operands
 * by hand — a ternary chain, an if-expression chain, or closing `if … return` statements — is flagged `Info`, and rewritten
 * to `Reflect.compare(a, b)` (the operands swapped for a descending chain) where both operands are proved non-null; any other
 * site is reported without a fix. Anything that is not exactly that function of pure operands of those types stays silent.
 */
class PreferReflectCompareCheckTest extends Test {

	public function testTernaryChainFlaggedAndFixed(): Void {
		final src: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-reflect-compare', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));'), applyFix(src));
	}

	/** On `null` the call answers `-1` in both argument orders where the chain answers `0`: no proof of non-null, no fix. */
	@:pin('control')
	@:killer('M-RCMP-ANY-NONNULL')
	public function testOperandsNotProvedNonNullAreReportedWithoutFix(): Void {
		final src: String = sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('no fix') >= 0);
		Assert.equals(src, applyFix(src));
		final text: String = ints('xs.sort((a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0);');
		Assert.equals(1, violations(text).length);
		Assert.equals(text, applyFix(text));
		final own: String = 'class C {\n\n\tvar own:Int;\n\tvar own2:Int;\n\n\tfunction f(xs:Array<Int>):Void {\n'
			+ '\t\txs.sort((a:Int, b:Int) -> own < own2 ? -1 : own > own2 ? 1 : 0);\n\t}\n}';
		Assert.equals(1, violations(own).length);
		Assert.equals(own, applyFix(own));
	}

	/** One proved operand is not enough: the call answers differently when the other is null. */
	@:pin('control')
	@:killer('M-RCMP-NONNULL-EITHER')
	public function testOneProvedOperandIsReportedWithoutFix(): Void {
		final src: String = sorted('xs.sort((a:Item, b:Item) -> c < b.n ? -1 : c > b.n ? 1 : 0);')
			.split('b:Item):Void')
			.join('b:Item, c:Int):Void');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/** A null-safe class proves its `String` parameters non-null, so they are fixed. */
	public function testStringOperandsOfANullSafeClassFixed(): Void {
		final head: String = '@:nullSafety(Strict)\nclass C {\n\n\tfunction f(xs:Array<String>):Void {\n\t\t';
		final src: String = '${head}xs.sort((a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0);\n\t}\n}';
		final run: FixRun = CheckFixture.fixRun(new PreferReflectCompare(), CheckFixture.withStd(src));
		Assert.equals(1, run.violations.length);
		Assert.equals('${head}xs.sort((a:String, b:String) -> Reflect.compare(a, b));\n\t}\n}', CanonicalEdit.applyEdits(src, run.edits));
	}

	/** Untyped parameters take the element type of their own array, not that of an outer `a` and `b`. */
	public function testUntypedParametersShadowingOuterIntsAreNotProved(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Array.hx', source: 'extern class Array<T> { function sort(f:(T, T) -> Int):Void; }' },
			{
				file: 'C.hx',
				source: 'class C {\n\n\tfunction f(xs:Array<Null<Int>>, a:Int, b:Int):Void {\n'
					+ '\t\txs.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);\n\t}\n}'
			}
		];
		Assert.equals(0, CheckFixture.violationsIn(new PreferReflectCompare(), files).length);
	}

	public function testStringFieldOperandsReported(): Void {
		Assert.equals(1, violations(sorted('xs.sort((a:Item, b:Item) -> a.s < b.s ? -1 : a.s > b.s ? 1 : 0);')).length);
	}

	public function testIfExpressionChainFixed(): Void {
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> if (a < b) -1 else if (a > b) 1 else 0);'))
		);
	}

	public function testReturnedChainInBlockFixed(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { trace(1); return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); return a < b ? -1 : a > b ? 1 : 0; });'))
		);
	}

	/** A function literal whose body is the bare `return` statement, with a written result type. */
	public function testReturnStatementBodyFixed(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int):Int return Reflect.compare(a, b));'),
			applyFix(ints('xs.sort(function(a:Int, b:Int):Int return a < b ? -1 : a > b ? 1 : 0);'))
		);
	}

	public function testClosingIfReturnStatementsFixed(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { trace(1); return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
	}

	/** A multi-key cascade: only the last key's three statements are the three-way comparison. */
	public function testMultiKeyCascadeRewritesTheLastKeyOnly(): Void {
		final head: String =
			'xs.sort(function(a:Int, b:Int) { final c:Int = 1; final d:Int = 2; if (a < b) return -1; if (a > b) return 1; ';
		Assert.equals(
			ints('${head}return Reflect.compare(c, d); });'),
			applyFix(ints('${head}if (c < d) return -1; if (c > d) return 1; return 0; });'))
		);
	}

	public function testElseIfReturnChainFixed(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { if (a < b) { return -1; } else if (a > b) return 1; else return 0; });'))
		);
	}

	/**
	 * A descending chain and a `>` first spelling are the ascending comparison
	 * of the swapped operands: `a < b ? 1 : …` is `Reflect.compare(b, a)`.
	 */
	public function testDescendingAndGreaterFirstSwapOperands(): Void {
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(b, a));'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> a < b ? 1 : a > b ? -1 : 0);'))
		);
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> a > b ? 1 : a < b ? -1 : 0);'))
		);
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> b < a ? 1 : a < b ? -1 : 0);'))
		);
	}

	/** A `Float` operand answers `0` for a `NaN` where `Reflect.compare` answers a sign; an unknown type proves nothing. */
	@:pin('control')
	@:killer('M-RCMP-ANY-OPERAND-TYPE')
	public function testOnlyIntAndStringOperands(): Void {
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.f < b.f ? -1 : a.f > b.f ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a, b) -> a.q < b.q ? -1 : a.q > b.q ? 1 : 0);')).length);
	}

	/** The chain reads each operand twice, the call once. */
	@:pin('control')
	@:killer('M-RCMP-IMPURE-OPERAND')
	public function testImpureOperandNotFlagged(): Void {
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.g < b.n ? -1 : a.g > b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.g ? -1 : a.n > b.g ? 1 : 0);')).length);
	}

	/** Two comparisons of the same operands in opposite directions, valued -1 and 1 and closed by 0, or another function. */
	@:pin('control')
	@:killer('M-RCMP-ANY-TERMINAL')
	public function testOtherFunctionsNotFlagged(): Void {
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n >= b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n <= b.n ? -1 : a.n > b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -2 : a.n > b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? -1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 2);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.m > b.m ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n < b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : 1);')).length);
		Assert.equals(0, violations(sorted('xs.sort(function(a:Item, b:Item) { if (a.n < b.n) return -1; return 1; });')).length);
	}

	/** Only the sign of a sort comparator's result is read: elsewhere the exact `-1` / `1` may be. */
	@:pin('control')
	@:killer('M-RCMP-ANY-CALL')
	public function testOnlySortCallbacks(): Void {
		Assert.equals(0, violations(sorted('final cmp = (a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0;')).length);
		Assert.equals(0, violations(sorted('xs.map((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('xs.sort((a:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);')).length);
		Assert.equals(0, violations(sorted('final r = a.n < b.n ? -1 : a.n > b.n ? 1 : 0;')).length);
	}

	/** The fix would delete a comment inside the replaced text. */
	public function testCommentInsideNotFlagged(): Void {
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 /* low */ : a.n > b.n ? 1 : 0);')).length);
		Assert.equals(1, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0); // sorted')).length);
	}

	public function testRegisteredDefaultOff(): Void {
		Assert.notNull(Linter.byId('prefer-reflect-compare'));
		Assert.isTrue(Std.isOfType(new PreferReflectCompare(), DefaultOff));
		Assert.isTrue(new PreferReflectCompare().supersedes().contains('prefer-if-expression-chain'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A parameter written without a type takes its element type from the array the callback is handed to. */
	public function testUntypedParametersTakeTheElementType(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Array.hx', source: 'extern class Array<T> { function sort(f:(T, T) -> Int):Void; }' }
		].concat([
			{ file: 'C.hx', source: sorted('xs.sort((a, b) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);') }
		]);
		Assert.equals(1, CheckFixture.violationsIn(new PreferReflectCompare(), files).length);
	}

	/** A parenthesised return, and the closing statements of a block, are also the other rules' findings: only this one stays. */
	public function testSupersedesTheRulesThatReadTheSameChain(): Void {
		final plugin: GrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final checks: Array<Check> = [
			new PreferReflectCompare(),
			new PreferIfExpressionChain(),
			new PreferIfExpressionReturn()
		];
		for (statement in [
			'xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);',
			'xs.sort(function(a:Int, b:Int) { if (a < b) { return -1; } else if (a > b) { return 1; } else { return 0; } });',
			'xs.sort(function(a:Int, b:Int) { return (a < b ? -1 : a > b ? 1 : 0); });',
			'xs.sort(function(a:Int, b:Int) { if (a < b) return -1; if (a > b) return 1; return 0; });'
		]) {
			final found: Array<Violation> = Linter.collect([{ file: 'C.hx', source: ints(statement) }], plugin, checks, null, false);
			Assert.equals(1, found.length, statement);
			Assert.equals('prefer-reflect-compare', found[0].rule);
		}
		// A report-only finding still replaces the fixable findings of the rules it supersedes on the same chain.
		final fields: Array<Violation> = Linter.collect([
			{ file: 'C.hx', source: sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);') }
		], plugin, checks, null, false);
		Assert.equals(1, fields.length);
		Assert.equals('prefer-reflect-compare', fields[0].rule);
		Assert.isTrue(fields[0].message.indexOf('no fix') >= 0);
	}

	/** A parenthesis around the returned chain stays; only the chain is replaced. */
	public function testParenthesisedChainKeepsItsParentheses(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { return (Reflect.compare(a, b)); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { return (a < b ? -1 : a > b ? 1 : 0); });'))
		);
	}

	/** The two comparisons read the same operands whatever the runs of whitespace inside them. */
	public function testOperandSpacingInsideAnOperandDoesNotMatter(): Void {
		Assert.equals(1, violations(sorted('xs.sort((a:Item, b:Item) -> a.n + 1 < b.n ? -1 : a.n  +   1 > b.n ? 1 : 0);')).length);
	}

	/** An operand of one type against an operand of another is not one comparison of two values. */
	@:pin('control')
	@:killer('M-RCMP-MIXED-OPERANDS')
	public function testMixedOperandTypesNotFlagged(): Void {
		Assert.equals(0, violations(sorted('xs.sort((a:Item, b:Item) -> a.n < b.f ? -1 : a.n > b.f ? 1 : 0);')).length);
	}

	/** A comment between the statements of the closing chain would be deleted by the fix. */
	public function testCommentBetweenClosingStatementsNotFlagged(): Void {
		Assert.equals(
			0,
			violations(ints('xs.sort(function(a:Int, b:Int) { if (a < b) return -1; /* mid */ if (a > b) return 1; return 0; });')).length
		);
	}

	/** The element type of the receiver array, not an outer variable of the same name, types an untyped parameter. */
	public function testUntypedParametersAreTypedByTheirOwnArray(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Array.hx', source: 'extern class Array<T> { function sort(f:(T, T) -> Int):Void; }' },
			{
				file: 'C.hx',
				source: 'class Item { public var n:Int; }\nclass Other { public var n:Float; public var f:Int; }\nclass C {\n\n'
					+ '\tfunction f(xs:Array<Other>, a:Item):Void {\n\t\txs.sort((a, b) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);\n'
					+ '\t\txs.sort((a, b) -> a.f < b.f ? -1 : a.f > b.f ? 1 : 0);\n\t}\n}'
			}
		];
		Assert.equals(1, CheckFixture.violationsIn(new PreferReflectCompare(), files).length);
	}

	/** An arrow lambda's block body is read like a `function` literal's. */
	public function testArrowBlockBodiesFixed(): Void {
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> { return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> { return a < b ? -1 : a > b ? 1 : 0; });'))
		);
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> { return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> { if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
	}

	private function sorted(statement: String): String {
		return 'class Item {\n\tpublic var n:Int;\n\tpublic var m:Int;\n\tpublic var f:Float;\n\tpublic var s:String;\n'
			+ '\tpublic var g(get, never):Int;\n\tfunction get_g():Int return 1;\n}\n\nclass C {\n\n'
			+ '\tfunction f(xs:Array<Item>, a:Item, b:Item):Void {\n\t\t$statement\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferReflectCompare(), src);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new PreferReflectCompare(), src);
	}

	private function ints(statement: String): String {
		return 'class C {\n\n\tfunction f(xs:Array<Int>):Void {\n\t\t$statement\n\t}\n}';
	}

}
