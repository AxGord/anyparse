package unit.devkit;

import devkit.Excerpt;
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

	public function testOnlyAFailedStepShowsItsExcerptUnderTheTable(): Void {
		final summary: Summary = new Summary();
		final failed: Outcome = summary.time('lint', () -> {
			summary.excerpt(['+ a.hx  r  new']);
			return Failed('1 new');
		});
		final passed: Outcome = summary.time('suite', () -> {
			summary.excerpt(['noise of a pass']);
			return Passed;
		});
		final bare: Outcome = summary.time('kits', () -> NotRun('no engine'));
		final skipped: Outcome = summary.time('jvm', () -> {
			summary.excerpt(['a skip']);
			return Skipped('untouched');
		});
		final notRun: Outcome = summary.time('corpus', () -> {
			summary.excerpt(['not run, with lines']);
			return NotRun('no snapshot');
		});
		Assert.same([
			Failed('1 new'),
			Passed,
			NotRun('no engine'),
			Skipped('untouched'),
			NotRun('no snapshot')
		], [failed, passed, bare, skipped, notRun]);
		Assert.equals('lint:\n  + a.hx  r  new\ncorpus:\n  not run, with lines', summary.excerpts());
		Assert.equals('', new Summary().excerpts());
	}

	public function testAnExcerptIsCutToTheTablesBound(): Void {
		final summary: Summary = new Summary();
		summary.add('lint', Failed('30 new'), 0, '', [for (i in 0...30) 'row $i']);
		final shown: Array<String> = summary.excerpts().split('\n');
		Assert.equals(1 + Excerpt.MAX_LINES, shown.length);
		Assert.equals('  … 21 more', shown[shown.length - 1]);
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
