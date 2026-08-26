package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * `SymbolIndex.hasSubtype` across TYPEDEF ALIASES — the walk `subtypesOf` does over the alias
 * edges before it answers, and the two alias shapes it deliberately stops at.
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
	 * The two alias shapes the walk deliberately does NOT follow, pinned so a later reader finds
	 * the boundary stated rather than guesses at it:
	 *
	 *  - `import pkg.Named as Alias;` — `ImportInfo` records only the alias NAME, never the path
	 *    it points at (the grammar puts nothing else in an `ImportAliasDecl`s name slot), so the
	 *    index cannot follow it at all. Closing it means the builder slicing that path out of the
	 *    declaration's source, a decoder `ModuleScan` and `MapScopeScan` already hold a copy of
	 *    each — so the fix is one shared decoder, not a third.
	 *  - a `#if`-GUARDED `typedef` — `aliasTargetNominal` is null for one by construction, because
	 *    every branch projects under one `Conditional` and following the indexed branch would
	 *    commit to whichever happened to be first.
	 *
	 * Both are UNSOUND in the same direction as the defect above, so a slice that closes either
	 * should DELETE the matching assertion, never weaken it.
	 */
	public function testAliasShapesTheSubtypeWalkDoesNotFollow(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Named.hx', source: 'package pkg;\nclass Named {}' },
			{ file: 'pkg/ByImport.hx', source: 'package pkg;\nimport pkg.Named as Alias;\nclass ByImport extends Alias {}' },
			{ file: 'pkg/Guarded.hx', source: 'package pkg;\nclass Guarded {}' },
			{
				file: 'pkg/GuardedAlias.hx',
				source: 'package pkg;\n#if js\ntypedef GuardedAlias = Guarded;\n#else\ntypedef GuardedAlias = Named;\n#end'
			},
			{ file: 'pkg/SubGuarded.hx', source: 'package pkg;\nclass SubGuarded extends GuardedAlias {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isFalse(index.hasSubtype('Named'), 'an `import ... as` alias is not followed');
		Assert.isFalse(index.hasSubtype('Guarded'), 'a `#if`-guarded typedef is not followed');
		Assert.isTrue(index.hasSubtype('Alias'), 'the written name still answers, so the subtype is not lost');
		Assert.isTrue(index.hasSubtype('GuardedAlias'), 'the written name still answers there too');
	}

}
