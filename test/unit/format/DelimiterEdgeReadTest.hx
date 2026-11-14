package unit.format;

import anyparse.core.Doc;
import anyparse.core.LeafTag;
import anyparse.format.wrap.WrapList;

/** `WrapList`'s delimiter-edge walkers read the leaf's tag, never its first or last byte. */
@:nullSafety(Strict)
class DelimiterEdgeReadTest extends Test {

	/** A tagged open leaf opens a delimiter; the same bytes untagged — a string fragment, say — do not. */
	@:pin('control')
	@:killer('M-DELIMEDGE-OPEN-READS-TAG')
	public function testOpenIsReadFromTheTag(): Void {
		Assert.isTrue(WrapList.startsWithOpenDelim(Concat([DelimiterLeaf.leaf('('), Text('a')])));
		Assert.isFalse(WrapList.startsWithOpenDelim(Concat([Text('('), Text('a')])));
	}

	/** A tagged collection open is a collection delimiter; a paren is not, nor are untagged bytes. */
	@:pin('control')
	@:killer('M-DELIMEDGE-COLLECTION-READS-TAG')
	public function testCollectionOpenIsReadFromTheTag(): Void {
		Assert.isTrue(WrapList.startsWithCollectionDelim(DelimiterLeaf.leaf('{')));
		Assert.isFalse(WrapList.startsWithCollectionDelim(DelimiterLeaf.leaf('(')));
		Assert.isFalse(WrapList.startsWithCollectionDelim(Text('{')));
	}

	/** A tagged close leaf closes a delimiter; the same bytes untagged do not. */
	@:pin('control')
	@:killer('M-DELIMEDGE-CLOSE-READS-TAG')
	public function testCloseIsReadFromTheTag(): Void {
		Assert.isTrue(WrapList.endsWithCloseDelim(Concat([Text('a'), DelimiterLeaf.leaf(')')])));
		Assert.isFalse(WrapList.endsWithCloseDelim(Concat([Text('a'), Text(')')])));
	}

	/** A brace close is a close too: the delimiter-close verdict holds for a tagged `}`, and not for the same byte untagged. */
	@:pin('control')
	@:killer('M-DELIMEDGE-CLOSE-BRACE-DROPPED')
	public function testBraceCloseIsAClose(): Void {
		Assert.isTrue(WrapList.endsWithCloseDelim(Concat([Text('a'), DelimiterLeaf.leaf('}')])));
		Assert.isFalse(WrapList.endsWithCloseDelim(Concat([Text('a'), Text('}')])));
	}

}
