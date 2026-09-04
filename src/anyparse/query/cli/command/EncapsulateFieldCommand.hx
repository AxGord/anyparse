package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq encapsulate-field` — turn a var field into a get/set property (@:isVar).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class EncapsulateFieldCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'encapsulate-field';
	}

	public function summary(): String {
		return 'Turn a var field into a get/set property (@:isVar)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runEncapsulateField(args);
	}

	public function usage(): Void {
		printEncapsulateFieldUsage();
	}

	private static function runEncapsulateField(args: Array<String>): Int {
		var lang: String = 'haxe';
		var typeName: Null<String> = null;
		var reformat: Bool = false;
		var write: Bool = false;
		var file: Null<String> = null;
		var fieldName: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					typeName = CliArgs.expectValue(args, ++i, '--type');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printEncapsulateFieldUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq encapsulate-field: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (fieldName == null)
						fieldName = a;
					else {
						CliIo.stderr('apq encapsulate-field: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || fieldName == null) {
			CliIo.stderr('apq encapsulate-field: missing required arguments (need <file> <field>)\n');
			printEncapsulateFieldUsage();
			return EXIT_USAGE;
		}
		final filePath: String = file;
		final fieldNameNN: String = fieldName;
		final typeNameNN: String = typeName ?? RefactorSupport.baseNameOf(filePath);
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq encapsulate-field: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// Discover the file's format config so the canonical gate matches the project's writer
		// style (space-after-colon, etc.), else a non-default-formatted file is wrongly rejected.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = EncapsulateField.encapsulate(source, typeNameNN, fieldNameNN, reformat, plugin, optsJson);
		final op: String = 'encapsulate-field';
		switch result {
			case Ok(text, rewrites):
				CliEdit.warnRewrites(op, filePath, rewrites);
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq encapsulate-field: encapsulated "$fieldNameNN" in $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq encapsulate-field: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printEncapsulateFieldUsage(): Void {
		CliIo.sysPrint('Usage: apq encapsulate-field <file> <field> [options]\n\n');
		CliIo.sysPrint('Turn a stored var field into a property with get / set accessors\n');
		CliIo.sysPrint('(via @:isVar, so the field stays the backing storage and no reference\n');
		CliIo.sysPrint('is renamed). Requires a plain, non-final, non-static instance var with\n');
		CliIo.sysPrint('an explicit type.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <T>     Declaring type name (default: the file\'s main type)\n');
		CliUsage.printShortReformatWriteLangHelp();
	}

}
