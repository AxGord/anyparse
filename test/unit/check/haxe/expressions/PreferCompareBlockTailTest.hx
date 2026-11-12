package unit.check.haxe.expressions;

import anyparse.check.LintConfig;
import anyparse.check.haxe.expressions.PreferCompareFunction;
import anyparse.query.CanonicalEdit;

/** What a block-bodied sort callback returns: an arrow's tail expression is its value, a `function` block's is not. */
class PreferCompareBlockTailTest extends Test {

	private static final NAMED: String = '{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"Int":"lib.Order.ints"}}}}';
	private static final ORDER: String = 'package lib;\nclass Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n}';
	private static final BODY: String = '{\n\t\t\tfinal d:Int = a - b;\n\t\t\td != 0 ? d : Reflect.compare(a, b);\n\t\t}';

	@:pin('control')
	@:killer('M-RCMP-ARROW-TAIL')
	public function testArrowBlockTailIsReturnedAndMoves(): Void {
		final src: String = source('xs.sort((a:Int, b:Int) -> $BODY);');
		final run: FixRun = run(src);
		Assert.isTrue(run.violations.length > 0);
		for (v in run.violations) Assert.equals(-1, v.message.indexOf('does not return'), v.message);
		Assert.isTrue(CanonicalEdit.applyEdits(src, run.edits).indexOf('Order.ints(a, b)') >= 0);
	}

	public function testFunctionBlockTailWithoutReturnIsNotReturned(): Void {
		final src: String = source('xs.sort(function(a:Int, b:Int):Int $BODY);');
		final found: Array<Violation> = run(src).violations;
		Assert.isTrue(found.length > 0);
		for (v in found) Assert.isTrue(v.message.indexOf('does not return') >= 0, v.message);
	}

	private function run(src: String): FixRun {
		return CheckFixture.fixRun(new PreferCompareFunction(), files(src), 'C.hx', null, _ -> LintConfig.parse(NAMED));
	}

	private function source(statement: String): String {
		return 'class C {\n\n\tfunction f(xs:Array<Int>):Void {\n\t\t$statement\n\t}\n}';
	}

	private function files(src: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: src },
			{ file: 'lib/Order.hx', source: ORDER },
			{ file: 'String.hx', source: 'extern class String { function toString():String; }' }
		];
	}

}
