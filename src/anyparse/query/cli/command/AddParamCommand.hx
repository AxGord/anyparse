package anyparse.query.cli.command;

import anyparse.query.AddParam;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq add-param` — add a backward-compatible parameter to a function.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class AddParamCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'add-param';
	}

	public function summary(): String {
		return 'Add a backward-compatible parameter to a function';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAddParam(args);
	}

	public function usage(): Void {
		printAddParamUsage();
	}

	/**
	 * `apq add-param <file> <line>:<col> <paramText> [--write]` — add
	 * `<paramText>` as a new trailing parameter to the function whose
	 * declaration is at `<line>:<col>`. The parameter MUST be
	 * backward-compatible — optional (`?name:T`) or defaulted
	 * (`name:T = v`) — so existing call sites need no update; this is a
	 * decl-only operation that touches no call site. `<paramText>` is a
	 * single positional (the user quotes it when it contains spaces) and is
	 * taken verbatim. `<line>:<col>` uses the same column convention
	 * `apq refs` prints. Without `--write` the rewritten source is emitted
	 * to stdout; with `--write` it overwrites the file in place. A cursor
	 * not on a function, a required parameter, a name collision, or an
	 * unparseable result exits non-zero with the file untouched.
	 */
	private static function runAddParam(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var paramText: Null<String> = null;

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
					printAddParamUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq add-param: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null && selectExpr == null && matchExpr == null && paramText == null && CliArgs.isPosSpec(a))
						posSpec = a;
					else if (paramText == null)
						paramText = a;
					else {
						CliIo.stderr('apq add-param: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null) || paramText == null) {
			CliIo.stderr("apq add-param: expected <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') <paramText>\n");
			printAddParamUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final paramStr: String = paramText;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq add-param: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final op: String = 'add-param';
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final result: AddParamResult = AddParam.addParam(source, pos.line, pos.col, paramStr, plugin);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq add-param: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq add-param: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printAddParamUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq add-param <file> (<line>[:<col>] | --select 'FnMember:<name>' | --match '<pattern>') <paramText> [--write]\n"
		);
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Add a backward-compatible parameter to a function declaration. The\n');
		CliIo.sysPrint('function whose declaration is at <line>:<col> gains <paramText> as a new\n');
		CliIo.sysPrint('trailing parameter (e.g. `?flag:Bool`, `count:Int = 0`, `?cb:Void->Void`).\n');
		CliIo.sysPrint('The parameter MUST be optional (`?name:T`) or defaulted (`name:T = v`),\n');
		CliIo.sysPrint('so existing call sites need no update — a required parameter would break\n');
		CliIo.sysPrint('them and is refused. This is a DECL-ONLY operation: no call site is\n');
		CliIo.sysPrint('touched, which makes it safe for methods AND local functions alike.\n');
		CliIo.sysPrint('Quote <paramText> if it contains spaces. <line>:<col> uses the same\n');
		CliIo.sysPrint('column convention `apq refs` prints. The rewrite is verified to\n');
		CliIo.sysPrint('re-parse; a cursor not on a function, a required parameter, a name\n');
		CliIo.sysPrint('collision, or an unparseable result exits non-zero with the file\n');
		CliIo.sysPrint('untouched.\n');
	}

}
