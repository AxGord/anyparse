package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.comment.CommentInventory;
import anyparse.format.comment.CommentLossException;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * `writeRoundTrip` must never hand back source whose comments it dropped.
 *
 * The Trivia parser captures a comment only where a capture slot exists
 * (statement / member / call-argument boundaries, the Pratt operand stash,
 * the per-construct sidecar slots). An inline block comment in a slot-less
 * expression seam — `if (/* c *\/ x)`, `return /* r *\/ x;`, a type
 * annotation, a class header — is consumed as whitespace and never reaches
 * the AST, so the writer re-emits the construct without it.
 *
 * Each seam below is one such site. The contract is the same for all of
 * them: the round trip REFUSES (`CommentLossException`) rather than
 * returning bytes that delete the comment, so the file `apq fmt` and every
 * canonicalising op leave behind still holds it. `HxInlineBlockCommentGapTest`
 * pins which seams the writer itself preserves and which fall to this guard.
 */
class HxInlineBlockCommentWriteTest extends Test {

	/**
	 * The guard's escape hatch is process-wide, so a developer running the
	 * suite with `APQ_ALLOW_COMMENT_LOSS` set would otherwise see every
	 * refusal assertion fail. Neutralised per test, restored after.
	 */
	private var _savedDecline: Null<String> = null;

	public inline function teardown(): Void Sys.putEnv(CommentInventory.DECLINE_ENV, _savedDecline);

	public inline function testIfConditionLeadingBlockComment(): Void {
		assertRefusesLoss('class Foo {\n\tfunction bar() {\n\t\tif (/* c */ x) {\n\t\t\trun();\n\t\t}\n\t}\n}\n', '/* c */');
	}

	public inline function testReturnLeadingBlockComment(): Void {
		assertRefusesLoss('class Foo {\n\tfunction bar() {\n\t\treturn /* r */ x;\n\t}\n}\n', '/* r */');
	}

	public function setup(): Void {
		_savedDecline = Sys.getEnv(CommentInventory.DECLINE_ENV);
		Sys.putEnv(CommentInventory.DECLINE_ENV, '');
	}

	public function testAssignmentTrailingBlockComment(): Void {
		// The one named seam the writer itself keeps: the trailing slot of an
		// expression statement. It moves the comment onto its own line, but no
		// byte is lost, so the guard stays out of the way.
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tx = 2 /* t */;\n\t}\n}\n';
		Assert.equals('class Foo {\n\tfunction bar() {\n\t\tx = 2;\n\t\t/* t */\n\t}\n}\n', roundTrip(source));
	}

	public function testGuardLeavesCapturedCommentsAlone(): Void {
		// A comment in a slot the parser DOES capture must still round-trip —
		// the guard must not freeze every file that holds a block comment. The
		// `: Int` annotation makes the source a NON fixed point, so the check
		// really runs instead of short-circuiting on `written == source`.
		final source: String = 'class Foo {\n\n\t/* head */\n\tvar n: Int = 1;\n\n\tfunction bar() {\n\t\tf(x /* a */);\n\t}\n\n}\n';
		Assert.equals(
			'class Foo {\n\n\t/* head */\n\tvar n:Int = 1;\n\n\tfunction bar() {\n\t\tf(x /* a */);\n\t}\n\n}\n', roundTrip(source)
		);
	}

	public function testElseSeamKeepsTheTextAsALineComment(): Void {
		// Pinned as an artifact, not an endorsement: the `} else /* e */ {` seam
		// re-emits the block comment as `// e ` (trailing space) on its own line.
		// No byte of the TEXT is lost, so the guard allows it — but the shape
		// change is invisible to an inventory check and belongs on the record.
		final source: String =
			'class Foo {\n\tfunction bar() {\n\t\tif (c) {\n\t\t\trun();\n\t\t} else /* e */ {\n\t\t\trun();\n\t\t}\n\t}\n}\n';
		Assert.equals(
			'class Foo {\n\tfunction bar() {\n\t\tif (c) {\n\t\t\trun();\n\t\t} else // e \n\t\t{\n\t\t\trun();\n\t\t}\n\t}\n}\n',
			roundTrip(source)
		);
	}

	public function testGuardDoesNotFireOnCommentFreeSource(): Void {
		final source: String = 'class Foo {\n\n\tfunction bar() {\n\t\trun();\n\t}\n\n}\n';
		Assert.equals(source, roundTrip(source));
	}

	/**
	 * The round trip refuses `source` with a `CommentLossException` naming
	 * `expected` as the comment it would have dropped.
	 */
	private function assertRefusesLoss(source: String, expected: String): Void {
		try {
			final written: Null<String> = roundTrip(source);
			Assert.fail('expected a comment-loss refusal, got: $written');
		} catch (exception: CommentLossException)
			Assert.equals(expected, exception.comment);
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
