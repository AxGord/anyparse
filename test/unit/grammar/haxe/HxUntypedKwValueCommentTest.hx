package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * A comment between `untyped` and its operand survives the trivia round trip as one after `return`
 * does: a same-line one stays on the keyword line, a block one is kept and settles in one pass, and
 * an `untyped` operand with no comment writes back unchanged.
 */
class HxUntypedKwValueCommentTest extends Test {

	@:pin('control')
	@:killer('M-UNTYPED-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterUntypedRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\treturn untyped // c\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-UNTYPED-KW-COMMENT-DROPPED')
	public function testInlineBlockCommentAfterUntypedSettlesInOnePass(): Void {
		assertSettles(
			'class Foo {\n\tfunction bar() {\n\t\treturn untyped /* c */ x;\n\t}\n}',
			'class Foo {\n\tfunction bar() {\n\t\treturn untyped /* c */\n\t\t\tx;\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-UNTYPED-KW-COMMENT-DROPPED')
	public function testOwnLineCommentAfterStatementUntypedRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tuntyped\n\t\t\t// own\n\t\t\tfoo();\n\t}\n}');
	}

	@:pin('guard')
	public function testUntypedWithoutCommentUnchanged(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\treturn untyped x;\n\t}\n}');
	}

	private function assertRoundtrip(source: String): Void {
		Assert.equals('$source\n', write(source));
	}

	/** `source` writes as `expected` and `expected` writes back unchanged: one pass reaches the fixed point. */
	private function assertSettles(source: String, expected: String): Void {
		Assert.equals('$expected\n', write(source));
		Assert.equals('$expected\n', write(expected));
	}

	private function write(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
