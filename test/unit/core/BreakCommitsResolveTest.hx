package unit.core;

import anyparse.core.BreakCommits;
import anyparse.core.BreakToken;
import anyparse.core.Doc;
import anyparse.core.Renderer;
import anyparse.core.ResolvedDoc;
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

	/**
	 * The decisions `resolveMeasured` hands back are a measure of exactly the Doc it returns: a decision node above an
	 * offer that is rebuilt when the offer resolves is recorded as the rebuilt node, so `CollapsePass` can key its rewrite
	 * by them without a measure render of its own.
	 */
	@:pin('control')
	@:killer('M-DECISIONS-OF-ANOTHER-DOC')
	public function testTheMeasureDecisionsAreOfTheResolvedDoc(): Void {
		final offer: Doc = Doc.BreakCommit(Doc.Text('brk'), Doc.Text('flat'), new BreakToken());
		final doc: Doc = Doc.IfFullLineExceeds(80, Doc.Concat([Doc.Text('('), offer]), Doc.Concat([Doc.Text('x'), offer]));
		final resolved: ResolvedDoc = BreakCommits.resolveMeasured(doc, 80, IndentChar.Tab, 4, 1);
		final decisions: Null<Array<{ node: Doc, crosses: Bool, ?indent: Int }>> = resolved.decisions;
		if (decisions == null) {
			Assert.fail('a Doc holding an offer is measured');
			return;
		}
		final fresh: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];
		Renderer.render(resolved.doc, 80, IndentChar.Tab, 4, 1, '\n', false, false, -1, fresh); // noqa: unused-return-value
		Assert.isTrue(fresh.length > 0, 'the fixture records a decision');
		Assert.equals(fresh.length, decisions.length);
		for (i => e in fresh) {
			Assert.isTrue(e.node == decisions[i].node, 'decision $i is keyed by a node of the resolved Doc');
			Assert.equals(e.crosses, decisions[i].crosses);
		}
	}

	private static function resolved(doc: Doc): Doc {
		return BreakCommits.resolve(doc, 80, IndentChar.Tab, 4, 1);
	}

}
