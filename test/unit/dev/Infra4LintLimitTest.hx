package unit.dev;

import dev.GateLint;
import dev.GateTree;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease.LeaseMode;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** `dev.GateLint`: how long one lint of the infra4 row may run, counted from its lease grant, before it is killed, and how a kill reads. */
@:nullSafety(Strict)
@:access(dev.GateLint)
final class Infra4LintLimitTest extends Test {

	/** What the process driver grants a leased job that names no limit of its own: ten minutes from the grant. */
	private static inline final DRIVER_DEFAULT_MS: Int = 10 * 60 * 1000;

	/** A lint of the infra4 row under a pool lease names a limit above the driver's default, which an honest lint under load reaches. */
	@:killer('M-GATE-INFRA4-LINT-UNBOUNDED')
	@:pin('control')
	public function testALintOfTheInfra4RowIsBoundedAboveTheDriversDefault(): Void {
		withGate(lint -> {
			final bounded: Command = lint.infraLint(Command.of(['true']), 'base tree');
			Assert.isTrue(bounded.limit() > DRIVER_DEFAULT_MS, 'limit: ${bounded.limit()} ms');
		});
	}

	/** A lint the driver killed at its limit is not run, and says the load of the host it was killed at, not that it printed nothing. */
	@:killer('M-GATE-INFRA4-LINT-TIMEOUT-UNNAMED')
	@:pin('control')
	public function testAKilledLintIsNotRunAndNamesTheLoad(): Void {
		withGate(lint -> {
			final killed: Result = new Result('lint', {
				status: null,
				out: '',
				err: '',
				failure: 'the command timed out after 5 ms',
				overflowed: false
			});
			switch lint.saveLint(killed, 'tree', lint._gate.log('now.json')) {
				case NotRun(why): Assert.stringContains('timeout at load ', why);
				case other: Assert.fail('got $other');
			}
		});
	}

	/** `body` over the lint rows of a gate on a one-commit tree, leasing from a pool. */
	public static function withGate(body: GateLint -> Void): Void {
		TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			final logs: String = dir.file('logs');
			for (d in [Path.join([tree, 'src']), Path.join([tree, 'bin']), logs]) FileSystem.createDirectory(d);
			for (f in ['src/keep', 'bin/apq-js-common.hxml', 'bin/apq-js.hxml']) File.saveContent(Path.join([tree, f]), '');
			final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
			cmd('git init -q -b main').at(tree).check();
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m base').at(tree).check();
			final gate: GateTree = new GateTree({
				tree: tree,
				logs: logs,
				baseline: true,
				frozen: [],
				infra: [],
				arms: [],
				allow: [],
				allowArms: [],
				noArms: false,
				threads: null,
				run: 'r'
			});
			body(new GateLint(gate, true, Own('wf-run', 8)));
		});
	}

}
