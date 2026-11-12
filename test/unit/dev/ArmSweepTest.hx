package unit.dev;

import dev.ArmRegistry;
import dev.ArmSweep;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.Exception;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev arm-sweep`: which landings a sweep follows, the land step that starts one and never fails the land, the record that
 * keeps a second sweep from starting beside a running one, and the verdict a sweep writes for the parent.
 */
@:nullSafety(Strict)
final class ArmSweepTest extends Test {

	/** A pid no process holds. */
	private static inline final GONE_PID: Int = 999999999;

	/** Two arms of a registry document, each with its type. */
	private static final REGISTRY: String = '{"arms": [{"name": "M-HELD", "type": "pkg.Held", "method": "f", "force": "0"}, '
		+ '{"name": "M-ROTTED", "type": "pkg.Rotted", "method": "g", "force": "1"}]}';

	public function testEveryThirtiethLandingIsDueAndNoOtherIs(): Void {
		Assert.isTrue(ArmSweep.due(ArmSweep.EVERY, ArmSweep.EVERY));
		Assert.isTrue(ArmSweep.due(2 * ArmSweep.EVERY, ArmSweep.EVERY));
		Assert.isFalse(ArmSweep.due(ArmSweep.EVERY - 1, ArmSweep.EVERY));
		Assert.isFalse(ArmSweep.due(null, ArmSweep.EVERY));
	}

	@:pin('control')
	@:killer('M-SWEEP-DUE-ALWAYS')
	public function testALandingNoSweepFollowsNeverCallsTheStart(): Void {
		final started: Array<String> = [];
		final outcome: Outcome = ArmSweep.afterwards(seam(started), ArmSweep.EVERY + 1, ArmSweep.EVERY, '/repo', 'abc', _ -> {});
		Assert.isTrue(outcome.match(Skipped(_)));
		Assert.same([], started);
	}

	public function testADueLandingStartsTheSweepOfTheLandedHeadOnce(): Void {
		final started: Array<String> = [];
		final notes: Array<String> = [];
		final outcome: Outcome = ArmSweep.afterwards(seam(started), ArmSweep.EVERY, ArmSweep.EVERY, '/repo', 'abc', notes.push);
		Assert.isTrue(outcome.match(Passed));
		Assert.same(['abc'], started);
		Assert.stringContains('arm sweep of abc', notes.join('\n'));
	}

	@:pin('control')
	@:killer('M-SWEEP-START-THROW-FAILS-LAND')
	public function testASweepThatCannotStartNeverFailsTheLand(): Void {
		final threw: Outcome = ArmSweep.afterwards(
			(repo, sha) -> throw new Exception('no pool'), ArmSweep.EVERY, ArmSweep.EVERY, '/repo', 'abc', _ -> {}
		);
		Assert.isTrue(threw.match(Skipped(_)), '$threw');
		final refused: Outcome = ArmSweep.afterwards(
			(repo, sha) -> Failed('no worktree'), ArmSweep.EVERY, ArmSweep.EVERY, '/repo', 'abc', _ -> {}
		);
		Assert.isTrue(refused.match(Skipped(_)), '$refused');
	}

	@:pin('control')
	@:killer('M-SWEEP-UNDERWAY-BLIND')
	public function testASweepWhoseProcessIsAliveIsNotStartedTwice(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('aaa.running'), 'log\n');
			File.saveContent(dir.file('aaa.pid'), '${js.Node.process.pid}\n');
			var launches: Int = 0;
			final outcome: Outcome = ArmSweep.begin(dir.path, 'bbb', () -> ++launches);
			Assert.isTrue(outcome.match(Skipped(_)), '$outcome');
			Assert.equals(0, launches);
			Assert.isFalse(FileSystem.exists(dir.file('bbb.running')));
			Assert.same(['arm-sweep: aaa running'], ArmSweep.statusLines(dir.path));
		});
	}

	public function testARecordWhoseProcessIsGoneHoldsNoStart(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('aaa.running'), 'log\n');
			File.saveContent(dir.file('aaa.pid'), '$GONE_PID\n');
			var launches: Int = 0;
			final outcome: Outcome = ArmSweep.begin(dir.path, 'bbb', () -> {
				launches++;
				return 4242;
			});
			Assert.isTrue(outcome.match(Passed), '$outcome');
			Assert.equals(1, launches);
			Assert.isFalse(FileSystem.exists(dir.file('aaa.running')));
			Assert.isTrue(FileSystem.exists(dir.file('bbb.running')));
			Assert.equals('4242\n', File.getContent(dir.file('bbb.pid')));
		});
	}

	@:pin('control')
	@:killer('M-SWEEP-VERDICT-DROPS-UNHELD')
	public function testTheVerdictListsAPlantedSurvivingArmWithItsTypeAndKiller(): Void {
		final log: String = [
			'KILLED     M-HELD               filter=unit.HeldTest 1 tests failed / 1 assertions: unit.HeldTest.testF',
			'SURVIVED   M-ROTTED             filter=unit.RottedTest 0 tests failed / 3 assertions',
			'2 tracks: 1 killed, 1 survived, 0 mismatch, 0 error'
		].join('\n');
		Assert.equals(
			'KILLED 1\nSURVIVED M-ROTTED type=pkg.Rotted killer=unit.RottedTest\n', ArmSweep.verdict(log, ArmRegistry.parse(REGISTRY))
		);
	}

	@:pin('control')
	@:killer('M-SWEEP-PARTIAL-RUN-READ-WHOLE')
	public function testARunCutShortOrMissingRowsGivesNoVerdict(): Void {
		final records: Array<ArmRecord> = ArmRegistry.parse(REGISTRY);
		final held: String = 'KILLED     M-HELD               filter=unit.HeldTest 1 tests failed / 1 assertions: unit.HeldTest.testF';
		final rotted: String = 'SURVIVED   M-ROTTED             filter=unit.RottedTest 0 tests failed / 3 assertions';
		final timedOut: Null<String> = ArmSweep.refusal(null, 'timed out after 10 ms', '$held\n$rotted', records);
		Assert.notNull(timedOut);
		Assert.stringContains('did not finish: timed out', timedOut ?? '');
		final partial: Null<String> = ArmSweep.refusal(1, '', held, records);
		Assert.notNull(partial);
		Assert.stringContains('1 of 2 arms', partial ?? '');
		Assert.isNull(ArmSweep.refusal(1, '', '$held\n$rotted', records));
	}

	public function testTheStatusVerbListsTheRecordsOfTheCache(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('arm-sweep'));
			File.saveContent(dir.file('arm-sweep/abc.verdict.txt'), 'KILLED 1\n');
			Assert.equals(0, ArmSweep.main(['status', '--cache', dir.path]));
			Assert.same(['arm-sweep: abc verdict ${dir.file('arm-sweep/abc.verdict.txt')}'], ArmSweep.statusLines(dir.file('arm-sweep')));
		});
	}

	public function testTheRunTheDetachedArgvNamesEndsWithAFailedRecordAndNoRunningOne(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			Assert.isTrue(cmd('git init -q $repo').run().ok);
			final cache: String = dir.file('cache');
			final sha: String = '0000000000000000000000000000000000000bad';
			final words: Array<String> = ArmSweep.argvOf(Unpooled, 'dev.js', repo, sha, cache);
			Assert.equals(1, ArmSweep.main(words.slice(words.indexOf('arm-sweep') + 1)));
			Assert.isTrue(FileSystem.exists(dir.file('cache/arm-sweep/$sha.failed')));
			Assert.isFalse(FileSystem.exists(dir.file('cache/arm-sweep/$sha.running')));
			Assert.isFalse(FileSystem.exists(dir.file('cache/arm-sweep/$sha.pid')));
			Assert.isFalse(FileSystem.exists(dir.file('cache/arm-sweep/$sha.verdict.txt')));
		});
	}

	public function testAnArmThatNeverBecameAPatchIsListedWithNoKiller(): Void {
		final log: String = 'APPLY-FAIL  M-ROTTED             M-ROTTED: could not read the body brace';
		Assert.same(['APPLY-FAIL M-ROTTED type=pkg.Rotted killer=-'], ArmSweep.unheld(log, ArmRegistry.parse(REGISTRY)));
	}

	public function testTheDetachedRunQueuesBelowEverySliceExecOnAFewThreads(): Void {
		final argv: Array<String> = ArmSweep.argvOf(Own('/plugin/scripts/wf-run', 8), '/cache/abc.dev.js', '/repo', 'abc', '/cache');
		Assert.equals('/plugin/scripts/wf-run', argv[0]);
		Assert.isTrue(argv.contains('--priority=-1'), argv.join(' '));
		Assert.equals('1-2', argv[argv.indexOf('--threads') + 1], argv.join(' '));
		Assert.same([
			'node',
			'/cache/abc.dev.js',
			'arm-sweep',
			'run',
			'abc',
			'--repo',
			'/repo',
			'--cache',
			'/cache'
		], argv.slice(argv.indexOf('--') + 5));
	}

	private static function seam(started: Array<String>): SweepStart {
		return (repo, sha) -> {
			started.push(sha);
			return Passed;
		};
	}

}
