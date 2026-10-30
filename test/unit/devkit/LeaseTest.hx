package unit.devkit;

import devkit.Command;
import devkit.Lease;
import devkit.Result;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `devkit.Lease`: a run under its caller's lease never asks the pool again, a run inside a workflow without one asks the
 * pool through `wf-run`, and a leased command keeps everything but the prefix that takes the lease.
 */
@:nullSafety(Strict)
final class LeaseTest extends Test {

	/** The first two lines of `wf-run --status`, as the workflow engine prints them. */
	private static inline final STATUS: String = 'pool /Users/u/.claude/workflow-pool: budget 10, held 7, load 5.23 (external 4.6, threshold 2)\n'
		+ 'locks held: none\n';

	/** Prints `DEVKIT_PROBE` and the threads its lease granted. */
	private static inline final SHOW_LEASE: String = 'process.stdout.write(process.env.DEVKIT_PROBE + "|" + process.env.WF_THREADS)';

	/** A `wf-run` that skips its own options and runs the command after `--` on a grant of three threads. */
	private static inline final FAKE_WF_RUN: String =
		'#!/bin/sh\nwhile [ "$$1" != "--" ]; do shift; done\nshift\nWF_THREADS=3 exec "$$@"\n';

	@:pin('control')
	@:killer('M-LEASE-NEST-UNDER-HELD')
	public function testARunUnderItsCallersLeaseNeverAsksThePool(): Void {
		TempDir.with(dir -> {
			final root: String = pluginRoot(dir);
			var probed: Int = 0;
			final probe: String -> Null<Int> = _ -> {
				probed++;
				return 10;
			};
			Assert.isTrue(Lease.modeOf(4, root, probe).match(Held(4)));
			Assert.equals(0, probed, 'a held lease nests no lease under it');
			Assert.isTrue(Lease.modeOf(null, root, probe).match(Own(_, 10)));
			Assert.isTrue(Lease.modeOf(null, root, _ -> null).match(Unpooled), 'a pool whose budget does not come is none');
			Assert.isTrue(Lease.modeOf(null, null, probe).match(Unpooled), 'outside a workflow');
			Assert.isTrue(Lease.modeOf(null, dir.file('none'), probe).match(Unpooled), 'a root without wf-run');
		});
	}

	public function testTheBudgetIsTheOneTheStatusNames(): Void {
		Assert.equals(10, Lease.budgetOf(STATUS));
		Assert.isNull(Lease.budgetOf('wf-run: something else\n'));
	}

	public function testAnAskTakesAFixedOrAFlexibleLease(): Void {
		final command: Command = Command.of(['node', 'bin/test.js']);
		final mode: LeaseMode = Own('/p/scripts/wf-run', 10);
		Assert.same([
			'/p/scripts/wf-run',
			'--fail-open',
			'--threads',
			'2',
			'--label',
			'lint',
			'--',
			'node',
			'bin/test.js'
		], Lease.take(mode, command, { min: 2, max: 2 }, 'lint').argv);
		Assert.same([
			'/p/scripts/wf-run',
			'--fail-open',
			'--threads',
			'2-6',
			'--wait-full=${Lease.WAIT_FULL_SECONDS}',
			'--label',
			'suite',
			'--',
			'node',
			'bin/test.js'
		], Lease.take(mode, command, { min: 2, max: 6 }, 'suite').argv);
		Assert.same(command.argv, Lease.take(mode, command, null, 'x').argv, 'no ask, no lease');
		Assert.same(command.argv, Lease.take(Held(10), command, { min: 1, max: 1 }, 'x').argv);
		Assert.same(command.argv, Lease.take(Unpooled, command, { min: 1, max: 1 }, 'x').argv);
	}

	public function testALeasedCommandRunsOnItsGrantWithItsOwnEnvironment(): Void {
		TempDir.with(dir -> {
			final wfRun: String = Path.join([pluginRoot(dir), 'scripts/wf-run']);
			final command: Command = Command.of(['node', '-e', SHOW_LEASE]).at(dir.path).env('DEVKIT_PROBE', 'kept');
			final run: Result = Lease.take(Own(wfRun, 10), command, { min: 2, max: 6 }, 'probe').run();
			Assert.equals('kept|3', run.out, run.err);
		});
	}

	/** A lease asked ahead queues one priority step above the caller's own `WF_PRIORITY`, read as the pool reads it. */
	public function testAheadIsOneStepAboveTheCallersPriority(): Void {
		final own: Null<String> = Sys.getEnv('WF_PRIORITY');
		final read: Array<Int> = [];
		CliFixture.always(() -> Sys.putEnv('WF_PRIORITY', own ?? ''), () -> {
			for (value in ['5', '-100', '', 'high', '5x']) {
				Sys.putEnv('WF_PRIORITY', value);
				read.push(Lease.ahead());
			}
		});
		Assert.same([6, -99, 1, 1, 1], read);
		final argv: Array<String> = Lease.take(Own('/p/scripts/wf-run', 10), Command.of(['true']), { min: 1, max: 1, priority: 7 }, 'x')
			.argv;
		Assert.contains('--priority=7', argv);
	}

	/** A workflow plugin root in `dir` whose `scripts/wf-run` is the fake one. */
	private static function pluginRoot(dir: TempDir): String {
		final root: String = dir.file('plugin');
		FileSystem.createDirectory(Path.join([root, 'scripts']));
		final wfRun: String = Path.join([root, 'scripts/wf-run']);
		sys.io.File.saveContent(wfRun, FAKE_WF_RUN);
		js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wfRun);
		return root;
	}

}
