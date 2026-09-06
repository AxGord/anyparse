package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `CommentOwnerGuard.detachedComment` on a DELETION whose comment text repeats elsewhere in the
 * file — the direction its own doc reasoned itself out of.
 *
 * The criterion aligns the source's comments with the spliced result's so it can ask which source
 * BLOCK each surviving comment came from. That alignment used to be a queue keyed on the comment's
 * TEXT with one shared cursor per text, and the doc argued only about a result that repeats a text
 * MORE often than the source: the queue runs dry, the comment reads as new, and no refusal can be
 * invented. The opposite surplus is the one deletions produce. A removed member takes its comments
 * with it, so a text it repeated — a bare `//` separator is the everyday case — has fewer
 * occurrences in the result than in the source, and every LATER occurrence drew the block index of
 * an EARLIER one. A surviving multi-comment block then reported a weld between two comments that
 * never moved, naming code hundreds of lines from the deletion. Measured on S117: 11 of 44
 * whole-member deletions were refused this way, and the workaround was to route them through
 * `move-member`, which bypasses the seam entirely.
 *
 * What replaced the queue is arithmetic: a comment no edit covers is copied verbatim, so its offset
 * in the result is its source offset shifted by the edits that end before it, and the source block
 * it belongs to is a lookup rather than a guess. Only a comment that lands INSIDE a replacement has
 * to be matched by text, and then only against the comments THAT edit covers — a deletion elsewhere
 * in the file cannot reach it.
 *
 * Two-sided by construction. `testDeletingAMemberWhoseCommentRepeatsIsAccepted` is the invented
 * refusal; the other two are the true refusals that must survive the change, both written on the
 * SAME fixture so the duplicate `//` is present while they fire — a guard that had merely gone
 * blind would pass the first and fail these.
 */
class CommentWeldDeletionSliceTest extends Test {

	/**
	 * Three members whose bodies each open with a bare `//`, and whose last body carries a second
	 * comment right under it plus a third comment further down. Every shape the two directions need
	 * is in this one fixture: a text that repeats (`//`), a surviving block of TWO comments, and a
	 * pair of blocks with one statement between them.
	 */
	private static final REPEATED_SEPARATOR: String = [
		'class C {',
		'\tfunction a(): Int {',
		'\t\t//',
		'\t\treturn 1;',
		'\t}',
		'',
		'\tfunction b(): Int {',
		'\t\t//',
		'\t\treturn 2;',
		'\t}',
		'',
		'\tfunction c(): Int {',
		'\t\t//',
		'\t\t// why three',
		'\t\tx();',
		'\t\t// after',
		'\t\treturn 3;',
		'\t}',
		'}',
		''
	].join('\n');

	/** The whole middle member, its own `//` included — what a member deletion actually splices out. */
	private static final MIDDLE_MEMBER: String = '\tfunction b(): Int {\n\t\t//\n\t\treturn 2;\n\t}\n\n';

	/**
	 * The reported invention: deleting the middle member leaves `//` and `// why three` exactly
	 * where they were, adjacent, with nothing removed between them — and the text queue reported
	 * them welded because the deletion consumed one earlier `//`.
	 *
	 * The assertion is the ACCEPTANCE plus the untouched pair in the result, so it cannot pass on a
	 * splice that silently dropped one of them.
	 */
	public function testDeletingAMemberWhoseCommentRepeatsIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(REPEATED_SEPARATOR, MIDDLE_MEMBER, ''));
		Assert.isTrue(text.indexOf('function b(') < 0, 'the member was not removed:\n$text');
		Assert.isTrue(text.indexOf('//\n\t\t// why three\n\t\tx();') >= 0, 'the surviving comments did not keep their code:\n$text');
	}

	/**
	 * TRUE REFUSAL, on the same fixture: the statement between `// why three` and `// after` goes,
	 * the two blocks meet, and the block that led it now leads `return 3;`. The duplicate
	 * `//` is still standing while this fires, so what has to hold the refusal up is the
	 * offset arithmetic — the queue this replaced would have drawn the owner from a block
	 * two members away and named the wrong pair.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WELD-BLIND')
	public function testWeldingAcrossTheRepeatedSeparatorIsStillRefused(): Void {
		switch SeamEdit.replace(REPEATED_SEPARATOR, '\t\tx();\n', '') {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to "// after"') >= 0, 'this is not the weld onto "// after": $message');
		}
	}

	/**
	 * TRUE REFUSAL through the other path: the comments land INSIDE the replacement, so the offset
	 * arithmetic cannot place them and the text match runs against the comments this edit covers.
	 * `// after` is hoisted above the statement it followed while `x();` survives — the
	 * `prefer-ternary-return` shape — and the duplicate `//` sits outside the edit, unable to reach
	 * the per-edit match.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WELD-BLIND')
	public function testHoistingInsideAReplacementIsStillRefused(): Void {
		switch SeamEdit.replace(REPEATED_SEPARATOR, '// why three\n\t\tx();\n\t\t// after', '// why three\n\t\t// after\n\t\tx();') {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to') >= 0, 'unexpected message: $message');
		}
	}

	/** The `Ok` text, proved to re-parse; an `Err` fails the test with its own message. */
	private function assertOk(result: EditResult): String {
		switch result {
			case Ok(text):
				try
					new HaxeQueryPlugin().parseFile(text)
				catch (exception: Exception)
					Assert.fail('the result failed to re-parse: ${exception.message}\n$text');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

}
