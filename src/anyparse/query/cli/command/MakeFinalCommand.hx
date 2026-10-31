package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;

/**
 * `apq make-final` — the CROSS-FILE (`--scope`) EDIT shape of the command seam.
 *
 * It is the pilot for the commands whose answer depends on files other than the
 * one they rewrite (`safe-delete`, `rename --scope`, `move`, `move-member`,
 * `pull-up` / `push-down`, `extract-superclass`): the same argument parsing and
 * the same edit tail as a single-file command, plus a scope the command resolves
 * through `CliArgs.collectScopeFiles` before it may decide anything.
 */
@:nullSafety(Strict)
final class MakeFinalCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'make-final';
	}

	public function summary(): String {
		return 'Turn a never-reassigned var field into final';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--write'], ['--scope', '--type']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final op: String = 'make-final';
		var lang: String = 'haxe';
		var typeName: Null<String> = null;
		var scopeDir: Null<String> = null;
		var write: Bool = false;
		var file: Null<String> = null;
		var fieldName: Null<String> = null;

		for (arg in new MakeFinalCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--type':
					typeName = arg.value();
				case '--scope':
					scopeDir = arg.value();
				case '--write':
					write = true;
				case '-h', '--help':
					usage();
					return EXIT_OK;
				case null:
					if (file == null) {
						file = a;
					} else if (fieldName == null) {
						fieldName = a;
					} else {
						CliIo.stderr('apq make-final: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
		}
		if (file == null || fieldName == null) {
			CliIo.stderr('apq make-final: missing required arguments (need <file> <field>)\n');
			usage();
			return EXIT_USAGE;
		}
		final filePath: String = file;
		final fieldNameNN: String = fieldName;
		final typeNameNN: String = typeName ?? RefactorSupport.baseNameOf(filePath);
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		final scopeFiles: Null<Array<{ file: String, source: String }>> = scopeDir == null ? [
			{
				file: filePath,
				source: try {
					CliIo.readFile(filePath);
				} catch (exception: Exception) {
					CliIo.stderr('apq make-final: $filePath: ${exception.message}\n');
					return EXIT_RUNTIME;
				}
			}
		] : CliArgs.collectScopeFiles(op, scopeDir, [filePath]);
		if (scopeFiles == null) return EXIT_RUNTIME;

		final result: EditResult = MakeFinal.makeFinal(filePath, typeNameNN, fieldNameNN, scopeFiles, plugin);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq make-final: made "$fieldNameNN" final in $filePath\n');
				} else {
					CliEdit.previewEdit(op, filePath, text);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq make-final: $message\n');
				return EXIT_RUNTIME;
		}
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq make-final <file> <field> [--scope <dir>] [options]\n\n');
		CliIo.sysPrint('Turn a mutable var field into final when it is never reassigned after its\n');
		CliIo.sysPrint('single initialisation — unblocks the move-member instance path (whose\n');
		CliIo.sysPrint('sibling-fields contract accepts only final fields). Any write outside the\n');
		CliIo.sysPrint('constructor refuses the change. --scope widens the reassignment check to\n');
		CliIo.sysPrint('cross-file obj.field writes.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <T>     Declaring type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --scope <dir>  Widen the reassignment check across the scope\n');
		CliIo.sysPrint('  --write        Apply in place (default: print the rewritten file)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
