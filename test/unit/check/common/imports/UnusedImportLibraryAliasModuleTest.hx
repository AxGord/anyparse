package unit.check.common.imports;

import anyparse.check.Severity;
import anyparse.query.CachingGrammarPlugin;

/**
 * `unused-import` on a library module holding an unguarded typedef to a target the resolution scope does not hold
 * (`typedef WidgetHandle = flash.display.Handle;`): its value set cannot be listed, which once made every such import an
 * unverifiable advisory. An unused one is a `Warning` of the risky arm — the target's bare constructors are bound through
 * the import, so only the oracle's compile may delete it; every reference form still keeps it.
 */
class UnusedImportLibraryAliasModuleTest extends Test {

	/** A display-class module; the unguarded alias of a platform type the scope never sees is what leaves its values unlisted. */
	private static final DISPLAY: String = 'package ext.lib;\n\n#if !flash\nclass Widget {}\n#else\ntypedef Widget = flash.display.Widget;\n'
		+ '#end\n\ntypedef WidgetHandle = flash.display.Handle;\n\ntypedef WidgetOptions = {\n\tvar id: Int;\n}';

	/** An import of the module named nowhere else in the file is a Warning, and the risky arm's: the oracle may delete it. */
	@:pin('control')
	@:killer('M-UNUSED-ALIAS-UNLISTED-KEPT')
	public function testUnusedAliasModuleImportIsWarning(): Void {
		final vs: Array<Violation> = runScoped('package pkg;\n\nimport ext.lib.Widget;\n\nclass C {}');
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(1, new UnusedImport().riskyArmFindings(vs).length);
	}

	/** A file using only a bare constructor of the alias's unseen target never gets a SAFE deletion of the import. */
	@:pin('control')
	@:killer('M-UNUSED-ALIAS-TARGET-SAFE')
	public function testBareConstructorOfUnseenTargetNoSafeFix(): Void {
		final lib: String = 'package ext.lib;\n\nclass Widget {}\n\ntypedef WidgetMode = ext.Mode;';
		final use: String = 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\tfinal m = Fast;\n}';
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: use }];
		final host: CachingGrammarPlugin = scopedHost(report, [{ file: 'ext/lib/Widget.hx', source: lib }]);
		final rule: UnusedImport = new UnusedImport();
		final vs: Array<Violation> = CheckFixture.violationsIn(rule, report, host);
		Assert.equals(0, rule.fix(use, vs, host).length);
		Assert.equals(vs.filter(v -> v.severity == Severity.Warning).length, rule.riskyArmFindings(vs).length);
	}

	/** A use only inside an `#if` branch no configuration compiles still keeps the import. */
	public function testUseUnderDeadConditionalKeepsImport(): Void {
		final vs: Array<Violation> = runScoped(
			'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\t#if never_defined\n\tvar w: Widget;\n\t#end\n}'
		);
		Assert.equals(0, vs.length);
	}

	/** A use as a type in a signature keeps the import. */
	public function testSignatureTypeKeepsImport(): Void {
		final vs: Array<Violation> = runScoped('package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\tfunction f(w: Widget): Void {}\n}');
		Assert.equals(0, vs.length);
	}

	/** A use of only a secondary type of the module keeps the import. */
	public function testSubtypeUseKeepsImport(): Void {
		final vs: Array<Violation> = runScoped('package pkg;\n\nimport ext.lib.Widget;\n\nclass C {\n\tvar o: WidgetOptions;\n}');
		Assert.equals(0, vs.length);
	}

	private function runScoped(useSource: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: useSource }];
		return CheckFixture.violationsIn(new UnusedImport(), report, scopedHost(report, [{ file: 'ext/lib/Widget.hx', source: DISPLAY }]));
	}

	/** A run host whose resolution scope is `report` beside the third-party `lib`. */
	private function scopedHost(
		report: Array<{ file: String, source: String }>, lib: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources(lib) } }
		);
		return scoped;
	}

}
