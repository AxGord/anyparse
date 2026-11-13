package unit.format;

import anyparse.core.Doc;
import anyparse.core.LeafTag;
import anyparse.format.wrap.LineCommentPastSep;

/** `LineCommentPastSep` knows a closing line comment by the leaf's tag, never by its bytes. */
@:nullSafety(Strict)
class LineCommentPastSepTest extends Test {

	/** A guarded leaf tagged a line comment closes its item; the same bytes untagged — a string, say — do not. */
	@:pin('control')
	@:killer('M-LEAFTAG-GUARD-READS-TAG')
	public function testAGuardedLeafIsALineCommentByItsTag(): Void {
		Assert.isTrue(
			LineCommentPastSep.isGuardedLineComment(Concat([Text(' // c', true, LeafTag.LineComment), OptHardlineSkipBeforeHardline]))
		);
		Assert.isFalse(LineCommentPastSep.isGuardedLineComment(Concat([Text(' // c'), OptHardlineSkipBeforeHardline])));
	}

}
