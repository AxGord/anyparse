package unit.grammar.haxe;

import anyparse.format.comment.CommentLossException;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round-trip tests for a comment trailing a ternary OPERAND — the
 * condition (before `?`) and the then-branch (before `:`), the two seams the
 * `@:fmt(captureTernaryTrail)` slots cover.
 *
 * Before the slots existed the condition's comment had no slot at all and the
 * round trip REFUSED the file (`CommentLossException`), while the then-branch's
 * leaked out through the Pratt stash and was re-emitted BELOW the whole
 * statement — reading as a comment on the next line rather than on its branch.
 *
 * A LINE comment forces the broken `cond\n\t? then\n\t: else` shape: `//` runs
 * to the newline, so any glued continuation would comment the rest of the
 * ternary out. A BLOCK comment is inline-safe and leaves the layout to the
 * cascade.
 */
class HxTernaryCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testThenBranchLineCommentStaysOnItsBranch(): Void {
		final source: String =
			'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a\n\t\t\t? b // then note\n\t\t\t: c;\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testConditionLineCommentStaysOnTheCondition(): Void {
		final source: String =
			'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a // cond note\n\t\t\t? b\n\t\t\t: c;\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * A line comment on an operand of an UNBROKEN ternary forces the break: the
	 * `: c` cannot stay on the comment's line. The result is the canonical broken
	 * shape, so a second pass is byte-stable (asserted by the sibling
	 * `testThenBranchLineCommentStaysOnItsBranch` fixture, which IS this output).
	 */
	public function testLineCommentForcesTheTernaryBreak(): Void {
		final source: String = 'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a ? b // then note\n\t\t\t: c;\n\t}\n}';
		final expected: String =
			'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a\n\t\t\t? b // then note\n\t\t\t: c;\n\t}\n}\n';
		Assert.equals(expected, roundTrip(source));
	}

	/** A block comment is inline-safe — it rides its operand and the ternary stays flat. */
	public function testThenBranchBlockCommentStaysInline(): Void {
		final source: String = 'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a ? b /* then */ : c;\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testConditionBlockCommentStaysInline(): Void {
		final source: String = 'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a /* cond */ ? b : c;\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A comment-free ternary is untouched — the slots are null and nothing forces a shape. */
	public function testNoCommentUnaffected(): Void {
		final source: String = 'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a ? b : c;\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * The condition seam used to have NO capture slot, so the fail-closed
	 * `CommentInventory` guard refused the whole file. It must not refuse any
	 * more — that refusal is what made `fmt` a no-op on such a file.
	 */
	public function testConditionCommentNoLongerRefusesTheRoundTrip(): Void {
		final source: String = 'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a // cond note\n\t\t\t? b : c;\n\t}\n}';
		final expected: String =
			'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a // cond note\n\t\t\t? b\n\t\t\t: c;\n\t}\n}\n';
		try
			Assert.equals(expected, new anyparse.grammar.haxe.HaxeQueryPlugin().writeRoundTrip(source))
		catch (exception: CommentLossException)
			Assert.fail('round trip still refuses: ${exception.comment}');
	}

	/**
	 * The forced `Keep` shape pins its wrapping LOCATION instead of taking the
	 * cascade's answer. Under a `ternaryExpression` config whose rules do not fire
	 * at `exceeds = true`, the cascade falls back to `AfterLast`, whose shape emits
	 * ` ?` BEFORE the break — putting the operator inside the comment
	 * (`return a // why ?`). `BeforeLast` is the only location a line comment
	 * survives, so it is passed explicitly.
	 */
	public function testForcedKeepPinsBeforeLastUnderEmptyCascade(): Void {
		final source: String =
			'class Foo {\n\tfunction bar(a:Bool, b:Int, c:Int):Int {\n\t\treturn a // why\n\t\t\t? b\n\t\t\t: c;\n\t}\n}';
		final cfg: String =
			'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "ternaryExpression": {"rules": []}}}';
		Assert.equals('$source\n', roundTripWith(source, cfg));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

	private function roundTripWith(source: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast, opts);
	}

}
