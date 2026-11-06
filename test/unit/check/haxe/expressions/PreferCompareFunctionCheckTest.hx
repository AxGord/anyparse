package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.common.control.PreferIfExpressionChain;
import anyparse.check.common.control.PreferIfExpressionReturn;
import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.check.haxe.expressions.PreferCompareFunction;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;

/**
 * The `prefer-compare-function` check: a sort callback spelling a three-way comparison of two `Int` or two `String` operands
 * by hand — a ternary chain, an if-expression chain, or closing `if … return` statements — is flagged `Info`, and rewritten
 * to the function named for their type, else `Reflect.compare(a, b)` (the operands
 * swapped for a descending chain), where both operands are proved non-null; any other
 * site is reported without a fix. Anything that is not exactly that function of pure operands of those types stays silent.
 */
class PreferCompareFunctionCheckTest extends Test {

	private static inline final NAMED: String =
		'{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"Int":"lib.Order.ints","String":"lib.Order.texts"}}}}';
	private static inline final STRING_ONLY: String =
		'{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"String":"lib.Order.texts"}}}}';
	private static inline final ORDER: String =
		'package lib;\nclass Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n\tpublic static function texts(a:String, b:String):Int return 0;\n}';

	public function testTernaryChainFlaggedAndFixed(): Void {
		final src: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-compare-function', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(ints('xs.sort(Reflect.compare);'), applyFix(src));
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
		final run: FixRun = CheckFixture.fixRun(new PreferCompareFunction(), CheckFixture.withStd(src));
		Assert.equals(1, run.violations.length);
		Assert.equals('${head}xs.sort(Reflect.compare);\n\t}\n}', CanonicalEdit.applyEdits(src, run.edits));
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
		Assert.equals(0, CheckFixture.violationsIn(new PreferCompareFunction(), files).length);
	}

	public function testStringFieldOperandsReported(): Void {
		Assert.equals(1, violations(sorted('xs.sort((a:Item, b:Item) -> a.s < b.s ? -1 : a.s > b.s ? 1 : 0);')).length);
	}

	public function testIfExpressionChainFixed(): Void {
		Assert.equals(
			ints('xs.sort(Reflect.compare);'), applyFix(ints('xs.sort((a:Int, b:Int) -> if (a < b) -1 else if (a > b) 1 else 0);'))
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
			ints('xs.sort(Reflect.compare);'), applyFix(ints('xs.sort(function(a:Int, b:Int):Int return a < b ? -1 : a > b ? 1 : 0);'))
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
			ints('xs.sort(Reflect.compare);'),
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
		Assert.equals(ints('xs.sort(Reflect.compare);'), applyFix(ints('xs.sort((a:Int, b:Int) -> a > b ? 1 : a < b ? -1 : 0);')));
		Assert.equals(ints('xs.sort(Reflect.compare);'), applyFix(ints('xs.sort((a:Int, b:Int) -> b < a ? 1 : a < b ? -1 : 0);')));
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
		Assert.notNull(Linter.byId('prefer-compare-function'));
		Assert.isNull(Linter.byId('prefer-reflect-compare'));
		Assert.isTrue(Std.isOfType(new PreferCompareFunction(), DefaultOff));
		Assert.isTrue(new PreferCompareFunction().supersedes().contains('prefer-if-expression-chain'));
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
		Assert.equals(1, CheckFixture.violationsIn(new PreferCompareFunction(), files).length);
	}

	/** A parenthesised return, and the closing statements of a block, are also the other rules' findings: only this one stays. */
	public function testSupersedesTheRulesThatReadTheSameChain(): Void {
		final plugin: GrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final checks: Array<Check> = [
			new PreferCompareFunction(),
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
			Assert.equals('prefer-compare-function', found[0].rule);
		}
		// A report-only finding still replaces the fixable findings of the rules it supersedes on the same chain.
		final fields: Array<Violation> = Linter.collect([
			{ file: 'C.hx', source: sorted('xs.sort((a:Item, b:Item) -> a.n < b.n ? -1 : a.n > b.n ? 1 : 0);') }
		], plugin, checks, null, false);
		Assert.equals(1, fields.length);
		Assert.equals('prefer-compare-function', fields[0].rule);
		Assert.isTrue(fields[0].message.indexOf('no fix') >= 0);
	}

	/** A parenthesis around a returned chain stays where the callback holds more than it; only the chain is replaced. */
	public function testParenthesisedChainKeepsItsParentheses(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { trace(1); return (Reflect.compare(a, b)); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); return (a < b ? -1 : a > b ? 1 : 0); });'))
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
		Assert.equals(1, CheckFixture.violationsIn(new PreferCompareFunction(), files).length);
	}

	/** An arrow lambda's block body is read like a `function` literal's. */
	public function testArrowBlockBodiesFixed(): Void {
		Assert.equals(
			ints('xs.sort(Reflect.compare);'), applyFix(ints('xs.sort((a:Int, b:Int) -> { return a < b ? -1 : a > b ? 1 : 0; });'))
		);
		Assert.equals(
			ints('xs.sort(Reflect.compare);'),
			applyFix(ints('xs.sort((a:Int, b:Int) -> { if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
	}

	/** The operands are the callback's own parameters in order and the chain is all it holds: no lambda stays around the function. */
	public function testBareParametersWriteTheFunctionItself(): Void {
		Assert.equals(importing(ints('xs.sort(Order.ints);')), namedFix(ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);')));
		Assert.equals(
			importing(ints('xs.sort(Order.ints);')),
			namedFix(ints('xs.sort(function(a:Int, b:Int) { if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
		Assert.equals(
			importing(strings('xs.sort(Order.texts);')), namedFix(strings('xs.sort((a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0);'))
		);
		Assert.equals(
			ints('xs.sort(Reflect.compare);'), namedFix(ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);'), STRING_ONLY)
		);
	}

	/** A swapped comparison, or a chain with more beside it in the callback, is no reference to the function: the lambda stays. */
	@:pin('control')
	@:killer('M-RCMP-BARE-ANY-ORDER')
	public function testOtherOperandsKeepTheLambdaAroundTheNamedCall(): Void {
		Assert.equals(
			importing(ints('xs.sort((a:Int, b:Int) -> Order.ints(b, a));')),
			namedFix(ints('xs.sort((a:Int, b:Int) -> a < b ? 1 : a > b ? -1 : 0);'))
		);
		Assert.equals(
			importing(ints('xs.sort(function(a:Int, b:Int) { trace(1); return Order.ints(a, b); });')),
			namedFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
	}

	/** A parameter holding a default value is no plain binder, and passing the function itself would drop that value. */
	public function testDefaultedParameterKeepsTheLambda(): Void {
		final src: String = ints('xs.sort((a:Int, ?b:Int = 1) -> a < b ? -1 : a > b ? 1 : 0);');
		Assert.equals(-1, namedFix(src).indexOf('xs.sort(Order.ints)'));
	}

	/** A statement chain beside another statement is not the whole callback, whatever the parameters. */
	@:pin('control')
	@:killer('M-RCMP-BARE-NOT-WHOLE')
	public function testChainBesideAStatementIsNotTheWholeCallback(): Void {
		Assert.equals(
			ints('xs.sort(function(a:Int, b:Int) { trace(1); return Reflect.compare(a, b); });'),
			applyFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); if (a < b) return -1; if (a > b) return 1; return 0; });'))
		);
	}

	/** Written around the two parameters, the existing call goes with its lambda; written around anything else, only the call moves. */
	@:pin('control')
	@:killer('M-RCMP-MOVE-IGNORED')
	public function testReflectCallInACallbackMovesToTheNamedFunction(): Void {
		Assert.equals(importing(ints('xs.sort(Order.ints);')), namedFix(ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));')));
		Assert.equals(
			importing(ints('xs.sort(Order.ints);')), namedFix(ints('xs.sort(function(a:Int, b:Int) { return Reflect.compare(a, b); });'))
		);
		Assert.equals(
			importing(ints('xs.sort((a:Int, b:Int) -> Order.ints(b, a));')),
			namedFix(ints('xs.sort((a:Int, b:Int) -> Reflect.compare(b, a));'))
		);
		final found: Array<Violation> = namedRun(ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));')).violations;
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('Order.ints') >= 0);
	}

	/** The call-site `inline` goes with the call it wrapped. */
	public function testInlineReflectCallMovesWithoutItsInline(): Void {
		Assert.equals(importing(ints('xs.sort(Order.ints);')), namedFix(ints('xs.sort((a:Int, b:Int) -> inline Reflect.compare(a, b));')));
		Assert.equals(
			importing(ints('xs.sort((a:Int, b:Int) -> Order.ints(b, a));')),
			namedFix(ints('xs.sort((a:Int, b:Int) -> inline Reflect.compare(b, a));'))
		);
		Assert.equals(
			importing(ints('xs.sort(function(a:Int, b:Int) { trace(1); return Order.ints(a, b); });')),
			namedFix(ints('xs.sort(function(a:Int, b:Int) { trace(1); return inline Reflect.compare(a, b); });'))
		);
	}

	/** `xs.sort(Reflect.compare)` moves only where the element type of `xs` is proved and that type is named. */
	@:pin('control')
	@:killer('M-RCMP-BARE-ANY-ELEMENT')
	public function testBareReflectMovesByTheElementType(): Void {
		Assert.equals(importing(ints('xs.sort(Order.ints);')), namedFix(ints('xs.sort(Reflect.compare);')));
		Assert.equals(importing(strings('xs.sort(Order.texts);')), namedFix(strings('xs.sort(Reflect.compare);')));
		for (element in ['Float', 'Null<Int>', 'Item']) {
			final src: String =
				'class Item {}\nclass C {\n\n\tfunction f(xs:Array<$element>):Void {\n\t\txs.sort(Reflect.compare);\n\t}\n}';
			Assert.equals(0, namedRun(src).violations.length, element);
			Assert.equals(src, namedFix(src), element);
		}
		final unknown: String = 'class C {\n\n\tfunction f(xs:Dynamic):Void {\n\t\txs.sort(Reflect.compare);\n\t}\n}';
		Assert.equals(0, namedRun(unknown).violations.length);
	}

	/** A type the project does not name keeps `Reflect.compare`: a chain is rewritten to it, an existing call stays silent. */
	@:pin('control')
	@:killer('M-RCMP-ANY-NAMED')
	public function testTypeNotNamedKeepsReflect(): Void {
		final moved: String = ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));');
		Assert.equals(0, namedRun(moved, STRING_ONLY).violations.length);
		Assert.equals(0, namedRun(ints('xs.sort(Reflect.compare);'), STRING_ONLY).violations.length);
		Assert.equals(0, CheckFixture.fixRunUnder(new PreferCompareFunction(), moved, '{}').violations.length);
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(b, a));'),
			namedFix(ints('xs.sort((a:Int, b:Int) -> a < b ? 1 : a > b ? -1 : 0);'), STRING_ONLY)
		);
	}

	/** Moving a call over a possible null changes the answer as much as rewriting a chain does: the finding stands without a fix. */
	@:pin('control')
	@:killer('M-RCMP-MOVE-NONNULL')
	public function testMovedCallOverUnprovedOperandsIsReportedWithoutFix(): Void {
		final src: String = sorted('xs.sort((a:Item, b:Item) -> Reflect.compare(a.n, b.n));');
		final found: Array<Violation> = namedRun(src).violations;
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('no fix') >= 0);
		Assert.equals(src, namedFix(src));
	}

	/** A function another function holds is not this callback, and a `Reflect` the project declares or binds is not the std one. */
	public function testOnlyTheStdCallInTheCallbackOwnBodyMoves(): Void {
		final nested: String = ints('xs.sort((a:Int, b:Int) -> { final f = (c:Int, d:Int) -> Reflect.compare(c, d); return f(a, b); });');
		Assert.equals(0, namedRun(nested).violations.length);
		final own: String = 'class Reflect {\n\tpublic static function compare(a:Int, b:Int):Int return 0;\n}\n'
			+ ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));\n\t\txs.sort(Reflect.compare);');
		Assert.equals(0, namedRun(own).violations.length);
		final local: String = ints(
			'final Reflect = 1;\n\t\txs.sort((a:Int, b:Int) -> Reflect.compare(a, b));\n\t\txs.sort(Reflect.compare);'
		);
		Assert.equals(0, namedRun(local).violations.length);
	}

	/** Outside null safety a `String` element may be `null`, where `Reflect.compare` and the typed function answer differently. */
	public function testBareReferenceOverAStringOutsideNullSafetyIsReportedWithoutFix(): Void {
		final src: String = 'class C {\n\n\tfunction f(xs:Array<String>):Void {\n\t\txs.sort(Reflect.compare);\n\t}\n}';
		final found: Array<Violation> = namedRun(src).violations;
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('no fix') >= 0);
		Assert.equals(src, namedFix(src));
	}

	/** A comment the rewrite would delete keeps the callback, in the lambda around a chain as in the lambda around a call. */
	public function testCommentInTheReplacedFunctionStaysSilent(): Void {
		for (statement in [
			'xs.sort((a:Int, /* low */ b:Int) -> a < b ? -1 : a > b ? 1 : 0);',
			'xs.sort((a:Int, /* low */ b:Int) -> Reflect.compare(a, b));'
		]) Assert.equals(0, namedRun(ints(statement)).violations.length, statement);
	}

	/** An import goes in once for the sites that need it, with the sites as one group the verifier keeps or drops together. */
	@:pin('control')
	@:killer('M-RCMP-IMPORT-LOST')
	public function testImportAddedOnceAndGroupedWithItsSites(): Void {
		final holder: String =
			'class C {\n\n\tfunction f(xs:Array<Int>, ys:Array<Int>):Void {\n\t\txs.sort($$FN);\n\t\tys.sort($$FN);\n\t}\n}';
		final src: String = holder.split('$$FN').join('Reflect.compare');
		Assert.equals(importing(holder.split('$$FN').join('Order.ints')), namedFix(src));
		final check: PreferCompareFunction = new PreferCompareFunction();
		check.setConfigResolver(_ -> LintConfig.parse(NAMED));
		final groups: Array<Null<Int>> = check.fixGrouped(
			src, namedRun(src).violations, new CachingGrammarPlugin(new HaxeQueryPlugin()), CheckFixture.index(namedFiles(src))
		)
			.map(e -> e.group);
		Assert.equals(3, groups.length);
		Assert.notNull(groups[0]);
		Assert.equals(groups[0], groups[1]);
		Assert.equals(groups[0], groups[2]);
	}

	/** A type already visible needs no import, whatever makes it so. */
	public function testVisibleTypeTakesNoImport(): Void {
		Assert.equals(importing(ints('xs.sort(Order.ints);')), namedFix(importing(ints('xs.sort(Reflect.compare);'))));
		Assert.equals('package lib;\n' + ints('xs.sort(Order.ints);'), namedFix('package lib;\n' + ints('xs.sort(Reflect.compare);')));
	}

	/** A name the index cannot find is an error, and no site of the file falls back to `Reflect.compare` behind it. */
	@:pin('control')
	@:killer('M-RCMP-UNRESOLVED-SILENT')
	public function testUnresolvedNameIsAConfigurationError(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		for (path in ['lib.Gone.ints', 'lib.Order.gone']) {
			final run: FixRun = namedRun(chain, namedInt(path));
			final all: Array<Violation> = CheckFixture.violationsIn(
				new PreferCompareFunction(), namedFiles(chain), null, _ -> LintConfig.parse(namedInt(path))
			);
			Assert.equals(1, all.length, path);
			Assert.equals(Severity.Error, all[0].severity, path);
			Assert.isNull(all[0].span, path);
			Assert.equals('C.hx', all[0].file, path);
			Assert.isTrue(all[0].message.indexOf(path) >= 0, path);
			Assert.equals(0, run.edits.length, path);
		}
	}

	/** A signature other than `(T, T): Int` is an error, for each way a declaration can miss it. */
	@:pin('control')
	@:killer('M-RCMP-ANY-SIGNATURE')
	public function testWrongSignatureIsAConfigurationError(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		for (member in [
			'public static function x(a:Int, b:Float):Int return 0;',
			'public static function x(a:Null<Int>, b:Int):Int return 0;',
			'public static function x(a:Int, b:Int):Bool return true;',
			'public static function x(a:Int):Int return 0;',
			'public static function x(a:Int, b:Int, c:Int):Int return 0;',
			'public static function x(a:Int, ?b:Int):Int return 0;',
			'public static function x<T>(a:T, b:T):Int return 0;',
			'private static function x(a:Int, b:Int):Int return 0;',
			'public function x(a:Int, b:Int):Int return 0;',
			'public static var x:Int = 0;'
		]) {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'C.hx', source: chain },
				{ file: 'lib/Bad.hx', source: 'package lib;\nclass Bad {\n\t$member\n}' }
			];
			final all: Array<Violation> = CheckFixture.violationsIn(
				new PreferCompareFunction(), files, null, _ -> LintConfig.parse(namedInt('lib.Bad.x'))
			);
			Assert.equals(1, all.length, member);
			Assert.equals(Severity.Error, all[0].severity, member);
		}
	}

	/** An option of the wrong shape is an error too, each said by name. */
	public function testMalformedOptionIsAConfigurationError(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		for (option in [
			'"lib.Order.ints"',
			'{"Float":"lib.Order.ints"}',
			'{"Int":3}',
			'{"Int":"ints"}',
			'{"Int":"lib.Order."}'
		]) {
			final json: String = '{"rules":{"prefer-compare-function":{"enabled":true,"compare":$option}}}';
			final all: Array<Violation> = CheckFixture.violationsIn(
				new PreferCompareFunction(), namedFiles(chain), null, _ -> LintConfig.parse(json)
			);
			Assert.equals(1, all.length, option);
			Assert.equals(Severity.Error, all[0].severity, option);
		}
	}

	/** One problem of one option is said once, whatever number of files it governs. */
	public function testAConfigurationErrorIsSaidOnce(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final files: Array<{ file: String, source: String }> = namedFiles(chain).concat([{ file: 'D.hx', source: chain }]);
		Assert.equals(
			1, CheckFixture.violationsIn(new PreferCompareFunction(), files, null, _ -> LintConfig.parse(namedInt('lib.Gone.ints'))).length
		);
	}

	/** The removed option writes nothing: the fix never spells a call-site `inline`. */
	public function testInlineOptionIsGone(): Void {
		final json: String = '{"rules":{"prefer-compare-function":{"enabled":true,"inline":true}}}';
		Assert.equals(
			ints('xs.sort((a:Int, b:Int) -> Reflect.compare(b, a));'),
			CheckFixture.fixedUnder(new PreferCompareFunction(), ints('xs.sort((a:Int, b:Int) -> a < b ? 1 : a > b ? -1 : 0);'), json)
		);
	}

	/** A moved lambda is also the wrapper rule's finding: only this one stays, and with no name the wrapper rule keeps its own. */
	public function testSupersedesTheWrapperRuleOnAMovedLambda(): Void {
		final files: Array<{ file: String, source: String }> = namedFiles(ints('xs.sort((a:Int, b:Int) -> Reflect.compare(a, b));'));
		final scoped: GrammarPlugin = StdScope.plugin(files);
		function rulesUnder(json: String): String {
			final compare: PreferCompareFunction = new PreferCompareFunction();
			final config: LintConfig = LintConfig.parse(json);
			compare.setConfigResolver(_ -> config);
			return Linter.collect(files, scoped, [compare, new RedundantLambdaWrapper()], _ -> config, false).map(v -> v.rule).join(',');
		}
		Assert.equals('prefer-compare-function', rulesUnder(NAMED));
		Assert.equals('redundant-lambda-wrapper', rulesUnder('{}'));
	}

	/**
	 * The rule is default-off, so the linter's per-file gate keeps a finding only on a file that enables it: the error has to
	 * stand on such a file, also when an earlier file of the run has the rule off, and stays away when no file enables it.
	 */
	@:pin('control')
	@:killer('M-RCMP-ERROR-NO-FILE', 'M-RCMP-ERROR-FIRST-FILE')
	public function testAConfigurationErrorReachesARunUnderEnablement(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final broken: LintConfig = LintConfig.parse(namedInt('lib.Gone.ints'));
		final off: LintConfig = LintConfig.parse(
			'{"rules":{"prefer-compare-function":{"enabled":false,"compare":{"Int":"lib.Gone.ints"}}}}'
		);
		final files: Array<{ file: String, source: String }> = [
			{ file: 'off/A.hx', source: chain },
			{ file: 'on/B.hx', source: chain },
			{ file: 'on/C.hx', source: chain },
			{ file: 'lib/Order.hx', source: ORDER }
		];
		function run(resolve: (String) -> LintConfig): Array<Violation> {
			return Linter.run(files, new CachingGrammarPlugin(new HaxeQueryPlugin()), [new PreferCompareFunction()], resolve, true);
		}
		final found: Array<Violation> = run(file -> file.indexOf('on/') == 0 ? broken : off);
		Assert.equals(1, found.length);
		Assert.equals(Severity.Error, found[0].severity);
		Assert.equals('on/B.hx', found[0].file);
		Assert.isTrue(found[0].message.indexOf('lib.Gone.ints') >= 0);
		Assert.equals(0, run(_ -> off).length);
	}

	/** Only the callback's result is read for its sign: a call that is its value, or a branch of its value, moves with a fix. */
	public function testReturnedCallsMoveWithAFix(): Void {
		Assert.equals(
			importing(ints('xs.sort((a:Int, b:Int) -> a == 1 ? Order.ints(b, a) : Order.ints(a, b));')),
			namedFix(ints('xs.sort((a:Int, b:Int) -> a == 1 ? Reflect.compare(b, a) : Reflect.compare(a, b));'))
		);
		Assert.equals(
			importing(ints('xs.sort(function(a:Int, b:Int) { if (a == 1) return Order.ints(b, a); return Order.ints(a, b); });')),
			namedFix(ints('xs.sort(function(a:Int, b:Int) { if (a == 1) return Reflect.compare(b, a); return (Reflect.compare(a, b)); });'))
		);
	}

	/** A call whose value is read for more than its sign keeps `Reflect.compare`, whose magnitude the named function need not match. */
	@:pin('control')
	@:killer('M-RCMP-MOVE-ANY-POSITION')
	public function testCallsTheCallbackDoesNotReturnAreReportedWithoutFix(): Void {
		for (statement in [
			'xs.sort((a:Int, b:Int) -> Reflect.compare(a, b) * 2 + Reflect.compare(b, a));',
			'xs.sort((a:Int, b:Int) -> Reflect.compare(a, b) == -1 ? 1 : 0);',
			'xs.sort(function(a:Int, b:Int) { final c:Int = Reflect.compare(a, b); return c != 0 ? c : 1; });'
		]) {
			final src: String = ints(statement);
			final found: Array<Violation> = namedRun(src).violations;
			Assert.isTrue(found.length > 0, statement);
			for (v in found) Assert.isTrue(v.message.indexOf('does not return') >= 0, statement);
			Assert.equals(src, namedFix(src), statement);
		}
	}

	/** `--fix` lists no findings, so the fix path is what carries a configuration error to its ledger. */
	public function testFixPathSaysTheConfigurationError(): Void {
		final src: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final run: FixRun = namedRun(src, namedInt('lib.Gone.ints'));
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		Assert.equals(run.violations[0].message, run.violations[0].declineReason);
	}

	/** A module whose class follows another type still resolves, whichever file is scanned first. */
	@:pin('control')
	@:killer('M-RCMP-FILE-SCOPED')
	public function testModuleWithAnotherTypeFirstResolves(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final order: String =
			'package lib;\nabstract Code(Int) to Int {}\nclass Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n}';
		for (head in [
			{ file: 'C.hx', source: chain },
			{ file: 'app/C.hx', source: 'package app;\n\n$chain' },
			{ file: 'app/C.hx', source: 'package app;\n\nimport lib.Code;\n\n$chain' },
			{ file: 'app/C.hx', source: 'package app;\n\nimport lib.Order.Code;\n\n$chain' },
			{ file: 'app/C.hx', source: 'package app;\n\n#if js\nusing lib.Order;\n#end\n\n$chain' }
		]) {
			final files: Array<{ file: String, source: String }> = [head, { file: 'lib/Order.hx', source: order }];
			final all: Array<Violation> = CheckFixture.violationsIn(
				new PreferCompareFunction(), files, null, _ -> LintConfig.parse(namedInt('lib.Order.ints'))
			);
			Assert.equals(1, all.length, head.source);
			Assert.notEquals(Severity.Error, all[0].severity, head.source);
		}
	}

	/** A configuration error says why: the type is absent, the type is several, or the member is absent. */
	@:pin('control')
	@:killer('M-RCMP-PRIVATE-TYPE')
	public function testConfigurationErrorNamesItsReason(): Void {
		final chain: String = ints('xs.sort((a:Int, b:Int) -> a < b ? -1 : a > b ? 1 : 0);');
		final twin: { file: String, source: String } = { file: 'alt/lib/Order.hx', source: ORDER };
		final privateMain: String = 'package lib;\nprivate class Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n}';
		final privateSub: String =
			'package lib;\nclass Order {}\nprivate class Hidden {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n}';
		final others: Array<{ file: String, source: String }> = namedFiles(chain).filter(f -> f.file != 'lib/Order.hx');
		for (reason in [
			{ path: 'lib.Order.ints', files: others.concat([{ file: 'lib/Order.hx', source: privateMain }]), said: 'names a private type' },
			{
				path: 'lib.Order.Hidden.ints',
				files: others.concat([{ file: 'lib/Order.hx', source: privateSub }]),
				said: 'names a private type'
			},
			{ path: 'lib.Gone.ints', files: namedFiles(chain), said: 'declares no "lib.Gone"' },
			{ path: 'lib.Order.gone', files: namedFiles(chain), said: 'declares no "lib.Order.gone"' },
			{ path: 'lib.Order.ints', files: namedFiles(chain).concat([twin]), said: 'is ambiguous: "lib.Order" names 2 types' }
		]) {
			final all: Array<Violation> = CheckFixture.violationsIn(
				new PreferCompareFunction(), reason.files, null, _ -> LintConfig.parse(namedInt(reason.path))
			);
			Assert.equals(1, all.length, reason.path);
			Assert.equals(Severity.Error, all[0].severity, reason.path);
			Assert.isTrue(all[0].message.indexOf(reason.said) >= 0, '${reason.path}: ${all[0].message}');
			final run: FixRun = CheckFixture.fixRun(
				new PreferCompareFunction(), reason.files, 'C.hx', null, _ -> LintConfig.parse(namedInt(reason.path))
			);
			Assert.equals(0, run.edits.length, reason.path);
		}
	}

	private function sorted(statement: String): String {
		return 'class Item {\n\tpublic var n:Int;\n\tpublic var m:Int;\n\tpublic var f:Float;\n\tpublic var s:String;\n'
			+ '\tpublic var g(get, never):Int;\n\tfunction get_g():Int return 1;\n}\n\nclass C {\n\n'
			+ '\tfunction f(xs:Array<Item>, a:Item, b:Item):Void {\n\t\t$statement\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferCompareFunction(), src);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new PreferCompareFunction(), src);
	}

	private function ints(statement: String): String {
		return 'class C {\n\n\tfunction f(xs:Array<Int>):Void {\n\t\t$statement\n\t}\n}';
	}

	private function namedFiles(source: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: source },
			{ file: 'lib/Order.hx', source: ORDER },
			{ file: 'String.hx', source: 'extern class String { function toString():String; }' }
		];
	}

	private function namedRun(source: String, json: String = NAMED): FixRun {
		return CheckFixture.fixRun(new PreferCompareFunction(), namedFiles(source), 'C.hx', null, _ -> LintConfig.parse(json));
	}

	private function namedFix(source: String, json: String = NAMED): String {
		return CanonicalEdit.applyEdits(source, namedRun(source, json).edits);
	}

	private function namedInt(path: String): String {
		return '{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"Int":"$path"}}}}';
	}

	private function importing(source: String): String {
		return 'import lib.Order;\n\n$source';
	}

	/** A `String` excludes `null` only under null safety, the proof a fix asks for. */
	private function strings(statement: String): String {
		return '@:nullSafety(Strict)\nclass C {\n\n\tfunction f(xs:Array<String>):Void {\n\t\t$statement\n\t}\n}';
	}

}
