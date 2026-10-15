package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.FieldWriteIndex;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * `IndexScope` is the one door onto index construction, and on a run host (`CachingGrammarPlugin`)
 * every answer comes from ONE build per file set. Nothing else in the suite can tell a live memo from
 * a dead one — a rebuilt index answers the same questions — so each test asserts the MECHANISM: the
 * same instance comes back for the same set, a fresh one for a set that changed.
 */
@:nullSafety(Strict)
class IndexScopeTest extends Test {

	private static final A: { file: String, source: String } = { file: 'p/A.hx', source: 'package p;\nclass A {}' };
	private static final B: { file: String, source: String } = { file: 'p/B.hx', source: 'package p;\nclass B extends A {}' };

	/**
	 * Two rules asking the report index over the same files share one build — a COPY of the array
	 * included, since a `FileGated` check is handed a filtered one. Killed by `M-INDEX-MEMO-OFF`
	 * (no memo hit) and `M-INDEXSCOPE-HOST-IGNORED` (the host is never asked).
	 */
	@:pin('control')
	@:killer('M-INDEX-MEMO-OFF')
	@:killer('M-INDEXSCOPE-HOST-IGNORED')
	public function testTheReportIndexIsBuiltOncePerFileSet(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: SymbolIndex = IndexScope.report([A, B], host);
		Assert.isTrue(IndexScope.report([A, B], host) == first);
		Assert.isTrue(IndexScope.over([A, B], host) == first);
		Assert.notNull(first.fileInfo('p/B.hx'));
	}

	/**
	 * Same paths, new text — a `--fix` pass — is a new index that sees the new text. Killed by
	 * `M-INDEX-MEMO-UNVALIDATED`, which answers any entry under the same paths.
	 */
	@:pin('control')
	@:killer('M-INDEX-MEMO-UNVALIDATED')
	public function testAChangedSourceIsRebuilt(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: SymbolIndex = IndexScope.report([A], host);
		final edited: SymbolIndex = IndexScope.report([{ file: A.file, source: 'package p;\nclass Renamed {}' }], host);
		Assert.isFalse(edited == first);
		Assert.equals('Renamed', edited.fileInfo(A.file)?.types[0]?.name);
	}

	/**
	 * A set and a different set never share an entry, even where a plain join of their paths would
	 * spell the same key (`ab` against `a` + `b`), and the third-party tag is part of the set. Killed
	 * by `M-INDEX-KEY-UNPREFIXED` and `M-INDEX-MEMO-TAG-IGNORED`.
	 */
	@:pin('control')
	@:killer('M-INDEX-KEY-UNPREFIXED')
	@:killer('M-INDEX-MEMO-TAG-IGNORED')
	public function testTheKeyTellsEveryFileSetApart(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final split: Array<{ file: String, source: String }> = [{ file: 'a', source: 'class X {}' }, { file: 'b', source: 'class Y {}' }];
		final first: SymbolIndex = IndexScope.report(split, host);
		IndexScope.report([{ file: 'ab', source: 'class X {}' }], host);
		Assert.isTrue(IndexScope.report(split, host) == first);
		final tagged: SymbolIndex = IndexScope.over([A], host, [A.file]);
		Assert.isTrue(tagged.isThirdParty(A.file));
		Assert.isFalse(IndexScope.report([A], host).isThirdParty(A.file));
		Assert.isTrue(IndexScope.over([A], host, [A.file]).isThirdParty(A.file));
	}

	/**
	 * The memo dies with the ambient-import memos at the head of a `--fix` pass: the build reads the
	 * ambient chain, which a previous pass may have rewritten. Killed by `M-INDEX-MEMO-OUTLIVES-AMBIENT`.
	 */
	@:pin('control')
	@:killer('M-INDEX-MEMO-OUTLIVES-AMBIENT')
	public function testTheMemoDiesWithTheAmbientChain(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: SymbolIndex = IndexScope.report([A], host);
		host.invalidateAmbientChain();
		Assert.isFalse(IndexScope.report([A], host) == first);
	}

	/**
	 * With no resolution scope the resolution and widest questions ARE the report question, and get
	 * the report build rather than a second one. Killed by `M-INDEXSCOPE-RESOLUTION-OWN-BUILD`.
	 */
	@:pin('control')
	@:killer('M-INDEXSCOPE-RESOLUTION-OWN-BUILD')
	public function testWithoutAScopeEveryQuestionSharesTheReportBuild(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final report: SymbolIndex = IndexScope.report([A, B], host);
		Assert.isTrue(IndexScope.resolution([A, B], host) == report);
		Assert.isTrue(IndexScope.widest([A, B], host) == report);
	}

	/**
	 * The report-scope write index is memoised the same way. Killed by `M-WRITE-INDEX-MEMO-OFF`.
	 */
	@:pin('control')
	@:killer('M-WRITE-INDEX-MEMO-OFF')
	public function testTheReportWriteIndexIsBuiltOncePerFileSet(): Void {
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: FieldWriteIndex = IndexScope.reportWrites([A, B], host);
		Assert.isTrue(IndexScope.reportWrites([A, B], host) == first);
		Assert.isTrue(IndexScope.resolutionWrites([A, B], host) == first);
	}

	/** A bare plugin has no run to memoise on: each ask builds, and answers the same index. */
	public function testABarePluginBuildsAfresh(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final first: SymbolIndex = IndexScope.report([A, B], plugin);
		final second: SymbolIndex = IndexScope.report([A, B], plugin);
		Assert.isFalse(first == second);
		Assert.notNull(second.fileInfo('p/B.hx'));
		Assert.isFalse(IndexScope.reportWrites([A], plugin) == IndexScope.reportWrites([A], plugin));
	}

}
