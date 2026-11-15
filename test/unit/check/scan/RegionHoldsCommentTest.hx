package unit.check.scan;

import anyparse.check.scan.CheckScan;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions.LexRegion;

/**
 * `CheckScan.regionHoldsComment` read through the file's lexical regions: a `//` spelled inside a string literal of
 * the dropped text is no comment, a real comment between the kept spans is, and a comment inside a kept span is not
 * dropped at all.
 */
class RegionHoldsCommentTest extends Test {

	@:pin('control')
	@:killer('M-REGION-HOLDS-COMMENT-ANY-TEXT')
	public function testStringMarkerInDroppedTextIsNoComment(): Void {
		Assert.isFalse(holds('f(x, "a//b", y);', 'x'));
		Assert.isFalse(holds("f(x, 'a/*b*/', y);", 'x'));
	}

	@:pin('control')
	@:killer('M-REGION-HOLDS-COMMENT-NEVER')
	public function testCommentBetweenKeptSpansHolds(): Void {
		Assert.isTrue(holds('f(x, /* c */ y);', 'x'));
		Assert.isTrue(holds('f(x, y); // c', 'x'));
	}

	public function testCommentInsideKeptSpanIsNotDropped(): Void {
		Assert.isFalse(holds('f(x /* c */, y);', 'x /* c */'));
	}

	/** Whether `src` minus the one kept span spelled `kept` holds a comment, over the whole of `src`. */
	private static function holds(src: String, kept: String): Bool {
		final regions: () -> Array<LexRegion> = ElementSpan.lazyRegions(src, new HaxeQueryPlugin());
		final at: Int = src.indexOf(kept);
		return CheckScan.regionHoldsComment(regions, new Span(0, src.length), [new Span(at, at + kept.length)]);
	}

}
