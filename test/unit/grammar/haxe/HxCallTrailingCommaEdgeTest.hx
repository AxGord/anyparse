package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A call argument list's trailing comma at the edges of `wrapping.trailingComma`: under the default `remove` a last
 * argument's after-separator line comment follows the argument with no comma, as an array literal's does, plain and chained, where
 * `keep` holds the comma; under `keep` a call glued around a block or collection argument drops the comma its source wrote, as
 * every glued list does; and a
 * `trailingCommas.callArgumentDefault: "yes"` leaves a sole argument that shares the open delimiter's line without one.
 */
class HxCallTrailingCommaEdgeTest extends Test {

	@:pin('control')
	@:killer('M-LAST-ARG-COMMENT-KEEPS-DROPPED-SEP')
	public function testRemoveDropsTheCommaBeforeALastArgumentComment(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, // c1\n\t\t\tb, // c2\n\t\t);\n\t\tfoo.bar(a, // c1\n\t\t\tb, // c2\n'
			+ '\t\t).baz();\n\t\tf(b, // c\n\t\t);\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tf(\n\t\t\ta, // c1\n\t\t\tb // c2\n\t\t);\n\t\tfoo.bar(\n'
			+ '\t\t\ta, // c1\n\t\t\tb // c2\n\t\t).baz();\n\t\tf(b // c\n\t\t);\n\t}\n}\n';
		assertWritesOnce('{}', source, expected);
	}

	/**
	 * The dropped comma's line comment is re-homed onto the tail of the construct before it, a block lambda here whose
	 * lines no source break decides, and the call is laid out from that tree, the one the next parse reads.
	 */
	@:pin('control')
	@:killer('M-CALL-ARGS-NOT-REHOMED')
	public function testADroppedCommaLaysTheArgumentOutAsTheNextParseReadsIt(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, function() {\n\t\t\tx;\n\t\t}, // c\n\t\t);\n\t}\n}\n';
		assertWritesOnce('{}', source, 'class A {\n\tfunction c() {\n\t\tf(a, function() {\n\t\t\tx;\n\t\t} // c\n\t\t);\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-FLAT-TRAILING-COMMA-KEPT-ON-GLUE')
	public function testAGluedCollectionCallDropsItsSourceComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, {\n\t\t\tx: 1,\n\t\t\ty: 2\n\t\t}, c,);\n\t\tf(a, {\n\t\t\tx: 1,\n'
			+ '\t\t\ty: 2\n\t\t}, c);\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tf(a, {\n\t\t\tx: 1,\n\t\t\ty: 2\n\t\t}, c);\n\t\tf(a, {\n\t\t\tx: 1,\n'
			+ '\t\t\ty: 2\n\t\t}, c);\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "objectLiteral": {"defaultWrap": "onePerLine", "rules": []}}}', source, expected
		);
	}

	@:pin('control')
	@:killer('M-FLAT-TRAILING-COMMA-KEPT-ON-GLUE')
	public function testAGluedBlockLambdaCallDropsItsSourceComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, function() {\n\t\t\tx;\n\t\t}, c,);\n\t\tf(a, function() {\n'
			+ '\t\t\tx;\n\t\t}, c);\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tf(a, function() {\n\t\t\tx;\n\t\t}, c);\n\t\tf(a, function() {\n'
			+ '\t\t\tx;\n\t\t}, c);\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": []}}}', source,
			expected
		);
	}

	@:pin('control')
	@:killer('M-SOLE-ARG-ADD-COMMA')
	public function testAnAddKnobLeavesASoleOverflowingArgumentWithoutAComma(): Void {
		final source: String = 'class A {\n\tfunction c() {\n'
			+ '\t\tfoo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n'
			+ '\t\tfoo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb());\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tfoo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
			+ '\t\t\t+ bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n'
			+ '\t\tfoo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb());\n\t}\n}\n';
		assertWritesOnce(
			'{"wrapping": {"trailingComma": "keep", "maxLineLength": 60}, "trailingCommas": {"callArgumentDefault": "yes"}}', source,
			expected
		);
	}

	@:pin('control')
	@:killer('M-LAST-ARG-COMMENT-DROPS-KEPT-SEP')
	public function testKeepHoldsTheCommaBeforeALastArgumentComment(): Void {
		final source: String = 'class A {\n\tfunction c() {\n\t\tf(a, // c1\n\t\t\tb, // c2\n\t\t);\n\t\tfoo.bar(a, // c1\n\t\t\tb, // c2\n'
			+ '\t\t).baz();\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction c() {\n\t\tf(\n\t\t\ta, // c1\n\t\t\tb, // c2\n\t\t);\n\t\tfoo.bar(\n'
			+ '\t\t\ta, // c1\n\t\t\tb, // c2\n\t\t).baz();\n\t}\n}\n';
		assertWritesOnce('{"wrapping": {"trailingComma": "keep"}}', source, expected);
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(HxWriteFixture.listsKeepSource(config));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
