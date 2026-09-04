package anyparse.query.cli.command;

import anyparse.query.ChangeSig;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq change-sig` — reorder a function's parameters + call-site args.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ChangeSigCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'change-sig';
	}

	public function summary(): String {
		return 'Reorder a function\'s parameters + call-site args';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runChangeSig(args);
	}

	public function usage(): Void {
		printChangeSigUsage();
	}

	/**
	 * `apq change-sig <file> <line>:<col> <perm> [--write]` — reorder the
	 * parameters of the function whose decl / binding is at `<line>:<col>`
	 * per `<perm>` (a comma-separated 0-based list of the OLD parameter
	 * indices in their NEW order, e.g. `2,0,1`), permuting the positional
	 * arguments at every resolvable in-file call site to match. The reorder
	 * is a SLOT SWAP — only the parameter / argument contents move, so the
	 * existing layout is preserved. `<line>:<col>` uses the same column
	 * convention `apq refs` prints. Without `--write` the rewritten source
	 * is emitted to stdout; with `--write` it overwrites the file in place.
	 * A reorder of a method also emits a cross-file advisory to stderr
	 * (callers in other files cannot be seen). A cursor not on a function,
	 * a malformed / non-permutation `<perm>`, an unresolvable / receiver-
	 * qualified call site, an arity mismatch, or an unparseable result,
	 * exits non-zero with the file untouched.
	 */
	private static function runChangeSig(args: Array<String>): Int {
		// noqa: complexity
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var permSpec: Null<String> = null;

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
					printChangeSigUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq change-sig: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (
						posSpec == null && selectExpr == null && matchExpr == null && permSpec == null && CliArgs.isPosSpec(a)
						&& a.indexOf(',') < 0
					)
						posSpec = a;
					else if (permSpec == null)
						permSpec = a;
					else {
						CliIo.stderr('apq change-sig: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null) || permSpec == null) {
			CliIo.stderr("apq change-sig: expected <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') <perm>\n");
			printChangeSigUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final permStr: String = permSpec;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq change-sig: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'change-sig';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final shape: RefShape = plugin.refShape();
		final result: ChangeSigResult = ChangeSig.changeSig(source, pos.line, pos.col, permStr, plugin, shape);
		switch result {
			case Ok(text, advisory):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq change-sig: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				if (advisory != null) CliIo.stderr('apq change-sig: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq change-sig: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printChangeSigUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq change-sig <file> (<line>:<col> | --select 'FnMember:<name>' | --match '<pattern>') <perm>  ("
			+ 'perm = comma-separated 0-based new order, e.g. 2,0,1)\n'
		);
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Scope-correct, format-preserving change-signature (parameter reorder).\n');
		CliIo.sysPrint('The function whose declaration / binding is at <line>:<col> has its\n');
		CliIo.sysPrint('parameters reordered per <perm> — a comma-separated 0-based list giving\n');
		CliIo.sysPrint('the NEW order of OLD parameter indices (for g(a,b,c), `2,0,1` reorders\n');
		CliIo.sysPrint('to c,a,b). The positional arguments at every resolvable in-file call\n');
		CliIo.sysPrint('site are permuted to match. The reorder is a slot swap — only the\n');
		CliIo.sysPrint('parameter / argument contents move, so the existing layout is preserved.\n');
		CliIo.sysPrint('Methods (called via bare `name(...)` / `this.name(...)`) and named local\n');
		CliIo.sysPrint('functions are supported; a receiver-qualified `obj.name(...)` call, an\n');
		CliIo.sysPrint('unresolvable call, or a call with omitted optional arguments is refused\n');
		CliIo.sysPrint('(change-sig never leaves a call site with stale argument order). A method\n');
		CliIo.sysPrint('reorder also emits a cross-file advisory (callers in other files are out\n');
		CliIo.sysPrint('of scope). <line>:<col> uses the same column convention `apq refs`\n');
		CliIo.sysPrint('prints. The rewrite is verified to re-parse; a cursor not on a function,\n');
		CliIo.sysPrint('a non-permutation <perm>, or an unparseable result, exits non-zero with\n');
		CliIo.sysPrint('the file untouched.\n');
	}

}
