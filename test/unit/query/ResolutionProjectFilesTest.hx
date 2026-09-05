package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.FieldWriteIndex;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * `CachingGrammarPlugin.resolutionProjectFiles` — the PROJECT view of a resolution scope:
 * report files UNION the declared `resolutionRoots`, and nothing from `resolutionLibs` or the
 * auto-discovered Haxe std — plus the two derived indexes memoised beside it.
 *
 * The split exists because a write proof and a type proof want different scopes. A field of a
 * project type can be assigned from any project file, so `prefer-final-public-field` /
 * `prefer-read-only-field` must widen past the lint scope; but the NAME-keyed scans those rules
 * also run (the skipped-file scan, structural conformance, the declaration-site lookup) only
 * lose findings when a haxelib and the std join them.
 *
 * S95 measured folding the library half into the write index as 16 of 109 Pony findings lost.
 * S97 re-measured it as 18 of 112 lost and 0 gained, and refuted the stated mechanism: 10 of the
 * losses are `SymbolIndex.text.skippedMayReference`, 3 are structural conformance against a
 * library anonymous structure, 5 are `declarationSiteOf` going ambiguous on a shared SIMPLE name
 * — and NONE is the write index. So the library now IS in the write index, tagged third-party
 * and narrowed per owner, which is what closes the third-party-subtype blind spot
 * (`unit.check.FieldWriteResolutionScopeTest`); the name-keyed scans stay on the project view
 * this class pins.
 */
class ResolutionProjectFilesTest extends Test {

	private static final REPORT: Array<{ file: String, source: String }> = [{ file: 'proj/A.hx', source: 'package proj;\nclass A {}' }];
	private static final ROOT: { file: String, source: String } = { file: 'other/B.hx', source: 'package other;\nclass B {}' };
	private static final LIB: { file: String, source: String } = { file: 'lib/C.hx', source: 'package lib;\nclass C {}' };

	/** With roots declared: report UNION roots, and the library-only file is absent. */
	public function testProjectFilesAreReportUnionDeclaredRoots(): Void {
		final plugin: CachingGrammarPlugin = scoped([ROOT], [ROOT, LIB]);
		// Leading assertion — the fixture reaches the code: the WIDE view still carries all three.
		Assert.equals(3, files(plugin.resolutionFiles()).length, 'the resolution view is report UNION the whole library');
		final project: Null<Array<{ file: String, source: String }>> = plugin.resolutionProjectFiles();
		Assert.notNull(project, 'a declared resolutionRoots entry gives a project view');
		final paths: Array<String> = [for (f in files(project)) f.file];
		Assert.equals(2, paths.length, 'report UNION roots, and nothing else');
		Assert.isTrue(paths.contains('proj/A.hx'), 'the report file stays in the project view');
		Assert.isTrue(paths.contains('other/B.hx'), 'the declared root joins it');
		Assert.isFalse(paths.contains('lib/C.hx'), 'the library-only file does not');
	}

	/**
	 * With no `resolutionRoots`, the project view is null and the caller falls back to the report
	 * scope it already holds — so a project that declares only `resolutionLibs` (the Pony fork's
	 * shape) is left exactly as it was. Passes at base as well: this is the half of the contract
	 * the fix must NOT change, and the arm that kills it is the one answering `resolutionFiles`
	 * here.
	 */
	public function testLibraryOnlyScopeHasNoProjectView(): Void {
		final plugin: CachingGrammarPlugin = scoped([], [LIB]);
		// Leading assertion — the scope really is injected, so a null below is a decision, not absence.
		Assert.equals(2, files(plugin.resolutionFiles()).length, 'the resolution view is report UNION library');
		Assert.isNull(plugin.resolutionProjectFiles(), 'a library-only scope leaves the write proof on the report scope');
	}

	/** No scope injected at all — both views are null. */
	public function testNoScopeHasNeitherView(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.isNull(plugin.resolutionFiles(), 'no scope, no resolution view');
		Assert.isNull(plugin.resolutionProjectFiles(), 'and no project view');
	}

	/**
	 * The two derived indexes are memoised on the host, the way `resolutionIndex` is: both field
	 * rules demand each of them, so without the memo a `--fix` pass built the project symbol index
	 * and the resolution-scoped write index TWICE per pass.
	 */
	public function testDerivedIndexesAreMemoised(): Void {
		final plugin: CachingGrammarPlugin = scoped([ROOT], [ROOT, LIB]);
		final index: Null<SymbolIndex> = plugin.projectIndex();
		final writes: Null<FieldWriteIndex> = plugin.fieldWriteIndex();
		// Leading assertions — both are really built, so an identity below is a memo and not two nulls.
		Assert.notNull(index, 'a declared root gives a project index');
		Assert.notNull(writes, 'an injected scope gives a write index');
		Assert.isTrue(index == plugin.projectIndex(), 'the second demand returns the SAME project index');
		Assert.isTrue(writes == plugin.fieldWriteIndex(), 'the second demand returns the SAME write index');
	}

	/**
	 * ...and the fix loop's once-per-pass `setResolutionIndex` expires them, since both are a
	 * function of THIS pass's report sources. One call, one pass, is the whole invalidation story.
	 */
	public function testSetResolutionIndexExpiresDerivedIndexes(): Void {
		final plugin: CachingGrammarPlugin = scoped([ROOT], [ROOT, LIB]);
		final index: Null<SymbolIndex> = plugin.projectIndex();
		final writes: Null<FieldWriteIndex> = plugin.fieldWriteIndex();
		Assert.notNull(index, 'a declared root gives a project index');
		Assert.notNull(writes, 'an injected scope gives a write index');
		plugin.setResolutionIndex(SymbolIndex.build(REPORT, plugin));
		Assert.isFalse(index == plugin.projectIndex(), 'a new pass rebuilds the project index');
		Assert.isFalse(writes == plugin.fieldWriteIndex(), 'a new pass rebuilds the write index');
	}

	private static function files(v: Null<Array<{ file: String, source: String }>>): Array<{ file: String, source: String }> {
		return v ?? [];
	}

	private static function scoped(
		roots: Array<{ file: String, source: String }>, library: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: REPORT, projectRoots: roots, library: new LibrarySources(library) }
		});
		return plugin;
	}

}
