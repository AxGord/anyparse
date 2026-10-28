package unit.devkit;

import devkit.Summary;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

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

	public function testADetailShowsBesideAPassAndNotBesideAFailure(): Void {
		final summary: Summary = new Summary();
		Assert.same(
			Passed, summary.time('suite', () -> {
				summary.detail('12 tests');
				return Passed;
			})
		);
		Assert.same(
			Failed('1 new'), summary.time('lint', () -> {
				summary.detail('3 files');
				return Failed('1 new');
			})
		);
		Assert.same(Passed, summary.time('fmt', () -> Passed));
		final rows: Array<String> = summary.table().split('\n');
		Assert.isTrue(rows[0].endsWith('  12 tests'), rows[0]);
		Assert.isTrue(rows[1].endsWith('  1 new'), 'a failure shows why it failed, not the reading: ${rows[1]}');
		Assert.isTrue(rows[2].endsWith('s'), 'a step that set no detail does not inherit the last one: ${rows[2]}');
	}

}
