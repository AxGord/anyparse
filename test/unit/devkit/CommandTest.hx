package unit.devkit;

import devkit.Cmd.cmd;
import devkit.CommandFailed;
import devkit.Pool;
import devkit.Result;
import devkit.TempDir;
import haxe.Exception;
import haxe.Json;
import haxe.Timer;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `Command.run` — one process through `HaxeSpawn.exec`, its argument vector handed over with no shell in between. The
 * programs here are `node -e` scripts, so the suite needs nothing the runner does not already have.
 */
@:nullSafety(Strict)
final class CommandTest extends Test {

	/** Prints its own arguments as JSON. */
	private static inline final ECHO_ARGS: String = 'console.log(JSON.stringify(process.argv.slice(1)))';

	/** Copies its standard input to its standard output, upper-cased. */
	private static inline final UPPER: String =
		'let s = ""; process.stdin.on("data", d => s += d).on("end", () => process.stdout.write(s.toUpperCase()))';

	/** Writes one line to each stream, then exits 3. */
	private static inline final FAIL: String = 'process.stdout.write("o\\n"); process.stderr.write("e\\n"); process.exit(3)';

	/** Never ends by itself. */
	private static inline final HANG: String = 'setInterval(() => {}, 1000)';

	/** Prints `DEVKIT_PROBE` and its working directory. */
	private static inline final SHOW_ENV: String = 'process.stdout.write(process.env.DEVKIT_PROBE + "|" + process.cwd())';

	/** Prints two lines. */
	private static inline final PRINT_XY: String = 'console.log("x"); console.log("y")';

	/** Prints a blank line between two, the last one ended. */
	private static inline final PRINT_GAP: String = 'process.stdout.write("a\\n\\nb\\n")';

	/** Prints one line with no break after it. */
	private static inline final PRINT_UNENDED: String = 'process.stdout.write("a")';

	/** Prints its parent's pid. */
	private static inline final PRINT_PPID: String = 'process.stdout.write(String(process.ppid))';

	/**
	 * How long the sleepers of `LEAVE_HOLDER` and `LEAVE_QUIET` live; a test must end well before.
	 */
	private static inline final HOLD_SECONDS: Float = 12;

	/**
	 * Prints the pid of a sleeper that keeps this command's streams open long after the command exits.
	 */
	private static inline final LEAVE_HOLDER: String = 'const c = require("child_process").spawn(process.execPath, ["-e", "setTimeout(() => {}, 12000)"], '
		+ '{ stdio: ["ignore", "inherit", "inherit"] }); c.unref(); console.log(c.pid)';

	/**
	 * Prints the pid of a sleeper that holds none of this command's streams, then exits at once.
	 */
	private static inline final LEAVE_QUIET: String = 'const c = require("child_process").spawn(process.execPath, ["-e", "setTimeout(() => {}, 12000)"], '
		+ '{ stdio: "ignore" }); c.unref(); console.log(c.pid)';

	/**
	 * Rewrites the file `argv[1]` on a short beat for a while, then exits.
	 */
	private static inline final BEAT: String = 'let n = 0; const t = setInterval(() => { require("fs").writeFileSync(process.argv[1], "beat " + n++); '
		+ 'if (n > 12) clearInterval(t); }, 200)';

	/** Prints the pid of a sleeper in a process group of its own that keeps this command's streams open, then exits at once. */
	private static inline final LEAVE_DETACHED: String = 'const c = require("child_process").spawn(process.execPath, ["-e", "setTimeout(() => {}, 12000)"], '
		+ '{ detached: true, stdio: ["ignore", "inherit", "inherit"] }); c.unref(); console.log(c.pid)';

	/** Prints a line on a short beat for a while, then exits. */
	private static inline final TICK: String =
		'let n = 0; const t = setInterval(() => { console.log("tick " + n++); if (n > 12) clearInterval(t); }, 200)';

	private final _node: String = js.Node.process.execPath;

	/** A tethered command runs under its tether, never as this process's own child, whatever command was derived from it. */
	public function testTheTetherIsKeptByEveryDerivedCommand(): Void {
		final own: String = '${js.Node.process.pid}';
		Assert.equals(own, cmd('$_node -e $PRINT_PPID').text(), 'untethered: this process\'s own child');
		TempDir.with(dir -> {
			final tethered: devkit.Command = cmd('$_node -e $PRINT_PPID').tethered();
			for (derived in [
				tethered,
				tethered.at(dir.path),
				tethered.env('DEVKIT_PROBE', 'x'),
				tethered.timeout(60000)
			]) {
				final parent: String = derived.text();
				Assert.notEquals(own, parent, derived.toString());
				Assert.notEquals('', parent);
			}
			Assert.notEquals(own, tethered.pipe(cmd('$_node -e $UPPER')).text(), 'the upstream stage of a pipe');
		});
	}

	public function testATetheredRunAnswersAsAnUntetheredOne(): Void {
		final plain: Result = cmd('$_node -e $FAIL').run();
		final tethered: Result = cmd('$_node -e $FAIL').tethered().run();
		Assert.same([plain.status, plain.out, plain.err, plain.failure], [tethered.status, tethered.out, tethered.err, tethered.failure]);
		Assert.equals(3, tethered.status);
	}

	/** The tether is the command's standard input, so an input or a pipe into it would be dropped: both are refused. */
	public function testATetheredCommandReadsNoInput(): Void {
		Assert.raises(() -> cmd('$_node -e $UPPER').tethered().input('x'));
		Assert.raises(() -> cmd('$_node -e $UPPER').input('x').tethered());
		Assert.raises(() -> cmd('$_node -e $PRINT_XY').pipe(cmd('$_node -e $UPPER').tethered()));
		Assert.raises(() -> cmd('$_node -e $PRINT_XY').pipe(cmd('$_node -e $UPPER')).tethered());
	}

	public function testArgumentsReachTheProgramVerbatim(): Void {
		final weird: Array<String> = ['--foo', 'a b', '', '$$HOME', 'it\'s', 'x;y|z', '"q"', '*', '`id`'];
		final echoed: Array<String> = Json.parse(cmd('$_node -e $ECHO_ARGS -- $weird').text());
		Assert.same(weird, echoed);
	}

	public function testAFailureKeepsItsStatusAndBothStreams(): Void {
		final result: Result = cmd('$_node -e $FAIL').run();
		Assert.isFalse(result.ok);
		Assert.equals(3, result.status);
		Assert.equals('o\n', result.out);
		Assert.equals('e\n', result.err);
		Assert.equals('', result.failure, 'the program ran: a status is a verdict, not a failure to run');
		final thrown: Null<CommandFailed> = try {
			Assert.fail('passed as ${result.check().status}');
			null;
		} catch (e: CommandFailed) {
			e;
		};
		Assert.notNull(thrown);
		if (thrown != null) Assert.isTrue(thrown.message.contains('exited 3') && thrown.message.endsWith(':\ne'), thrown.message);
	}

	public function testEnvironmentAndWorkingDirectory(): Void {
		TempDir.with(dir -> {
			final shown: String = cmd('$_node -e $SHOW_ENV').env('DEVKIT_PROBE', 'v w').at(dir.path).text();
			Assert.equals('v w|${js.node.Fs.realpathSync(dir.path)}', shown);
		});
	}

	public function testAPrefixRunsTheCommandWithItsDirectoryAndEnvironment(): Void {
		TempDir.with(dir -> {
			final shown: String = cmd('$_node -e $SHOW_ENV').env('DEVKIT_PROBE', 'v').at(dir.path).under(['env', 'UNUSED=1']).text();
			Assert.equals('v|${js.node.Fs.realpathSync(dir.path)}', shown);
		});
		Assert.raises(() -> cmd('$_node -e $PRINT_XY').pipe(cmd('$_node -e $UPPER')).under(['env']));
	}

	public function testInputAndPipes(): Void {
		Assert.equals('AB\nCD', cmd('$_node -e $UPPER').input('ab\ncd').text());
		final lines: Array<String> = cmd('$_node -e $PRINT_XY').pipe(cmd('$_node -e $UPPER')).lines();
		Assert.same(['X', 'Y'], lines);
	}

	/** `pipefail`: a failing stage answers for the pipeline, and the stages after it never run. */
	public function testAFailingStageAnswersForThePipeline(): Void {
		final result: Result = cmd('$_node -e $FAIL').pipe(cmd('$_node -e $UPPER')).run();
		Assert.equals(3, result.status);
		Assert.equals('o\n', result.out, 'the failing stage\'s own output, never upper-cased');
	}

	public function testATimeoutKillsTheProgram(): Void {
		final started: Float = Timer.stamp();
		final result: Result = cmd('$_node -e $HANG').timeout(300).run();
		Assert.isNull(result.status);
		Assert.isTrue(result.failure.endsWith('timed out after 300 ms'), result.failure);
		Assert.isTrue(Timer.stamp() - started < 30, 'killed, not waited out');
	}

	public function testAProgramThatCannotLaunchSaysSo(): Void {
		final result: Result = cmd('devkit-no-such-program-zzz --x').run();
		Assert.isNull(result.status);
		Assert.isTrue(result.failure.startsWith('could not launch devkit-no-such-program-zzz'), result.failure);
	}

	public function testLinesDropOnlyTheFinalBreak(): Void {
		Assert.same(['a', '', 'b'], cmd('$_node -e $PRINT_GAP').lines());
		Assert.same([], cmd('$_node -e 0').lines());
		Assert.same(['a'], cmd('$_node -e $PRINT_UNENDED').lines());
	}

	/** A run ends at its process's exit: a grandchild still holding its output does not keep the caller waiting. */
	public function testARunEndsAtItsExitWhateverHoldsItsOutput(): Void {
		final started: Float = Timer.stamp();
		final run: Result = cmd('$_node -e $LEAVE_HOLDER').run();
		final elapsed: Float = Timer.stamp() - started;
		final holder: Null<Int> = Std.parseInt(run.out.trim());
		killQuietly(holder);
		Assert.equals(0, run.status);
		Assert.isTrue(elapsed < HOLD_SECONDS - 4, 'ended after $elapsed s');
		Assert.notNull(holder);
	}

	/** The process driver gives the pipes a short grace after the exit, then names what still holds them and kills it. */
	public function testAnOrphanHoldingTheOutputIsNamedAndKilled(): Void {
		final started: Float = Timer.stamp();
		final runs: Array<Result> = Pool.of(2).run([cmd('$_node -e $LEAVE_HOLDER'), cmd('$_node -e $PRINT_XY')]);
		final elapsed: Float = Timer.stamp() - started;
		final holder: Null<Int> = Std.parseInt(runs[0].out.trim());
		Assert.equals(0, runs[0].status);
		Assert.isTrue(elapsed < HOLD_SECONDS - 4, 'ended after $elapsed s');
		Assert.stringContains('orphan held output: $holder ', runs[0].err);
		Assert.isFalse(alive(holder), 'the holder is gone');
		Assert.equals('', runs[1].err, 'a run that left nothing behind names nothing');
	}

	/** A reaped command names and kills what its group left running even when that holds none of its streams. */
	public function testAReapedCommandKillsWhatItLeftRunning(): Void {
		final run: Result = cmd('$_node -e $LEAVE_QUIET').reaped().run();
		final holder: Null<Int> = Std.parseInt(run.out.trim());
		Assert.equals(0, run.status);
		Assert.stringContains('orphan left running: $holder ', run.err);
		Assert.isFalse(alive(holder), 'the sleeper is gone');
	}

	/** A command with nothing to name leaves its streams as they were. */
	public function testAReapedCommandThatLeftNothingNamesNothing(): Void {
		final run: Result = cmd('$_node -e $PRINT_XY').reaped().run();
		Assert.same([0, 'x\ny\n', ''], [run.status, run.out, run.err]);
	}

	/** A silent command is cut once its idle time passes, and the failure says where its progress file stood. */
	public function testASilentCommandIsCutAtItsIdleTime(): Void {
		TempDir.with(dir -> {
			final progress: String = dir.file('progress');
			sys.io.File.saveContent(progress, 'unit.SomeTest.testWhereItStopped');
			final started: Float = Timer.stamp();
			final run: Result = cmd('$_node -e $HANG').timeout(60000).watched(1500, progress).run();
			Assert.isNull(run.status);
			Assert.stringContains('no progress for 2 s', run.failure);
			Assert.stringContains('last started: unit.SomeTest.testWhereItStopped', run.failure);
			Assert.isTrue(Timer.stamp() - started < 20);
		});
	}

	/** A command that keeps its progress file moving outlives its idle time. */
	public function testACommandThatKeepsMovingIsNotCut(): Void {
		TempDir.with(dir -> {
			final progress: String = dir.file('progress');
			final run: Result = cmd('$_node -e $BEAT $progress').timeout(60000).watched(1000, progress).run();
			Assert.equals(0, run.status);
			Assert.equals('', run.failure);
		});
	}

	/** A holder the job's group cannot reach is told apart, and the run still ends once the pipes are given up. */
	public function testAHolderOutsideTheJobGroupIsGivenUpOn(): Void {
		final started: Float = Timer.stamp();
		final runs: Array<Result> = Pool.of(2).run([cmd('$_node -e $LEAVE_DETACHED'), cmd('$_node -e $PRINT_XY')]);
		final elapsed: Float = Timer.stamp() - started;
		killQuietly(Std.parseInt(runs[0].out.trim()));
		Assert.equals(0, runs[0].status);
		Assert.isTrue(elapsed < HOLD_SECONDS - 4, 'ended after $elapsed s');
		Assert.stringContains('orphan held output: (outside the job group)', runs[0].err);
	}

	/** Output bytes are signs of life too: a command that keeps printing outlives its idle time with no progress file. */
	public function testACommandThatKeepsPrintingIsNotCut(): Void {
		TempDir.with(dir -> {
			final run: Result = cmd('$_node -e $TICK').timeout(60000).watched(1000, dir.file('never-written')).run();
			Assert.equals(0, run.status);
			Assert.equals('', run.failure);
		});
	}

	private static function alive(pid: Null<Int>): Bool {
		if (pid == null) return false;
		for (_ in 0...30) {
			try {
				js.Syntax.code('process.kill({0}, 0)', pid);
			} catch (exception: Exception) {
				return false;
			}
			Sys.sleep(0.1);
		}
		return true;
	}

	private static function killQuietly(pid: Null<Int>): Void {
		if (pid != null) try js.Node.process.kill(pid) catch (exception: Exception) { // noqa: swallowed-exception
			// the holder may be gone already
		}
	}

}
