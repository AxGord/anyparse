package unit;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round-trip tests for the head -> body seam: a same-line
 * `// comment` sitting between a construct HEAD and the `{` that opens
 * its body on the NEXT source line.
 *
 * Two pre-existing defect classes lived on that seam:
 *
 *  1. COMMENT LOSS - the captured `<field>AfterTrail` slot was never
 *     read by the writer, so `} catch (e:Dynamic) // c` + newline `{`
 *     re-emitted without the comment at all. Data loss.
 *  2. BRACE ABSORPTION - the comment WAS re-emitted, but nothing forced
 *     a break after it, so the following `{` landed on the comment's own
 *     line and became part of the comment (`function g() // c {`). The
 *     output no longer parses. Worse than loss.
 *
 * A line comment terminates at `\n` by definition, so a writer site that
 * emits one verbatim while sibling content can still follow on the same
 * Doc line must guarantee a break. The guard is an
 * `OptHardlineSkipBeforeHardline`, which drops when the next emit is
 * already a hardline - byte-inert everywhere the seam was not broken.
 *
 * Block-style head comments (`/* c *\/`) keep their existing glue: they
 * do not terminate at a newline, so `head /* c *\/ {` is legal.
 *
 * SCOPE. Both fixes are writer-side and reach only the seams whose comment
 * the PARSER captures into a slot. These heads still lose it because no
 * slot exists for them, and closing that needs parser work, not a writer
 * guard:
 *  - `do // c` + newline `{` (body is the first field of `HxDoWhileStmt`,
 *    with no `beforeNewlineSlotFirst` opt-in);
 *  - `class` / `interface` / `enum` / `typedef` heads, whose last token is
 *    not a `@:trail`-bearing Ref, so no `AfterTrail` slot is synthesised;
 *  - `function g(a:Int) // c` and `function g():Void // c` - the NON-empty
 *    param Star has no close-trailing capture (a block comment is lost
 *    there too, which is how the gap reads as parse-side), and an optional
 *    `@:lead(':')` Ref grows no `AfterTrail`.
 */
class HxHeadCommentSeamWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// --- 1. comment loss -----------------------------------------------

	/**
	 * The named defect: `} catch (e:Dynamic) // tight` followed by a
	 * newline `{` used to drop `// tight` entirely. `HxCatchClause.param`
	 * publishes `paramAfterTrail`, but `body` is an `@:optional` Ref, and
	 * only the MANDATORY-Ref bodyPolicy path threaded the slot.
	 */
	public function testCatchHeadLineCommentSurvives(): Void {
		final source: String =
			'class Foo {\n\tfunction bar() {\n\t\ttry {\n\t\t\ta();\n\t\t} catch (e:Dynamic) // tight\n\t\t{\n\t\t\tb();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Sibling of the catch case: the `switch` subject's `)` -> `{` seam. */
	public function testSwitchHeadLineCommentSurvives(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tswitch (v) // pick\n\t\t{\n\t\t\tcase 1:\n\t\t\t\ta();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	// --- 2. brace absorption -------------------------------------------

	/**
	 * `function g() // c` + newline `{`: the EMPTY-param close-peek Star
	 * emitted `paramsTrailClose` with no following break, so the body's
	 * `{` was swallowed by the comment and the output stopped parsing.
	 */
	public function testFnEmptyParamsHeadLineCommentSurvives(): Void {
		final source: String = 'class Foo {\n\tfunction bar() // sig\n\t{\n\t\ta();\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * `abstract A(Int) // c` + newline `{}`: the EMPTY `from`/`to` clause
	 * tryparse Star emitted the prior field's after-trail comment with no
	 * following break. Non-empty clause lists already round-tripped (fork
	 * corpus `lineends/issue_363_abstract_with_comments`).
	 */
	public function testAbstractEmptyClausesHeadLineCommentSurvives(): Void {
		final source: String = 'abstract A(Int) // under\n{}';
		Assert.equals('$source\n', roundTrip(source));
	}

	// --- 3. block-comment glue is unchanged ----------------------------

	/** A block comment does not terminate at `\n`, so the glue is legal. */
	public function testFnEmptyParamsHeadBlockCommentStaysGlued(): Void {
		final source: String = 'class Foo {\n\tfunction bar() /* sig */\n\t{\n\t\ta();\n\t}\n}';
		final expected: String = 'class Foo {\n\tfunction bar() /* sig */ {\n\t\ta();\n\t}\n}\n';
		Assert.equals(expected, roundTrip(source));
	}

	// --- 4. block-bodied if/for/while keep base indent ------------------

	/**
	 * `if (c) // c` + newline `{`: the comment already survived, but the
	 * forced-Next layout added a body-indent Nest meant for BARE bodies,
	 * so the whole block moved one level right. A block body owns its own
	 * indent via its `{ }` Nest - it must stay at the head's indent, which
	 * is also the shape the fork emits for `else // comment`.
	 */
	public function testIfHeadLineCommentKeepsBlockAtBaseIndent(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tif (c) // yes\n\t\t{\n\t\t\ta();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Bare (non-block) then-body still takes the body-indent Nest. */
	public function testIfHeadLineCommentBareBodyStillIndents(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tif (c) // yes\n\t\t\ta();\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testForHeadLineCommentKeepsBlockAtBaseIndent(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tfor (i in a) // each\n\t\t{\n\t\t\tb();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	public function testWhileHeadLineCommentKeepsBlockAtBaseIndent(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\twhile (c) // spin\n\t\t{\n\t\t\ta();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** `else // c` already round-tripped through the kw-trivia slot. */
	public function testElseHeadLineCommentSurvives(): Void {
		final source: String =
			'class Foo {\n\tfunction bar() {\n\t\tif (c) {\n\t\t\ta();\n\t\t} else // no\n\t\t{\n\t\t\tb();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	// --- 5. idempotency ------------------------------------------------

	/** Every seam shape above must be a fixed point of a second pass. */
	public function testSeamShapesAreIdempotent(): Void {
		final sources: Array<String> = [
			'class Foo {\n\tfunction bar() {\n\t\ttry {\n\t\t\ta();\n\t\t} catch (e:Dynamic) // tight\n\t\t{\n\t\t\tb();\n\t\t}\n\t}\n}',
			'class Foo {\n\tfunction bar() {\n\t\tswitch (v) // pick\n\t\t{\n\t\t\tcase 1:\n\t\t\t\ta();\n\t\t}\n\t}\n}',
			'class Foo {\n\tfunction bar() // sig\n\t{\n\t\ta();\n\t}\n}',
			'abstract A(Int) // under\n{}',
			'class Foo {\n\tfunction bar() {\n\t\tif (c) // yes\n\t\t{\n\t\t\ta();\n\t\t}\n\t}\n}',
		];
		for (source in sources) {
			final once: String = roundTrip(source);
			Assert.equals(once, roundTrip(once), 'not idempotent: $source');
		}
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
