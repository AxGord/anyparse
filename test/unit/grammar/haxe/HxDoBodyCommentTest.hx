package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * A comment between the `do` keyword and its body survives the trivia round trip, as one after
 * `else`, `while (…)` or `for (…)` does: a same-line one stays on the keyword line and pushes a
 * non-block body onto the next line, an own-line one stays on its own line.
 */
class HxDoBodyCommentTest extends Test {

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterDoNonBlockRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tdo // afterDo\n\t\t\ta(); while (cond);\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterDoBlockRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tdo // afterDo\n\t\t{\n\t\t\ta();\n\t\t} while (cond);\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testOwnLineCommentAfterDoRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tdo\n\t\t\t// own\n\t\t\ta(); while (cond);\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testBlockCommentAfterDoNonBlockRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tdo /* afterDo */\n\t\t\ta(); while (cond);\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterExpressionDoRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tvar g = () -> do // afterDo\n\t\t\ta() while (cond);\n\t}\n}');
	}

	@:pin('control')
	@:killer('M-DO-KW-COMMENT-DROPPED')
	public function testSameLineCommentAfterNestedDoRoundTrip(): Void {
		assertRoundtrip('class Foo {\n\tfunction bar() {\n\t\tdo do // afterDo\n\t\t\ta(); while (a); while (b);\n\t}\n}');
	}

	private function assertRoundtrip(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(ast));
	}

}
