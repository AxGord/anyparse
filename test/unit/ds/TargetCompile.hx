package unit.ds;

import anyparse.proc.ProcessRun;
import anyparse.proc.ProcessSpawn;
import haxe.Exception;
import unit.cli.CliFixture;

/** The one answer to "the run of a program `Main` compiled against the project's `src` for a target the suite does not run on". */
final class TargetCompile {

	private static inline final BUFFER: Int = 8 * 1024 * 1024;

	/** The run of `source` as `Main` under `args`, or null when this host has no working `haxe`. */
	public static function compile(source: String, args: Array<String>): Null<ProcessRun> {
		final dir: String = CliFixture.writeDir('dstargets', [{ name: 'Main.hx', source: source }]);
		try {
			final run: ProcessRun = ProcessSpawn.run(['-cp', '${CliFixture.repoRoot()}/src', '-cp', dir, '-main', 'Main'].concat(
				args
			), dir, BUFFER);
			CliFixture.removeDir(dir);
			if (run.failure == '') return run;
			Assert.pass('haxe unavailable - skipped');
			return null;
		} catch (exception: Exception) {
			CliFixture.removeDir(dir);
			throw exception;
		}
	}

}
