package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;

/**
 * Whether an operand is a call is read off the tag of its call's open
 * leaf, which the call writer names; never off the bytes before a `(`.
 */
@:nullSafety(Strict)
class CallOpenTagReadTest extends Test {

	/** A name followed by a leaf tagged as a call's open is a call; the same `(` untagged (a keyword's or a group's paren) is not. */
	@:pin('control')
	@:killer('M-CALLOPEN-READS-TAG')
	public function testACallIsReadOffTheOpenTag(): Void {
		Assert.isTrue(DocMeasure.operandIsCall(Concat([Text('a.f'), DelimiterLeaf.callArgs(args())])));
		Assert.isFalse(DocMeasure.operandIsCall(Concat([Text('if '), args()])));
	}

	/** An operand whose first visible byte does not start a name is not a simple call, whatever call it holds. */
	@:pin('control')
	@:killer('M-CALLOPEN-HEAD-NAME')
	public function testAPrefixedOperandIsNotACall(): Void {
		Assert.isFalse(DocMeasure.operandIsCall(Concat([Text('!'), Text('f'), DelimiterLeaf.callArgs(args())])));
		Assert.isTrue(DocMeasure.operandIsCall(Concat([Text(' '), Text('f'), DelimiterLeaf.callArgs(args())])));
	}

	/** The call writer names the open of every layout its argument run offers, the broken one and the flat one. */
	@:pin('control')
	@:killer('M-CALLARGS-EVERY-LAYOUT')
	public function testEveryLayoutOfTheRunOpensACall(): Void {
		switch DelimiterLeaf.callArgs(Group(IfBreak(args(), args()))) {
			case Group(IfBreak(brk, flat)):
				Assert.isTrue(opensCall(brk));
				Assert.isTrue(opensCall(flat));
			case _:
				Assert.fail('the run keeps its shape');
		}
	}

	/** Only the run's head is named: a run that leads with something else, and a paren nested after the head, stay as built. */
	@:pin('control')
	@:killer('M-CALLARGS-HEAD-ONLY')
	public function testOnlyTheHeadOfTheRunIsNamed(): Void {
		switch DelimiterLeaf.callArgs(Concat([Text('x'), DelimiterLeaf.leaf('(')])) {
			case Concat([_, Text(_, _, tag)]):
				Assert.isFalse(DelimiterLeaf.opensCallArgs(tag));
			case _:
				Assert.fail('the run keeps its shape');
		}
		switch DelimiterLeaf.callArgs(Concat([DelimiterLeaf.leaf('('), DelimiterLeaf.leaf('(')])) {
			case Concat([Text(_, _, head), Text(_, _, nested)]):
				Assert.isTrue(DelimiterLeaf.opensCallArgs(head));
				Assert.isFalse(DelimiterLeaf.opensCallArgs(nested));
			case _:
				Assert.fail('the run keeps its shape');
		}
	}

	/** An empty call `()` is one leaf: named a call's open, it still closes the run at its end. */
	@:pin('control')
	@:killer('M-CALLARGS-KEEPS-END-EDGE')
	public function testAnEmptyCallKeepsItsCloseEdge(): Void {
		switch DelimiterLeaf.callArgs(DelimiterLeaf.leaf('()')) {
			case Text('()', _, Delimiter(CallArgs, Closes)):
				Assert.pass();
			case other:
				Assert.fail('expected a call open closing at its end, got $other');
		}
	}

	private static function args(): Doc {
		return Concat([DelimiterLeaf.leaf('('), Text('a'), DelimiterLeaf.leaf(')')]);
	}

	private static function opensCall(d: Doc): Bool {
		return switch DocMeasure.firstVisibleLeaf(d) {
			case Text(_, _, tag): DelimiterLeaf.opensCallArgs(tag);
			case _: false;
		};
	}

}
