package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round trip of a comment between a ternary's `?` or `:` and the operand after it: the writer keeps
 * it where the source wrote it. A block comment stays inline; a line comment ends its line, the ternary breaks
 * before each operator and the operand goes below the comment one indent deeper.
 */
class HxTernaryOperandCommentTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-UNCAPTURED')
	public function testBlockCommentAfterQuestionKept(): Void {
		final source: String = wrap('\t\tvar h = a ? /* c */ b : c;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-UNCAPTURED')
	public function testBlockCommentAfterColonKept(): Void {
		final source: String = wrap('\t\tvar h = a ? b : /* c */ c;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-RUN-UNWRITTEN')
	public function testLineCommentAfterQuestionKept(): Void {
		final source: String = wrap('\t\tvar h = a\n\t\t\t? // c\n\t\t\t\tb\n\t\t\t: c;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-RUN-UNWRITTEN')
	public function testLineCommentAfterColonKept(): Void {
		final source: String = wrap('\t\tvar h = a\n\t\t\t? b\n\t\t\t: // c\n\t\t\t\tc;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-UNCAPTURED')
	public function testNestedElseTernaryCommentKept(): Void {
		final source: String = wrap('\t\tvar h = a ? b : c ? /* c */ d : e;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-TERNARY-AFTER-OP-OWN-LINE-DROPPED')
	public function testOwnLineCommentAfterOperatorsKept(): Void {
		// An own-line comment after `?` or `:` moves up to the operator's line, the canonical line-comment layout.
		final source: String = wrap('\t\tvar h = a ?\n\t\t\t// c\n\t\t\tb : c;\n\t\tvar k = a ? b :\n\t\t\t// d\n\t\t\tc;');
		final expected: String = wrap(
			'\t\tvar h = a\n\t\t\t? // c\n\t\t\t\tb\n\t\t\t: c;\n\t\tvar k = a\n\t\t\t? b\n\t\t\t: // d\n\t\t\t\tc;'
		);
		Assert.equals('$expected\n', roundTrip(source));
	}

	private function wrap(body: String): String {
		return 'class Foo {\n\tfunction bar() {\n$body\n\t}\n}';
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
