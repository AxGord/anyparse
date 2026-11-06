package devkit;

import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.SpawnJob;
import haxe.DynamicAccess;
import haxe.Exception;

/**
 * One program and its argument vector, run with no shell in between — so nothing in an argument is ever quoted,
 * split or expanded. Usually built by `Cmd.cmd`. A command is immutable: `at`, `env`, `timeout`, `input`, `pipe` and
 * `tethered` each answer a new one, so a command can be kept and reused as a template.
 *
 * Every run goes through `HaxeSpawn` (here and from `Pool`), the project's one process
 * seam: a run ends at its process's exit, and whatever its process group still runs then — an
 * orphan holding its pipes included — is named in `err` (`orphan left running`) and killed.
 * A short program (`SHORT_PROGRAMS`) is the exception: it runs in this process, bounded by its own `timeout` alone.
 */
@:nullSafety(Strict)
final class Command {

	/**
	 * The byte cap on each captured stream. Node's own default (1 MiB) is one a verbose tool outgrows; past this cap the
	 * run is killed and answers a `failure`.
	 */
	public static inline final MAX_BUFFER: Int = 256 * 1024 * 1024;

	/**
	 * The programs that end within moments and start nothing that outlives them (git plumbing, process listings): a run of one
	 * needs no process driver, which costs a node start on top of the program itself. Such a run is bounded by the command's own
	 * `timeout` and by nothing else, as a driven one is; a caller that knows its program is plumbing names one.
	 */
	private static final SHORT_PROGRAMS: Array<String> = ['git', 'ps', 'pgrep'];

	public final argv: Array<String>;

	private final _cwd: Null<String>;
	private final _env: DynamicAccess<String>;
	private final _timeout: Int;
	private final _input: Null<String>;
	private final _upstream: Null<Command>;
	private final _tethered: Bool;
	private final _guard: Guard;

	private function new(
		argv: Array<String>, cwd: Null<String>, env: DynamicAccess<String>, timeout: Int, input: Null<String>, upstream: Null<Command>,
		tethered: Bool, guard: Guard
	) {
		this.argv = argv;
		_cwd = cwd;
		_env = env;
		_timeout = timeout;
		_input = input;
		_upstream = upstream;
		_tethered = tethered;
		_guard = guard;
	}

	/** `run`, throwing `CommandFailed` unless it exited 0. */
	public inline function check(): Result {
		return run().check();
	}

	/** The standard output of a run that must exit 0. */
	public inline function text(): String {
		return check().out;
	}

	/** The output lines of a run that must exit 0 (`Result.lines`). */
	public inline function lines(): Array<String> {
		return check().lines();
	}

	/** This command run in `dir`. */
	public function at(dir: String): Command {
		return new Command(argv, dir, _env, _timeout, _input, _upstream, _tethered, _guard);
	}

	/** This command with the environment variable `name` set to `value` over this process's environment. */
	public function env(name: String, value: String): Command {
		final env: DynamicAccess<String> = Reflect.copy(_env) ?? {};
		env[name] = value;
		return new Command(argv, _cwd, env, _timeout, _input, _upstream, _tethered, _guard);
	}

	/** This command killed after `ms` milliseconds, which then answers a `failure`; 0 is no limit. */
	public function timeout(ms: Int): Command {
		return new Command(argv, _cwd, _env, ms, _input, _upstream, _tethered, _guard);
	}

	/**
	 * This command run under a tether to the process driver that starts it (`SpawnJob.tethered`): it and everything it
	 * starts end with the driver however the driver goes, so a run killed outright leaves no such command behind. A
	 * tethered command always runs through the driver, as a `Pool` job. Its standard input is the tether, so it reads
	 * no `input` and no pipe: either is refused.
	 */
	public function tethered(): Command {
		if (_input != null || _upstream != null)
			throw new Exception('`${toString()}` reads an input, and a tethered command reads its tether');
		return new Command(argv, _cwd, _env, _timeout, _input, _upstream, true, _guard);
	}

	/**
	 * This command killed once it has been silent for `ms` milliseconds — no byte on either stream and no change of the file
	 * `progress` — which then answers a `failure` quoting the text of `progress`: where a stalled run stood. Runs through the
	 * process driver. A process group the command leads is killed whole. With `awaitProgress` the silence counts only from the
	 * first change of `progress`: a command that queues behind a lease wrapper has not begun, and is not silent.
	 */
	public function watched(ms: Int, progress: String, awaitProgress: Bool = false): Command {
		return new Command(argv, _cwd, _env, _timeout, _input, _upstream, _tethered, {
			idle: ms,
			progress: progress,
			awaitProgress: awaitProgress
		});
	}

	/**
	 * This command run by the program `prefix` names, `prefix` laid before this argument vector — a wrapper such as a lease or
	 * a nice level, which runs what follows it. Everything else of the command is kept; a pipeline is refused, since a
	 * prefix would run only its last stage.
	 */
	public function under(prefix: Array<String>): Command {
		if (_upstream != null) throw new Exception('`${toString()}` is a pipeline, and a prefix would run only its last stage');
		if (prefix.length == 0) throw new Exception('a prefix needs a program to run');
		return new Command(prefix.concat(argv), _cwd, _env, _timeout, _input, _upstream, _tethered, _guard);
	}

	/** This command with `text` as its standard input. */
	public function input(text: String): Command {
		if (_upstream != null) throw new Exception('`${toString()}` already reads a pipe');
		if (_tethered) throw new Exception('`${toString()}` is tethered, and a tethered command reads its tether');
		return new Command(argv, _cwd, _env, _timeout, text, _upstream, _tethered, _guard);
	}

	/**
	 * `next` reading this command's standard output — `a | b` with `pipefail`: when this command fails, the pipeline
	 * answers its result and `next` never runs. The stages run one after another, each to its end.
	 */
	public function pipe(next: Command): Command {
		if (next._input != null || next._upstream != null) throw new Exception('`$next` already has an input');
		if (next._tethered) throw new Exception('`$next` is tethered, and a tethered command reads its tether');
		return new Command(next.argv, next._cwd, next._env, next._timeout, null, this, next._tethered, next._guard);
	}

	/** Run the command (every stage of a pipeline) to its end. Never throws for the command's own sake: see `Result`. */
	public function run(): Result {
		final upstream: Null<Command> = _upstream;
		if (upstream == null) return spawn(_input);
		final first: Result = upstream.run();
		return first.ok ? spawn(first.out) : first;
	}

	/** The command as a shell would spell it, every argument that needs it single-quoted — for messages, never for a shell. */
	public function toString(): String {
		final own: String = argv.map(quoted).join(' ');
		final upstream: Null<Command> = _upstream;
		return upstream == null ? own : '$upstream | $own';
	}

	/** The text this command reads on its standard input, or null. */
	@:allow(devkit.Pool)
	private inline function stdinText(): Null<String> {
		return _input;
	}

	/** Whether this command reads the output of another: a pipeline, which runs one stage at a time. */
	@:allow(devkit.Pool)
	private inline function isPipeline(): Bool {
		return _upstream != null;
	}

	/** This command as one job of `HaxeSpawn`, reading the file `stdin` when given. */
	@:allow(devkit.Pool)
	private function job(stdin: Null<String>): SpawnJob {
		final job: SpawnJob = {
			cmd: argv[0],
			args: argv.slice(1),
			cwd: _cwd,
			env: HaxeSpawn.environment(_env),
			timeout: _timeout,
			reap: true
		};
		if (stdin != null) job.stdin = stdin;
		if (_tethered) job.tethered = true;
		if (_guard.idle > 0) job.idle = _guard.idle;
		if (_guard.progress != null) job.progress = _guard.progress;
		if (_guard.awaitProgress) job.awaitProgress = true;
		return job;
	}

	/** One process: this command with `input` (when given) on its standard input. */
	private function spawn(input: Null<String>): Result {
		return input == null
			? new Result(toString(), one(job(null)))
			: TempDir.with(dir -> {
				final file: String = dir.file('stdin');
				sys.io.File.saveContent(file, input);
				return new Result(toString(), one(job(file)));
			});
	}

	/** The command running `argv[0]` over the rest of `argv`. */
	public static function of(argv: Array<String>): Command {
		if (argv.length == 0) throw new Exception('a command needs a program to run');
		return new Command(argv.copy(), null, {}, 0, null, null, false, {
			idle: 0,
			progress: null,
			awaitProgress: false
		});
	}

	/** One argument of a `Cmd.cmd` template: `value` as text; a null `value` (`source` in the template) throws. */
	public static function word(value: Null<Any>, source: String): String {
		if (value == null) throw new Exception('cmd: `$source` is null');
		return Std.string(value);
	}

	/** The arguments an array `value` (`source` in the template) fills a whole template word with. */
	public static function words(value: Null<Array<String>>, source: String): Array<String> {
		if (value == null) throw new Exception('cmd: `$source` is null');
		return [for (item in value) word(item, source)];
	}

	/** `parts` laid end to end: the argument vector of a template, one array per template word. */
	public static function flat(parts: Array<Array<String>>): Array<String> {
		return [for (part in parts) for (item in part) item];
	}

	/**
	 * One job run to its end. A short program (`runsDirect`) runs in this process; any other goes through the process
	 * driver, which answers at the process's exit and not at its pipes' end: what its process group still runs at the exit is named
	 * in the `err` (`orphan left running`) and killed, as it was when the caller's own group was reaped. The limit is the job's
	 * `timeout` alone.
	 */
	private static function one(job: SpawnJob): HaxeRun {
		return runsDirect(job) ? HaxeSpawn.exec(job, MAX_BUFFER) : HaxeSpawn.runDriven([job], MAX_BUFFER, 1)[0];
	}

	/** `arg` as it would have to be written in a POSIX shell. */
	private static function quoted(arg: String): String {
		return arg != '' && ~/^[A-Za-z0-9_@%+=:,.\/-]+$/.match(arg) ? arg : "'" + arg.split("'").join("'\\''") + "'";
	}

	/**
	 * Whether `job` runs in this process, with no process driver between: a short program no one needs to outlive this process,
	 * watch for silence or tether to a driver. Its streams go to files and not to pipes, so what it leaves behind cannot hold the run.
	 */
	private static function runsDirect(job: SpawnJob): Bool {
		return job.tethered != true && (job.idle ?? 0) <= 0 && SHORT_PROGRAMS.contains(job.cmd ?? '');
	}

}

/** How a command is supervised once it runs: the group it leaves behind, and the silence it is cut after. */
typedef Guard = {

	/** Milliseconds of silence after which the run is killed; 0 for no limit. */
	var idle: Int;

	/** The file whose change counts as a sign of life, and whose text says where a stalled run stood. */
	var progress: Null<String>;

	/** Whether `idle` counts from the first change of `progress` and not from the start. */
	var awaitProgress: Bool;
}
