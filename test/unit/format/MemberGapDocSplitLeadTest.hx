package unit.format;

import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.MemberGap;

/** `MemberGap.docSplitLead` and what `docGap` makes of it: the before-doc blank of a split-led member stays out of the gap. */
@:nullSafety(Strict)
class MemberGapDocSplitLeadTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-DOC-SPLIT-LEAD-ANY-PREDECESSOR')
	public function testOnlyALineCommentBeforeTheLastDocSplitsTheLead(): Void {
		Assert.isTrue(MemberGap.docSplitLead(['/** a */', '// b', '/** c */']));
		Assert.isTrue(MemberGap.docSplitLead(['// b', '/** c */', '// d']));
		Assert.isFalse(MemberGap.docSplitLead(['/** a */', '/** c */']));
		Assert.isFalse(MemberGap.docSplitLead(['/** c */', '// d']));
		Assert.isFalse(MemberGap.docSplitLead(['// b']));
		Assert.isFalse(MemberGap.docSplitLead([]));
	}

	@:pin('control')
	@:killer('M-DOC-GAP-SPLIT-LEAD-IGNORED')
	public function testASplitLeadDropsOnlyTheBeforeDocBlank(): Void {
		Assert.equals(DocGapVerdict.Keep, MemberGap.docGap(false, true, CommentEmptyLinesPolicy.One, CommentEmptyLinesPolicy.One, true));
		Assert.equals(DocGapVerdict.Blank, MemberGap.docGap(true, true, CommentEmptyLinesPolicy.One, CommentEmptyLinesPolicy.One, true));
		Assert.equals(
			DocGapVerdict.NoBlank, MemberGap.docGap(false, true, CommentEmptyLinesPolicy.One, CommentEmptyLinesPolicy.None, true)
		);
		Assert.equals(DocGapVerdict.Blank, MemberGap.docGap(false, true, CommentEmptyLinesPolicy.One, CommentEmptyLinesPolicy.One, false));
	}

}
