package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.comment.CommentInventory;

/**
 * The comment scan and the whitespace-loose comparison behind the writer's
 * fail-closed comment guard.
 *
 * The scan runs over both sides of a round trip, so a mis-lex costs either a
 * frozen file (a phantom comment on one side) or, worse, a missed loss (a
 * real comment hidden inside a mis-lexed region). Haxe's interpolating
 * single-quoted string is the sharp edge: `'a ${f('b')} c'` nests the SAME
 * quote, so the interpolation has to be scanned as code.
 */
class CommentInventoryTest extends Test {

	public function testCollectsLineAndBlockComments(): Void {
		final src: String = 'class C {\n\t// line\n\tfunction f() {\n\t\t/* block */\n\t}\n}\n';
		Assert.same(['// line', '/* block */'], CommentInventory.collect(src));
	}

	public function testStringPayloadIsNotAComment(): Void {
		Assert.same([], CommentInventory.collect('var a = "/* not a comment */";\nvar b = \'// me neither\';\n'));
	}

	// Double-quoted fixtures below: the scanned SOURCE contains `$`, which a
	// single-quoted Haxe literal would interpolate.
	public function testNestedInterpolationQuoteDoesNotDesyncTheScan(): Void {
		Assert.same(['// real'], CommentInventory.collect("var s = 'a ${f('b')} c';\n// real\nvar t = \"x\";\n"));
	}

	public function testCommentInsideInterpolationCounts(): Void {
		Assert.same(['/* c */'], CommentInventory.collect("var s = '${/* c */ x}';\n"));
	}

	public function testEscapedDollarOpensNoInterpolation(): Void {
		Assert.same(['// after'], CommentInventory.collect("var s = '$${';\n// after\n"));
	}

	public function testRegexLiteralIsNotAComment(): Void {
		Assert.same(['// after'], CommentInventory.collect('var r = ~/a\\/\\/b/;\n// after\n'));
	}

	public function testUnterminatedBlockCommentRunsToEnd(): Void {
		Assert.same(['/* open'], CommentInventory.collect('var a = 1;\n/* open'));
	}

	public function testWhitespaceReformattingOfACommentIsNotLoss(): Void {
		Assert.isNull(CommentInventory.firstMissing('//x\n', '// x\n'));
		Assert.isNull(CommentInventory.firstMissing('/**\n * doc\n */\n', '/**\n\t * doc\n\t */\n'));
	}

	public function testDroppedCommentIsReported(): Void {
		Assert.equals('/* gone */', CommentInventory.firstMissing('f(/* gone */ x);\n', 'f(x);\n'));
	}

	public function testOneOfTwoIdenticalCommentsDroppedIsReported(): Void {
		Assert.equals('// same', CommentInventory.firstMissing('// same\n// same\n', '// same\n'));
	}

	public function testCommentFreeSourceNeverReportsLoss(): Void {
		Assert.isNull(CommentInventory.firstMissing('var a = 1;\n', 'var a = 1;\n'));
	}

	public function testBlockToLineConversionKeepsTheText(): Void {
		Assert.isNull(CommentInventory.firstMissing('} else /* e */ {\n', '} else // e\n{\n'));
	}

	public function testGuardDeclinedReadsTheEnvironmentSwitch(): Void {
		final saved: Null<String> = Sys.getEnv(CommentInventory.DECLINE_ENV);
		Sys.putEnv(CommentInventory.DECLINE_ENV, '1');
		Assert.isTrue(CommentInventory.guardDeclined());
		// `0` and the empty string read as UNSET, so a shell exporting a
		// computed value (`APQ_ALLOW_COMMENT_LOSS=$DEBUG`) keeps the guard on.
		Sys.putEnv(CommentInventory.DECLINE_ENV, '0');
		Assert.isFalse(CommentInventory.guardDeclined());
		Sys.putEnv(CommentInventory.DECLINE_ENV, '');
		Assert.isFalse(CommentInventory.guardDeclined());
		Sys.putEnv(CommentInventory.DECLINE_ENV, saved);
	}

}
