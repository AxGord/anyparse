package unit.core;

import anyparse.core.BreakCommits;
import anyparse.core.BreakToken;
import anyparse.core.Doc;
import utest.Assert;
import utest.Test;

/**
 * `BreakCommits.replaced` copies only the path to its target, on the side every walker reads — the bound that keeps a
 * host offering every nested break polynomial in the nesting depth.
 */
@:nullSafety(Strict)
final class BreakCommitsReplacedTest extends Test {

	/** A subtree that does not hold the target comes back as the same node, so the offers share all but their own path. */
	@:pin('control')
	@:killer('M-OFFER-COPIES-WHOLE')
	public function testAnUntouchedSiblingIsShared(): Void {
		final target: Doc = Doc.Text('t');
		final sibling: Doc = Doc.Concat([Doc.Text('a'), Doc.Text('b')]);
		switch BreakCommits.replaced(Doc.Concat([Doc.Group(target), sibling]), target, Doc.Text('u')) {
			case Concat([Group(Text('u', _)), kept]):
				Assert.isTrue(kept == sibling, 'the untouched sibling must be the same node');
			case other:
				Assert.fail('unexpected shape: $other');
		}
	}

	/** Another break's alternative is not rewritten: its `brk` side comes back as the same node. */
	@:pin('control')
	@:killer('M-OFFER-REPLACES-BOTH-SIDES')
	public function testAnotherBreaksAlternativeIsLeftAlone(): Void {
		final target: Doc = Doc.Text('t');
		final brk: Doc = Doc.Concat([target, Doc.Text('x')]);
		switch BreakCommits.replaced(Doc.BreakCommit(brk, Doc.Concat([target]), new BreakToken()), target, Doc.Text('u')) {
			case BreakCommit(kept, Concat([Text('u', _)]), _):
				Assert.isTrue(kept == brk, 'the other break\'s alternative must be the same node');
			case other:
				Assert.fail('unexpected shape: $other');
		}
	}

}
