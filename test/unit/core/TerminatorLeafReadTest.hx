package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;
import anyparse.format.wrap.WrapList;

/**
 * Which terminator an item ends on (`;`, `}`, `#end`) is read off its last code leaf's tag, never its bytes.
 */
@:nullSafety(Strict)
class TerminatorLeafReadTest extends Test {

	/**
	 * A `;` literal is tagged a terminator; a region terminal is tagged closing only when it ends on its `#end`.
	 */
	@:pin('control')
	@:killer('M-TERMLEAF-SEMI-PLAIN')
	@:killer('M-TERMLEAF-REGION-PLAIN')
	public function testTagOfReadsTheTerminator(): Void {
		Assert.same(Delimiter(NoOpen, Terminator), DelimiterLeaf.tagOf(';'));
		Assert.same(Delimiter(NoOpen, ClosesRegion), DelimiterLeaf.tagOf('#end'));
		Assert.isTrue(WrapList.endsWithCondEnd(DelimiterLeaf.regionLeaf('#if x a\n#end')));
		Assert.isFalse(WrapList.endsWithCondEnd(DelimiterLeaf.regionLeaf('#if x')));
	}

	/** The `;` reader asks the tag: a tagged `;` ends the item, the same byte untagged does not. */
	@:pin('control')
	@:killer('M-TERMLEAF-SEMI-BYTES')
	public function testSemiReadsTheTag(): Void {
		Assert.isTrue(DocMeasure.endsWithSemi(Concat([Text('a'), DelimiterLeaf.leaf(';'), Line(' ')])));
		Assert.isFalse(DocMeasure.endsWithSemi(Concat([Text('a;')])));
	}

	/** A trailing comment is skipped: `a; // c` ends on its `;`, and `a // x;` does not. */
	@:pin('control')
	@:killer('M-TERMLEAF-COMMENT-READ')
	public function testTrailingCommentIsSkipped(): Void {
		Assert.isTrue(DocMeasure.endsWithSemi(Concat([Text('a'), DelimiterLeaf.leaf(';'), Text(' // c', true, LineComment)])));
		Assert.isFalse(DocMeasure.endsWithSemi(Concat([Text('a'), Text('// x;', true, LineComment)])));
	}

	/** A statement ends terminated on a tagged `}` or `;`. */
	@:pin('control')
	@:killer('M-TERMLEAF-STMT-SEMI-OFF')
	public function testStmtTerminatorReadsBoth(): Void {
		Assert.isTrue(DocMeasure.endsWithStmtTerminator(Concat([Text('a'), DelimiterLeaf.leaf(';')])));
		Assert.isTrue(DocMeasure.endsWithStmtTerminator(Concat([Text('a'), DelimiterLeaf.leaf('}')])));
		Assert.isFalse(DocMeasure.endsWithStmtTerminator(Concat([Text('a}')])));
	}

	/** A conditional-region operand ends on `#end` by its tag, not by the same bytes untagged. */
	@:pin('control')
	@:killer('M-TERMLEAF-CONDEND-OFF')
	public function testCondEndReadsTheTag(): Void {
		Assert.isTrue(WrapList.endsWithCondEnd(Concat([Text('a'), DelimiterLeaf.leaf('#end')])));
		Assert.isFalse(WrapList.endsWithCondEnd(Text('#end')));
	}

}
