package testkit;

using StringTools;

#if nodejs
import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.HaxeSpawn;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleGeneration;
#end

/**
 * The test binary run as a CHILD PROCESS by a test that needs a second `apq`-like process — a concurrent run over the
 * same generation locks, or a parent to SIGKILL. `APQ_TEST_CHILD` names the role and the child exits once it is done,
 * so the suite never starts:
 *
 *  - `prepare`: `OracleGeneration.prepare` over the configurations in the JSON file `APQ_TEST_CHILD_INPUT`, writing
 *    each resulting configuration's `unavailable` reason (or null) as JSON to `APQ_TEST_CHILD_OUTPUT`;
 *  - `spawn`: `HaxeSpawn.runAll` over the jobs in the JSON file `APQ_TEST_CHILD_INPUT`, two at a time;
 *  - `bounded-run` / `bounded-pending`: the same jobs through `HaxeSpawn.runAll` / `HaxeSpawn.startAll` + `await`,
 *    the driver bounded by `APQ_TEST_CHILD_BOUND` ms, writing the runs as JSON to `APQ_TEST_CHILD_OUTPUT` - so a test
 *    can wedge a driver and still end, by killing this process, when the bound fails to.
 *
 * It is the CHILD's code that is under test, which is why it is this binary — a mutation arm's cut reaches it.
 */
class TestChild {

	/** Milliseconds `wedge` gives its child before it kills it: far past the bound a test sets, far short of forever. */
	private static inline final WEDGE_DEADLINE: Int = 30000;

	/** Run the child role this process was started for; false when it was started as the suite. */
	public static function run(): Bool {
		#if nodejs
		final role: Null<String> = Sys.getEnv('APQ_TEST_CHILD');
		if (role == null || role == '') return false;
		final input: String = sys.io.File.getContent(Sys.getEnv('APQ_TEST_CHILD_INPUT') ?? '');
		switch role {
			case 'prepare':
				final configs: Array<OracleConfig> = haxe.Json.parse(input);
				final ready: Array<OracleConfig> = OracleGeneration.prepare(configs).oracles;
				OracleGeneration.release(ready);
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', haxe.Json.stringify([for (c in ready) c.unavailable]));
			case 'spawn':
				HaxeSpawn.runAll(haxe.Json.parse(input), 1024 * 1024, 2);
			case 'bounded-run':
				final runs: Array<HaxeRun> = HaxeSpawn.runAll(haxe.Json.parse(input), 1024 * 1024, 2, false, childBound());
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', haxe.Json.stringify(runs));
			case 'bounded-pending':
				final runs: Array<HaxeRun> = HaxeSpawn.startAll(haxe.Json.parse(input), 1024 * 1024, 2, childBound()).await();
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', haxe.Json.stringify(runs));
			case _:
				throw new haxe.Exception('unknown APQ_TEST_CHILD role "$role"');
		}
		return true;
		#else
		return false;
		#end
	}

	#if nodejs
	/**
	 * Run the child `role` (`bounded-run` or `bounded-pending`) in `dir` over one job that stops its own driver — a
	 * stopped process takes no signal but SIGKILL, the wedge a test can make on purpose — with the driver bounded by
	 * `bound` ms, and answer the runs it wrote, or null when it wrote none before `WEDGE_DEADLINE` ms, when this process
	 * kills it. A driver still stopped then is killed too, so nothing is left behind.
	 */
	public static function wedge(role: String, dir: String, bound: Int): Null<Array<HaxeRun>> {
		sys.io.File.saveContent(
			'$dir/jobs.json', haxe.Json.stringify([{ args: [], cwd: dir, shell: 'echo $$PPID > driver.txt; kill -STOP $$PPID' }])
		);
		final env: Dynamic = js.Syntax.code('Object.assign({}, process.env)');
		env.APQ_TEST_CHILD = role;
		env.APQ_TEST_CHILD_INPUT = '$dir/jobs.json';
		env.APQ_TEST_CHILD_OUTPUT = '$dir/runs.json';
		env.APQ_TEST_CHILD_BOUND = '$bound';
		js.node.ChildProcess.spawnSync(js.Node.process.execPath, [js.Syntax.code('process.argv[1]')], {
			env: env,
			stdio: 'ignore',
			timeout: WEDGE_DEADLINE,
			killSignal: 'SIGKILL'
		});
		final pid: String = try sys.io.File.getContent('$dir/driver.txt') catch (exception: haxe.Exception) '';
		final driver: Null<Int> = Std.parseInt(pid.trim());
		if (driver != null && stopped(driver)) js.Syntax.code('process.kill({0}, "SIGKILL")', driver);
		return try haxe.Json.parse(sys.io.File.getContent('$dir/runs.json')) catch (exception: haxe.Exception) null;
	}

	/** The driver bound `APQ_TEST_CHILD_BOUND` names, in milliseconds. */
	private static function childBound(): Int {
		final bound: Null<Int> = Std.parseInt(Sys.getEnv('APQ_TEST_CHILD_BOUND') ?? '');
		if (bound == null) throw new haxe.Exception('APQ_TEST_CHILD_BOUND names no bound');
		return bound;
	}

	/** Whether `pid` is a stopped process — the wedged driver, never a process that took its pid over since. */
	private static function stopped(pid: Int): Bool {
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-o', 'stat=', '-p', '$pid'], { encoding: 'utf8' });
		return res.stdout != null && '${res.stdout}'.trim().startsWith('T');
	}
	#end

}
