package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;

/** The first open delimiter of a chain segment is read off its leaf tags, never its bytes. */
@:nullSafety(Strict)
class OpenDelimPrefixReadTest extends Test {

	/** A leaf opening at its first byte ends the prefix after that byte; one opening at its end edge, after its last non-blank byte. */
	@:pin('control')
	@:killer('M-OPENDELIM-FIRST-BYTE')
	public function testPrefixEndsAfterAFirstByteOpener(): Void {
		Assert.equals(5, DocMeasure.flatPrefixToOpenDelim(Concat([Text('.f'), Line(' '), Text('x'), DelimiterLeaf.leaf('('), Text('a')])));
		Assert.equals(3, DocMeasure.flatPrefixToOpenDelim(Concat([Text('.f'), DelimiterLeaf.leaf('['), DelimiterLeaf.leaf('(')])));
	}

	/** A composite leaf such as `foo( ` opens at its end edge: the prefix stops at its last non-blank byte. */
	@:pin('control')
	@:killer('M-OPENDELIM-END-EDGE')
	public function testPrefixEndsAtAnEndEdgeOpener(): Void {
		Assert.equals(5, DocMeasure.flatPrefixToOpenDelim(Concat([Text('.'), DelimiterLeaf.leaf('foo( '), Text('a')])));
	}

	/** A bracket inside an untagged leaf (a string literal) opens nothing, and a segment with no tagged opener has no prefix. */
	@:pin('control')
	@:killer('M-OPENDELIM-BYTES')
	public function testUntaggedBracketOpensNothing(): Void {
		Assert.isNull(DocMeasure.flatPrefixToOpenDelim(Concat([Text('.f'), Text('"a(b"')])));
		Assert.equals(8, DocMeasure.flatPrefixToOpenDelim(Concat([Text('.f'), Text('"a(b"'), DelimiterLeaf.leaf('(')])));
	}

}
