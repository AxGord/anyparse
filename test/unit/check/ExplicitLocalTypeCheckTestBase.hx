package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * Fixture scaffolding shared by the `explicit-local-type` check test parts: the
 * class-source wrapper, a gated run, and the fix / no-fix assertions.
 */
class ExplicitLocalTypeCheckTestBase extends Test {

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new ExplicitLocalType().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixContains(body: String, expected: String): Void {
		assertFixContainsSrc(wrap(body), expected);
	}

	private function assertFixContainsSrc(src: String, expected: String): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertNoFix(body: String): Void {
		assertNoFixSrc(wrap(body));
	}

	private function assertNoFixSrc(src: String): Void {
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	/**
	 * Fix `fixSrc` (as `C.hx`) with a `SymbolIndex` built over it plus `otherFiles`, and
	 * assert the canonicalized result contains `expected` — the cross-file resolution path.
	 */
	private function assertFixIdx(fixSrc: String, otherFiles: Array<{ file: String, source: String }>, expected: String): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final fixFile: { file: String, source: String } = { file: 'C.hx', source: fixSrc };
		final index: SymbolIndex = SymbolIndex.build([fixFile].concat(otherFiles), plugin);
		final vs: Array<Violation> = check.run([fixFile], plugin);
		Assert.isTrue(vs.length >= 1);
		switch CanonicalEdit.canonicalize(fixSrc, check.fix(fixSrc, vs, plugin, index), true, plugin) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** As `assertFixIdx`, but asserts no edit is produced (report-only). */
	private function assertNoFixIdx(fixSrc: String, otherFiles: Array<{ file: String, source: String }>): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final fixFile: { file: String, source: String } = { file: 'C.hx', source: fixSrc };
		final index: SymbolIndex = SymbolIndex.build([fixFile].concat(otherFiles), plugin);
		Assert.equals(0, check.fix(fixSrc, check.run([fixFile], plugin), plugin, index).length);
	}

	/**
	 * `fix`'s canonicalized result for `fixSrc` (as `C.hx`) when `libFiles` are reachable ONLY through
	 * the plugin's RESOLUTION scope — the report index is built over the report files alone, exactly
	 * as a `Cli` run builds it. The harness for the arms that ask the wider index; a bare plugin
	 * carries no such scope, which is what makes every fixture above a report-scope-only one.
	 *
	 * An unfixed shape comes back as `fixSrc` itself, so a caller pins "report-only" by equality.
	 */
	private function scopedFixText(
		fixSrc: String, libFiles: Array<{ file: String, source: String }>, ?otherReportFiles: Array<{ file: String, source: String }>
	): String {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: fixSrc }].concat(otherReportFiles ?? []);
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(libFiles) } });
		final index: SymbolIndex = SymbolIndex.build(report, scoped);
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.isTrue(vs.length >= 1, 'the fixture must produce a finding to fix');
		switch CanonicalEdit.canonicalize(fixSrc, check.fix(fixSrc, vs, scoped, index), true, scoped) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
		return fixSrc;
	}

}
