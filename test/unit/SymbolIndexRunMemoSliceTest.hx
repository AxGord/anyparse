package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * The two RUN-scoped memos on `SymbolIndex` — `supertypeNameUnion` and `sourceCarriesAllowGrant`
 * — and the gate that reads the second one.
 *
 * Both replace work that used to be redone per CALLER ASK rather than per file: the supertype map
 * was rebuilt from `allFiles()` x `types` for every method the framework carve-outs asked about
 * (2.1s of a 95s project lint), and the `@:allow` scan re-read the whole source for every member a
 * confinement gate looked at (423ms of a 2.4s lint of one 416 KB file, ~19%). Neither changes an
 * answer, so nothing else in the suite can tell a live memo from a dead one — which is what these
 * tests are for, and why each asserts the MECHANISM (the same map object comes back; the gate
 * consults the slot) and not only the answer.
 *
 * Its own class rather than more methods on `SymbolIndexSliceTest`, which sits at exactly the
 * `oversized-type` cap — the same reason `SymbolIndexAliasSliceTest` exists.
 */
@:access(anyparse.query.SymbolIndex)
class SymbolIndexRunMemoSliceTest extends Test {

	/**
	 * The supertype union map is built ONCE per index instance: the second ask hands back the very
	 * same object. Green at base BY CONSTRUCTION only while the memo is written; killed by arm M2,
	 * which drops the `_supertypeNames` assignment and rebuilds per call.
	 */
	public function testSupertypeNameUnionIsBuiltOncePerIndex(): Void {
		final index: SymbolIndex = build([
			{ file: 'pkg/Base.hx', source: 'package pkg;\nclass Base {}' },
			{ file: 'pkg/Mid.hx', source: 'package pkg;\nclass Mid extends Base {}' },
			{ file: 'pkg/Leaf.hx', source: 'package pkg;\nclass Leaf extends Mid {}' }
		]);
		final first: Map<String, Array<String>> = index.supertypeNameUnion();
		Assert.isTrue(first.exists('Leaf'));
		Assert.isTrue(index.supertypeNameUnion() == first);
		// A second index is a second run and gets its own map.
		Assert.isFalse(build([{ file: 'pkg/Base.hx', source: 'package pkg;\nclass Base {}' }]).supertypeNameUnion() == first);
	}

	/**
	 * Two files declaring the same simple name contribute BOTH their supertypes — the map reads as
	 * "SOME declaration of this name extends that one", which is the direction every consumer of it
	 * treats as "leave this member alone".
	 */
	public function testSupertypeNameUnionUnionsBothDeclarationsOfASimpleName(): Void {
		final index: SymbolIndex = build([
			{ file: 'p/Node.hx', source: 'package p;\nclass Node extends Alpha {}' },
			{ file: 'q/Node.hx', source: 'package q;\nclass Node extends Beta {}' }
		]);
		final supers: Null<Array<String>> = index.supertypeNameUnion()['Node'];
		Assert.notNull(supers);
		final names: Array<String> = supers ?? [];
		Assert.isTrue(names.contains('Alpha'), 'expected Alpha in $names');
		Assert.isTrue(names.contains('Beta'), 'expected Beta in $names');
	}

	/**
	 * The union appends to a COPY of each type's `supertypes`, never to the index's own array — an
	 * append there would rewrite the index for every later reader of that type. Asserted through
	 * `hasSubtype`, which walks the same declarations: the second declaration's supertype must not
	 * have become the first one's.
	 */
	public function testSupertypeNameUnionDoesNotRewriteTheIndex(): Void {
		final index: SymbolIndex = build([
			{ file: 'p/Node.hx', source: 'package p;\nclass Node extends Alpha {}' },
			{ file: 'q/Node.hx', source: 'package q;\nclass Node extends Beta {}' },
			{ file: 'p/Alpha.hx', source: 'package p;\nclass Alpha {}' },
			{ file: 'q/Beta.hx', source: 'package q;\nclass Beta {}' }
		]);
		Assert.notNull(index.supertypeNameUnion()['Node']);
		final info: Null<FileInfo> = index.fileInfo('p/Node.hx');
		Assert.notNull(info);
		final declared: Array<String> = info == null ? [] : info.types[0].supertypes;
		Assert.equals(1, declared.length);
		Assert.equals('Alpha', declared[0]);
	}

	/**
	 * The one-slot grant memo answers each source on its own merits, including when the walk
	 * alternates between files — the slot evicts, it never carries an answer across.
	 */
	public function testGrantMemoAnswersEachSourceOnItsOwnMerits(): Void {
		final granting: String = 'package p;\n@:allow(p.Other)\nclass A {\n\tprivate var x: Int = 1;\n}';
		final plain: String = 'package p;\nclass B {\n\tprivate var x: Int = 1;\n}';
		final index: SymbolIndex = build([{ file: 'p/A.hx', source: granting }, { file: 'p/B.hx', source: plain }]);
		for (i in 0...3) {
			Assert.isTrue(index.sourceCarriesAllowGrant(granting));
			Assert.isFalse(index.sourceCarriesAllowGrant(plain));
		}
		// Repeats of ONE source keep the same answer, which is what the slot is for.
		Assert.isTrue(index.sourceCarriesAllowGrant(granting));
		Assert.isTrue(index.sourceCarriesAllowGrant(granting));
		Assert.equals(granting, index._grantScanSource);
	}

	/**
	 * A tag inside a comment is not metadata, and the memo does not change that — the masking lives
	 * in `RefactorSupport.carriesAllowGrant`, which the slot fills from.
	 */
	public function testGrantMemoKeepsTheCommentMasking(): Void {
		final commented: String = 'package p;\n/** mentions @:allow in prose */\nclass A {}';
		final index: SymbolIndex = build([{ file: 'p/A.hx', source: commented }]);
		Assert.isFalse(index.sourceCarriesAllowGrant(commented));
		Assert.equals(RefactorSupport.carriesAllowGrant(commented, new HaxeQueryPlugin()), index.sourceCarriesAllowGrant(commented));
	}

	/**
	 * THE mechanism pin for the hoist: the confinement gate reads the INDEX's slot rather than
	 * rescanning the source itself. Seeding the slot with an answer the text does not support flips
	 * the gate — which it can only do if the gate goes through `sourceCarriesAllowGrant`. Green at
	 * base BY CONSTRUCTION; killed by arm M3, which puts the direct `carriesAllowGrant(source)` call
	 * back into `privateMemberScanIsSound`.
	 */
	public function testConfinementGateReadsTheIndexGrantSlot(): Void {
		final plain: String = 'package p;\nclass B {\n\tprivate var x: Int = 1;\n}';
		final index: SymbolIndex = build([{ file: 'p/B.hx', source: plain }]);
		Assert.isTrue(RefactorSupport.privateMemberScanIsSound(plain, index, 'x'));
		index._grantScanSource = plain;
		index._grantScanAnswer = true;
		Assert.isFalse(RefactorSupport.privateMemberScanIsSound(plain, index, 'x'));
	}

	private function build(files: Array<{ file: String, source: String }>): SymbolIndex {
		return SymbolIndex.build(files, new HaxeQueryPlugin());
	}

}
