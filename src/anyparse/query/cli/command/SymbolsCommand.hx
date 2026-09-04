package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq symbols` — list top-level type declarations across a scope (cross-file).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class SymbolsCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'symbols';
	}

	public function summary(): String {
		return 'List top-level type declarations across a scope (cross-file)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSymbols(args);
	}

	public function usage(): Void {
		printSymbolsUsage();
	}

	/**
	 * `apq symbols <scope> [--lang <name>] [--kind <Kind>]` — list every
	 * top-level type declaration across the `<scope>` (one or more
	 * file/dir/glob specs) as `<import-path>\t<Kind>\t<file>:<line>:<col>`,
	 * in input-file order then source order. `<import-path>` is what a
	 * consumer would `import` — the module path for the module's main
	 * type, else `module.SubType`. `--kind` filters to one decl kind
	 * (`ClassDecl` / `InterfaceDecl` / `EnumDecl` / `TypedefDecl` /
	 * `AbstractDecl`). Unparseable files are skipped silently. This is the
	 * CLI surface of the cross-file `SymbolIndex` type browser.
	 */
	private static function runSymbols(args: Array<String>): Int {
		var lang: String = 'haxe';
		var kindFilter: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--kind':
					kindFilter = CliArgs.expectValue(args, ++i, '--kind');
				case '-h', '--help':
					printSymbolsUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq symbols: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq symbols: expected <scope> (one or more file/dir/glob specs)\n');
			printSymbolsUsage();
			return EXIT_USAGE;
		}

		final io = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq symbols: ${CliArgs.quotedSpecs(inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final files: Array<{ file: String, source: String }> = [
			for (path in paths)
				{
					file: path,
					source: (try CliIo.readSourceForParse(path) catch (exception: Exception) {
						CliIo.stderr('apq symbols: $path: ${exception.message}\n');
						return EXIT_RUNTIME;
					}: String)
				}
		];

		final rows: Array<SymbolQuery.SymbolRow> = SymbolQuery.symbols(files, plugin, kindFilter);
		for (row in rows) CliIo.sysPrint('${SymbolQuery.formatSymbolRow(row)}\n');
		return EXIT_OK;
	}

	private static function printSymbolsUsage(): Void {
		CliIo.sysPrint('Usage: apq symbols <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('List every top-level type declaration across the scope (one or more\n');
		CliIo.sysPrint('file/dir/glob specs) as <import-path>\\t<Kind>\\t<file>:<line>:<col>.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --kind <Kind>   Only list this decl kind (ClassDecl/InterfaceDecl/\n');
		CliIo.sysPrint('                  EnumDecl/TypedefDecl/AbstractDecl)\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
