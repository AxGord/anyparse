package unit.dev;

import dev.MutationCheck.TrackRow;
import dev.MutationSlot;
import devkit.Cmd.cmd;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * One slot of `dev mutation-check`: the filters a killer-first track runs, when its reading answers for the filtered
 * run, the transcripts classified in this process, and a track that never reaches a build — a slot that cannot be
 * reset, a patch that does not apply, a track another slot claimed, a parent that is gone.
 */
@:nullSafety(Strict)
final class MutationSlotTest extends Test {

	public function testTheKillerFilterIsEveryExpectationAsATestToken(): Void {
		Assert.equals('test:unit.A.testX,test:unit.B.testY', MutationSlot.killerTokens(' unit.A.testX, ,unit.B.testY '));
		Assert.equals('', MutationSlot.killerTokens(''));
	}

	public function testAKillerReadingAnswersWhenItMatchedAnExpectation(): Void {
		Assert.isTrue(MutationSlot.matchedAny(reading('KILLED', '1 tests failed / 2 assertions: a.T.x'), 'a.T.x'));
		Assert.isFalse(MutationSlot.matchedAny(reading('SURVIVED', '0 tests failed / 2 assertions'), 'a.T.x'));
		Assert.isFalse(MutationSlot.matchedAny(reading('RUN-FAIL', 'no utest header block in the transcript'), 'a.T.x'));
		Assert.isTrue(
			MutationSlot.matchedAny(reading('MISMATCH', '1 tests failed / 2 assertions: a.T.x (missing: a.T.y)'), 'a.T.x,a.T.y'),
			'one of two matched: the filtered run is the same MISMATCH'
		);
		Assert.isFalse(
			MutationSlot.matchedAny(reading('MISMATCH', '1 tests failed / 2 assertions: o.T.z (missing: a.T.x, a.T.y)'), 'a.T.x,a.T.y'),
			'none matched: red only among tests this run left out'
		);
		Assert.isFalse(
			MutationSlot.matchedAny(
				reading('MISMATCH', '1 tests failed: o.T.z (missing: a.T.x, …)', '1 tests failed: o.T.z (missing: a.T.x, a.T.y)'),
				'a.T.x,a.T.y'
			),
			'the uncapped detail is the one counted'
		);
	}

	public function testAFallbackSplitsAPlainClassListOnly(): Void {
		Assert.same(['unit.A#0/2,unit.B#0/2', 'unit.A#1/2,unit.B#1/2'], MutationSlot.fallbackTokens('unit.A,unit.B', 2));
		for (filter in ['ALL', '', 'unit.A#0/2', 'test:unit.A.x']) Assert.isNull(MutationSlot.fallbackTokens(filter, 2), filter);
	}

	public function testSlicesOfOneRunAreClassifiedAsTheirUnion(): Void {
		TempDir.with(dir -> {
			final red: String = dir.file('red');
			final green: String = dir.file('green');
			File.saveContent(red, transcript(false, ['unit.SampleTest', '  testTwo: FAILURE expected 1 but was 2']));
			File.saveContent(green, transcript(true, ['unit.OtherTest', '  testOne: OK .']));
			final one: Classified = MutationSlot.classify('SampleTest.testTwo', [green, red]);
			Assert.equals('KILLED', one.verdict);
			Assert.equals('1 tests failed / 24 assertions: unit.SampleTest.testTwo', one.detail);
			Assert.equals('SURVIVED', MutationSlot.classify('SampleTest.testTwo', [green]).verdict);
			Assert.equals('MISMATCH', MutationSlot.classify('SampleTest.testTwo, Other.testNever', [red]).verdict);
		});
	}

	public function testABuildFailureNamesItsCauseAndItsLog(): Void {
		TempDir.with(dir -> {
			final log: String = dir.file('build.log');
			File.saveContent(log, 'src/F.hx:3: characters 3-11 : Cannot inline a not final return\n');
			final cell: String = MutationSlot.buildDetail(log);
			Assert.isTrue(cell.startsWith('inline-return | '), cell);
			Assert.isTrue(cell.endsWith(' ($log)'), cell);
			Assert.equals(dir.file('none'), MutationSlot.buildDetail(dir.file('none')), 'an unreadable log is named by its path');
		});
	}

	public function testATrackThatCannotBeResetOrPatchedNamesWhy(): Void {
		TempDir.with(dir -> {
			final workroot: String = dir.file('work');
			FileSystem.createDirectory(workroot);
			final slot: String = MutationSlot.slotDir(workroot, 1);
			FileSystem.createDirectory(slot);
			cmd('git init -q $slot').check();
			File.saveContent('$slot/a.txt', 'a\n');
			cmd('git -C $slot -c user.name=t -c user.email=t@t add a.txt').check();
			cmd('git -C $slot -c user.name=t -c user.email=t@t commit -q -m a').check();
			File.saveContent(dir.file('bad.patch'), '--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-nope\n+b\n');
			slotFiles(workroot, [
				{
					name: 'P',
					patch: dir.file('bad.patch'),
					filter: 'ALL',
					expected: ''
				},
				{
					name: 'C',
					patch: dir.file('bad.patch'),
					filter: 'ALL',
					expected: ''
				}
			], '${js.Node.process.pid}');
			FileSystem.createDirectory('$workroot/claims');
			FileSystem.createDirectory('$workroot/claims/C');
			Assert.equals(0, MutationSlot.run(1, workroot));
			final patched: Array<String> = MutationSlot.readVerdict(workroot, 'P');
			Assert.equals('PATCH-FAIL', patched[0]);
			Assert.stringContains('a.txt', patched[1]);
			Assert.same(['RUN-FAIL', 'no verdict written'], MutationSlot.readVerdict(workroot, 'C'), 'another slot claimed it');
			FileSystem.deleteFile('$workroot/P.verdict');
			js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", '$slot/.git');
			FileSystem.deleteDirectory('$workroot/claims/P');
			Assert.equals(0, MutationSlot.run(1, workroot));
			final reset: Array<String> = MutationSlot.readVerdict(workroot, 'P');
			Assert.equals('WT-FAIL', reset[0]);
			Assert.isTrue(reset[1].startsWith('slot 1 could not be reset: '), reset[1]);
		});
	}

	public function testASlotWhoseParentIsGoneTakesNoTrack(): Void {
		TempDir.with(dir -> {
			final workroot: String = dir.file('work');
			FileSystem.createDirectory(workroot);
			// a pid no process holds: past the largest one the system hands out
			slotFiles(workroot, [
				{
					name: 'P',
					patch: dir.file('none.patch'),
					filter: 'ALL',
					expected: ''
				}
			], '2147483646');
			Assert.equals(0, MutationSlot.run(1, workroot));
			Assert.isFalse(FileSystem.exists('$workroot/claims/P'), 'no track claimed');
		});
	}

	public function testRowsRoundTripThroughTheWorkroot(): Void {
		final row: TrackRow = {
			name: 'A',
			patch: '/p',
			filter: 'unit.X',
			expected: 'unit.X.t|u'
		};
		Assert.same([row], MutationSlot.decodeRows('${MutationSlot.encodeRow(row)}\n'));
		Assert.equals('a b ', MutationSlot.oneLine('a\nb\n'));
	}

	private static function reading(verdict: String, detail: String, ?full: String): Classified {
		return { verdict: verdict, detail: detail, full: full };
	}

	/** A utest transcript of one class, red or green. */
	private static function transcript(ok: Bool, rows: Array<String>): String {
		final failed: Int = ok ? 0 : 1;
		return [
			'assertations: 12',
			'successes: 12',
			'errors: 0',
			'failures: $failed',
			'warnings: 0',
			'execution time: 0.01',
			'',
			ok ? 'results: ALL TESTS OK (success: true)' : 'results: FAILED (success: false)'
		].concat(rows).join('\n') + '\n';
	}

	/** The files a parent writes for its slots: the rows, their deal order and the owner pid. */
	private static function slotFiles(workroot: String, rows: Array<TrackRow>, owner: String): Void {
		File.saveContent('$workroot/${MutationSlot.ROWS}', [for (row in rows) '${MutationSlot.encodeRow(row)}\n'].join(''));
		File.saveContent('$workroot/${MutationSlot.ORDER}', [for (row in rows) '${row.name}\n'].join(''));
		File.saveContent('$workroot/${MutationSlot.OWNER}', '$owner\n');
	}

}
