package anyparse.query.cli.command;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq add-element` — `lang`, `write` / `reformat`, the insertion address (`afterSpec` / `beforeSpec` / `appendSpec`, plus `selectExpr` / `matchExpr` / `nth`), and the element source (`code` or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef AddElementOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var afterSpec: Null<String>;
	var beforeSpec: Null<String>;
	var appendSpec: Null<String>;
	var selectExpr: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var file: Null<String>;
	var code: Null<String>;
	var fromFile: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq add-element` — insert a sibling element — statement/case/list elem (--after/--before).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class AddElementCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'add-element';
	}

	public function summary(): String {
		return 'Insert a sibling element — statement/case/list elem (--after/--before)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runAddElement(args);
	}

	public function usage(): Void {
		printAddElementUsage();
	}

	private static inline function addElementParseExit(code: Int): AddElementOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			afterSpec: null,
			beforeSpec: null,
			appendSpec: null,
			selectExpr: null,
			matchExpr: null,
			nth: null,
			file: null,
			code: null,
			fromFile: null,
			errExit: code
		};
	}

	/**
	 * `apq add-element <file> (--after <line>:<col> | --before <line>:<col>)
	 * <code> [--reformat] [--write]` — insert `<code>` as a new sibling
	 * element next to the existing element whose first token is at
	 * `<line>:<col>` (a statement in a block, a `case` in a `switch`, an
	 * array / object / call-argument element). The separator the slot needs
	 * (a `,` for comma lists, a newline for statement / case lists) is added
	 * automatically; the inserted element is WRITER-FORMATTED and the whole
	 * file is re-parse-validated (a malformed element is rejected). To
	 * append, point at the last sibling with `--after`; to prepend, the
	 * first with `--before`. `<line>:<col>` use the `apq refs` print
	 * convention. The source must already be canonical unless `--reformat`.
	 * Without `--write` the result goes to stdout; with `--write` it
	 * overwrites in place.
	 */
	private static function runAddElement(args: Array<String>): Int {
		// noqa: complexity
		final o: AddElementOpts = parseAddElementArgs(args);
		if (o.errExit != null) return o.errExit;
		var code: Null<String> = o.code;
		if (o.fromFile != null || code == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('add-element', code, o.fromFile, true);
			if (resolved == null) return EXIT_RUNTIME;
			code = resolved;
		}
		final file: Null<String> = o.file;
		if (file == null || code == null) {
			CliIo.stderr(
				'apq add-element: expected <file> (--after | --before | --append) (<line>[:<col>] '
				+ "| --select '<sel>' | --match '<pattern>') (<code> | --from-file <path> | -)\n"
			);
			printAddElementUsage();
			return EXIT_USAGE;
		}
		final afterSpec: Null<String> = o.afterSpec;
		final beforeSpec: Null<String> = o.beforeSpec;
		final appendSpec: Null<String> = o.appendSpec;
		// Exactly one of --after / --before / --append must be given.
		final targetCount: Int = (afterSpec != null ? 1 : 0) + (beforeSpec != null ? 1 : 0) + (appendSpec != null ? 1 : 0);
		if (targetCount != 1) {
			CliIo.stderr('apq add-element: provide exactly one of --after, --before, or --append\n');
			return EXIT_USAGE;
		}

		// targetCount == 1 guarantees exactly one spec is non-null; the
		// `cast` commits the narrowing the analyzer can't prove across the
		// struct-field rebind. An empty spec = valueless mode flag — the
		// address comes from --select / --match instead.
		final posSpec: String = afterSpec ?? beforeSpec ?? (cast appendSpec: String);
		final atSpec: Null<String> = posSpec == '' ? null : posSpec;
		if (atSpec == null && o.selectExpr == null && o.matchExpr == null) {
			CliIo.stderr("apq add-element: no target address — give a position or --select '<sel>' / --match '<pattern>'\n");
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final codeStr: String = code;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq add-element: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final pos: Null<Position> = CliEdit.resolveAddressPos('add-element', source, plugin, atSpec, o.selectExpr, o.matchExpr, o.nth);
		if (pos == null) return EXIT_RUNTIME;
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = appendSpec != null
			? AddElement.appendElement(source, pos.line, pos.col, codeStr, o.reformat, plugin, optsJson)
			: AddElement.addElement(source, pos.line, pos.col, afterSpec != null ? After : Before, codeStr, o.reformat, plugin, optsJson);
		return CliEdit.finishEdit('add-element', filePath, o.write, result);
	}

	private static function printAddElementUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq add-element <file> (--after | --before | --append) (<l>[:<c>] | --select '<sel>' | --match '<pattern>') ("
			+ '<code> | --from-file <path> | -) [options]\n'
		);
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Insert <code> as a new element into a list-shaped slot. With --after / --before,\n');
		CliIo.sysPrint('the address is an existing SIBLING element (a statement in a block, a case in\n');
		CliIo.sysPrint('a switch, an array / object / call-argument element). With --append, it is\n');
		CliIo.sysPrint('the CONTAINER itself (block / array / object / call / new / class / switch); the\n');
		CliIo.sysPrint('element is added as the last child — which also works on an empty container that\n');
		CliIo.sysPrint('has no sibling to point at. The slot separator (comma or newline) is added\n');
		CliIo.sysPrint('automatically; the element is writer-formatted + re-parse-validated. The element\n');
		CliIo.sysPrint('text may be inline, from --from-file, or stdin when it is the literal `-`.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A BRACE-LESS body slot — the sole statement of an if / else / loop body or an arrow\n');
		CliIo.sysPrint('lambda expression body — holds one statement and has no sibling position, so it GAINS\n');
		CliIo.sysPrint('braces and the element lands inside it. Address the statement for that; address the\n');
		CliIo.sysPrint('enclosing if to insert after the whole construct.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Addressing (the mode flag takes an inline position, or combine it with --select / --match):\n');
		CliIo.sysPrint("  <l>[:<c>]           1-based position; column omitted = the line's first\n");
		CliIo.sysPrint('                      non-whitespace character\n');
		CliIo.sysPrint("  --select '<sel>'    Selector: Kind / Kind:name / A > B (child) / A >> B\n");
		CliIo.sysPrint('                      (descendant); must resolve to exactly one node\n');
		CliIo.sysPrint("  --match '<pattern>' apq-search structural pattern ($x metavars); exactly one\n");
		CliIo.sysPrint('  --nth <k>           Pick the k-th (1-based) of several matches\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --after [<l>[:<c>]]   Insert after the addressed sibling element\n');
		CliIo.sysPrint('  --before [<l>[:<c>]]  Insert before the addressed sibling element\n');
		CliIo.sysPrint('  --append [<l>[:<c>]]  Append as the last child of the addressed container\n');
		CliIo.sysPrint('  --from-file <path> Read the element text from a file instead of the argument\n');
		CliIo.sysPrint('  --write           Overwrite the file in place (default: print to stdout)\n');
		CliIo.sysPrint('  --reformat        Canonicalise the whole file if it is not already canonical\n');
		CliIo.sysPrint('  --lang <name>     Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help        Show this help\n');
	}

	private static function parseAddElementArgs(args: Array<String>): AddElementOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var afterSpec: Null<String> = null;
		var beforeSpec: Null<String> = null;
		var appendSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var file: Null<String> = null;
		var code: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				// The mode flags take a position value only when one follows —
				// `--after --select '<sel>'` and a trailing `--append` are valueless
				// (the address then comes from --select / --match); '' marks the mode.
				case '--after':
					afterSpec = isPosToken(args, i) ? args[++i] : '';
				case '--before':
					beforeSpec = isPosToken(args, i) ? args[++i] : '';
				case '--append':
					appendSpec = isPosToken(args, i) ? args[++i] : '';
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddElementUsage();
					return addElementParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq add-element: unknown option "$a"\n');
						return addElementParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (code == null)
						code = a;
					else {
						CliIo.stderr('apq add-element: unexpected extra argument "$a"\n');
						return addElementParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			reformat: reformat,
			afterSpec: afterSpec,
			beforeSpec: beforeSpec,
			appendSpec: appendSpec,
			selectExpr: selectExpr,
			matchExpr: matchExpr,
			nth: nth,
			file: file,
			code: code,
			fromFile: fromFile,
			errExit: null
		};
	}

	/**
	 * Whether the token after a mode flag is a position value (`<line>[:<col>]`
	 * starts with a digit) — an `--after` / `--before` / `--append` followed by
	 * another flag or the stdin marker is valueless (the address then comes from
	 * `--select` / `--match`).
	 */
	private static function isPosToken(args: Array<String>, i: Int): Bool {
		if (i + 1 >= args.length) return false;
		final next: String = args[i + 1];
		if (next.length == 0) return false;
		final c: Int = next.fastCodeAt(0);
		return c >= '0'.code && c <= '9'.code;
	}

}
