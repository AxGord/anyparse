package unit.query;

import anyparse.query.MemberWriteScan;

/**
 * `MemberWriteScan.writtenInRange` reads its candidates as word tokens of the code: a write inside an interpolation hole
 * is one, and an assignment spelled in a string's text or in a comment is none.
 */
@:nullSafety(Strict)
final class MemberWriteScanTokenTest extends Test {

	/** `cnt++` inside a `${ … }` hole is code, so the field is written. */
	@:pin('control')
	@:killer('M-CODE-WORDS-HOLES-SKIPPED')
	public function testAWriteInsideAnInterpolationHoleIsAWrite(): Void {
		Assert.isTrue(written("class C { function f() { trace('n=${cnt++}'); } }"));
	}

	/** `cnt = 1` in a plain string and `cnt = 2` in a comment are text, so nothing writes the field. */
	@:pin('control')
	@:killer('M-CODE-WORDS-REGION-TEXT-COUNTS')
	public function testAnAssignmentSpelledInAStringOrACommentIsNoWrite(): Void {
		Assert.isFalse(written('class C { function f() { trace("cnt = 1"); } } // cnt = 2'));
	}

	/** Whether `cnt` is written anywhere in `source`, by the Haxe grammar's token reader. */
	private static function written(source: String): Bool {
		return MemberWriteScan.writtenInRange(source, 'cnt', null, 0, source.length, new HaxeQueryPlugin());
	}

}
