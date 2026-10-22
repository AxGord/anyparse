package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * The trailing comma is the one token the formatter may change, and only through
 * `wrapping.trailingComma` (`keep` by default): a call writes back the comma its source put after
 * the last argument in every layout, as every other list does. The call-argument list read only the
 * add-knob, so the comma was dropped.
 */
class HxCallArgsTrailingCommaKeepTest extends Test {

	@:pin('control')
	@:killer('M-CALL-FLAT-SOURCE-TRAIL-OFF')
	public function testAFlatCallKeepsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2,);\n\t\tv(1, 2);\n\t}\n}\n';
		assertWritesOnce('{}', source, source);
	}

	@:pin('control')
	@:killer('M-CALL-SOURCE-TRAIL-OFF')
	public function testABrokenCallKeepsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2,);\n\t\tv(1, 2);\n\t}\n}\n';
		final expected: String =
			'class A {\n\tfunction c() {\n\t\tv(\n\t\t\t1,\n\t\t\t2,\n\t\t);\n\t\tv(\n\t\t\t1,\n\t\t\t2\n\t\t);\n\t}\n}\n';
		assertWritesOnce('{"wrapping": {"callParameter": {"defaultWrap": "onePerLine", "rules": []}}}', source, expected);
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
