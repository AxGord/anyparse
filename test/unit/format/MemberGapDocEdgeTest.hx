package unit.format;

import anyparse.format.MemberGap;

/**
 * `MemberGap.docEdge` / `bodyHasDoc`: a stated `…TypeIfDocComments` count replaces a type body's edge count only when
 * the body holds a doc comment among its direct children, and an absent one leaves the edge count as it was.
 */
@:nullSafety(Strict)
class MemberGapDocEdgeTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-DOC-EDGE-IFDOC-IGNORED')
	public function testADocCountReplacesTheEdgeOfABodyWithADoc(): Void {
		Assert.equals(1, MemberGap.docEdge(0, 1, [member([]), member(['/** d */'])], []));
		Assert.equals(0, MemberGap.docEdge(null, 0, [member(['/** d */'])], []));
	}

	@:pin('control')
	@:killer('M-DOC-EDGE-ABSENT-KEY-NULLS')
	public function testAnAbsentDocCountKeepsTheStatedEdge(): Void {
		Assert.equals(2, MemberGap.docEdge(2, null, [member(['/** d */'])], []));
		Assert.isNull(MemberGap.docEdge(null, null, [member(['/** d */'])], []));
	}

	@:pin('control')
	@:killer('M-BODY-HAS-DOC-ALWAYS')
	public function testABodyWithoutADocKeepsTheStatedEdge(): Void {
		Assert.equals(0, MemberGap.docEdge(0, 1, [member(['// line']), member(['/* block */'])], ['// tail']));
	}

	@:pin('control')
	@:killer('M-BODY-HAS-DOC-TRAIL-BLIND')
	public function testADocAmongTheTrailingCommentsCounts(): Void {
		Assert.isTrue(MemberGap.bodyHasDoc([member([])], ['/** tail */']));
	}

	@:pin('control')
	@:killer('M-BODY-HAS-DOC-EMPTY-BODY')
	public function testABodyOfCommentsAloneHoldsNoDoc(): Void {
		final none: Array<LeadingCommented> = [];
		Assert.isFalse(MemberGap.bodyHasDoc(none, ['/** orphan */']));
	}

	private static function member(comments: Array<String>): LeadingCommented {
		return { leadingComments: comments };
	}

}
