package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;

/**
 * `apq safe-delete` — remove a member only if unreferenced across the scope.
 *
 * A `--scope` EDIT: the answer depends on files other than the one it rewrites, so the
 * scope is collected first and the result leaves through `CliEdit`'s write / preview tail.
 */
@:nullSafety(Strict)
final class SafeDeleteCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'safe-delete';
	}

	public function summary(): String {
		return 'Remove a member only if unreferenced across the scope';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--reformat', '--write'], ['--scope', '--type']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSafeDelete(args);
	}

	public function usage(): Void {
		printSafeDeleteUsage();
	}

	private static function runSafeDelete(args: Array<String>): Int {
		var lang: String = 'haxe';
		var srcType: Null<String> = null;
		var scopeDir: Null<String> = null;
		var reformat: Bool = false;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var memberName: Null<String> = null;

		for (arg in new SafeDeleteCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--type':
					srcType = arg.value();
				case '--scope':
					scopeDir = arg.value();
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSafeDeleteUsage();
					return EXIT_OK;
				case null:
					if (srcFile == null) {
						srcFile = a;
					} else if (memberName == null) {
						memberName = a;
					} else {
						CliIo.stderr('apq safe-delete: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
		}
		if (srcFile == null || memberName == null || scopeDir == null) {
			CliIo.stderr('apq safe-delete: missing required arguments (need <srcFile> <member> --scope <dir>)\n');
			printSafeDeleteUsage();
			return EXIT_USAGE;
		}
		final srcFileNN: String = srcFile;
		final memberNameNN: String = memberName;
		final srcTypeName: String = srcType ?? RefactorSupport.baseNameOf(srcFileNN);
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		final op: String = 'safe-delete';
		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(op, scopeDir, [srcFileNN]);
		if (scopeFiles == null) return EXIT_RUNTIME;

		// The op WRITES `srcFile`, so the canonical gate and the re-emit are judged by the
		// config that governs THAT file — the same discovery every sibling writer-emit op
		// does. Skipping it made the gate compare a project-canonical file against compiled
		// defaults and refuse it, naming `apq fmt --write` as the remedy for the state that
		// command had just produced; `--reformat` then re-canonicalised under the defaults,
		// so the escape hatch de-formatted the file.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(srcFileNN);
		final result: EditResult = SafeDelete.safeDelete(
			srcFileNN, srcTypeName, memberNameNN, reformat, scopeFiles, plugin, plugin.refShape(), optsJson
		);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(srcFileNN, text);
					CliIo.stderr('apq safe-delete: removed "$memberNameNN" from $srcFileNN\n');
				} else {
					CliEdit.previewEdit(op, srcFileNN, text);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq safe-delete: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printSafeDeleteUsage(): Void {
		CliIo.sysPrint('Usage: apq safe-delete <srcFile> <member> --scope <dir> [options]\n\n');
		CliIo.sysPrint('Remove a member only when no reference to it survives under the scope —\n');
		CliIo.sysPrint('the guarded, cross-file, any-visibility form of remove-member. Any\n');
		CliIo.sysPrint('x.member field access or bare in-type reference blocks the deletion and\n');
		CliIo.sysPrint('is listed. Self-references (recursion) do not count.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Declaring type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --scope <dir>  Reference-check scope (dir/glob; srcFile auto-included)\n');
		CliUsage.printShortReformatWriteLangHelp();
	}

}
