package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq remove-import` — remove an import / using by module path (backend of lint --fix).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RemoveImportCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'remove-import';
	}

	public function summary(): String {
		return 'Remove an import / using by module path (backend of lint --fix)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRemoveImport(args);
	}

	public function usage(): Void {
		printRemoveImportUsage();
	}

	/**
	 * `apq remove-import <file> <module.path> [--reformat] [--write]` — remove
	 * the `import` / `using` whose exposed path equals `<module.path>` (the
	 * alias for an aliased import). The path must name exactly one statement, and
	 * a block comment directly above it goes too unless `--keep-doc` says otherwise.
	 * The by-name counterpart of `remove-element`; backend of `lint --fix`.
	 */
	private static function runRemoveImport(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = true;
		var file: Null<String> = null;
		var modulePath: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--keep-doc':
					withDoc = false;
				case '-h', '--help':
					printRemoveImportUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq remove-import: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (modulePath == null)
						modulePath = a;
					else {
						CliIo.stderr('apq remove-import: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || modulePath == null) {
			CliIo.stderr('apq remove-import: expected <file> <module.path>\n');
			printRemoveImportUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final path: String = modulePath;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq remove-import: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit(
			'remove-import', filePath, write, RemoveImport.removeImport(source, path, reformat, plugin, withDoc, optsJson)
		);
	}

	private static function printRemoveImportUsage(): Void {
		CliIo.sysPrint('Usage: apq remove-import <file> <module.path> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Remove the import / using statement whose exposed path equals <module.path>\n');
		CliIo.sysPrint('(the alias for an aliased import). The path must name exactly one statement.\n');
		CliIo.sysPrint('The by-name counterpart of remove-element; backend of lint --fix.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --keep-doc      Leave the import\'s leading block comment behind\n');
		CliUsage.printOptionsEditTail();
	}

}
