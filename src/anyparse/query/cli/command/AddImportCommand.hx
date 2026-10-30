package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;

/**
 * `apq add-import` — add an import / using to a module (writer-formatted, canonical-gated).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class AddImportCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'add-import';
	}

	public function summary(): String {
		return 'Add an import / using to a module (writer-formatted, canonical-gated)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAddImport(args);
	}

	public function usage(): Void {
		printAddImportUsage();
	}

	/**
	 * `apq add-import <file> <module.path> [--using] [--reformat] [--write]`
	 * — add an `import <module.path>;` (or `using` with `--using`; a whole
	 * `using x.Y;` / `import x.Y;` statement is accepted as `<module.path>`
	 * too, its keyword picking the kind) where `AddImport` seats it. The result is WRITER-FORMATTED (the whole file
	 * is re-emitted through the writer, which also re-parse-validates); the
	 * file must already be canonical, else it is refused unless `--reformat`
	 * is given. An already-present import of the same kind is refused.
	 * Without `--write` the rewritten source is emitted to stdout; with
	 * `--write` it overwrites the file in place. An empty path, a duplicate,
	 * a non-canonical file without `--reformat`, or an unparseable result
	 * exits non-zero with the file untouched.
	 */
	private static function runAddImport(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var isUsing: Bool = false;
		var file: Null<String> = null;
		var path: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--using':
					isUsing = true;
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddImportUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq add-import: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null) {
						file = a;
					} else if (path == null) {
						path = a;
					} else {
						CliIo.stderr('apq add-import: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || path == null) {
			CliIo.stderr('apq add-import: expected <file> <module.path> [--using]\n');
			printAddImportUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final pathStr: String = path;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq add-import: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = ProjectResolution.hostFor(CliArgs.pickPlugin(lang), filePath, source);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = AddImport.addImport(source, pathStr, isUsing, reformat, plugin, optsJson);
		final op: String = 'add-import';
		switch result {
			case Ok(text, rewrites):
				CliEdit.warnRewrites(op, filePath, rewrites);
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq add-import: wrote $filePath\n');
				} else {
					CliEdit.previewEdit(op, filePath, text);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq add-import: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printAddImportUsage(): Void {
		CliIo.sysPrint('Usage: apq add-import <file> <module.path> [--using] [--reformat] [--write]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --using             Add a `using` instead of an `import`\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('Add `import <module.path>;` (or `using` with --using). <module.path> may be\n');
		CliIo.sysPrint('the whole statement — `using x.Y;` adds a using, `import x.Y;` an import.\n');
		CliIo.sysPrint('An import takes its ordered slot in the import run, else lands after the\n');
		CliIo.sysPrint('last import, else after the `package` declaration, else at the start of the\n');
		CliIo.sysPrint('file; a using lands ABOVE the first existing using (lowest static-extension\n');
		CliIo.sysPrint('priority: Haxe ranks them in reverse order), else after the last import /\n');
		CliIo.sysPrint('package. A `#if` region guarding the whole module body is its header.\n');
		CliIo.sysPrint('The result is WRITER-FORMATTED (the whole file is re-emitted through the\n');
		CliIo.sysPrint('writer, which also re-parse-validates). The file must already be canonical;\n');
		CliIo.sysPrint('otherwise it is refused unless --reformat is given. A statement of the same\n');
		CliIo.sysPrint('kind already present — behind an `#if` included — is refused (a no-op). An\n');
		CliIo.sysPrint('empty path, text that is neither a module path nor a statement, a duplicate,\n');
		CliIo.sysPrint('a non-canonical file without --reformat, or an unparseable result exits\n');
		CliIo.sysPrint('non-zero with the file untouched.\n');
	}

}
