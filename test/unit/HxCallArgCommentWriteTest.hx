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

	private static final _forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

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

}
