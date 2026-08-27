package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * `SymbolIndex.hasSubtype` across TYPEDEF and IMPORT aliases — the walk `subtypesOf` does
 * over the alias edges before it answers, and the one alias shape it deliberately stops at.
 *
 * Its own class rather than three more methods on `SymbolIndexSliceTest`, which sits at exactly
 * the `oversized-type` cap: any addition there trips the advisory, and "decompose" is what the
 * advisory asks for.
 *
 * The defect these pin is a wrong DELETION, not a wrong report. `class Bad extends U` where
 * `typedef U = Util` puts `U` in `supertypes`, so keying the adjacency on the WRITTEN name alone
 * answered "`Util` has no subtype" on a fully parseable tree; every consumer reads that answer as
 * a licence, and `unused-private --fix` deleted a private constructor that `Bad`s `super()`
 * calls (verified against Haxe 4.3.7: the tree then failed with `Util does not have a
 * constructor`).
 */
class SymbolIndexAliasSliceTest extends Test {

	/**
	 * Three alias shapes, all transitive through one walk: a single hop, a two-hop chain, and a
	 * target written QUALIFIED in another package. The alias's OWN name keeps answering too —
	 * nothing that worked before stops working — and a type nothing extends still has no subtype,
	 * so the walk cannot be passing by saying yes to everything.
	 */
	public function testSubtypeThroughTypedefAlias(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/One.hx', source: 'package pkg;\nclass One {}' },
			{ file: 'pkg/AliasOne.hx', source: 'package pkg;\ntypedef AliasOne = One;' },
			{ file: 'pkg/SubOne.hx', source: 'package pkg;\nclass SubOne extends AliasOne {}' },
			{ file: 'pkg/Two.hx', source: 'package pkg;\nclass Two {}' },
			{ file: 'pkg/MidTwo.hx', source: 'package pkg;\ntypedef MidTwo = Two;' },
			{ file: 'pkg/HeadTwo.hx', source: 'package pkg;\ntypedef HeadTwo = MidTwo;' },
			{ file: 'pkg/SubTwo.hx', source: 'package pkg;\nclass SubTwo extends HeadTwo {}' },
			{ file: 'far/Three.hx', source: 'package far;\nclass Three {}' },
			{ file: 'pkg/AliasThree.hx', source: 'package pkg;\ntypedef AliasThree = far.Three;' },
			{ file: 'pkg/SubThree.hx', source: 'package pkg;\nclass SubThree extends AliasThree {}' },
			{ file: 'pkg/Lonely.hx', source: 'package pkg;\nclass Lonely {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('One'), 'a one-hop typedef alias of the supertype');
		Assert.isTrue(index.hasSubtype('Two'), 'a two-hop typedef alias chain');
		Assert.isTrue(index.hasSubtype('Three'), 'a typedef whose target is written qualified, in another package');
		Assert.isTrue(index.hasSubtype('AliasOne'), 'the alias name itself still answers');
		Assert.isFalse(index.hasSubtype('Lonely'), 'and a type nothing extends still has no subtype');
	}

	/**
	 * The alias walk terminates on a CYCLE. `typedef A = B; typedef B = A` is not legal Haxe, but
	 * the index is name-keyed and builds its adjacency from whatever a corpus holds, so the walk
	 * has to stop on its own rather than by trusting the input.
	 */
	public function testAliasCycleDoesNotHangTheAdjacency(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Loop.hx', source: 'package pkg;\ntypedef Loop = Ring;' },
			{ file: 'pkg/Ring.hx', source: 'package pkg;\ntypedef Ring = Loop;' },
			{ file: 'pkg/Spin.hx', source: 'package pkg;\nclass Spin extends Loop {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('Loop'));
		Assert.isTrue(index.hasSubtype('Ring'));
	}

	/**
	 * The IMPORT alias, in both spellings the grammar projects (`as` and `in`) and with the target
	 * written qualified in another package. The grammar puts only the alias in the node's name
	 * slot, so the path comes out of `ImportInfo.aliasTarget`, decoded from the statement source.
	 *
	 * Import aliases are per-FILE, and `ByImport.hx` / `ByIn.hx` pin that: both bind the name
	 * `Alias`, to different targets, and each subtype lands under ITS OWN target — a single
	 * project-wide alias map could only answer one of the two.
	 */
	public function testSubtypeThroughImportAlias(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Named.hx', source: 'package pkg;\nclass Named {}' },
			{ file: 'pkg/ByImport.hx', source: 'package pkg;\nimport pkg.Named as Alias;\nclass ByImport extends Alias {}' },
			{ file: 'pkg/InForm.hx', source: 'package pkg;\nclass InForm {}' },
			{ file: 'pkg/ByIn.hx', source: 'package pkg;\nimport pkg.InForm in Alias;\nclass ByIn extends Alias {}' },
			{ file: 'far/Distant.hx', source: 'package far;\nclass Distant {}' },
			{ file: 'pkg/ByFar.hx', source: 'package pkg;\nimport far.Distant as D;\nclass ByFar extends D {}' },
			{ file: 'pkg/Lonely.hx', source: 'package pkg;\nclass Lonely {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('Named'), 'an `import ... as` alias is followed');
		Assert.isTrue(index.hasSubtype('InForm'), 'and so is the `import ... in` spelling');
		Assert.isTrue(index.hasSubtype('Distant'), 'a target in another package resolves through its qualified path');
		Assert.isTrue(index.hasSubtype('Alias'), 'the written name still answers, so nothing that worked before stops');
		Assert.isFalse(index.hasSubtype('Lonely'), 'and a type nothing extends still has no subtype');
	}

	/**
	 * The two alias kinds COMPOSE, in either order: an import alias of a typedef, and a typedef
	 * whose target is an import alias. The import hop is consulted inside the closure walk rather
	 * than only on the written supertype name, which is what makes the second direction work.
	 */
	public function testImportAliasComposesWithTypedefAlias(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Root.hx', source: 'package pkg;\nclass Root {}' },
			{ file: 'pkg/Mid.hx', source: 'package pkg;\ntypedef Mid = Root;' },
			{ file: 'pkg/ByImportOfTypedef.hx', source: 'package pkg;\nimport pkg.Mid as M;\nclass ByImportOfTypedef extends M {}' },
			{ file: 'pkg/Leaf.hx', source: 'package pkg;\nclass Leaf {}' },
			{ file: 'pkg/Hop.hx', source: 'package pkg;\nimport pkg.Leaf as L;\ntypedef Hop = L;' },
			{ file: 'pkg/ByTypedefOfImport.hx', source: 'package pkg;\nclass ByTypedefOfImport extends Hop {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('Root'), 'an import alias of a typedef reaches the typedef target');
		Assert.isTrue(index.hasSubtype('Leaf'), 'a typedef of an import alias reaches the imported target');
	}

	/**
	 * The one alias shape the walk deliberately does NOT follow, pinned so a later reader finds the
	 * boundary stated rather than guesses at it: a `#if`-GUARDED `typedef`, whose
	 * `aliasTargetNominal` is null by construction, because every branch projects under one
	 * `Conditional` and following the indexed branch would commit to whichever happened to be
	 * first.
	 *
	 * It is UNSOUND in the same direction as the defect above, so a slice that closes it should
	 * DELETE the assertion, never weaken it.
	 */
	public function testGuardedTypedefTheSubtypeWalkDoesNotFollow(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Named.hx', source: 'package pkg;\nclass Named {}' },
			{ file: 'pkg/Guarded.hx', source: 'package pkg;\nclass Guarded {}' },
			{
				file: 'pkg/GuardedAlias.hx',
				source: 'package pkg;\n#if js\ntypedef GuardedAlias = Guarded;\n#else\ntypedef GuardedAlias = Named;\n#end'
			},
			{ file: 'pkg/SubGuarded.hx', source: 'package pkg;\nclass SubGuarded extends GuardedAlias {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isFalse(index.hasSubtype('Guarded'), 'a `#if`-guarded typedef is not followed');
		Assert.isTrue(index.hasSubtype('GuardedAlias'), 'the written name still answers, so the subtype is not lost');
	}

	/**
	 * The residue this slice leaves, pinned in the direction it errs. A `#if` region whose
	 * branches bind ONE alias name to DIFFERENT targets keeps only the FIRST:
	 * `SymbolIndexBuilder.importDedupKey` keys an alias statement as `alias|<the alias NAME>`,
	 * so the second branch is dropped as a duplicate, and `importAliasEdges` maps one alias to
	 * one target rather than to an array. Either mechanism alone would lose it.
	 *
	 * This is the UNSAFE direction — the other compilation's target is left with no subtype, so
	 * a private member it reaches is offered for deletion — and it is NOT a regression: before
	 * `ImportInfo.aliasTarget` existed neither branch was followed. Pinned rather than fixed
	 * because closing it needs a target-bearing dedup key AND multi-valued edges. A slice that
	 * closes it should DELETE the `isFalse`, never weaken it.
	 */
	public function testGuardedImportAliasFollowsOnlyTheFirstBranch(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/First.hx', source: 'package pkg;\nclass First {}' },
			{ file: 'pkg/Second.hx', source: 'package pkg;\nclass Second {}' },
			{
				file: 'pkg/Both.hx',
				source: 'package pkg;\n#if js\nimport pkg.First as U;\n#else\nimport pkg.Second as U;\n#end\nclass Both extends U {}'
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(index.hasSubtype('First'), 'the first branch is followed');
		Assert.isFalse(index.hasSubtype('Second'), 'the second binding of the same alias name is dropped');
	}

}
