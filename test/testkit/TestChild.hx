package testkit;

#if nodejs
import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.HaxeRun;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.LintConfig.OracleGenerate;
import anyparse.check.oracle.OracleGeneration;
import anyparse.check.oracle.SpawnJob;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import devkit.RawJson;
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
 *    can wedge a driver and still end, by killing this process, when the bound fails to;
 *  - `flood`: the content of `APQ_TEST_CHILD_INPUT` printed to stdout, then `Sys.exit` — the suite's own way out.
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
				final configs: Array<OracleConfig> = [for (c in TestChildDocumentParser.parse(input).configs ?? []) oracleConfig(c)];
				final ready: Array<OracleConfig> = OracleGeneration.prepare(configs).oracles;
				OracleGeneration.release(ready);
				final unavailable: Array<JValue> = [
					for (c in ready) {
						final why: Null<String> = c.unavailable;
						why == null ? JNull : JString(why);
					}
				];
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', RawJson.print(JArray(unavailable)));
			case 'spawn':
				HaxeSpawn.runAll(TestChildDocumentParser.parse(input).jobs ?? [], 1024 * 1024, 2);
			case 'bounded-run':
				final runs: Array<HaxeRun> = HaxeSpawn.runAll(
					TestChildDocumentParser.parse(input).jobs ?? [], 1024 * 1024, 2, false, childBound()
				);
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', runsText(runs));
			case 'flood':
				// a transcript printed and the process ended straight after, as utest's report ends it
				Sys.print(input);
				Sys.exit(0);
			case 'bounded-pending':
				final runs: Array<HaxeRun> = HaxeSpawn.startAll(
					TestChildDocumentParser.parse(input).jobs ?? [], 1024 * 1024, 2, childBound()
				)
					.await();
				sys.io.File.saveContent(Sys.getEnv('APQ_TEST_CHILD_OUTPUT') ?? '', runsText(runs));
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
		sys.io.File.saveContent('$dir/jobs.json', jobsText([{ args: [], cwd: dir, shell: 'echo $$PPID > driver.txt; kill -STOP $$PPID' }]));
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
		final written: Null<Array<ChildRun>> = try TestChildDocumentParser.parse(sys.io.File.getContent('$dir/runs.json'))
			.runs catch (exception: haxe.Exception) null;
		return written == null ? null : [for (r in written) haxeRun(r)];
	}

	/** The input file of a `spawn`, `bounded-run` or `bounded-pending` child: the jobs it runs. */
	public static function jobsText(jobs: Array<SpawnJob>): String {
		return TestChildDocumentWriter.write({ jobs: jobs }, JsonFormat.instance.compactWriteOptions);
	}

	/** The input file of a `prepare` child: the configurations it prepares. */
	public static function configsText(configs: Array<OracleConfig>): String {
		return TestChildDocumentWriter.write({ configs: [for (c in configs) childConfig(c)] }, JsonFormat.instance.compactWriteOptions);
	}

	/** The output file of a `bounded-run` or `bounded-pending` child: the runs it answers. */
	private static function runsText(runs: Array<HaxeRun>): String {
		final written: Array<ChildRun> = [
			for (r in runs)
				{
					status: r.status,
					out: r.out,
					err: r.err,
					failure: r.failure,
					overflowed: r.overflowed,
					cancelled: r.cancelled,
					unstarted: r.unstarted
				}
		];
		return TestChildDocumentWriter.write({ runs: written }, JsonFormat.instance.compactWriteOptions);
	}

	/** The run `r` was written as. */
	private static function haxeRun(r: ChildRun): HaxeRun {
		return {
			status: r.status,
			out: r.out,
			err: r.err,
			failure: r.failure,
			overflowed: r.overflowed,
			cancelled: r.cancelled,
			unstarted: r.unstarted
		};
	}

	/** Configuration `c` as a child reads it: every key but the run's own memo. */
	private static function childConfig(c: OracleConfig): ChildOracleConfig {
		final generate: Null<OracleGenerate> = c.generate;
		return {
			hxml: c.hxml,
			dir: c.dir,
			defines: c.defines,
			generate: generate == null ? null : {
				command: generate.command,
				root: generate.root,
				inputs: generate.inputs,
				probeDir: generate.probeDir
			},
			unavailable: c.unavailable,
			raced: c.raced,
			modules: c.modules
		};
	}

	/** The configuration `c` was written from. */
	private static function oracleConfig(c: ChildOracleConfig): OracleConfig {
		final generate: Null<ChildOracleGenerate> = c.generate;
		return {
			hxml: c.hxml,
			dir: c.dir,
			defines: c.defines,
			generate: generate == null ? null : {
				command: generate.command,
				root: generate.root,
				inputs: generate.inputs,
				probeDir: generate.probeDir
			},
			unavailable: c.unavailable,
			raced: c.raced,
			modules: c.modules
		};
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
