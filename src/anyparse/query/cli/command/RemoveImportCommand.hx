package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.ImportSpelling.ImportSpelled;

/**
 * `apq remove-import` — remove an import / using by module path (backend of lint --fix).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RemoveImportCommand implements CliCommand implements PostWriteFix {

	public function new() {}

	public function name(): String {
		return 'remove-import';
	}

	public function summary(): String {
		return 'Remove an import / using by module path (backend of lint --fix)';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--keep-doc', '--reformat', '--using', '--write'], []);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRemoveImport(args, ctx.postWriteFix);
	}

	public function usage(): Void {
		printRemoveImportUsage();
	}

	/**
	 * `apq remove-import <file> <module.path> [--using] [--reformat] [--write]` — remove
	 * the `import` / `using` whose exposed path equals `<module.path>` (the
	 * alias for an aliased import). `<module.path>` may be the whole statement
	 * (`using x.Y;`), whose keyword narrows the match to that kind; `--using` is
	 * the flag spelling of the same narrowing. The path must name exactly one statement, and
	 * a block comment directly above it goes too unless `--keep-doc` says otherwise.
	 * The by-name counterpart of `remove-element`; backend of `lint --fix`.
	 */
	private static function runRemoveImport(args: Array<String>, fix: Bool): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = true;
		var usingFlag: Bool = false;
		var file: Null<String> = null;
		var modulePath: Null<String> = null;

		for (arg in new RemoveImportCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--keep-doc':
					withDoc = false;
				case '--using':
					usingFlag = true;
				case '-h', '--help':
					printRemoveImportUsage();
					return EXIT_OK;
				case null:
					if (file == null) {
						file = a;
					} else if (modulePath == null) {
						modulePath = a;
					} else {
						CliIo.stderr('apq remove-import: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
		}
		if (file == null || modulePath == null) {
			CliIo.stderr('apq remove-import: expected <file> <module.path>\n');
			printRemoveImportUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final spelled: Null<ImportSpelled> = ImportSpelling.split(modulePath, usingFlag);
		if (spelled == null) {
			CliIo.stderr('apq remove-import: ${ImportSpelling.flagConflict(modulePath)}\n');
			return EXIT_USAGE;
		}
		// `--using` is the keyword spelled as a flag: the op reads the statement form, so the flag
		// becomes one rather than a second parameter the library entry point would have to carry.
		final path: String = usingFlag ? '${ImportSpelling.USING_WORD} ${spelled.path}' : modulePath;
		final source: String = try {
			CliIo.readFile(filePath);
		} catch (exception: Exception) {
			CliIo.stderr('apq remove-import: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit(
			'remove-import', filePath, write, RemoveImport.removeImport(source, path, reformat, plugin, withDoc, optsJson),
			fix ? plugin : null
		);
	}

	private static function printRemoveImportUsage(): Void {
		CliIo.sysPrint('Usage: apq remove-import <file> <module.path> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Remove the import / using statement whose exposed path equals <module.path>\n');
		CliIo.sysPrint('(the alias for an aliased import). The path must name exactly one statement.\n');
		CliIo.sysPrint('<module.path> may be the whole statement (`using x.Y;` / `import x.Y;`): its\n');
		CliIo.sysPrint('keyword narrows the match to that kind, so `using a.B;` names the using alone\n');
		CliIo.sysPrint('beside an `import a.B;`. The by-name counterpart of remove-element; backend of\n');
		CliIo.sysPrint('lint --fix.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --using         Remove the `using` of <module.path> (the statement form\'s flag spelling)\n');
		CliIo.sysPrint('  --keep-doc      Leave the import\'s leading block comment behind\n');
		CliUsage.printOptionsEditTail();
		CliUsage.printPostWriteFixTail();
	}

}
