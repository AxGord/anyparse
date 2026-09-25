package unit.check;

import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `CompilerOracle.typecheckAll` overlaps its compiles and still answers what the sequential loop
 * answered: the outcome of the first configuration IN DECLARED ORDER that does not confirm — not the
 * first to finish.
 *
 * The fixture makes the two disagree on purpose. The second configuration fails SLOWLY (an init
 * macro sleeps before typing) and the third fails at once with a different error, so an overlapped
 * run sees the third fail first; the verdict must still be the second's.
 */
@:nullSafety(Strict)
final class OracleParallelVerdictTest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'class Main {\n\n\tpublic static function main() {\n\t\t#if slowbad\n\t\tSlowMissing.call();\n'
		+ '\t\t#end\n\t\t#if fastbad\n\t\tFastMissing.call();\n\t\t#end\n\t\ttrace(1);\n\t}\n\n}\n';
	private static final OK: String = '-cp .\n-main Main\n';
	private static final SLOW: String = '-cp .\n-main Main\n-D slowbad\n--macro Sys.sleep(2)\n';
	private static final FAST: String = '-cp .\n-main Main\n-D fastbad\n';
	#end

	@:pin('control')
	@:killer('M-DRIVER-CANCELS-EARLIER-JOBS')
	public function testTheOverlappedVerdictIsTheFirstFailureInDeclaredOrder(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('oracleparallel', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'ok.hxml', source: OK },
			{ name: 'slow.hxml', source: SLOW },
			{ name: 'fast.hxml', source: FAST }
		]);
		if (!CompilerOracle.typecheck('$dir/ok.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final configs: Array<OracleConfig> = [
			for (name in ['ok', 'slow', 'fast', 'ok']) { hxml: '$dir/$name.hxml', dir: dir, defines: [] }
		];
		final declared: Null<String> = Sys.getEnv('APQ_ORACLE_PARALLEL');
		Sys.putEnv('APQ_ORACLE_PARALLEL', '4');
		final overlapped: OracleOutcome = CompilerOracle.typecheckAll(configs);
		Sys.putEnv('APQ_ORACLE_PARALLEL', '1');
		final sequential: OracleOutcome = CompilerOracle.typecheckAll(configs);
		Sys.putEnv('APQ_ORACLE_PARALLEL', declared ?? '');
		Assert.isTrue(errorsOf(sequential).contains('SlowMissing'), 'the sequential loop stops at the second configuration: $sequential');
		Assert.isTrue(
			errorsOf(overlapped).contains('SlowMissing'), 'and so does the overlapped run, though the third failed first: $overlapped'
		);
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

}
