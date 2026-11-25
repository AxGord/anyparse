package unit.check.haxe.expressions;

import anyparse.check.haxe.expressions.PreferCompareFunction;
import anyparse.query.CanonicalEdit;

/** A sort callback whose value is the difference of two `Int` operands: it overflows, so it is rewritten to the comparison. */
class PreferCompareSubtractionTest extends Test {

	private static final BARE: String = '{"rules":{"prefer-compare-function":true}}';
	private static final NAMED: String = '{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"Int":"lib.Order.ints"}}}}';
	private static final ORDER: String = 'package lib;\nclass Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n}';

	@:pin('control')
	@:killer('M-PCF-SUB-SILENT')
	public function testAscendingSubtractionIsReportedAndFixed(): Void {
		final src: String = items('xs.sort((a:Item, b:Item) -> a.n - b.n);');
		final found: Array<Violation> = CheckFixture.fixRunUnder(new PreferCompareFunction(), src, BARE).violations;
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('overflows') >= 0, found[0].message);
		Assert.equals(items('xs.sort((a:Item, b:Item) -> Reflect.compare(a.n, b.n));'), fixed(src));
	}

	@:pin('control')
	@:killer('M-PCF-SUB-SILENT')
	public function testDescendingSubtractionKeepsItsOperandOrder(): Void {
		Assert.equals(
			items('xs.sort((a:Item, b:Item) -> Reflect.compare(b.n, a.n));'), fixed(items('xs.sort((a:Item, b:Item) -> b.n - a.n);'))
		);
	}

	public function testBlockBodyAndParenthesesAreRewritten(): Void {
		Assert.equals(
			items('xs.sort(function(a:Item, b:Item) { return Reflect.compare(a.n, b.n); });'),
			fixed(items('xs.sort(function(a:Item, b:Item) { return a.n - b.n; });'))
		);
		Assert.equals(
			items('xs.sort((a:Item, b:Item) -> Reflect.compare(a.n - a.m, b.n - b.m));'),
			fixed(items('xs.sort((a:Item, b:Item) -> (a.n - a.m) - (b.n - b.m));'))
		);
		Assert.equals(
			items('xs.sort((a:Item, b:Item) -> Reflect.compare(a.n, b.n));'), fixed(items('xs.sort((a:Item, b:Item) -> (a.n - b.n));'))
		);
	}

	public function testBareParametersWriteTheFunctionItself(): Void {
		Assert.equals(
			'class C {\n\n\tfunction f(xs:Array<Int>):Void {\n\t\txs.sort(Reflect.compare);\n\t}\n}',
			fixed('class C {\n\n\tfunction f(xs:Array<Int>):Void {\n\t\txs.sort((a:Int, b:Int) -> a - b);\n\t}\n}')
		);
	}

	public function testNamedFunctionTakesThePlaceOfReflectCompare(): Void {
		final src: String = 'class C {\n\n\tfunction f(xs:Array<Item>):Void {\n\t\txs.sort((a:Item, b:Item) -> a.n - b.n);\n\t}\n}\n'
			+ 'class Item { public var n:Int; }';
		final run: FixRun = CheckFixture.fixRun(
			new PreferCompareFunction(), [{ file: 'C.hx', source: src }, { file: 'lib/Order.hx', source: ORDER }],
			'C.hx', null, _ -> LintConfig.parse(NAMED)
		);
		Assert.equals(1, run.violations.length);
		final text: String = CanonicalEdit.applyEdits(src, run.edits);
		Assert.isTrue(text.indexOf('Order.ints(a.n, b.n)') >= 0, text);
		Assert.isTrue(text.indexOf('import lib.Order;') >= 0, text);
	}

	@:pin('control')
	@:killer('M-PCF-SUB-INT-ONLY')
	public function testFloatSubtractionIsLeftAlone(): Void {
		Assert.equals(0, violations(items('xs.sort((a:Item, b:Item) -> a.f - b.f);')).length);
	}

	@:pin('control')
	@:killer('M-PCF-SUB-ANY-OPERANDS')
	public function testSubtractionNotOfTheTwoParametersIsLeftAlone(): Void {
		Assert.equals(0, violations(items('xs.sort((a:Item, b:Item) -> a.n - a.m);')).length);
		Assert.equals(0, violations(items('xs.sort((a:Item, b:Item) -> a.n - 1);')).length);
	}

	@:pin('control')
	@:killer('M-PCF-SUB-ANY-CALL')
	public function testSubtractionOutsideASortCallbackIsLeftAlone(): Void {
		Assert.equals(0, violations(items('Lambda.fold(xs, (x: Item, acc: Int) -> x.n - acc, 0);')).length);
		Assert.equals(0, violations(items('final d: Int = xs[0].n - xs[1].n;')).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.fixRunUnder(new PreferCompareFunction(), src, BARE).violations;
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedUnder(new PreferCompareFunction(), src, BARE);
	}

	private function items(statement: String): String {
		return 'class Item {\n\tpublic var n:Int;\n\tpublic var m:Int;\n\tpublic var f:Float;\n}\n\nclass C {\n\n'
			+ '\tfunction f(xs:Array<Item>):Void {\n\t\t$statement\n\t}\n}';
	}

}
