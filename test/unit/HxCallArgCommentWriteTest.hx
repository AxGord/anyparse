package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for comments in call-argument positions —
 * inline block comments in an empty arg list (`f(/* c *\/)`), glued before
 * the first argument (`f(/* c *\/ x)`), and before a later argument
 * (`f(a, /* c *\/ b)`). These were previously dropped by the writer /
 * eaten by the parser's pre-loop whitespace skip.
 */
class HxCallArgCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testEmptyCallArgInnerBlockCommentRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(/* null */);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tg(/* null */);\n\t}\n}\n', out);
	}

	public function testCallArgLeadingBlockCommentRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\th(a, /* keep */ b);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\th(a, /* keep */ b);\n\t}\n}\n', out);
	}

	public function testCallArgFirstArgLeadingBlockCommentRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tm(/* a */ x);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tm(/* a */ x);\n\t}\n}\n', out);
	}

	public function testMultipleLeadingBlockCommentsRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tp(/* a */ /* b */ q);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tp(/* a */ /* b */ q);\n\t}\n}\n', out);
	}


	/**
	 * A line comment as the sole content of an empty arg list must NOT be
	 * captured into the inner-comment slot: emitted inline it would swallow
	 * the `)` (`g(// hmm);`) and produce unparseable output. The writer
	 * drops it (pre-slice behavior) and the result stays parseable.
	 */
	public function testEmptyCallArgLineCommentStaysParseable(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(// hmm\n\t\t);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tg();\n\t}\n}\n', out);
		// The output must reparse (round-trip contract).
		final reparsed: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(out);
		Assert.equals(out, HaxeModuleTriviaWriter.write(reparsed));
	}


	/**
	 * A block comment PRECEDING the callee of a call — standalone
	 * (`/* keep *\/ g()`), after an operator (`a * /* keep *\/ g()`), or before
	 * a call that has arguments (`/* keep *\/ g(arg)`) — stays before the call
	 * instead of being relocated inside the argument list. The pre-callee
	 * comment is captured from pending trivia before the args loop can drain it
	 * into an argument's leading slot.
	 */
	public function testCallLeadingBlockCommentStandaloneRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tx = /* keep */ g();\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tx = /* keep */ g();\n\t}\n}\n', out);
	}

	public function testCallLeadingBlockCommentAfterOperatorRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tx = a * /* keep */ g();\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tx = a * /* keep */ g();\n\t}\n}\n', out);
	}

	public function testCallLeadingBlockCommentWithArgRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tx = /* keep */ g(arg);\n\t}\n}';
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tx = /* keep */ g(arg);\n\t}\n}\n', out);
	}

}
