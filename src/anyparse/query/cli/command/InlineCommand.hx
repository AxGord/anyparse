package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Inline;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq inline` — inline a local variable into its uses.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class InlineCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'inline';
	}

	public function summary(): String {
		return 'Inline a local variable into its uses';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runInline(args);
	}

	public function usage(): Void {
		printInlineUsage();
	}

	/**
	 * `apq inline <file> <line>:<col> [--write]` — scope-correct,
	 * format-preserving inline of the local `var` / `final` binding
	 * identified by the symbol at `<line>:<col>`. Every read of the
	 * binding is replaced with the binding's initializer source text
	 * (parenthesised when the initializer is an operator expression), the
	 * declaration line is deleted, and the result is verified to re-parse.
	 * Reuses the `refs` resolver — the same scope-aware engine `rename`
	 * uses — so the EXACT binding under the cursor is targeted.
	 *
	 * The inline refuses unless the binding is single-assignment and its
	 * initializer is side-effect-free (no calls / field access / new /
	 * collections / lambdas / interpolation) and depends only on stable
	 * locals — a conservative whitelist that never trades correctness for
	 * reach. `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A cursor that is not
	 * on an inlinable local, an unsafe initializer, or a rewrite that
	 * fails to re-parse exits non-zero with the source untouched.
	 */
	private static function runInline(args: Array<String>): Int {
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
					printInlineUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq inline: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						CliIo.stderr('apq inline: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null)) {
			CliIo.stderr("apq inline: expected <file> (<line>:<col> | --select '<sel>' | --match '<pattern>')\n");
			printInlineUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq inline: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'inline';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final shape: RefShape = plugin.refShape();
		final result: InlineResult = Inline.inlineVar(source, pos.line, pos.col, plugin, shape);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq inline: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq inline: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printInlineUsage(): Void {
		CliIo.sysPrint("Usage: apq inline <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') [--write]\n");
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Scope-correct, format-preserving inline of the local var / final\n');
		CliIo.sysPrint('binding identified by the symbol at <line>:<col>. Every read of the\n');
		CliIo.sysPrint('binding is replaced with its initializer source (parenthesised when\n');
		CliIo.sysPrint('the initializer is an operator expression) and the declaration line is\n');
		CliIo.sysPrint('removed. The inline refuses unless the binding is single-assignment and\n');
		CliIo.sysPrint('its initializer is side-effect-free (no calls / field access / new /\n');
		CliIo.sysPrint('collections / lambdas / interpolation) and reads only stable locals.\n');
		CliIo.sysPrint('<line>:<col> uses the same column convention `apq refs` prints. The\n');
		CliIo.sysPrint('rewrite is verified to re-parse; a cursor not on an inlinable local, an\n');
		CliIo.sysPrint('unsafe initializer, or an unparseable result, exits non-zero with the\n');
		CliIo.sysPrint('file untouched.\n');
	}

}
