package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A call inside a method chain honours `wrapping.trailingComma` like a regular call: under `keep` its source trailing
 * comma survives flat and broken, under the default `remove` it goes. A `trailingCommas.*Default: "yes"` adds a comma to
 * a list broken over lines only, never to one that stays on one line, and a function parameter list drops its trailing
 * comma whatever the key says.
 */
class HxChainCallTrailingCommaTest extends Test {

	private static inline final KEEP: String = '{"wrapping": {"trailingComma": "keep"}}';
	private static inline final ADD: String = '{"trailingCommas": {"callArgumentDefault": "yes"}}';

	@:pin('control')
	@:killer('M-CHAIN-CALL-FLAT-SOURCE-TRAIL-OFF')
	public function testAFlatChainCallKeepsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tfoo.bar(1, 2,).baz();\n\t\tx = foo.bar(1,).baz(2,).qux();\n\t}\n}\n';
		assertWritesOnce(KEEP, source, source);
	}

	@:pin('control')
	@:killer('M-CHAIN-CALL-SOURCE-TRAIL-OFF')
	public function testABrokenChainCallKeepsItsTrailingComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tfoo.bar(1, 2,).baz();\n\t\tfoo.bar(1, 2).baz();\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tfoo.bar(\n\t\t\t1,\n\t\t\t2,\n\t\t).baz();\n\t\tfoo.bar(\n\t\t\t1,\n'
			+ '\t\t\t2\n\t\t).baz();\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "callParameter": {"defaultWrap": "onePerLine", "rules": []}}}', source, expected
		);
	}

	@:pin('control')
	@:killer('M-CHAIN-CALL-FLAT-TRAIL-UNDER-REMOVE')
	public function testAChainCallDropsItsTrailingCommaByDefault(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tfoo.bar(1, 2,).baz();\n\t}\n}\n';
		assertWritesOnce('{}', source, 'class A {\n\tfunction c() {\n\t\tfoo.bar(1, 2).baz();\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-FILL-TRAIL-SEP-UNGATED')
	public function testAnAddKnobLeavesAOneLineCallWithoutAComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);\n\t\tv(function() {\n\t\t\tx;\n'
			+ '\t\t}, 2);\n\t}\n}\n';
		assertWritesOnce(ADD, source, source);
	}

	@:pin('control')
	@:killer('M-FILL-TRAIL-SEP-DROPPED')
	public function testAnAddKnobStillCommasACallBrokenOverLines(): Void {
		final source: String =
			'class A {\n\tfunction c() {\n\t\tfoo.bar(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbb, cccccccccccccccccc, ddddddd);\n\t}\n}\n';
		final expected: String =
			'class A {\n\tfunction c() {\n\t\tfoo.bar(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbb,\n\t\t\tcccccccccccccccccc, ddddddd,);\n\t}\n}\n';
		assertWritesOnce('{"wrapping": {"maxLineLength": 60}, "trailingCommas": {"callArgumentDefault": "yes"}}', source, expected);
	}

	@:pin('control')
	@:killer('M-FILL-FLAT-SOURCE-TRAIL-OFF')
	public function testAOneLineFilledCallKeepsItsSourceComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tv(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,);\n\t}\n}\n';
		assertWritesOnce(KEEP, source, source);
	}

	@:pin('guard')
	public function testAParameterListDropsItsTrailingCommaUnderKeep(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\th(function(a, b,) {});\n\t}\n}\n';
		assertWritesOnce(KEEP, source, 'class A {\n\tfunction c() {\n\t\th(function(a, b) {});\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-COLLECTION-ARG-FLAT-SOURCE-TRAIL-OFF')
	public function testAOneLineCallWithACollectionArgKeepsItsSourceComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, b, {x: 1, y: 2},);\n\t\tfoo.bar(a, {x: 1},).baz();\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "maxLineLength": 60, "callParameter": {"defaultWrap": "fillLine", "rules": []}}}',
			source, source
		);
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
