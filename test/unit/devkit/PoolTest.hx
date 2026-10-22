package unit.devkit;

import devkit.Cmd.cmd;
import devkit.Pool;
import devkit.Result;
import devkit.TempDir;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `Pool` — commands as separate processes through `HaxeSpawn.runAll`'s process driver: results in the order given,
 * the commands really overlapping, and a timeout, an input or an environment honoured per command.
 */
@:nullSafety(Strict)
final class PoolTest extends Test {

	/** Prints its first argument. */
	private static inline final PRINT_ARG: String = 'process.stdout.write(process.argv[1])';

	/**
	 * Marks itself started in the directory `argv[1]` (as `argv[2]`), then waits for `argv[3]` marks in all: it exits 0
	 * only when that many commands were running at once, 1 when it gave up waiting.
	 */
	private static inline final RENDEZVOUS: String = 'const fs = require("fs"), path = require("path");'
		+ ' const [dir, me, want] = process.argv.slice(1); fs.writeFileSync(path.join(dir, me), "");'
		+ ' const end = Date.now() + 20000; (function wait() {'
		+ ' if (fs.readdirSync(dir).filter(f => f.startsWith("job")).length >= Number(want)) process.exit(0);'
		+ ' if (Date.now() > end) process.exit(1); setTimeout(wait, 20); })();';

	/** Never ends by itself. */
	private static inline final HANG: String = 'setInterval(() => {}, 1000)';

	/** Copies its standard input to its standard output. */
	private static inline final CAT: String = 'process.stdin.pipe(process.stdout)';

	/** Prints `DEVKIT_PROBE`. */
	private static inline final SHOW_ENV: String = 'process.stdout.write(String(process.env.DEVKIT_PROBE))';

	private final _node: String = js.Node.process.execPath;

	public function testResultsComeBackInTheOrderGiven(): Void {
		final items: Array<String> = [for (i in 0...7) 'item $i'];
		final results: Array<Result> = Pool.of(3).map(items, item -> cmd('$_node -e $PRINT_ARG -- $item'));
		Assert.same(items, [for (r in results) r.out]);
		Assert.isTrue(results.foreach(r -> r.ok));
	}

	/** Four commands that each wait for all four to have started: only a pool that really overlaps them passes. */
	public function testCommandsRunAtTheSameTime(): Void {
		TempDir.with(dir -> {
			final results: Array<Result> = Pool.of(4)
				.map([for (i in 0...4) 'job$i'], me -> cmd('$_node -e $RENDEZVOUS -- ${dir.path} $me 4'));
			Assert.same([0, 0, 0, 0], [for (r in results) r.status]);
		});
	}

	public function testATimeoutEndsOnlyItsOwnCommand(): Void {
		final results: Array<Result> = Pool.of(2).run([cmd('$_node -e $HANG').timeout(300), cmd('$_node -e $PRINT_ARG -- done')]);
		Assert.isNull(results[0].status);
		Assert.isTrue(results[0].failure.contains('timed out after 300 ms'), results[0].failure);
		Assert.equals('done', results[1].out);
	}

	public function testInputAndEnvironmentArePerCommand(): Void {
		final results: Array<Result> = Pool.of(2).run([
			cmd('$_node -e $CAT').input('first'),
			cmd('$_node -e $CAT').input('second'),
			cmd('$_node -e $SHOW_ENV').env('DEVKIT_PROBE', 'v w'),
			cmd('$_node -e $SHOW_ENV')
		]);
		Assert.same(['first', 'second', 'v w', 'undefined'], [for (r in results) r.out]);
	}

	/** More commands than one driver run carries still come back, every one, in order. */
	public function testCommandsBeyondOneDriverRun(): Void {
		final items: Array<String> = [for (i in 0...20) '$i'];
		Assert.same(items, [
			for (r in Pool.of(2).map(items, item -> cmd('$_node -e $PRINT_ARG -- $item'))) r.out
		]);
	}

	public function testRefusals(): Void {
		Assert.raises(Pool.of.bind(0));
		Assert.raises(() -> Pool.of(2).run([cmd('a').pipe(cmd('b'))]), null, 'a pipeline runs one stage at a time, alone');
	}

}
