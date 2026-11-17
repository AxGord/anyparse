package unit.dev;

import devkit.Result;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev.GateLint`: a lint report cut short is never saved, cached or compared; it reads as a lint that did not run. */
@:nullSafety(Strict)
@:access(dev.GateLint)
final class LintReportCompleteTest extends Test {

	private static inline final WHOLE: String = '[{"file":"a/B.hx","rule":"r","line":1}]';
	private static inline final CUT: String = '[{"file":"a/B.hx","rule":"r","li';

	@:pin('control')
	@:killer('M-GATE-LINT-REPORT-COMPLETE-BLIND')
	public function testAReportCutShortByAnExitZeroLintReadsAsNotRunAndLeavesNoFile(): Void {
		Infra4LintLimitTest.withGate(lint -> {
			final out: String = lint._gate.log('now.json');
			final run: Result = new Result('lint', {
				status: 0,
				out: CUT,
				err: '',
				failure: '',
				overflowed: false
			});
			switch lint.saveLint(run, 'tree', out) {
				case NotRun(why):
					Assert.stringContains('incomplete', why);
				case other:
					Assert.fail('got $other');
			}
			Assert.isFalse(FileSystem.exists(out));
		});
	}

	public function testAWholeReportIsSaved(): Void {
		Infra4LintLimitTest.withGate(lint -> {
			final out: String = lint._gate.log('now.json');
			final run: Result = new Result('lint', {
				status: 1,
				out: WHOLE,
				err: '',
				failure: '',
				overflowed: false
			});
			Assert.isTrue(lint.saveLint(run, 'tree', out).match(Passed));
			Assert.equals(WHOLE, File.getContent(out));
		});
	}

	@:pin('control')
	@:killer('M-GATE-LINT-CACHED-CUT-SERVED')
	public function testACachedReportCutShortIsAMiss(): Void {
		Infra4LintLimitTest.withGate(lint -> {
			lint.storeLint('k', CUT);
			Assert.isNull(lint.cachedLint('k'));
			lint.storeLint('k', WHOLE);
			Assert.equals(WHOLE, lint.cachedLint('k'));
		});
	}

	@:pin('control')
	@:killer('M-GATE-LINT-KILLED-WHOLE-SAVED')
	public function testAKilledLintWhoseOutputParsesIsNotRunAndLeavesNoFile(): Void {
		Infra4LintLimitTest.withGate(lint -> {
			final out: String = lint._gate.log('now.json');
			final run: Result = new Result('lint', {
				status: null,
				out: WHOLE,
				err: '',
				failure: 'the command timed out after 5 ms',
				overflowed: false
			});
			Assert.isTrue(lint.saveLint(run, 'tree', out).match(NotRun(_)));
			Assert.isFalse(FileSystem.exists(out));
		});
	}

}
