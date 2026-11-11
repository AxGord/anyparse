package unit.check.common.imports;

import anyparse.check.Severity;
import anyparse.query.CachingGrammarPlugin;

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
	private static final WIDGET: String = 'package ext.lib;\n\nclass Widget {}';

	/** A stand-in library module whose one static is an extension of `String`. */
	private static final PAD: String = 'package ext.lib;\n\nclass Pad {\n\tpublic static function pad(s: String): String return s;\n}';

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
		final vs: Array<Violation> = CheckFixture.violationsIn(new UnusedImport(), [{ file: 'pkg/C.hx', source: use }]);
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

	/**
	 * `fix` deletes exactly the `Warning`s, so every `Info` this check emits IS a decline — and the
	 * run had no way to say so. On a real tree `lint --fix` reported `unused-import <declined> of
	 * <reported>: fix declined here, yet the rule produced N edit(s) elsewhere in this run — so it
	 * HAS an autofix and withheld it, without saying why`, and the four arms behind those declines
	 * are four different answers (out-of-scope, `#if`-guarded, unknown `using`, unknown wildcard).
	 *
	 * Each arm now writes its own `Violation.declineReason`, composed from the SAME constant its
	 * reported message is built from, so the report and the ledger cannot drift apart. A deletable
	 * `Warning` carries none: nothing declined it.
	 */
	public function testEveryUnverifiableArmSaysWhyItDeclined(): Void {
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/lib/Widget.hx', source: WIDGET }];
		final outOfScope: Array<Violation> = runScoped('package pkg;\n\nimport totally.unknown.Thing;\n\nclass C {}', lib);
		assertDecline(outOfScope, 'the module is declared in no file this run read');
		final guarded: Array<Violation> = runScoped('package pkg;\n\n#if js\nimport ext.lib.Widget;\n#end\n\nclass C {}', lib);
		assertDecline(guarded, 'the canonicaliser normalises the module-level import block ONLY');
		final wildcard: Array<Violation> = runScoped('package pkg;\n\nimport some.pack.*;\n\nclass C {}', lib);
		assertDecline(wildcard, 'has an unknown member set');
		final usingUnknown: Array<Violation> = runScoped('package pkg;\n\nusing totally.unknown.Helpers;\n\nclass C {}', lib);
		assertDecline(usingUnknown, 'known neither to the std probe nor to the report and project index');
		// The other half of the contract: a finding the fix DOES take carries no reason at all, so a
		// reader never sees a decline where an edit happened.
		final report: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: 'package pkg;\n\nimport ext.lib.Widget;\n\nclass C {}' }
		];
		final deletable: FixRun = CheckFixture.fixRun(new UnusedImport(), report, scopedHost(report, lib));
		Assert.equals(1, deletable.violations.length);
		Assert.equals(Severity.Warning, deletable.violations[0].severity);
		Assert.isNull(deletable.violations[0].declineReason, 'a finding the fix takes declined nothing');
		Assert.equals(1, deletable.edits.length, 'and it really is the arm that produces an edit');
	}

	/** A `using` on a module of the project's own `resolutionRoots` that no extension call goes through is a deletable Warning. */
	@:pin('control')
	@:killer('M-USING-MODULE-REPORT-SCOPED')
	public function testProjectRootUsingUnusedIsWarning(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Pad;\n\nclass C {}';
		final vs: Array<Violation> = runWithProjectRoots(use, [{ file: 'ext/lib/Pad.hx', source: PAD }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('unused using'));
	}

	/** Control: the same `using` kept live by an extension call it provides reports nothing. */
	@:pin('control')
	@:killer('M-USING-MODULE-REPORT-SCOPED')
	public function testProjectRootUsingKeptByExtensionCall(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Pad;\n\nclass C {\n\tfunction f(s: String): String return s.pad();\n}';
		final vs: Array<Violation> = runWithProjectRoots(use, [{ file: 'ext/lib/Pad.hx', source: PAD }]);
		Assert.equals(0, vs.length);
	}

	/** A `using` on a LIBRARY module stays an unverifiable Info: a library's extension surface is not its statics alone. */
	@:pin('control')
	@:killer('M-USING-LIBRARY-WIDENED')
	public function testLibraryUsingStaysInfo(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Pad;\n\nclass C {}';
		final vs: Array<Violation> = runScoped(use, [{ file: 'ext/lib/Pad.hx', source: PAD }]);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('extension use not tracked'));
	}

	/** A `using` on a project module that is a typedef of a class brings that class's statics: the extension call keeps it. */
	@:pin('control')
	@:killer('M-USING-ALIAS-NOT-FOLLOWED')
	public function testProjectRootUsingOfTypedefKeptByTargetsExtensionCall(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Alias;\n\nclass C {\n\tfunction f(s: String): String return s.pad();\n}';
		final project: Array<{ file: String, source: String }> = [
			{ file: 'ext/lib/Pad.hx', source: PAD },
			{ file: 'ext/lib/Alias.hx', source: 'package ext.lib;\n\ntypedef Alias = ext.lib.Pad;' }
		];
		Assert.equals(0, runWithProjectRoots(use, project).length);
	}

	/** A typedef whose target no index resolves leaves its `using` an unverifiable Info, never a deletable Warning. */
	@:pin('control')
	@:killer('M-USING-ALIAS-NOT-FOLLOWED')
	public function testProjectRootUsingOfUnresolvedTypedefStaysInfo(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Alias;\n\nclass C {}';
		final project: Array<{ file: String, source: String }> = [
			{ file: 'ext/lib/Alias.hx', source: 'package ext.lib;\n\ntypedef Alias = totally.unknown.Thing;' }
		];
		final vs: Array<Violation> = runWithProjectRoots(use, project);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/**
	 * A typedef of a class a build macro extends leaves its `using` an
	 * unverifiable Info: the statics the macro adds are not in the declaration.
	 */
	@:pin('control')
	@:killer('M-USING-ALIAS-BUILD-IGNORED')
	public function testProjectRootUsingOfTypedefOfBuiltClassStaysInfo(): Void {
		final use: String = 'package pkg;\n\nusing ext.lib.Alias;\n\nclass C {}';
		final project: Array<{ file: String, source: String }> = [
			{ file: 'ext/lib/Built.hx', source: 'package ext.lib;\n\n@:build(ext.lib.Maker.run())\nclass Built {}' },
			{ file: 'ext/lib/Alias.hx', source: 'package ext.lib;\n\ntypedef Alias = ext.lib.Built;' }
		];
		final vs: Array<Violation> = runWithProjectRoots(use, project);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/**
	 * `vs` is one unfixable advisory whose `declineReason` names `gate`, and whose message still
	 * CONTAINS the shared half that reason opens with — the pin that keeps the two one string.
	 */
	private function assertDecline(vs: Array<Violation>, gate: String): Void {
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		final reason: Null<String> = vs[0].declineReason;
		Assert.notNull(reason, 'an Info advisory is a decline and must say why: ${vs[0].message}');
		if (reason == null) return;
		Assert.isTrue(reason.contains(gate), 'the reason names the gate that closed - got: $reason');
		final shared: String = reason.split(' — ')[0];
		Assert.isTrue(vs[0].message.contains(shared), 'and shares its opening with the reported message - got: ${vs[0].message}');
	}

	private function runScoped(useSource: String, lib: Array<{ file: String, source: String }>): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: useSource }];
		return CheckFixture.violationsIn(new UnusedImport(), report, scopedHost(report, lib));
	}

	/** A run host whose declared resolution scope is `report` beside the third-party `lib`. */
	private function scopedHost(
		report: Array<{ file: String, source: String }>, lib: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources(lib) } }
		);
		return scoped;
	}

	private function runWithProjectRoots(useSource: String, project: Array<{ file: String, source: String }>): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: useSource }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: project, library: new LibrarySources(project) } }
		);
		return CheckFixture.violationsIn(new UnusedImport(), report, scoped);
	}

}
