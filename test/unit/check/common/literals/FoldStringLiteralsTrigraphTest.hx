package unit.check.common.literals;

/**
 * A merge never joins two literals across a seam where the text would form a C++ trigraph: that cut is what
 * `trigraph-in-string` writes, and a fold that undid it would flag the fixed file again.
 */
class FoldStringLiteralsTrigraphTest extends FoldStringLiteralsCheckTestBase {

	@:pin('control')
	@:killer('M-FOLD-TRIGRAPH-SEAM-OPEN')
	public function testTrigraphSeamStaysCut(): Void {
		Assert.equals(0, violations(wrap("'a?' + '?)'")).length);
		Assert.equals("'a?' + '?=b'", foldOf(wrap("'a?' + '?=' + 'b'")));
	}

	public function testOtherSeamsStillMerge(): Void {
		Assert.equals("'a?x'", foldOf(wrap("'a?' + 'x'")));
		Assert.equals("'a??x'", foldOf(wrap("'a?' + '?' + 'x'")));
	}

	/** The seam test reads the group gathered so far, so a one-character middle segment does not hide the trigraph it completes. */
	@:pin('control')
	@:killer('M-FOLD-TRIGRAPH-SEAM-OPEN')
	public function testAMiddleSegmentDoesNotHideTheTrigraph(): Void {
		Assert.equals("'??' + ')'", foldOf(wrap("'?' + '?' + ')'")));
		Assert.equals(0, violations(wrap("'??' + ')'")).length);
	}

}
