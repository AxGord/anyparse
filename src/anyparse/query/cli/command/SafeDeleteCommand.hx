package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;
import anyparse.query.ModuleMove.TestMirror;

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
		return 'Remove a member, or a whole type, only if unreferenced across the scope';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--reformat', '--write'], ['--scope', '--type']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSafeDelete(args, ctx.ledger);
	}

	public function usage(): Void {
		printSafeDeleteUsage();
	}

	private static function runSafeDelete(args: Array<String>, ledger: RunLedger): Int {
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
		if (srcFile == null || scopeDir == null) {
			CliIo.stderr('apq safe-delete: missing required arguments (need <srcFile> [<member>] --scope <dir>)\n');
			printSafeDeleteUsage();
			return EXIT_USAGE;
		}
		final srcFileNN: String = srcFile;
		final srcTypeName: String = srcType ?? CliArgs.typeNameOfFile(lang, srcFileNN);
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		final op: String = 'safe-delete';
		if (CliArgs.refuseDataGrammar(op, plugin)) return EXIT_RUNTIME;
		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(
			op, plugin.langName(), scopeDir, [srcFileNN]
		);
		if (scopeFiles == null) return EXIT_RUNTIME;

		// The op WRITES `srcFile`, so the canonical gate and the re-emit are judged by the
		// config that governs THAT file — the same discovery every sibling writer-emit op
		// does. Skipping it made the gate compare a project-canonical file against compiled
		// defaults and refuse it, naming `apq fmt --write` as the remedy for the state that
		// command had just produced; `--reformat` then re-canonicalised under the defaults,
		// so the escape hatch de-formatted the file.
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(srcFileNN, ledger);
		if (memberName == null)
			return runSafeDeleteType(op, srcFileNN, srcTypeName, reformat, write, scopeDir, scopeFiles, plugin, optsJson);
		final memberNameNN: String = memberName;
		final result: EditResult = SafeDelete.safeDelete(
			srcFileNN, srcTypeName, memberNameNN, reformat, scopeFiles, plugin, plugin.refShape(), optsJson
		);
		switch result {
			case Ok(text):
				if (write) {
					RegistryFollowCommand.writeFollowed(op, [{ path: srcFileNN, content: text }], plugin);
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
		CliIo.sysPrint('Usage: apq safe-delete <srcFile> [<member>] --scope <dir> [options]\n\n');
		CliIo.sysPrint('Remove a member only when no reference to it survives under the scope —\n');
		CliIo.sysPrint('the guarded, cross-file, any-visibility form of remove-member. Any\n');
		CliIo.sysPrint('x.member field access or bare in-type reference blocks the deletion and\n');
		CliIo.sysPrint('is listed. Self-references (recursion) do not count.\n\n');
		CliIo.sysPrint('Without <member> the TYPE is removed the same way: every type position, new,\n');
		CliIo.sysPrint('static access, import / using, #if branch, reflective string and a retain /\n');
		CliIo.sysPrint('export annotation refuses and is listed, and so does an enum constructor (or enum\n');
		CliIo.sysPrint('abstract value) named bare and a using of the module of a type with a static\n');
		CliIo.sysPrint('function (a static extension). The only type of its module takes the file\n');

		CliIo.sysPrint('with it; a type among others loses its declaration alone. Comments,\n');
		CliIo.sysPrint('directives, ambient import sources and test companions are named, never\n');
		CliIo.sysPrint('removed.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Declaring type name (default: the file\'s main type); the type to remove without <member>\n');
		CliIo.sysPrint('  --scope <dir>  Reference-check scope (dir/glob; srcFile auto-included)\n');
		CliUsage.printShortReformatWriteLangHelp();
	}

	/**
	 * The type form: no `<member>` was given, so `typeName` of `srcFile` is removed — the whole file when it is the module's only
	 * type, its declaration alone otherwise — after `SafeDeleteType` has listed nothing that still reaches it.
	 */
	private static function runSafeDeleteType(
		op: String, srcFile: String, typeName: String, reformat: Bool, write: Bool, scopeDir: String,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, optsJson: Null<String>
	): Int {
		final mirrors: Array<TestMirror> = switch ModuleMoveCli.declarationFor(srcFile) {
			case Left(message):
				CliIo.stderr('apq $op: $message\n');
				return EXIT_RUNTIME;
			case Right(declaration): declaration.mirrors;
		};
		final companions: Array<String> = ModuleMove.companionsOf(ConfigFinder.absolute(srcFile), mirrors, ConfigFinder.fileExists);
		switch SafeDeleteType.safeDeleteType(srcFile, typeName, reformat, scopeFiles, plugin, scopeDir, companions, optsJson) {
			case Refused(reasons):
				for (r in reasons) CliIo.stderr('apq $op: $r\n');
				CliIo.stderr('apq $op: refusing to delete "$typeName" — ${reasons.length} reason(s), nothing written\n');
				return EXIT_RUNTIME;
			case RemoveFile(file, notes):
				for (n in notes) CliIo.stderr('apq $op: note: $n\n');
				if (!write) {
					CliIo.sysPrint('apq $op: would delete $file (the only type of its module)\n');
					return EXIT_OK;
				}
				if (!CliIo.deletePath(file)) {
					CliIo.stderr('apq $op: could not delete $file\n');
					return EXIT_RUNTIME;
				}
				CliIo.stderr('apq $op: deleted $file\n');
				return EXIT_OK;
			case RemoveDeclaration(file, text, notes):
				for (n in notes) CliIo.stderr('apq $op: note: $n\n');
				if (write) {
					RegistryFollowCommand.writeFollowed(op, [{ path: file, content: text }], plugin);
					CliIo.stderr('apq $op: removed "$typeName" from $file\n');
				} else {
					CliEdit.previewEdit(op, file, text);
				}
				return EXIT_OK;
		}
	}

}
