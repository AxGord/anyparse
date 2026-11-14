package unit.query;

import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import anyparse.query.SourceComments;

/**
 * `LexicalRegions.commentIntersects`: a range holds a REAL comment of the file's lexical regions, where the string-blind
 * `SourceComments.hasCommentMarker` answers yes for a `//` spelled inside a literal and sees no difference between a
 * comment in a literal's text and one written in its `${ … }` code hole.
 */
class LexicalRegionsCommentIntersectsTest extends Test {

	@:pin('control')
	@:killer('M-SPAN-COMMENT-LITERAL-COUNTS')
	public function testMarkerInsideStringLiteralIsNotAComment(): Void {
		final src: String = "var u = 'http://x';";
		Assert.isFalse(has(src, 0, src.length));
		Assert.isTrue(SourceComments.hasCommentMarker(src, 0, src.length));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-REGIONS-IGNORED')
	public function testLineCommentIsAComment(): Void {
		final src: String = 'var a = 1; // note\nvar b = 2;';
		Assert.isTrue(has(src, 0, src.length));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-REGIONS-IGNORED')
	public function testBlockCommentIsAComment(): Void {
		final src: String = 'var a = /* note */ 1;';
		Assert.isTrue(has(src, 0, src.length));
	}

	public function testSpanInsideTheCommentBodyIsAComment(): Void {
		final src: String = 'var a = /* note */ 1;';
		final at: Int = src.indexOf('note');
		Assert.isTrue(has(src, at, at + 2));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-START-INCLUSIVE')
	public function testSpanEndingAtTheRegionStartIsNotAComment(): Void {
		final src: String = 'var a = 1; // note';
		final open: Int = src.indexOf('//');
		Assert.isFalse(has(src, 0, open));
	}

	public function testSpanOverlappingTheRegionStartByOneByteIsAComment(): Void {
		final src: String = 'var a = 1; // note';
		final open: Int = src.indexOf('//');
		Assert.isTrue(has(src, 0, open + 1));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-END-INCLUSIVE')
	public function testSpanStartingAtTheRegionEndIsNotAComment(): Void {
		final src: String = 'var a = /* note */ 1;';
		final close: Int = src.indexOf('*/') + 2;
		Assert.isFalse(has(src, close, src.length));
	}

	public function testSpanOverlappingTheRegionEndByOneByteIsAComment(): Void {
		final src: String = 'var a = /* note */ 1;';
		final close: Int = src.indexOf('*/') + 2;
		Assert.isTrue(has(src, close - 1, src.length));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-EMPTY-SPAN-SCANNED')
	public function testEmptyAndReversedSpansAreNotAComment(): Void {
		final src: String = 'var a = /* note */ 1;';
		final at: Int = src.indexOf('note');
		Assert.isFalse(has(src, at, at));
		Assert.isFalse(has(src, at + 2, at));
	}

	public function testCommentFreeSourceIsNotAComment(): Void {
		final src: String = 'var a = 1;';
		Assert.isFalse(has(src, 0, src.length));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-HOLE-BLIND')
	public function testBlockCommentInsideAnInterpolationHoleIsAComment(): Void {
		final src: String = "var s = '${a /* c */ + b}';";
		Assert.isTrue(has(src, 0, src.length));
		Assert.isTrue(SourceComments.hasCommentMarker(src, 0, src.length));
	}

	@:pin('control')
	@:killer('M-SPAN-COMMENT-HOLE-BLIND')
	public function testLineCommentInsideAnInterpolationHoleIsAComment(): Void {
		final src: String = "var s = '${f(a) // x\n}';";
		Assert.isTrue(has(src, 0, src.length));
	}

	public function testSpanInsideTheHoleButOutsideItsCommentIsNotAComment(): Void {
		final src: String = "var s = '${a /* c */ + b}';";
		final at: Int = src.indexOf('+ b');
		Assert.isFalse(has(src, at, src.length));
	}

	public function testMarkerInTheLiteralTextAroundAHoleIsNotAComment(): Void {
		final src: String = "var s = 'http://${a} // y';";
		Assert.isFalse(has(src, 0, src.length));
	}

	private function has(src: String, from: Int, to: Int): Bool {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(src);
		return LexicalRegions.commentIntersects(from, to, regions);
	}

}
