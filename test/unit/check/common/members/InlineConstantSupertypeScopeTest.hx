package unit.check.common.members;

import anyparse.check.common.members.InlineConstant;
import anyparse.query.CachingGrammarPlugin;

/**
 * `inline-constant`'s build-macro bail asks where a supertype is declared across the run's whole scope, not only the
 * linted files: a class implementing a build-macro type declared outside the report is macro-built whichever directory
 * is linted. The verdict must not depend on how many files the run was handed.
 */
class InlineConstantSupertypeScopeTest extends Test {

	private static final DECL: String = 'package pkg;\nclass Consts implements Base { public static inline final X: String = "x"; }';
	private static final BUILT_BASE: String = 'package pkg;\n@:autoBuild(pkg.Builder.build())\ninterface Base {}';
	private static final PLAIN_BASE: String = 'package pkg;\ninterface Base {}';

	@:pin('control')
	@:killer('M-INLINE-BUILD-INDEX-REPORT-SCOPE')
	public function testSupertypeOutsideTheReportCarryingABuildMacroKeepsInline(): Void {
		Assert.equals(0, flagged(BUILT_BASE));
	}

	public function testSupertypeOutsideTheReportWithoutOneStillDrops(): Void {
		Assert.equals(1, flagged(PLAIN_BASE));
	}

	private function flagged(base: String): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Consts.hx', source: DECL }];
		final roots: Array<{ file: String, source: String }> = [{ file: 'pkg/Base.hx', source: base }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: roots, library: new LibrarySources(roots) } }
		);
		return CheckFixture.violationsIn(new InlineConstant(), report, plugin).length;
	}

}
