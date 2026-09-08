package anyparse.query.cli.command;

import anyparse.query.cli.CliArgs.PositionalScan;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq declares` — declaration site(s) of one named type (ambiguity check).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class DeclaresCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'declares';
	}

	public function summary(): String {
		return 'Declaration site(s) of one named type (ambiguity check)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runDeclares(args);
	}

	public function usage(): Void {
		printDeclaresUsage();
	}

	/**
	 * `apq declares <type>… [--] <scope> [--lang <name>]` — the declaration site(s) of each named type across `<scope>` (one or more
	 * file/dir/glob specs), matching either the simple name or the fully
	 * qualified import path. Each site prints as
	 * `qualified<TAB>kind<TAB>file:line:col` on stdout. More than one is an
	 * ambiguity (two decls of the same name) and zero means the type is not
	 * declared in the scope — both are reported on stderr so stdout stays a
	 * clean row list. The focused, single-type counterpart of `symbols`.
	 */
	private static function runDeclares(args: Array<String>): Int {
		var lang: String = 'haxe';
		final typeNames: Array<String> = [];
		// A bare `--` makes every positional before it a type name and every one
		// after it a scope spec; without one the first positional is the type and
		// the rest are scope specs, exactly as before.
		final scan: PositionalScan = CliArgs.beginPositionalScan(args);

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--':
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printDeclaresUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq declares: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					CliArgs.routePositional(a, i, scan.separator, typeNames, scan.inputSpecs);
			}
			i++;
		}
		if (typeNames.length == 0 || scan.inputSpecs.length == 0) {
			CliIo.stderr('apq declares: expected <type> <scope> (one or more file/dir/glob specs)\n');
			printDeclaresUsage();
			return EXIT_USAGE;
		}

		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, scan.inputSpecs, scan.separator < 0);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq declares: ${CliArgs.quotedSpecs(scan.inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final files: Array<{ file: String, source: String }> = [
			for (path in paths)
				{
					file: path,
					source: (try CliIo.readSourceForParse(path) catch (exception: Exception) {
						CliIo.stderr('apq declares: $path: ${exception.message}\n');
						return EXIT_RUNTIME;
					}: String)
				}
		];

		// ONE listing for the whole batch — the parse is the expensive half and it
		// does not depend on the names.
		final listing: Array<SymbolQuery.SymbolRow> = SymbolQuery.symbols(files, plugin);
		final batchedOutput: Bool = typeNames.length > 1;
		for (name in typeNames) {
			final rows: Array<SymbolQuery.SymbolRow> = SymbolQuery.declaredAmong(listing, name);
			if (batchedOutput) CliIo.sysPrint(CliWalk.batchSection(name));
			if (rows.length == 0)
				CliIo.stderr('apq declares: no type named "$name" in ${scan.inputSpecs.join(', ')}\n');
			else if (rows.length > 1)
				CliIo.stderr('apq declares: ambiguous — ${rows.length} declarations of "$name"\n');
			for (row in rows) CliIo.sysPrint('${SymbolQuery.formatSymbolRow(row)}\n');
		}
		return EXIT_OK;
	}

	private static function printDeclaresUsage(): Void {
		CliIo.sysPrint('Usage: apq declares <type> <scope...> [options]\n');
		CliIo.sysPrint('       apq declares <type>... -- <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Print the declaration site(s) of the type named <type> across the scope\n');
		CliIo.sysPrint('(file/dir/glob specs after the type), matching the simple name or the fully\n');
		CliIo.sysPrint('qualified import path. Each row is qualified<TAB>kind<TAB>file:line:col. More\n');
		CliIo.sysPrint('than one row is an ambiguity; zero means the type is not declared in the\n');
		CliIo.sysPrint('scope. The focused, single-type counterpart of symbols.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A bare `--` splits SEVERAL types from the scope: the listing is built ONCE\n');
		CliIo.sysPrint('and every type answered off it, each under its own `=== <type> ===` section.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
