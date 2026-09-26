package unit.check;

import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage;
import anyparse.check.OracleRunMemo;
import anyparse.check.TypedFactsProbe;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `OracleRunMemo`: inside one run, a compile of a tree the run already compiled is answered from the memo — and only a
 * compile of the same CONTENT, only one whose input held still, and never with the streams a rejection may not quote.
 *
 * Every fixture counts COMPILES, not spawns: its hxml runs an init macro (`Counter.hit`) that appends a line to
 * `compiles.log` in the configuration's directory, so the compiler itself says how often it ran, whichever class
 * spawned it.
 */
@:nullSafety(Strict)
final class OracleRunMemoTest extends Test {

	#if (sys || nodejs)
	private static final GOOD: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final BAD: String = 'class Main {\n\tstatic function main() {\n\t\tnope();\n\t}\n}\n';
	private static final MUTATOR: String = 'class Mutator {\n\tpublic static function once():Void {\n'
		+ '\t\tif (sys.FileSystem.exists(\'mutated.flag\')) return;\n\t\tsys.io.File.saveContent(\'mutated.flag\', \'\');\n'
		+ '\t\tsys.io.File.saveContent(\'Main.hx\', \'class Main { static function main() { nope(); } }\\n\');\n\t}\n}\n';
	private static final BUILD: String = '-cp .\n-main Main\n--js out.js\n' + CompileCounter.MACRO;
	#end

	/** The coverage probe of the tree a baseline just compiled with `-v` IS that compile, so it costs none of its own. */
	@:pin('control')
	@:killer('M-RUNMEMO-PROBE-RECOMPILES')
	public function testTheCoverageProbeReusesTheBaselineCompile(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		final coverage: OracleCoverage = OracleCoverage.probeAll(oracles)[0];
		Assert.isTrue(coverage.covers('$dir/Main.hx'), 'the reused run still names what the compile read');
		Assert.equals(1, CompileCounter.count(dir), 'one compile answered both the baseline and the probe');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A verdict is reused for the content it was taken on and for nothing else: the broken tree is compiled (the `-v`
	 * compile and its plain retry), and the tree restored to the first content is answered without a compile.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-KEY-IGNORES-CONTENT')
	public function testAVerdictIsReusedForTheSameContentOnly(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the first content confirms');
		sys.io.File.saveContent('$dir/Main.hx', BAD);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Rejected(_)), 'the edited content is compiled and refused');
		Assert.equals(3, CompileCounter.count(dir), 'the edit cost the -v compile and its plain retry');
		sys.io.File.saveContent('$dir/Main.hx', GOOD);
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Confirmed), 'the first content is still green');
		Assert.equals(3, CompileCounter.count(dir), 'and it is answered from the memo');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A baseline that fails is quoted as the PLAIN compile quotes it: the `-v` lines never reach a rejection. */
	@:pin('control')
	@:killer('M-RUNMEMO-QUOTES-THE-VERBOSE-STREAMS')
	public function testARejectedBaselineQuotesThePlainCompile(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(BAD, BUILD);
		if (dir == null) return;
		final plain: String = errorsOf(CompilerOracle.typecheck('build.hxml', dir));
		final remembered: String = errorsOf(CompilerOracle.judging(remembering(dir)).verdict);
		Assert.isTrue(plain.indexOf('nope') >= 0, 'the plain compile names the error: $plain');
		Assert.equals(plain, remembered);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A compile whose input changed while it ran is not filed: here an init macro rewrites `Main.hx` before typing, so the
	 * compile judged content its starting fingerprint never named, and the restored tree must be compiled afresh.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-FILES-A-MOVED-INPUT')
	public function testACompileWhoseInputMovedIsNotFiled(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, '$BUILD--macro Mutator.once()\n');
		if (dir == null) return;
		sys.io.File.saveContent('$dir/Mutator.hx', MUTATOR);
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Rejected(_)), 'the compile read what the macro wrote');
		sys.io.File.saveContent('$dir/Main.hx', GOOD);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the restored tree is compiled, not answered');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The facts compile brings the baseline of the same tree along, so the baseline asked next costs no compile. */
	@:pin('control')
	@:killer('M-RUNMEMO-NO-BASELINE-AHEAD')
	public function testTheFactsCompileBringsTheBaselineAlong(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts compile answered');
		Assert.equals(2, CompileCounter.count(dir), 'the facts compile and the baseline beside it');
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		Assert.equals(2, CompileCounter.count(dir), 'and it is answered from the memo');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Configurations no lint run prepared carry no memo, and every question is a compile, as it always was. */
	@:pin('guard')
	public function testAConfigurationOutsideARunIsAlwaysCompiled(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = [{ hxml: 'build.hxml', dir: dir, defines: [] }];
		CompilerOracle.judging(oracles);
		CompilerOracle.judging(oracles);
		Assert.equals(2, CompileCounter.count(dir));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function errorsOf(outcome: OracleOutcome): String {
		return switch outcome {
			case Rejected(errors): errors;
			case _: '';
		};
	}

	#if (sys || nodejs)
	/** A scratch project of `main` and `build`, or null (the test passed) when no compiler is available. */
	private static function scratch(main: String, build: String): Null<String> {
		final dir: String = CliFixture.writeDir('runmemo', [
			{ name: 'Main.hx', source: main },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'build.hxml', source: build }
		]);
		final probe: String = CliFixture.writeDir('runmemoprobe', [
			{ name: 'Main.hx', source: GOOD },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'build.hxml', source: BUILD }
		]);
		final works: Bool = CompilerOracle.typecheck('build.hxml', probe).match(Confirmed);
		CliFixture.removeDir(probe);
		if (works) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	/** The one configuration of `dir`, as a lint run prepares it: carrying a fresh memo. */
	private static function remembering(dir: String): Array<OracleConfig> {
		return OracleRunMemo.attach([{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false));
	}
	#end

}
