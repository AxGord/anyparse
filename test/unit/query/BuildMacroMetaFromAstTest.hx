package unit.query;

import anyparse.check.common.members.InlineConstant;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.MemberWriteScan;
import unit.CheckFixture;

/**
 * Whether a type is macro-built, or a `@:coreApi` core replacement, is read from its module's
 * metadata nodes, never from the module text: a doc comment or a string literal spelling
 * `@:autoBuild` / `@:build` / `@:coreApi` is prose, and must not make every implementor look
 * macro-built to the consumers that decline such types (`inline-constant` here), nor a sibling
 * write scan decline a file (`MemberWriteScan.sourceCarriesBuildMacro`).
 */
class BuildMacroMetaFromAstTest extends Test {

	private static final DECL: String = 'package pkg;\nclass Consts implements Base { public static inline final X: String = "x"; }';
	private static final EXTENDS_DECL: String = 'package pkg;\nclass Consts extends Root { public static inline final X: String = "x"; }';

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-TRUE')
	public function testADocCommentNamingAutoBuildIsNotABuildMacro(): Void {
		Assert.equals(
			1, flagged(DECL, 'pkg/Base.hx', 'package pkg;\n/** Implementors are not built by `@:autoBuild` here. */\ninterface Base {}')
		);
	}

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-TRUE')
	public function testALineCommentNamingBuildIsNotABuildMacro(): Void {
		Assert.equals(1, flagged(DECL, 'pkg/Base.hx', 'package pkg;\n// a @:build would go here\ninterface Base {}'));
	}

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-TRUE')
	public function testAStringNamingAutoBuildIsNotABuildMacro(): Void {
		Assert.equals(
			1, flagged(EXTENDS_DECL, 'pkg/Root.hx', 'package pkg;\nclass Root {\n\tpublic static final TAG: String = "@:autoBuild";\n}')
		);
	}

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-FALSE')
	public function testARealAutoBuildOnTheSupertypeStillDeclines(): Void {
		Assert.equals(0, flagged(DECL, 'pkg/Base.hx', 'package pkg;\n@:autoBuild(pkg.Builder.build())\ninterface Base {}'));
	}

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-FALSE')
	public function testAGuardedAutoBuildOnTheSupertypeStillDeclines(): Void {
		Assert.equals(0, flagged(DECL, 'pkg/Base.hx', 'package pkg;\n#if js\n@:autoBuild(pkg.Builder.build())\n#end\ninterface Base {}'));
	}

	@:pin('control')
	@:killer('M-BUILD-META-FILE-FLAGS-FALSE')
	public function testARealBuildOnTheTypeStillDeclines(): Void {
		Assert.equals(
			0, flaggedAlone('package pkg;\n@:build(pkg.Builder.build())\nclass Consts { public static inline final X: String = "x"; }')
		);
	}

	@:pin('control')
	@:killer('M-CORE-API-META-TRUE')
	public function testACommentNamingCoreApiDoesNotPinTheShape(): Void {
		Assert.equals(
			1, flaggedAlone('package pkg;\n/** Not a @:coreApi type. */\nclass Consts { public static inline final X: String = "x"; }')
		);
	}

	@:pin('control')
	@:killer('M-CORE-API-META-FALSE')
	public function testARealCoreApiStillPinsTheShape(): Void {
		Assert.equals(0, flaggedAlone('package pkg;\n@:coreApi\nclass Consts { public static inline final X: String = "x"; }'));
	}

	@:pin('control')
	@:killer('M-MWS-META-NAMED-TRUE')
	public function testTheSharedPredicateIgnoresCommentsAndStrings(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isFalse(MemberWriteScan.sourceCarriesBuildMacro('/** see @:autoBuild */\ninterface I {}', plugin));
		Assert.isFalse(MemberWriteScan.sourceCarriesBuildMacro('class C {\n\tstatic final S: String = "@:build";\n}', plugin));
	}

	@:pin('control')
	@:killer('M-MWS-META-COND-UNWALKED')
	public function testTheSharedPredicateSeesATagInAConditionalBranch(): Void {
		Assert.isTrue(MemberWriteScan.sourceCarriesBuildMacro('#if js\n@:build(B.b())\n#end\nclass C {}', new HaxeQueryPlugin()));
	}

	@:pin('control')
	@:killer('M-MWS-META-UNPARSED-NO')
	public function testAnUnparseableSourceCountsAsMacroBuilt(): Void {
		Assert.isTrue(MemberWriteScan.sourceCarriesBuildMacro('class C {', new HaxeQueryPlugin()));
	}

	@:pin('control')
	@:killer('M-SIB-META-NESTED-UNLIFTED')
	public function testADoublyGuardedAutoBuildOnTheSupertypeStillDeclines(): Void {
		Assert.equals(
			0, flagged(DECL, 'pkg/Base.hx', 'package pkg;\n#if a\n#if b\n@:autoBuild(pkg.B.build())\n#end\n#end\ninterface Base {}')
		);
	}

	@:pin('control')
	@:killer('M-SIB-META-NESTED-UNLIFTED')
	public function testADoublyGuardedBuildOnTheTypeStillDeclines(): Void {
		Assert.equals(
			0,
			flaggedAlone(
				'package pkg;\n#if a\n#if b\n@:build(pkg.B.build())\n#end\n#end\n'
				+ 'class Consts { public static inline final X: String = "x"; }'
			)
		);
	}

	private function flagged(decl: String, rootFile: String, root: String): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Consts.hx', source: decl }];
		final roots: Array<{ file: String, source: String }> = [{ file: rootFile, source: root }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> { report: report, projectRoots: roots, library: new LibrarySources(roots) } }
		);
		return CheckFixture.violationsIn(new InlineConstant(), report, plugin).length;
	}

	private function flaggedAlone(decl: String): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Consts.hx', source: decl }];
		return CheckFixture.violationsIn(new InlineConstant(), report, new CachingGrammarPlugin(new HaxeQueryPlugin())).length;
	}

}
