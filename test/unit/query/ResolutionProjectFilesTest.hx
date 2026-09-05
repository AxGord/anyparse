package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import utest.Assert;
import utest.Test;

/**
 * `CachingGrammarPlugin.resolutionProjectFiles` — the PROJECT view of a resolution scope:
 * report files UNION the declared `resolutionRoots`, and nothing from `resolutionLibs` or the
 * auto-discovered Haxe std.
 *
 * The split exists because a write proof and a type proof want different scopes. A field of a
 * project type can be assigned from any project file, so `prefer-final-public-field` /
 * `prefer-read-only-field` must widen past the lint scope; but a haxelib and the std cannot
 * assign into the project — the dependency runs the other way — and their writes only reach a
 * scan keyed on the member NAME, where they suppress. Measured over the Pony fork: folding the
 * library half into that write index lost 16 of 109 findings ('speed', 'panel', 'timer',
 * 'ready', 'names' — every one a name the std also spells) and gained none.
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
