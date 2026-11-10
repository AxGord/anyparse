package unit.check.haxe.expressions;

import anyparse.check.LintConfig;
import anyparse.check.haxe.expressions.PreferCompareFunction;
import anyparse.query.CanonicalEdit;

/** A hand-spelled chain whose target is the project's named function: the rule fixes it or says nothing, never "no fix". */
class PreferCompareNamedTargetTest extends Test {

	private static final NAMED: String = '{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"String":"lib.Order.texts"}}}}';
	private static final ORDER: String = 'package lib;\nclass Order {\n\tpublic static function texts(a:String, b:String):Int return 0;\n}';
	private static final CHAIN: String = 'xs.sort((a:Item, b:Item) -> a.s < b.s ? -1 : a.s > b.s ? 1 : 0);';

	@:pin('control')
	@:killer('M-RCMP-NAMED-TARGET-NULL')
	public function testChainTargetingTheNamedFunctionIsFixed(): Void {
		final src: String = source(CHAIN);
		final run: FixRun = CheckFixture.fixRun(new PreferCompareFunction(), files(src), 'C.hx', null, _ -> LintConfig.parse(NAMED));
		for (v in run.violations) Assert.equals(-1, v.message.indexOf('no fix'), v.message);
		Assert.equals(
			'import lib.Order;\n\n' + source('xs.sort((a:Item, b:Item) -> Order.texts(a.s, b.s));'),
			CanonicalEdit.applyEdits(src, run.edits)
		);
	}

	private function source(statement: String): String {
		return 'class Item {\n\tpublic var s:String;\n}\n\nclass C {\n\n\tfunction f(xs:Array<Item>):Void {\n\t\t$statement\n\t}\n}';
	}

	private function files(src: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: src },
			{ file: 'lib/Order.hx', source: ORDER },
			{ file: 'String.hx', source: 'extern class String { function toString():String; }' }
		];
	}

}
