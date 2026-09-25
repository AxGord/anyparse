package testkit;

#if nodejs
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
 *  - `spawn`: `HaxeSpawn.runAll` over the jobs in the JSON file `APQ_TEST_CHILD_INPUT`, two at a time.
 *
 * It is the CHILD's code that is under test, which is why it is this binary — a mutation arm's cut reaches it.
 */
class TestChild {

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
			case _:
				throw new haxe.Exception('unknown APQ_TEST_CHILD role "$role"');
		}
		return true;
		#else
		return false;
		#end
	}

}
