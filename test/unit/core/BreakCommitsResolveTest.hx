package unit.core;

import anyparse.core.BreakCommits;
import anyparse.core.BreakToken;
import anyparse.core.Doc;
import anyparse.format.IndentChar;

/**
 * `BreakCommits.resolve` leaves no `BreakCommit` behind: a committed break (no token) settles to its `flat` side without
 * a measure render, and one carrying a token still goes through the measure, which takes the flat side when nothing
 * in the Doc took its break.
 */
@:nullSafety(Strict)
final class BreakCommitsResolveTest extends Test {

	/** Only committed breaks: each settles to its `flat` side, and a subtree holding none comes back as the same node. */
	@:pin('control')
	@:killer('M-SETTLE-KEEPS-COMMITTED')
	public function testACommittedBreakSettlesToItsFlatSide(): Void {
		final sibling: Doc = Doc.Concat([Doc.Text('a'), Doc.Text('b')]);
		final doc: Doc = Doc.Concat([Doc.Group(BreakCommits.committed(Doc.Text('brk'), Doc.Text('flat'))), sibling]);
		switch resolved(doc) {
			case Concat([Group(Text('flat', _)), kept]):
				Assert.isTrue(kept == sibling, 'the subtree holding no commit must be the same node');
			case other:
				Assert.fail('unexpected shape: $other');
		}
	}

	/** A break with a token beside a committed one is still resolved, by the measure render, to its flat side. */
	@:pin('control')
	@:killer('M-SETTLE-SKIPS-TOKEN')
	public function testATokenBreakIsResolvedByTheMeasure(): Void {
		final doc: Doc = Doc.Concat([
			Doc.BreakCommit(Doc.Text('brk'), Doc.Text('flat'), new BreakToken()),
			BreakCommits.redecided(Doc.Text('kept'))
		]);
		switch resolved(doc) {
			case Concat([Text('flat', _), Text('kept', _)]):
				Assert.pass();
			case other:
				Assert.fail('unexpected shape: $other');
		}
	}

	/** A Doc holding no `BreakCommit` comes back as itself. */
	@:pin('guard')
	public function testADocWithoutCommitsIsItself(): Void {
		final doc: Doc = Doc.Concat([Doc.Text('a'), Doc.Group(Doc.Text('b'))]);
		Assert.isTrue(resolved(doc) == doc);
	}

	private static function resolved(doc: Doc): Doc {
		return BreakCommits.resolve(doc, 80, IndentChar.Tab, 4, 1);
	}

}
