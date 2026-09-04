package anyparse.query.cli.command;

import anyparse.query.MoveSymbol;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq pull-up` — move an instance member up to its superclass.
 *
 * A `--scope` EDIT: the answer depends on files other than the one it rewrites, so the
 * scope is collected first and the result leaves through `CliEdit`'s write / preview tail.
 */
@:nullSafety(Strict)
final class PullUpCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'pull-up';
	}

	public function summary(): String {
		return 'Move an instance member up to its superclass';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runInheritanceMove(args, true);
	}

	public function usage(): Void {
		printInheritanceMoveUsage(true);
	}

	public static function runInheritanceMove(args: Array<String>, up: Bool): Int {
		final cmd: String = up ? 'pull-up' : 'push-down';
		var lang: String = 'haxe';
		var srcType: Null<String> = null;
		var targetType: Null<String> = null;
		var scopeDir: Null<String> = null;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var memberName: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					srcType = CliArgs.expectValue(args, ++i, '--type');
				case '--to':
					targetType = CliArgs.expectValue(args, ++i, '--to');
				case '--scope':
					scopeDir = CliArgs.expectValue(args, ++i, '--scope');
				case '--write':
					write = true;
				case '-h', '--help':
					printInheritanceMoveUsage(up);
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq $cmd: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (srcFile == null)
						srcFile = a;
					else if (memberName == null)
						memberName = a;
					else {
						CliIo.stderr('apq $cmd: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (srcFile == null || memberName == null || targetType == null || scopeDir == null) {
			CliIo.stderr('apq $cmd: missing required arguments\n');
			printInheritanceMoveUsage(up);
			return EXIT_USAGE;
		}
		final srcFileNN: String = srcFile;
		final srcTypeName: String = srcType ?? RefactorSupport.baseNameOf(srcFileNN);
		final targetTypeName: String = targetType;
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles(cmd, scopeDir, [srcFileNN]);
		if (scopeFiles == null) return EXIT_RUNTIME;

		final result: MoveResult = up
			? InheritanceMove.pullUp(srcFileNN, srcTypeName, memberName, targetTypeName, scopeFiles, plugin)
			: InheritanceMove.pushDown(srcFileNN, srcTypeName, memberName, targetTypeName, scopeFiles, plugin);
		return MoveCommand.emitMoveResult(cmd, result, srcFileNN, srcFileNN, write, plugin);
	}

	public static function printInheritanceMoveUsage(up: Bool): Void {
		final cmd: String = up ? 'pull-up' : 'push-down';
		final rel: String = up ? 'superclass' : 'subclass';
		CliIo.sysPrint('Usage: apq $cmd <srcFile> <member> --to <$rel> --scope <dir> [options]\n\n');
		if (up) {
			CliIo.sysPrint('Move an instance member from a subclass up to its superclass. No call\n');
			CliIo.sysPrint('sites change (subclass instances still see the inherited member). Refuses\n');
			CliIo.sysPrint('when the moved body references a subclass-only member.\n\n');
		} else {
			CliIo.sysPrint('Move an instance member from a superclass down to a subclass. No call\n');
			CliIo.sysPrint('sites are rewritten; callers holding a superclass-typed receiver stop\n');
			CliIo.sysPrint('compiling (a loud error, never a silent change).\n\n');
		}
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Source type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --to <$rel>  Target type name (must be in the direct inheritance relation)\n');
		CliIo.sysPrint('  --scope <dir>  Scope to locate the target type (dir/glob; srcFile auto-included)\n');
		CliIo.sysPrint('  --write        Apply in place (default: print a per-file summary)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
