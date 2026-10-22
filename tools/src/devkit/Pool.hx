package devkit;

import anyparse.check.HaxeSpawn;
import haxe.Exception;

using Lambda;

/**
 * Commands run as separate processes, at most `size` at a time, their results answered in the order the commands
 * were given. The processes share nothing but the machine, so commands that write a common path must not share a
 * pool. Runs through `HaxeSpawn.runAll`, whose process driver kills each command at its own `timeout`.
 */
@:nullSafety(Strict)
final class Pool {

	/**
	 * The rounds of `size` commands one driver run carries. The driver answers a whole batch in ONE reply, and a batch of
	 * every command could outgrow the longest string the runtime can hold; the cost is a wait for a batch's slowest
	 * command before the next batch starts.
	 */
	private static inline final BATCH_ROUNDS: Int = 8;

	private final _size: Int;

	private function new(size: Int) {
		_size = size;
	}

	/** Every command of `commands` run to its end, results in `commands` order. A pipeline is refused: run it alone. */
	public function run(commands: Array<Command>): Array<Result> {
		final pipeline: Null<Command> = commands.find(c -> c.isPipeline());
		if (pipeline != null) throw new Exception('`$pipeline` is a pipeline, which runs one stage at a time — run it alone');
		return commands.exists(c -> c.stdinText() != null)
			? TempDir.with(dir -> answer(commands, [for (i => c in commands) c.job(stdinFile(dir, i, c))]))
			: answer(commands, [for (c in commands) c.job(null)]);
	}

	/** The command `command` makes of every item of `items`, run as `run` runs them. */
	public function map<T>(items: Array<T>, command: T -> Command): Array<Result> {
		return run(items.map(command));
	}

	private function answer(commands: Array<Command>, jobs: Array<SpawnJob>): Array<Result> {
		final runs: Array<HaxeRun> = [];
		final batch: Int = _size * BATCH_ROUNDS;
		var from: Int = 0;
		while (from < jobs.length) {
			for (run in HaxeSpawn.runAll(jobs.slice(from, from + batch), Command.MAX_BUFFER, _size)) runs.push(run);
			from += batch;
		}
		return [for (i => c in commands) new Result(c.toString(), runs[i])];
	}

	/** A pool running at most `size` commands at once. */
	public static function of(size: Int): Pool {
		if (size < 1) throw new Exception('a pool runs at least one command at a time, not $size');
		return new Pool(size);
	}

	/** The file in `dir` holding the standard input of the `i`-th command `c`, or null when it reads none. */
	private static function stdinFile(dir: TempDir, i: Int, c: Command): Null<String> {
		final text: Null<String> = c.stdinText();
		if (text == null) return null;
		final file: String = dir.file('stdin-$i');
		sys.io.File.saveContent(file, text);
		return file;
	}

}
