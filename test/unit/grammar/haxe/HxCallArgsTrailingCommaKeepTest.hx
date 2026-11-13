package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under `wrapping.trailingComma: keep` (the Haxe writer defaults to `remove`) a call laid out broken writes
 * back the comma its source put after the last argument, and a call glued onto one line drops it, as every
 * other list does.
 */
class HxCallArgsTrailingCommaKeepTest extends Test {

	@:pin('control')
	@:killer('M-FLAT-TRAILING-COMMA-KEPT-ON-GLUE')
	public function testAFlatCallDropsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2,);\n\t\tv(1, 2);\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep"}}', source, 'class A {\n\tfunction c() {\n\t\tv(1, 2);\n\t\tv(1, 2);\n\t}\n}\n'
		);
	}

	@:pin('control')
	@:killer('M-CALL-SOURCE-TRAIL-OFF')
	public function testABrokenCallKeepsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2,);\n\t\tv(1, 2);\n\t}\n}\n';
		final expected: String =
			'class A {\n\tfunction c() {\n\t\tv(\n\t\t\t1,\n\t\t\t2,\n\t\t);\n\t\tv(\n\t\t\t1,\n\t\t\t2\n\t\t);\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "callParameter": {"defaultWrap": "onePerLine", "rules": []}}}', source, expected
		);
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(config);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
