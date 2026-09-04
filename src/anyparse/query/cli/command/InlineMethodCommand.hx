package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq inline-method` — inline a single-return function into its call sites + delete it.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class InlineMethodCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'inline-method';
	}

	public function summary(): String {
		return 'Inline a single-return function into its call sites + delete it';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runInlineMethod(args);
	}

	public function usage(): Void {
		printInlineMethodUsage();
	}

	/**
	 * `apq inline-method <file> <line>:<col> [--write]` — inline the
	 * function whose declaration is at `<line>:<col>` into EVERY in-file
	 * call site and delete the now-dead declaration. The body must reduce
	 * to a single return expression; each call's positional arguments are
	 * substituted for the parameters (parenthesised to preserve
	 * precedence), and the call-site set is proven complete before any
	 * rewrite. Like `inline` it is format-preserving (raw span splices, not
	 * the writer). `<line>:<col>` uses the same column convention
	 * `apq refs` prints. Without `--write` the rewritten source is emitted
	 * to stdout; with `--write` it overwrites the file in place. A cursor
	 * not on a function, a non-single-return body, an unprovable call set,
	 * an impure dropped / duplicated argument, an arity mismatch, or an
	 * unparseable result exits non-zero with the file untouched. NOTE: a
	 * method may have callers in OTHER files that this in-file op cannot
	 * see or update — inlining deletes the declaration regardless.
	 */
	private static function runInlineMethod(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '-h', '--help':
					printInlineMethodUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq inline-method: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						CliIo.stderr('apq inline-method: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null)) {
			CliIo.stderr("apq inline-method: expected <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>')\n");
			printInlineMethodUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq inline-method: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'inline-method';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final shape: RefShape = plugin.refShape();
		final result: EditResult = InlineMethod.inlineMethod(source, pos.line, pos.col, plugin, shape);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq inline-method: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq inline-method: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printInlineMethodUsage(): Void {
		CliIo.sysPrint("Usage: apq inline-method <file> (<line>[:<col>] | --select 'FnMember:<name>' | --match '<pattern>') [options]\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Inline the single-return function declared at <line>:<col> into every\n');
		CliIo.sysPrint('in-file call site (arguments substituted for parameters) and delete the\n');
		CliIo.sysPrint('declaration. The call-site set is proven complete before any rewrite.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
