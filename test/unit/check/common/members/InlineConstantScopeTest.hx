package unit.check.common.members;

import anyparse.check.common.members.InlineConstant;
import anyparse.query.CachingGrammarPlugin;

/**
 * `inline-constant`'s macro-consumption gate reads the run's whole scope, not only the linted files: a
 * public string constant whose class a macro-context file outside the report names keeps its `inline`.
 * The verdict must not depend on how many files the run was handed.
 */
class InlineConstantScopeTest extends Test {

	private static final DECL: String = 'package pkg;\nclass Consts { public static inline final X: String = "x"; }';
	private static final MACRO_READER: String = 'package pkg;\n#if macro\nclass Reader { static function f() return Consts.X; }\n#end';
	private static final PLAIN_READER: String = 'package pkg;\nclass Reader { static function f() return Consts.X; }';

	@:pin('control')
	@:killer('M-INLINE-MACRO-GATE-REPORT-SCOPE')
	public function testMacroReaderInTheResolutionScopeKeepsInline(): Void {
		Assert.equals(0, flagged(MACRO_READER));
	}

	public function testPlainReaderInTheResolutionScopeStillDrops(): Void {
		Assert.equals(1, flagged(PLAIN_READER));
	}

	/** A library cannot name a project type in source: its macro-context files share a simple name by accident only. */
	@:pin('control')
	@:killer('M-INLINE-MACRO-GATE-LIBRARY-HALF')
	public function testMacroReaderInTheLibraryHalfKeepsNothing(): Void {
		Assert.equals(1, flagged(MACRO_READER, true));
	}

	private function flagged(reader: String, inLibrary: Bool = false): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Consts.hx', source: DECL }];
		final roots: Array<{ file: String, source: String }> = inLibrary ? [] : [{ file: 'pkg/Reader.hx', source: reader }];
		final library: Array<{ file: String, source: String }> = inLibrary ? [{ file: 'lib/Reader.hx', source: reader }] : roots;
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: roots, library: new LibrarySources(library) } }
		);
		return CheckFixture.violationsIn(new InlineConstant(), report, plugin).length;
	}

}
