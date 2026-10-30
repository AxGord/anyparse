package anyparse.query.cli.command;

import anyparse.query.Address.AddressResult;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.DataPath.DataLookup;

/**
 * `apq get` — print the value at a dotted path (or a `--select` address) of a data document: a string
 * decoded and unquoted, a number / boolean / null as written, an object or array as compact JSON. Works
 * for every grammar `DataPath.walkable` accepts; one with no object or array kind is refused.
 */
@:nullSafety(Strict)
final class GetCommand implements CliCommand implements StdinDocument {

	private static inline final OP: String = 'get';

	/** The file argument naming standard input. */
	private static inline final STDIN: String = '-';

	public function new() {}

	public function name(): String {
		return OP;
	}

	public function summary(): String {
		return 'Print the value at a dotted path of a data document (JSON)';
	}

	public function flags(): CliFlags {
		return new CliFlags([], ['--nth', '--select']);
	}

	public function usage(): Void {
		printGetUsage();
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final o: Null<GetArgs> = parseGetArgs(args);
		if (o == null) {
			printGetUsage();
			return EXIT_OK;
		}
		final fromStdin: Bool = o.file == STDIN;
		final plugin: GrammarPlugin = pluginFor(o.file, o.lang, fromStdin);
		final label: String = fromStdin ? '<stdin>' : o.file;
		final shape: RefShape = plugin.refShape();
		if (!DataPath.walkable(shape)) {
			CliIo.stderr('apq get: $label: the ${plugin.langName()} grammar declares no object or array, so no path names a value in it\n');
			return EXIT_RUNTIME;
		}
		final source: String = try fromStdin ? ctx.readStdin() : CliIo.readFile(o.file) catch (exception: Exception) {
			CliIo.stderr('apq get: $label: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: Exception) {
			CliIo.stderr('apq get: $label does not parse: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final selectExpr: Null<String> = o.select;
		final start: Null<QueryNode> = selectExpr == null ? tree : selected(tree, source, plugin, selectExpr, o.nth, label);
		if (start == null) return EXIT_RUNTIME;
		return switch DataPath.resolve(start, o.segments, shape) {
			case Found(value):
				CliIo.sysPrint('${DataPath.render(value, source, shape)}\n');
				EXIT_OK;
			case Missing(why):
				CliIo.stderr('apq get: $label: $why\n');
				EXIT_RUNTIME;
		};
	}

	/** `args` read into a `GetArgs`, or null for `--help`; a malformed argv throws `UsageFailure`. */
	private static function parseGetArgs(args: Array<String>): Null<GetArgs> {
		var lang: Null<String> = null;
		var select: Null<String> = null;
		var nth: Null<Int> = null;
		final positionals: Array<String> = [];
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					select = CliArgs.expectValue(args, ++i, '--select');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '-h', '--help':
					return null;
				case _:
					if (a.startsWith('--')) throw new UsageFailure('unknown option "$a"');
					positionals.push(a);
			}
			i++;
		}
		if (positionals.length == 0 || positionals.length > 2 || (positionals.length == 1 && select == null))
			throw new UsageFailure("expected <file|-> <path> (or --select '<sel>' [<path>])");
		return {
			lang: lang,
			select: select,
			nth: nth,
			file: positionals[0],
			segments: DataPath.parse(positionals.length == 2 ? positionals[1] : '')
		};
	}

	/** The grammar of `file`: its extension's, else `--lang`'s; stdin has only `--lang` (the dispatcher fills it in from the content). */
	private static function pluginFor(file: String, lang: Null<String>, fromStdin: Bool): GrammarPlugin {
		final named: Null<String> = fromStdin ? lang : CliArgs.langOfFile(file) ?? lang;
		if (named == null) throw new UsageFailure('$file: no --lang, and no registered grammar claims the file — pass --lang <name>');
		return CliArgs.pickPlugin(named);
	}

	/** The node `--select` names, or null after saying why there is none. */
	private static function selected(
		tree: QueryNode, source: String, plugin: GrammarPlugin, selectExpr: String, nth: Null<Int>, label: String
	): Null<QueryNode> {
		final result: AddressResult = Address.resolve(tree, source, plugin, { select: selectExpr, nth: nth });
		return switch result {
			case Ok(_, node) if (node != null):
				node;
			case Ok(_, _):
				CliIo.stderr('apq get: $label: --select resolved to no node\n');
				null;
			case Err(message):
				CliIo.stderr('apq get: $label: $message\n');
				null;
		};
	}

	private static function printGetUsage(): Void {
		CliIo.sysPrint("Usage: apq get <file|-> <path> | apq get <file|-> --select '<sel>' [<path>]\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Print the value at <path> of a data document (JSON): a string decoded and unquoted,\n');
		CliIo.sysPrint('a number / boolean / null as written, an object or array as compact JSON.\n');
		CliIo.sysPrint('A missing path exits 1 with the reason on stderr; a code file is refused.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Path:\n');
		CliIo.sysPrint('  a.b.c         keys joined by "."; a digit segment indexes an array (a.0.b)\n');
		CliIo.sysPrint('  a\\.b          "\\." is a dot inside a key, "\\\\" a backslash\n');
		CliIo.sysPrint('  .             the whole document (also the empty path)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint("  --select '<sel>'    Start from the node the selector names (`Member:rules`); the\n");
		CliIo.sysPrint('                      path, if any, continues from there\n');
		CliIo.sysPrint('  --nth <k>           Pick the k-th of several --select matches\n');
		CliIo.sysPrint('  --lang <name>       The grammar; stdin (-) with no --lang is read as JSON when it\n');
		CliIo.sysPrint('                      starts with { or [\n');
	}

}

/** `apq get`'s argv, read. */
typedef GetArgs = {
	final lang: Null<String>;
	final select: Null<String>;
	final nth: Null<Int>;
	final file: String;
	final segments: Array<String>;
};
