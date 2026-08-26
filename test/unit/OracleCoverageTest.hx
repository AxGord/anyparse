package unit;

import anyparse.check.CompilerOracle;
import anyparse.check.OracleCoverage;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

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
	#end

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
