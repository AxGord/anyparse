package unit.runtime;

import anyparse.runtime.CommentRun;

/** `CommentRun.lines` and `endsWithLineComment` read a joined trailing slot back by its comments, not by its raw newlines. */
@:nullSafety(Strict)
final class CommentRunTest extends Test {

	@:pin('control')
	@:killer('M-COMMENT-RUN-LINES-BLOCK-BLIND')
	public function testANewlineInsideABlockCommentEndsNoLine(): Void {
		Assert.same(['/* a\n b */ // c', '/* d */'], CommentRun.lines('/* a\n b */ // c\n/* d */'));
	}

	@:pin('control')
	@:killer('M-COMMENT-RUN-LINES-LINE-BLIND')
	public function testABlockOpenerInsideALineCommentHidesNoNewline(): Void {
		Assert.same(['// see /* x', '/* d */'], CommentRun.lines('// see /* x\n/* d */'));
	}

	@:pin('control')
	@:killer('M-COMMENT-RUN-ENDS-ANY-LINE')
	public function testOnlyTheLastLineDecidesTheEnd(): Void {
		Assert.isFalse(CommentRun.endsWithLineComment('// c\n/* d */'));
		Assert.isTrue(CommentRun.endsWithLineComment('/* x */ // c'));
	}

	/** A run on one line comes back whole. */
	public function testOneLineRunIsOneLine(): Void {
		Assert.same(['/* x */ /* y */'], CommentRun.lines('/* x */ /* y */'));
	}

}
