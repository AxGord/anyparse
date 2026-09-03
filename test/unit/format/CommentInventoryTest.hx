package unit.format;

import anyparse.format.comment.CommentInventory;
import anyparse.format.comment.CommentScan;
import anyparse.grammar.haxe.HaxeLexicalRegions;
import utest.Assert;
import utest.Test;

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

	/** The Haxe grammar's comment lexer — the seam every pin below is taken through. */
	private static final HAXE: CommentScan = HaxeLexicalRegions.scanComments;

	/**
	 * A lexer that knows only `//` and nothing about string literals — what a second
	 * grammar's first draft looks like, and what makes the seam OBSERVABLE: on the fixture
	 * below it disagrees with the Haxe one, so an audit that ignored its parameter would
	 * answer the same twice.
	 */
	private static final NAIVE: CommentScan = (source, onComment) -> {
		var at: Int = source.indexOf('//');
		while (at >= 0) {
			final nl: Int = source.indexOf('\n', at);
			final end: Int = nl < 0 ? source.length : nl;
			onComment(at, end);
			at = source.indexOf('//', end);
		}
	};

	public function testCollectsLineAndBlockComments(): Void {
		final src: String = 'class C {\n\t// line\n\tfunction f() {\n\t\t/* block */\n\t}\n}\n';
		Assert.same(['// line', '/* block */'], CommentInventory.collect(src, HAXE));
	}

	public function testStringPayloadIsNotAComment(): Void {
		Assert.same([], CommentInventory.collect('var a = "/* not a comment */";\nvar b = \'// me neither\';\n', HAXE));
	}

	// Double-quoted fixtures below: the scanned SOURCE contains `$`, which a
	// single-quoted Haxe literal would interpolate.
	public function testNestedInterpolationQuoteDoesNotDesyncTheScan(): Void {
		Assert.same(['// real'], CommentInventory.collect("var s = 'a ${f('b')} c';\n// real\nvar t = \"x\";\n", HAXE));
	}

	public function testCommentInsideInterpolationCounts(): Void {
		Assert.same(['/* c */'], CommentInventory.collect("var s = '${/* c */ x}';\n", HAXE));
	}

	public function testEscapedDollarOpensNoInterpolation(): Void {
		Assert.same(['// after'], CommentInventory.collect("var s = '$${';\n// after\n", HAXE));
	}

	public function testRegexLiteralIsNotAComment(): Void {
		Assert.same(['// after'], CommentInventory.collect('var r = ~/a\\/\\/b/;\n// after\n', HAXE));
	}

	public function testUnterminatedBlockCommentRunsToEnd(): Void {
		Assert.same(['/* open'], CommentInventory.collect('var a = 1;\n/* open', HAXE));
	}

	public function testWhitespaceReformattingOfACommentIsNotLoss(): Void {
		Assert.isNull(CommentInventory.firstMissing('//x\n', '// x\n', HAXE));
		Assert.isNull(CommentInventory.firstMissing('/**\n * doc\n */\n', '/**\n\t * doc\n\t */\n', HAXE));
	}

	public function testDroppedCommentIsReported(): Void {
		Assert.equals('/* gone */', CommentInventory.firstMissing('f(/* gone */ x);\n', 'f(x);\n', HAXE));
	}

	public function testOneOfTwoIdenticalCommentsDroppedIsReported(): Void {
		Assert.equals('// same', CommentInventory.firstMissing('// same\n// same\n', '// same\n', HAXE));
	}

	public function testCommentFreeSourceNeverReportsLoss(): Void {
		Assert.isNull(CommentInventory.firstMissing('var a = 1;\n', 'var a = 1;\n', HAXE));
	}

	public function testBlockToLineConversionKeepsTheText(): Void {
		Assert.isNull(CommentInventory.firstMissing('} else /* e */ {\n', '} else // e\n{\n', HAXE));
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

	/**
	 * THE SEAM IS WIRED, NOT MERELY DECLARED: the audit's answer follows the `CommentScan`
	 * it is handed. The Haxe lexer reads `'// not a comment'` as a string literal and finds
	 * no comment in this source, so rewriting the literal away is no loss; the naive one
	 * calls the same bytes a comment and reports losing it. Both halves run on the SAME
	 * source, so neither can pass by accident — a `firstMissing` that had kept a hardcoded
	 * scan would give the first answer twice.
	 */
	public function testTheAuditFollowsTheScanItIsHanded(): Void {
		final src: String = "var s = '// not a comment';\n";
		final out: String = 'var s = 1;\n';
		Assert.same([], CommentInventory.collect(src, HAXE));
		Assert.same(["// not a comment';"], CommentInventory.collect(src, NAIVE));
		Assert.isNull(CommentInventory.firstMissing(src, out, HAXE));
		Assert.equals("// not a comment';", CommentInventory.firstMissing(src, out, NAIVE));
	}

}
