package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;
import anyparse.format.wrap.WrapList;

/**
 * A leaf that ends on a decimal digit, or starts with a `.`, says so through its tag, set where the writer builds it, so
 * the interval writer and the method-chain reader never re-read the leaf's bytes. The sweep
 * that holds each tag equal to the bytes' answer over written Docs is `WordStartLeafTest`'s.
 */
@:nullSafety(Strict)
class ValueLeafTagTest extends Test {

	/** A constant literal is classified by its first and last byte: a leading dot opens, a trailing digit ends. */
	@:pin('control')
	@:killer('M-VALUELEAF-DIGIT-TAGOF')
	@:killer('M-VALUELEAF-DOT-OPEN')
	public function testTagOfReadsDotAndDigit(): Void {
		Assert.same(LeafTag.Delimiter(Dot, Plain), DelimiterLeaf.tagOf('...'));
		Assert.same(LeafTag.Delimiter(Dot, Digit), DelimiterLeaf.tagOf('.5'));
		Assert.same(LeafTag.Delimiter(WordStart, Digit), DelimiterLeaf.tagOf('x1'));
		Assert.same(LeafTag.Delimiter(NoOpen, Digit), DelimiterLeaf.tagOf('42'));
		Assert.same(LeafTag.Delimiter(NoOpen, Closes), DelimiterLeaf.tagOf(')'));
		Assert.isNull(DelimiterLeaf.tagOf(' .'));
		Assert.isFalse(DelimiterLeaf.startsWithDot(DelimiterLeaf.tagOf(' .')));
		Assert.isFalse(DelimiterLeaf.endsWithDigit(DelimiterLeaf.tagOf('1 ')));
	}

	/** A runtime string is classified by the same two bytes where the leaf is built. */
	@:pin('control')
	@:killer('M-VALUELEAF-DIGIT-RUNTIME')
	public function testRuntimeLeafReadsDotAndDigit(): Void {
		Assert.same(Text('.field', null, Delimiter(Dot, Plain)), DelimiterLeaf.runtimeLeaf('.field'));
		Assert.same(Text('0xF1', null, Delimiter(NoOpen, Digit)), DelimiterLeaf.runtimeLeaf('0xF1'));
		Assert.same(Text('n1', null, Delimiter(WordStart, Digit)), DelimiterLeaf.runtimeLeaf('n1'));
		Assert.same(Text('1 ', null, null), DelimiterLeaf.runtimeLeaf('1 '));
		Assert.same(Text('', null, null), DelimiterLeaf.runtimeLeaf(''));
	}

	/** The interval writer's digit test asks the last leaf's tag: a tagged digit end answers, the same bytes untagged do not. */
	@:pin('control')
	@:killer('M-VALUELEAF-DIGIT-READ')
	public function testDigitReaderAsksTheTag(): Void {
		Assert.isTrue(WrapList.endsWithDecimalDigit(Concat([Text('i + '), DelimiterLeaf.runtimeLeaf('1')])));
		Assert.isFalse(WrapList.endsWithDecimalDigit(Concat([Text('i + '), Text('1')])));
		Assert.isFalse(WrapList.endsWithDecimalDigit(Concat([DelimiterLeaf.runtimeLeaf('1'), Text(')')])));
	}

	/** A chain link behind a hardline is read off the first leaf's tag: a tagged leading dot answers, the same bytes untagged do not. */
	@:pin('control')
	@:killer('M-VALUELEAF-DOT-READ')
	public function testDotReaderAsksTheTag(): Void {
		Assert.isTrue(DocMeasure.startsWithDot(Concat([Empty, DelimiterLeaf.runtimeLeaf('.map')])));
		Assert.isFalse(DocMeasure.startsWithDot(Concat([Empty, Text('.map')])));
		Assert.isFalse(DocMeasure.startsWithDot(Concat([DelimiterLeaf.runtimeLeaf('x'), DelimiterLeaf.runtimeLeaf('.map')])));
	}

	/** A dot-led leaf opens no run: a chain link before `(` is no open delimiter by itself, like a name. */
	@:pin('control')
	@:killer('M-VALUELEAF-DOT-NOT-AN-OPENER')
	public function testDotOpensNoRun(): Void {
		Assert.isNull(DocMeasure.flatPrefixToOpenDelim(DelimiterLeaf.runtimeLeaf('...')));
		final link: Doc = DelimiterLeaf.runtimeLeaf('.map');
		Assert.equals(5, DocMeasure.flatPrefixToOpenDelim(Concat([link, Text('(', null, Delimiter(Paren, Plain))])));
	}

}
