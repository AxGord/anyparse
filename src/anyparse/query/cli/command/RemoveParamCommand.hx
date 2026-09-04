package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RemoveParam;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq remove-param` — remove a function parameter + call-site args.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RemoveParamCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'remove-param';
	}

	public function summary(): String {
		return 'Remove a function parameter + call-site args';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRemoveParam(args);
	}

	public function usage(): Void {
		printRemoveParamUsage();
	}

	/**
	 * `apq remove-param <file> <line>:<col> <index> [--write]` — remove the
	 * parameter at 0-based `<index>` from the function whose decl / binding
	 * is at `<line>:<col>`, deleting the corresponding positional argument
	 * at every resolvable in-file call site. The inverse of `add-param`,
	 * but — unlike `add-param` (decl-only, backward-compat-safe) — removing
	 * a parameter BREAKS calls, so it updates call sites with the SAME
	 * strict completeness proof `change-sig` uses (an unresolvable /
	 * receiver-qualified call, a value capture, or an arity mismatch is
	 * refused). The removed parameter must be unused in the body — a
	 * remaining use is refused (the result would reference an undefined
	 * identifier). `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A removal on a method
	 * also emits a cross-file advisory to stderr (callers in other files
	 * cannot be seen). A cursor not on a function, an out-of-range index, a
	 * used parameter, an unresolvable call, an arity mismatch, or an
	 * unparseable result, exits non-zero with the file untouched.
	 */
	private static function runRemoveParam(args: Array<String>): Int {
		// noqa: complexity
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var indexSpec: Null<String> = null;

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
					printRemoveParamUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq remove-param: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					// With a named address the position slot is skipped — every later
					// positional is the index (which is also digits-only, so the slot
					// routing must not steal it).
					else if (posSpec == null && selectExpr == null && matchExpr == null && indexSpec == null && a.indexOf(':') >= 0)
						posSpec = a;
					else if (indexSpec == null)
						indexSpec = a;
					else {
						CliIo.stderr('apq remove-param: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null) || indexSpec == null) {
			CliIo.stderr("apq remove-param: expected <file> (<line>:<col> | --select '<sel>' | --match '<pattern>') <index>\n");
			printRemoveParamUsage();
			return EXIT_USAGE;
		}
		final index: Null<Int> = RefactorSupport.parseStrictInt(indexSpec);
		if (index == null) {
			CliIo.stderr('apq remove-param: malformed index "$indexSpec" — expected a non-negative integer\n');
			return EXIT_USAGE;
		}
		final paramIndex: Int = index;

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq remove-param: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'remove-param';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final shape: RefShape = plugin.refShape();
		final result: RemoveParamResult = RemoveParam.removeParam(source, pos.line, pos.col, paramIndex, plugin, shape);
		switch result {
			case Ok(text, advisory):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq remove-param: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				if (advisory != null) CliIo.stderr('apq remove-param: $advisory\n');
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq remove-param: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printRemoveParamUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq remove-param <file> (<line>:<col> | --select 'FnMember:<name>' | --match '<pattern>') <index> [--write]  ("
			+ 'index = 0-based parameter to remove)\n'
		);
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Scope-correct, format-preserving remove-parameter — the inverse of\n');
		CliIo.sysPrint('add-param. The function whose declaration / binding is at <line>:<col>\n');
		CliIo.sysPrint('loses the parameter at 0-based <index>, and the corresponding positional\n');
		CliIo.sysPrint('argument is deleted at every resolvable in-file call site (the separating\n');
		CliIo.sysPrint('comma goes too, so the surviving list stays well-formed). Unlike\n');
		CliIo.sysPrint('add-param (decl-only, always backward-compatible), removing a parameter\n');
		CliIo.sysPrint('BREAKS calls, so remove-param updates call sites with the SAME strict\n');
		CliIo.sysPrint('completeness proof change-sig uses: a receiver-qualified `obj.name(...)`\n');
		CliIo.sysPrint('call, an unresolvable call, a value capture, or a call with omitted\n');
		CliIo.sysPrint('optional arguments is refused (the removal never leaves a call with a\n');
		CliIo.sysPrint('stale argument). The removed parameter must be unused in the body — a\n');
		CliIo.sysPrint('remaining use is refused (the result would reference an undefined\n');
		CliIo.sysPrint('identifier). Methods (called via bare `name(...)` / `this.name(...)`) and\n');
		CliIo.sysPrint('named local functions are supported; a method removal also emits a\n');
		CliIo.sysPrint('cross-file advisory (callers in other files are out of scope).\n');
		CliIo.sysPrint('<line>:<col> uses the same column convention `apq refs` prints. The\n');
		CliIo.sysPrint('rewrite is verified to re-parse; a cursor not on a function, an\n');
		CliIo.sysPrint('out-of-range index, a used parameter, or an unparseable result, exits\n');
		CliIo.sysPrint('non-zero with the file untouched.\n');
	}

}
