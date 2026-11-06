package unit.grammar;

#if nodejs
import unit.cli.CliFixture;

/** Compiles a one-schema fixture against this tree's `src` and reads what the macro says: the harness of a schema-refusal test. */
final class SchemaCompile {

	/** What compiling `files`, whose `Main.hx` is the entry, against this tree's `src` prints on failure; '' on success. */
	public static function errorOf(label: String, files: Array<{ name: String, source: String }>): String {
		final dir: String = CliFixture.writeDir(label, files);
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--js',
			'$dir/out.js',
			'--no-output'
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return run.status == 0 ? '' : '${run.stderr}';
	}

}
#end
