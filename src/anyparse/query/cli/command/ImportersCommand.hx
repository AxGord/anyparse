package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.cli.CliArgs.ResolvedInputs;

/**
 * `apq importers` — list files importing a given module (cross-file).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ImportersCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'importers';
	}

	public function summary(): String {
		return 'List files importing a given module (cross-file)';
	}

	public function flags(): CliFlags {
		return new CliFlags([], []);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runImporters(args);
	}

	public function usage(): Void {
		printImportersUsage();
	}

	/**
	 * `apq importers <module> <scope> [--lang <name>]` — list the files in
	 * `<scope>` (one or more file/dir/glob specs after the module) that
	 * import `<module>` — a direct `import` / `using` of the module itself
	 * or of one of its sub-types. A wildcard `import pkg.*;` is NOT
	 * counted (see `SymbolIndex.filesImportingModule`). The reverse-
	 * dependency / impact-analysis surface of the cross-file `SymbolIndex`.
	 */
	private static function runImporters(args: Array<String>): Int {
		var lang: String = 'haxe';
		var module: Null<String> = null;
		final inputSpecs: Array<String> = [];

		for (arg in new ImportersCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '-h', '--help':
					printImportersUsage();
					return EXIT_OK;
				case null:
					if (module == null)
						module = a;
					else
						inputSpecs.push(a);
			}
		}
		if (module == null || inputSpecs.length == 0) {
			CliIo.stderr('apq importers: expected <module> <scope> (one or more file/dir/glob specs)\n');
			printImportersUsage();
			return EXIT_USAGE;
		}

		final modulePath: String = module;
		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq importers: ${CliArgs.quotedSpecs(inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final files: Array<{ file: String, source: String }> = [
			for (path in paths)
				{
					file: path,
					source: (try CliIo.readSourceForParse(path) catch (exception: Exception) {
						CliIo.stderr('apq importers: $path: ${exception.message}\n');
						return EXIT_RUNTIME;
					}: String)
				}
		];

		final hits: Array<String> = SymbolQuery.importers(files, plugin, modulePath);
		for (path in hits) CliIo.sysPrint('$path\n');
		return EXIT_OK;
	}

	private static function printImportersUsage(): Void {
		CliIo.sysPrint('Usage: apq importers <module> <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('List the files in the scope (file/dir/glob specs after the module) that\n');
		CliIo.sysPrint('import <module> — the module itself or one of its sub-types. A wildcard\n');
		CliIo.sysPrint('import pkg.*; is not counted.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
