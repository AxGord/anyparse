package unit;

import anyparse.format.comment.CommentLossException;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round-trip tests for comments in call-argument positions —
 * inline block comments in an empty arg list (`f(/* c *\/)`), glued before
 * the first argument (`f(/* c *\/ x)`), and before a later argument
 * (`f(a, /* c *\/ b)`). These were previously dropped by the writer /
 * eaten by the parser's pre-loop whitespace skip.
 *
 * The second half covers LINE-style comments in the same positions: they have
 * no inline emission (a `//` swallows whatever follows on its line), so before
 * the after-sep capture they were dropped outright and the round trip refused
 * the whole file.
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


	/**
	 * A LINE comment after an argument's separator (`arg, // note`) belongs to
	 * THAT argument's line. It used to land in the NEXT argument's leading slot,
	 * which the writer could only emit inline — impossible for `//` — so it was
	 * DROPPED and the round trip refused the file. Now the parser routes it to
	 * the previous argument's trailing slot (`trailingBeforeSep == false`) and
	 * the force-multi shape, which owns the separator, cuddles it after the comma.
	 */
	public function testArgTrailingLineCommentAfterSepRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\taaa, // note\n\t\t\tbbb\n\t\t);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** An OWN-LINE line comment before an argument is emitted above it, on its own line of the force-multi list. */
	public function testArgOwnLineLeadingLineCommentRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\taaa,\n\t\t\t// note\n\t\t\tbbb\n\t\t);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * A BEFORE-separator trailing comment (the last argument's, or one written
	 * ahead of the comma) is NOT a force-multi trigger: the render-time guard in
	 * `trailingCommentDocGuarded` already keeps the next token off its line under
	 * every cascade shape. Pinned so the after-sep work above cannot widen into
	 * re-wrapping every `arg // noqa` call in a tree.
	 */
	public function testLastArgTrailingLineCommentKeepsCascadeShape(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(aaa,\n\t\t\tbbb // note\n\t\t\t);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * An after-separator comment forces the one-argument-per-line shape whatever
	 * the wrap cascade would have picked — the source below fits on one line and
	 * still breaks, because a `//` cannot have the next argument after it.
	 */
	public function testAfterSepCommentForcesOneArgPerLine(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(aaa, // note\n\t\t\tbbb);\n\t}\n}';
		final expected: String = 'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\taaa, // note\n\t\t\tbbb\n\t\t);\n\t}\n}\n';
		Assert.equals(expected, roundTrip(source));
	}

	/**
	 * The spec's refusal repro: a comment after the first argument's comma made
	 * the whole round trip throw `CommentLossException`, so `fmt` left the file
	 * alone. It must survive instead.
	 */
	public function testArgLineCommentNoLongerRefusesTheRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\tone, // first arg note\n\t\t\ttwo\n\t\t);\n\t}\n}';
		try
			Assert.equals('$source\n', new anyparse.grammar.haxe.HaxeQueryPlugin().writeRoundTrip(source))
		catch (exception: CommentLossException)
			Assert.fail('round trip still refuses: ${exception.comment}');
	}

	/** A comment-free arg list is untouched — every new branch is gated on a captured comment. */
	public function testNoCommentArgsUnaffected(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tg(aaa, bbb);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A MULTI-LINE block comment leading an argument had nowhere to go either — same own-line treatment. */
	public function testArgMultiLineBlockLeadingCommentRoundTrip(): Void {
		final source: String =
			'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\taaa,\n\t\t\t/* one\n\t\t\t * two\n\t\t\t */\n\t\t\tbbb\n\t\t);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * The force-multi shape emits the separator from `Trivial.sepAfter`, not from
	 * the element's position. A conditional group that absorbed the comma
	 * (`#if F, false #end`) elided the source one at that gap; emitting one anyway
	 * yields `g(true, , true)` with the branch off — unparseable output the
	 * comment-loss guard cannot see, since every comment survived it.
	 */
	public function testForceMultiHonoursSourceElidedSeparator(): Void {
		final source: String =
			'class Foo {\n\tfunction bar() {\n\t\tg(\n\t\t\ttrue\n\t\t\t#if FSE, false #end,\n\t\t\t// lead\n\t\t\ttrue\n\t\t);\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
