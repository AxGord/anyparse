package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * End-to-end gating probe for `apq lint --fail-on <severity>`.
 *
 * `lint` is report-only by default (always exit 0). `--fail-on` makes it
 * exit non-zero when a finding at-or-above the named severity is present,
 * so CI can gate on it. These drive `Cli.run(['lint', ...])` against a tmp
 * fixture that produces exactly one `unused-import` Warning.
 */
class LintFailOnCliTest extends Test {

	public function testNoFailOnExitsZero(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('lintfailon', 'package pkg;\nimport a.b.Unused;\nclass C {}');
		Assert.equals(0, Cli.run(['lint', fixture]), 'lint is report-only without --fail-on');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFailOnWarningExitsNonZero(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('lintfailon', 'package pkg;\nimport a.b.Unused;\nclass C {}');
		Assert.equals(1, Cli.run(['lint', '--fail-on', 'warning', fixture]), 'a warning + --fail-on warning exits non-zero');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFailOnErrorIgnoresWarnings(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('lintfailon', 'package pkg;\nimport a.b.Unused;\nclass C {}');
		Assert.equals(0, Cli.run(['lint', '--fail-on', 'error', fixture]), 'only warnings present so --fail-on error exits 0');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFailOnUnknownValueIsUsageError(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('lintfailon', 'package pkg;\nclass C {}');
		Assert.equals(2, Cli.run(['lint', '--fail-on', 'nope', fixture]), 'unknown --fail-on value is a usage error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
