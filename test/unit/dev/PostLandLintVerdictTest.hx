package unit.dev;

import dev.PostLand;
import devkit.Lease.LeaseMode;
import devkit.Summary.Outcome;
import devkit.TempDir;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The whole-lint phase of a post-land run under a lease: a phase still waiting for its lease has not run, and the lint's verdict
 * reads only the lint's own report.
 */
@:nullSafety(Strict)
final class PostLandLintVerdictTest extends Test {

	private static final WAIT: String = 'wf-run: waiting for 1 threads — held 10/14 by refused slice id, 3 ahead in queue';

	@:pin('control')
	@:killer('M-POSTLAND-LINT-NEVER-STARTED')
	@:killer('M-POSTLAND-LINT-NEVER-STARTED-REASON')
	public function testAPhaseThatNeverGotItsLeaseIsNotRunAndNotRed(): Void {
		TempDir.with(dir -> {
			final verdict: Outcome = PostLand.wholeLint('/nonexistent', 'abc1234', dir.path, tree(dir, 'echo "[]"'), standIn(dir, false));
			switch verdict {
				case NotRun(why):
					Assert.stringContains('exited 3', why);
					Assert.isFalse(why.contains('held 10/14') || why.contains('refused'), why);
				case _: Assert.fail('got $verdict');
			}
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-LINT-NO-START-MARK')
	public function testAWaitLineBeforeACleanLintIsGreen(): Void {
		TempDir.with(dir -> {
			final verdict: Outcome = PostLand.wholeLint('/nonexistent', 'abc1234', dir.path, tree(dir, 'echo "[]"'), standIn(dir, true));
			Assert.isTrue(verdict.match(Passed), 'got $verdict');
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-LINT-OWN-ERROR')
	public function testALintThatRanAndBrokeIsRedWithItsOwnError(): Void {
		TempDir.with(dir -> {
			final verdict: Outcome = PostLand.wholeLint(
				'/nonexistent', 'abc1234', dir.path, tree(dir, 'echo "lint exploded" >&2; exit 2'), standIn(dir, true)
			);
			switch verdict {
				case Failed(why):
					Assert.stringContains('lint exploded', why);
					Assert.isFalse(why.contains('waiting for'), why);
				case _: Assert.fail('got $verdict');
			}
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-SETTLE-NOT-RUN')
	public function testARunWithoutAVerdictStaysLostAndLeavesNoRedRecord(): Void {
		TempDir.with(dir -> {
			final record: String = dir.file('post-land/abc1234.running');
			sys.FileSystem.createDirectory(dir.file('post-land'));
			File.saveContent(record, 'log\n');
			PostLand.settle(dir.path, 'abc1234', NotRun('never started'));
			Assert.same(['abc1234'], PostLand.lost(dir.path));
			Assert.same([], PostLand.red(dir.path));
			PostLand.settle(dir.path, 'abc1234', Passed);
			Assert.same([], PostLand.lost(dir.path));
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-RUN-VERDICT')
	public function testALintThatNeverStartedLeavesTheRunUnjudgedUnlessHxcppFailed(): Void {
		final unrun: Outcome = NotRun('never started');
		Assert.isTrue(PostLand.runVerdict(unrun, Passed).match(NotRun(_)));
		Assert.isTrue(PostLand.runVerdict(unrun, Skipped('no src')).match(NotRun(_)));
		Assert.isTrue(PostLand.runVerdict(unrun, Failed('c++')).match(Failed(_)));
		Assert.isTrue(PostLand.runVerdict(Passed, Skipped('no src')).match(Skipped(_)));
	}

	/** A tree whose `bin/hxq` runs `script` for the lint. */
	public static function tree(dir: TempDir, script: String): String {
		final root: String = dir.file('tree');
		sys.FileSystem.createDirectory(root);
		sys.FileSystem.createDirectory('$root/bin');
		File.saveContent('$root/bin/hxq', '$script\n');
		return root;
	}

	/** A `wf-run` that prints a wait line, then runs the command after `--` when `grants`, else ends without running it. */
	private static function standIn(dir: TempDir, grants: Bool): LeaseMode {
		final path: String = dir.file(grants ? 'wf-run-grant' : 'wf-run-wait');
		final run: String = grants ? 'shift; exec "$$@"' : 'exit 3';
		File.saveContent(path, '#!/bin/sh\necho \'$WAIT\' >&2\nwhile [ "$$1" != "--" ]; do shift; done\n$run\n');
		js.node.Fs.chmodSync(path, '755');
		return Own(path, 1);
	}

}
