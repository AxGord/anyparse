package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * End-to-end probe for `apq lint --no-oracle`.
 *
 * The compiler oracle is a PROJECT-WIDE `haxe <hxml> --no-output` regardless of
 * how narrow the lint scope is — measured at 16.1s of an 18.7s single-file run
 * on this project, which makes it the inner loop's largest single cost.
 * `--no-oracle` declines it; a single-file lint then takes 2.2s.
 *
 * What these pin is that declining a gate can only ever WEAKEN a verdict:
 * findings are untouched, and the run can never turn a skipped typecheck into a
 * pass or a failure. The fixtures carry no `compilerOracle` config, so they also
 * cover the case the flag must be a no-op in — a project that never asks the
 * compiler anything.
 */
class LintNoOracleCliTest extends Test {

	public function testNoOracleKeepsExitCode(): Void {
		#if (sys || nodejs)
		final fixture: String = warningDir();
		Assert.equals(0, Cli.run(['lint', '--no-oracle', fixture]), 'lint stays report-only with --no-oracle');
		CliFixture.removeDir(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Declining the oracle must not weaken `--fail-on`: the findings still gate. */
	public function testNoOracleStillFailsOnWarning(): Void {
		#if (sys || nodejs)
		final fixture: String = warningDir();
		Assert.equals(
			1, Cli.run(['lint', '--no-oracle', '--fail-on', 'warning', fixture]),
			'a warning still gates the run when the oracle is declined'
		);
		CliFixture.removeDir(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Same findings with and without the flag — the oracle never produced any. */
	public function testNoOracleLeavesFindingsUnchanged(): Void {
		#if (sys || nodejs)
		final fixture: String = warningDir();
		final withOracle: Int = Cli.run(['lint', '--fail-on', 'warning', fixture]);
		final without: Int = Cli.run(['lint', '--no-oracle', '--fail-on', 'warning', fixture]);
		Assert.equals(withOracle, without, 'the flag changes what is PROVED, never what is FOUND');
		CliFixture.removeDir(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An unknown flag stays a usage error — `--no-oracle` must not swallow neighbours. */
	public function testUnknownFlagIsStillAUsageError(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('lintnooracle', 'package pkg;\nclass C {}');
		Assert.equals(2, Cli.run(['lint', '--no-oracle', '--nope', fixture]), 'an unknown flag is a usage error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * Fixture dir producing exactly one unused-import Warning: the importing file
	 * plus a stub declaring `a.b.Unused`, so the import is verifiable in scope (an
	 * out-of-scope named import is only an Info advisory).
	 */
	private static function warningDir(): String {
		return CliFixture.writeDir('lintnooracle', [
			{ name: 'C.hx', source: 'package pkg;\nimport a.b.Unused;\nclass C {}' },
			{ name: 'Unused.hx', source: 'package a.b;\n\nclass Unused {}\n' }
		]);
	}
	#end

}
