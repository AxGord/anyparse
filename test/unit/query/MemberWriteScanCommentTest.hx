package unit.query;

import anyparse.query.MemberWriteScan;

/**
 * `MemberWriteScan.writtenInRange` skips a block comment between a prefix `++` / `--` and the name, and finds that comment
 * on the lexical regions: the walk back from the comment's closer lands on its real opener, not the nearest opener before it.
 */
class MemberWriteScanCommentTest extends Test {

	@:pin('control') @:killer('M-WRITESCAN-BLOCK-COMMENT-BLIND')
	public function testBlockCommentBetweenIncrementAndNameStillReadsAsAWrite(): Void {
		Assert.isTrue(written('class C { function f(y:Int) { y = ++ /* c */ cnt; } }'));
	}

	@:pin('control') @:killer('M-WRITESCAN-BLOCK-COMMENT-BLIND')
	public function testOpenerInsideTheCommentDoesNotEndTheSkipEarly(): Void {
		Assert.isTrue(written('class C { function f(y:Int) { y = ++ /* a /* b */ cnt; } }'));
	}

	@:pin('guard')
	public function testBlockCommentAfterANonIncrementOperatorIsNoWrite(): Void {
		Assert.isFalse(written('class C { function f(y:Int) { y = y + /* c */ cnt; } }'));
	}

	private function written(source: String): Bool {
		return MemberWriteScan.writtenInRange(source, 'cnt', null, 0, source.length, new HaxeQueryPlugin());
	}

}
