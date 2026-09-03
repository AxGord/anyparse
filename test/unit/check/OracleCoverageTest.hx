package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `OracleCoverage` — the answer to "does the configured oracle actually compile this
 * file", and the PREMISE that makes the question load-bearing.
 *
 * Two of these tests spawn the real compiler, because the premise is a statement about
 * the compiler and nothing else can settle it: the same deliberate type error placed
 * INSIDE and OUTSIDE the hxml's compiled set produces opposite verdicts from the very
 * `haxe <hxml> --no-output` run that `FixVerifier` reads as proof. One variable — the
 * file the error sits in — so the discriminator cannot be anything else.
 */
@:nullSafety(Strict)
final class OracleCoverageTest extends Test {

	#if (sys || nodejs)
	/** Reached from `-main`, so the oracle compiles it. */
	private static final MAIN: String = 'class Main {\n\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n\n}\n';

	/** On the classpath and referenced by nothing — present on disk, absent from the build. */
	private static final OTHER: String =
		'class Other {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n\t\ttrace(2);\n\t}\n\n}\n';

	/** `MAIN` with one type error. */
	private static final BROKEN_MAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\tvar x:Int = "not an int";\n\t\ttrace(x);\n\t}\n\n}\n';

	/** `OTHER` with the SAME type error — the only difference is which file carries it. */
	private static final BROKEN_OTHER: String = 'class Other {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n'
		+ '\t\tvar x:Int = "not an int";\n\t\ttrace(x);\n\t}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';

	/**
	 * ONE compiled file, TWO branches, and only one of them typechecked — the shape a file's
	 * `Parsed` line cannot describe. `-D regionon` below is what makes the first branch the
	 * live one.
	 */
	private static final BRANCHED: String = 'class Main {\n\n\tstatic function main() {\n\t\t#if regionon\n'
		+ '\t\tvar live:Int = 1;\n\t\ttrace(live);\n\t\t#else\n\t\tvar dead:Int = 2;\n\t\ttrace(dead);\n\t\t#end\n\t}\n\n}\n';

	/** `BRANCHED` with the type error in the branch the oracle DOES typecheck. */
	private static final BROKEN_LIVE: String = 'class Main {\n\n\tstatic function main() {\n\t\t#if regionon\n'
		+ '\t\tvar live:Int = "not an int";\n\t\ttrace(live);\n\t\t#else\n\t\tvar dead:Int = 2;\n\t\ttrace(dead);\n\t\t#end\n\t}\n\n}\n';

	/** The SAME error in the branch it does not — one variable, and the compile cannot see it. */
	private static final BROKEN_DEAD: String = 'class Main {\n\n\tstatic function main() {\n\t\t#if regionon\n'
		+ '\t\tvar live:Int = 1;\n\t\ttrace(live);\n\t\t#else\n\t\tvar dead:Int = "not an int";\n\t\ttrace(dead);\n\t\t#end\n\t}\n\n}\n';
	private static final BRANCHED_HXML: String = '-cp .\n-main Main\n-D regionon\n';

	/**
	 * Arm 1's module. Its first region is live under THIS arm's defines; its second needs a flag
	 * only the OTHER arm declares, and no compile ever had both.
	 */
	private static final ARM_A: String = 'class ArmA {\n\n\tstatic function main() {\n\t\t#if arma\n\t\ttrace(\'a\');\n\t\t#end\n'
		+ '\t\t#if (arma && armb)\n\t\ttrace(\'both\');\n\t\t#end\n\t\ttrace(1);\n\t}\n\n}\n';
	private static final ARM_B: String = 'class ArmB {\n\n\tstatic function main() {\n\t\ttrace(2);\n\t}\n\n}\n';

	/**
	 * A two-arm hxml whose FIRST arm names a `-js` output. `haxe check.hxml --no-output` — what
	 * the oracle runs — appends the flag to the LAST arm, so that first arm really emits.
	 */
	private static final TWO_ARM_HXML: String = '-cp .\n-main ArmA\n-D arma\n-js out.js\n--next\n-cp .\n-main ArmB\n-D armb\n--no-output\n';
	#end

	/** One arm per `Defines:` line, each owning the files parsed after it and the defines it declares. */
	public function testParseArmsSplitsOnDefinesLines(): Void {
		final transcript: String = 'Classpath: /a\nDefines: js;target.name=js\nParsed src/A.hx\n'
			+ 'Calling macro haxe.macro.Compiler.define (--macro define(\'nodejs\'):1)\nParsed src/B.hx\n'
			+ 'Classpath: /a\nDefines: neko;sys\nParsed src/C.hx\n';
		final arms: Array<CompiledArm> = OracleCoverage.parseArms(transcript);
		Assert.equals(2, arms.length);
		Assert.same(['src/A.hx', 'src/B.hx'], arms[0].files);
		Assert.same(['js', 'target.name', 'nodejs'], arms[0].defines);
		Assert.same(['src/C.hx'], arms[1].files);
		Assert.same(['neko', 'sys'], arms[1].defines);
	}

	/**
	 * The `--macro define(...)` scrape, which is not an optimisation: the compiler prints its
	 * `Defines:` line BEFORE init macros run, and hxnodejs declares `nodejs` from its
	 * `extraParams.hxml` exactly this way — so without this line every `#if nodejs` region on a
	 * node project would be unprovable.
	 */
	public function testMacroDefineNameReadsTheFirstQuotedArgument(): Void {
		Assert.equals('nodejs', OracleCoverage.macroDefineName('Calling macro haxe.macro.Compiler.define (--macro define(\'nodejs\'):1)'));
		Assert.equals('KEY', OracleCoverage.macroDefineName('Calling macro haxe.macro.Compiler.define (--macro define("KEY", "v"):1)'));
		Assert.isNull(
			OracleCoverage.macroDefineName(
				'Calling macro haxe.macro.Compiler.define (/Users/x/project/src/pkg/Build.hx:12: characters 3-40)'
			),
			'a define called from inside a build macro names its call site, not its argument - unknown, never assumed'
		);
	}

	/**
	 * A `Parsed` line before any `Defines:` line opens an arm with an EMPTY define set: the file
	 * still counts as compiled, and none of its conditional regions is provable.
	 *
	 * Measured NOT to happen with Haxe 4.3.7 — `haxe -v --each` prints `Classpath:` then
	 * `Defines:` before parsing anything, once per `--next` arm and NOT again for the macro
	 * context (verified on this project, whose build macros run, and on a two-arm hxml where the
	 * count is exactly 2). This pins the fallback anyway, because the alternative to an empty
	 * arm is attributing those files to no arm at all, which reads as "not compiled".
	 */
	public function testParsedBeforeAnyDefinesOpensAnEmptyArm(): Void {
		final arms: Array<CompiledArm> = OracleCoverage.parseArms('Parsed src/Early.hx\nDefines: js\nParsed src/Late.hx\n');
		Assert.equals(2, arms.length);
		Assert.same(['src/Early.hx'], arms[0].files);
		Assert.same([], arms[0].defines);
		Assert.same(['js'], arms[1].defines);
	}

	/** `key=value` entries contribute their KEY, because a condition names the flag and not its value. */
	public function testDefinesOfDropsValues(): Void {
		Assert.same(['haxe', 'js', 'target.unicode'], OracleCoverage.definesOf('Defines: haxe=4.3.7;js;target.unicode;'));
	}

	/** The transcript reader: only `Parsed` lines, deduped (the macro context re-parses), order preserved. */
	public function testParsedPathsReadsOnlyParsedLines(): Void {
		final transcript: String = 'Classpath: /a;/b\nDefines: haxe=4.3.7\nParsed /std/StdTypes.hx\nParsed src/A.hx\n'
			+ 'Parsing src/Nope.hx\nParsed src/A.hx\nsrc/A.hx:1: characters 1-2 : Warning : something\nParsed src/B.hx\n';
		Assert.same(['/std/StdTypes.hx', 'src/A.hx', 'src/B.hx'], OracleCoverage.parsedPaths(transcript));
	}

	/**
	 * An UNKNOWN coverage answers false for everything. The direction matters: a caller
	 * reads `covers` as permission to call a typecheck a verification, and a missing answer
	 * must never become one.
	 */
	public function testExplicitListResolvesARelativeRootAgainstTheProcessCwd(): Void {
		#if (sys || nodejs)
		// `covers` resolves the queried file against the PROCESS cwd, so a coverage built from
		// a relative root has to land on the same key — and the case that exposes a mismatch is
		// a path that does NOT exist, where the symlink resolution both sides rely on throws and
		// the raw join is all that is left.
		final coverage: OracleCoverage = OracleCoverage.of(['pkg/Absent.hx'], '.');
		Assert.isTrue(coverage.known);
		Assert.isTrue(coverage.covers('pkg/Absent.hx'), 'a relative root must not produce a key the membership test can never match');
		Assert.isFalse(coverage.covers('pkg/Other.hx'), 'and it still answers no for a file the list does not name');
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUnknownCoverageRefusesEveryFile(): Void {
		final coverage: OracleCoverage = OracleCoverage.unknown('probe did not run');
		Assert.isFalse(coverage.known);
		Assert.equals('probe did not run', coverage.reason);
		Assert.equals(0, coverage.size);
		Assert.isFalse(coverage.covers('src/Anything.hx'));
	}

	/** The probe names the compiled set and leaves an unreferenced sibling out of it. */
	public function testProbeSeparatesTheCompiledSetFromTheRest(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir();
		if (skipWithoutHaxe(dir)) return;
		final coverage: OracleCoverage = OracleCoverage.probe('check.hxml', dir);
		Assert.isTrue(coverage.known, 'the probe answered: ${coverage.reason}');
		Assert.isTrue(coverage.covers('$dir/Main.hx'), 'the module `-main` reaches IS compiled');
		Assert.isFalse(coverage.covers('$dir/Other.hx'), 'a module nothing references is NOT compiled, classpath or no classpath');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The premise, measured rather than assumed: the SAME type error fails the oracle from a
	 * compiled file and does not fail it from an uncompiled one. Without this, "coverage"
	 * would be a plausible-sounding proxy for nothing.
	 */
	public function testTheOracleCannotFailOnAFileOutsideItsCompiledSet(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir();
		if (skipWithoutHaxe(dir)) return;
		File.saveContent('$dir/Other.hx', BROKEN_OTHER);
		Assert.isTrue(
			CompilerOracle.typecheck('check.hxml', dir).match(Confirmed),
			'a type error OUTSIDE the compiled set leaves the oracle green — which is why a green verdict there proves nothing'
		);
		File.saveContent('$dir/Other.hx', OTHER);
		File.saveContent('$dir/Main.hx', BROKEN_MAIN);
		Assert.isTrue(
			CompilerOracle.typecheck('check.hxml', dir).match(Rejected(_)), 'the identical error INSIDE the compiled set fails it'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The REGION premise, measured exactly like the file one above: the same type error inside
	 * and outside a compiled file's live branch produces opposite verdicts from the very run
	 * `FixVerifier` reads as proof — while `covers` answers TRUE for both, because the file is
	 * parsed either way. One variable, the branch the error sits in.
	 */
	public function testTheOracleCannotFailInsideAnExcludedBranch(): Void {
		#if (sys || nodejs)
		final dir: String = branchedDir();
		if (skipWithoutHaxe(dir)) return;
		File.saveContent('$dir/Main.hx', BROKEN_DEAD);
		Assert.isTrue(
			CompilerOracle.typecheck('check.hxml', dir).match(Confirmed),
			'a type error in a branch the defines exclude leaves the oracle green - the file is parsed, the branch is not typechecked'
		);
		File.saveContent('$dir/Main.hx', BROKEN_LIVE);
		Assert.isTrue(CompilerOracle.typecheck('check.hxml', dir).match(Rejected(_)), 'the identical error in the live branch fails it');
		File.saveContent('$dir/Main.hx', BRANCHED);
		final coverage: OracleCoverage = OracleCoverage.probe('check.hxml', dir);
		Assert.isTrue(coverage.known, 'the probe answered: ${coverage.reason}');
		Assert.isTrue(coverage.covers('$dir/Main.hx'), 'file granularity says yes to both branches, which is the whole defect');
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		Assert.isNull(
			coverage.uncovered('$dir/Main.hx', BRANCHED, [at(BRANCHED, 'var live')], shape, new HaxeQueryPlugin().lexicalRegions(BRANCHED)),
			'the live branch IS verifiable'
		);
		Assert.notNull(
			coverage.uncovered('$dir/Main.hx', BRANCHED, [at(BRANCHED, 'var dead')], shape, new HaxeQueryPlugin().lexicalRegions(BRANCHED)),
			'and the excluded one is not, though the file is compiled'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The probe must run the compile it DESCRIBES. `--each` pushes what precedes it into every
	 * arm, so a `--no-output` written before it suppresses output the oracle's own
	 * `haxe <hxml> --no-output` lets the earlier arms emit. Measured here by the emission itself:
	 * arm 1 names a `-js` output, and after the probe that file exists — under the old flag order
	 * it did not, and an hxml whose later arm consumed an earlier one's output would have failed
	 * the probe while passing the oracle.
	 *
	 * The same run pins the per-ARM define model: `#if arma` is live under the arm that compiles
	 * `ArmA`, while `#if (arma && armb)` — one flag from each arm — is live under neither, which
	 * is exactly the answer a union of all arms' defines would get wrong.
	 */
	public function testProbeRunsTheSameCompileTheOracleDoes(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('oraclecovarms', [
			{ name: 'ArmA.hx', source: ARM_A },
			{ name: 'ArmB.hx', source: ARM_B },
			{ name: 'check.hxml', source: TWO_ARM_HXML }
		]);
		if (skipWithoutHaxe(dir)) return;
		if (sys.FileSystem.exists('$dir/out.js')) sys.FileSystem.deleteFile('$dir/out.js');
		final coverage: OracleCoverage = OracleCoverage.probe('check.hxml', dir);
		Assert.isTrue(coverage.known, 'the probe answered: ${coverage.reason}');
		Assert.isTrue(coverage.covers('$dir/ArmA.hx'), 'the first arm is described');
		Assert.isTrue(coverage.covers('$dir/ArmB.hx'), 'and so is the second — that is what `--each` buys');
		Assert.isTrue(
			sys.FileSystem.exists('$dir/out.js'),
			'the probe ran the arm the oracle lets EMIT, so a later arm consuming its output would see the same tree'
		);
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		Assert.isNull(
			coverage.uncovered('$dir/ArmA.hx', ARM_A, [at(ARM_A, 'trace(\'a\')')], shape, new HaxeQueryPlugin().lexicalRegions(ARM_A)),
			'a flag the compiling arm declares makes its region live'
		);
		Assert.notNull(
			coverage.uncovered('$dir/ArmA.hx', ARM_A, [at(ARM_A, 'trace(\'both\')')], shape, new HaxeQueryPlugin().lexicalRegions(ARM_A)),
			'a condition needing one flag from EACH arm is live under neither - arms are not unioned'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * True when this host has no working `haxe` — the fixture typechecks by construction, so a
	 * rejection means no compiler. Carries the skip verdict AND the teardown, so each scenario
	 * opens with one line instead of the same four.
	 */
	private function skipWithoutHaxe(dir: String): Bool {
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return false;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return true;
	}

	/** A zero-length span at `needle`'s first occurrence — the shape an insertion has. */
	private static function at(source: String, needle: String): Span {
		final from: Int = source.indexOf(needle);
		return new Span(from, from);
	}

	/** A fixture whose single compiled module has one live and one excluded branch. */
	private static function branchedDir(): String {
		return CliFixture.writeDir('oraclecovregion', [
			{ name: 'Main.hx', source: BRANCHED },
			{ name: 'check.hxml', source: BRANCHED_HXML }
		]);
	}

	/** A fresh fixture: a `-main` module, an unreferenced sibling on the same classpath, and the hxml. */
	private static function fixtureDir(): String {
		return CliFixture.writeDir('oraclecov', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Other.hx', source: OTHER },
			{ name: 'check.hxml', source: HXML }
		]);
	}
	#end

}
