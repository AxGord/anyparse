package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * A comment between `return`, `throw` or `try` and the value or body that follows survives the
 * trivia round trip as one after `do` does: a same-line or block one stays on the keyword line and
 * pushes a non-block value onto the next line, an own-line one stays on its own line, in statement
 * and in expression position, and each shape settles in one pass.
 */
class HxKwValueCommentTest extends Test {

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testSameLineCommentAfterReturnRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\treturn // c\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testBlockCommentAfterReturnRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\treturn /* c */\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testInlineBlockCommentAfterReturnSettlesInOnePass(): Void {
		assertSettles(
			'class Foo {\n\tfunction bar() {\n\t\treturn /* c */ x;\n\t}\n}',
			'class Foo {\n\tfunction bar() {\n\t\treturn /* c */\n\t\t\tx;\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testOwnLineCommentAfterReturnRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\treturn\n\t\t\t// own\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testSameLineCommentAfterThrowRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tthrow // c\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testSameLineAndOwnLineCommentAfterThrowRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tthrow // a\n\t\t\t// b\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testSameLineCommentAfterExpressionThrowRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tvar a = throw // c\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-KW-VALUE-COMMENT-DROPPED')
	public function testSameLineCommentAfterExpressionReturnRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tvar g = () -> return // c\n\t\t\tx;\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterTryNonBlockRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\ttry // c\n\t\t\tfoo();\n\t\tcatch (e:Dynamic) {}\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterTryBlockRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\ttry // c\n\t\t{\n\t\t\tfoo();\n\t\t} catch (e:Dynamic) {}\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testInlineBlockCommentAfterTrySettlesInOnePass(): Void {
		assertSettles(
			'class Foo {\n\tfunction bar() {\n\t\ttry /* c */ foo(); catch (e:Dynamic) {}\n\t}\n}',
			'class Foo {\n\tfunction bar() {\n\t\ttry /* c */\n\t\t\tfoo();\n\t\tcatch (e:Dynamic) {}\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterExpressionTryRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tvar a = try // c\n\t\t\tfoo()\n\t\tcatch (e:Dynamic)\n\t\t\t1;\n\t}\n}');
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
