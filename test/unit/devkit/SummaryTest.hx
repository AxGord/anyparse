package unit.devkit;

import devkit.Summary;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/** `Summary` — four outcomes, never two: a step that could not run fails the verdict like a step that failed. */
@:nullSafety(Strict)
final class SummaryTest extends Test {

	public function testOnlyPassedAndSkippedStepsPass(): Void {
		final summary: Summary = new Summary();
		Assert.isTrue(summary.passed(), 'nothing ran, nothing failed');
		summary.add('build', Passed);
		summary.add('jvm', Skipped('the core did not move'));
		Assert.isTrue(summary.passed());
		final failed: Summary = new Summary();
		failed.add('lint', Failed('2 findings'));
		Assert.isFalse(failed.passed());
		final notRun: Summary = new Summary();
		notRun.add('corpus', NotRun('no snapshot'));
		Assert.isFalse(notRun.passed());
	}

	public function testAStepThatThrowsDidNotRun(): Void {
		final summary: Summary = new Summary();
		Assert.same(Passed, summary.time('build', () -> Passed));
		Assert.same(NotRun('no binary'), summary.time('suite', () -> throw new Exception('no binary')));
		Assert.isFalse(summary.passed());
	}

	public function testTheTableAlignsItsColumns(): Void {
		final summary: Summary = new Summary();
		summary.add('build', Passed, 1234);
		summary.add('lint', Failed('2 findings'), 50);
		summary.add('jvm', Skipped('core untouched'), 0);
		Assert.equals(
			'build  passed      1.2s\nlint   FAILED      0.1s  2 findings\njvm    skipped     0.0s  core untouched', summary.table()
		);
	}

}
