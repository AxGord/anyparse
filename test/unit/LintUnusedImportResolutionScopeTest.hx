package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;

using StringTools;

/**
 * `unused-import` widened via the RESOLUTION SCOPE. When the plugin carries a
 * resolution scope (report files UNION configured library roots — openfl / lime),
 * a named import whose module RESOLVES in that scope earns a verifiable deletable
 * `Warning` instead of the out-of-scope `Info` advisory. The conservative gates
 * still hold: a `#if`-guarded import stays `Info`, a wildcard stays `Info`, a
 * library import kept live by a SECONDARY type or a bare enum constructor is not
 * flagged, and a module resolvable in NEITHER report nor library scope stays `Info`.
 */
class LintUnusedImportResolutionScopeTest extends Test {

	/** A tiny stand-in "library" module injected as the resolution scope. */
	private static inline final WIDGET: String = 'package ext.lib;\n\nclass Widget {}';

	/** An unused named import of a resolution-scoped library module is a deletable Warning (was an Info advisory). */
	public function testLibraryImportUnusedIsWarning(): Void {
		final use: String = 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: WIDGET }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** Control: without a resolution scope the same import is an unverifiable Info. */
	public function testLibraryImportUnusedIsInfoWithoutScope(): Void {
		final use: String = 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: use }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A library import kept live ONLY by a SECONDARY type of its module is NOT flagged — deleting it would break the compile. */
	public function testLibrarySecondaryTypeKeepsImport(): Void {
		final lib: String = 'package ext.lib;\n\ntypedef WidgetExtra = {\n\tvar id: Int;\n}\n\nclass Widget {}';
		final use: String = 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\tvar x: WidgetExtra;\n}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: lib }]);
		Assert.equals(0, vs.length);
	}

	/** A library enum import used ONLY via a bare constructor is NOT flagged (expected-type resolution keeps it live). */
	public function testLibraryBareEnumConstructorKeepsImport(): Void {
		final lib: String = 'package ext.lib;\n\nenum Mode {\n\tOn;\n\tOff;\n}';
		final use: String = 'package pkg;\n\nimport ext.lib.Mode;\n\nclass C {\n\tvar x = On;\n}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Mode.hx', source: lib }]);
		Assert.equals(0, vs.length);
	}

	/** A module resolvable in NEITHER report nor library scope stays an unverifiable Info. */
	public function testUnresolvableModuleStaysInfo(): Void {
		final use: String = 'package pkg;\n\nimport totally.unknown.Thing;\n\nclass C {}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: WIDGET }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('not in lint scope'));
	}

	/** A `#if`-guarded unused library import stays Info — never a Warning (the fix must not touch a line inside a `#if`). */
	public function testGuardedLibraryImportStaysInfo(): Void {
		final use: String = 'package pkg;\n\n#if js\nimport ext.lib.Widget;\n#end\n\nclass C {}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: WIDGET }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A static wildcard on a resolution-scoped library type stays Info — wildcard verdicts are not widened. */
	public function testWildcardLibraryImportStaysInfo(): Void {
		final lib: String = 'package ext.lib;\n\nclass Widget {\n\tpublic static var COUNT: Int = 0;\n}';
		final use: String = 'package pkg;\n\nimport ext.lib.Widget.*;\n\nclass C {}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: lib }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A resolution-scoped library import whose type IS used is not flagged (baseline). */
	public function testLibraryImportUsedNotFlagged(): Void {
		final use: String = 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\tvar w: Widget;\n}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Widget.hx', source: WIDGET }]);
		Assert.equals(0, vs.length);
	}

	private function runScoped(useSource: String, lib: Array<{ file: String, source: String }>): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: useSource }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionFiles(report.concat.bind(lib));
		return new UnusedImport().run(report, scoped);
	}

}
