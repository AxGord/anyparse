package anyparse.query.cli.command;

import anyparse.query.Address.AddressResult;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.CliArgs.ExpandedInputs;
import anyparse.query.cli.DataPath.DataLookup;
import anyparse.query.cli.DataPath.WhereClause;

/**
 * `apq get` — print the value at a dotted path (or a `--select` address) of a data document: a string
 * decoded and unquoted, a number / boolean / null as written, an object or array as compact JSON. Works
 * for every grammar `DataPath.walkable` accepts; one with no object or array kind is refused.
 */
@:nullSafety(Strict)
final class GetCommand implements CliCommand implements StdinDocument implements LanguageFreeWhen {

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

	/** Under `--where` every document is routed by its own extension, so the call names no language. */
	public function languageFreeFor(args: Array<String>): Bool {
		return args.contains('--where');
	}

	public function flags(): CliFlags {
		return new CliFlags([], ['--nth', '--select', '--where']);
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
		final where: Null<WhereClause> = o.where;
		if (where != null) return runWhere(o, where, ctx);
		final doc: Null<LoadedDocument> = load(o.files[0], o.lang, ctx);
		if (doc == null) return EXIT_RUNTIME;
		final selectExpr: Null<String> = o.select;
		final start: Null<QueryNode> = selectExpr == null
			? doc.tree
			: selected(doc.tree, doc.source, doc.plugin, selectExpr, o.nth, doc.label);
		if (start == null) return EXIT_RUNTIME;
		return switch DataPath.resolve(start, o.segments, doc.shape) {
			case Found(value):
				CliIo.sysPrint('${DataPath.render(value, doc.source, doc.shape)}\n');
				EXIT_OK;
			case Missing(why):
				CliIo.stderr('apq get: ${doc.label}: $why\n');
				EXIT_RUNTIME;
		};
	}

	/**
	 * `--where`: every document the specs name, searched for the records whose `<path>` prints as `<value>`;
	 * one `<file> <record path>` line per record. Exit 1 when none matches, or when a spec names no `.json`
	 * file or a file is not a data document.
	 */
	private static function runWhere(o: GetArgs, where: WhereClause, ctx: CliContext): Int {
		final expanded: ExpandedInputs = CliArgs.expandInputs(o.files, '.json');
		var failed: Bool = expanded.unmatched.length > 0;
		for (spec in expanded.unmatched) CliIo.stderr('apq get: "$spec" matched no .json file\n');
		var matches: Int = 0;
		for (file in expanded.paths) {
			final doc: Null<LoadedDocument> = load(file, o.lang, ctx);
			if (doc == null) {
				failed = true;
				continue;
			}
			final root: QueryNode = DataPath.valueOf(doc.tree, doc.shape);
			if (root.kind != doc.shape.objectLiteralKind && root.kind != doc.shape.arrayLiteralKind) {
				CliIo.stderr('apq get: $file: the document is a ${root.kind}, not an object or an array — it holds no record\n');
				failed = true;
				continue;
			}
			for (record in DataPath.records(doc.tree, where, doc.source, doc.shape)) {
				CliIo.sysPrint('$file ${record.length == 0 ? '.' : DataPath.format(record)}\n');
				matches++;
			}
		}
		return matches > 0 && !failed ? EXIT_OK : EXIT_RUNTIME;
	}

	/** `file` (or stdin for `-`) parsed as a data document, or null after saying why it is not one. */
	private static function load(file: String, lang: Null<String>, ctx: CliContext): Null<LoadedDocument> {
		final fromStdin: Bool = file == STDIN;
		final plugin: GrammarPlugin = pluginFor(file, lang, fromStdin);
		final label: String = fromStdin ? '<stdin>' : file;
		final shape: RefShape = plugin.refShape();
		if (!DataPath.walkable(shape)) {
			CliIo.stderr('apq get: $label: the ${plugin.langName()} grammar declares no object or array, so no path names a value in it\n');
			return null;
		}
		final source: String = try {
			fromStdin ? ctx.readStdin() : CliIo.readFile(file);
		} catch (exception: Exception) {
			CliIo.stderr('apq get: $label: ${exception.message}\n');
			return null;
		};
		final tree: QueryNode = try {
			plugin.parseFile(source);
		} catch (exception: Exception) {
			CliIo.stderr('apq get: $label does not parse: ${exception.message}\n');
			return null;
		};
		return {
			plugin: plugin,
			shape: shape,
			source: source,
			tree: tree,
			label: label
		};
	}

	/** `<path>=<value>` split at its first `=`: the key path to read in each record, and what it must print as. */
	private static function parseWhere(clause: String): WhereClause {
		final eq: Int = clause.indexOf('=');
		if (eq < 0) throw new UsageFailure('--where expects <path>=<value>, got "$clause"');
		return { segments: DataPath.parse(clause.substr(0, eq)), value: clause.substr(eq + 1) };
	}

	/** `args` read into a `GetArgs`, or null for `--help`; a malformed argv throws `UsageFailure`. */
	private static function parseGetArgs(args: Array<String>): Null<GetArgs> {
		var lang: Null<String> = null;
		var select: Null<String> = null;
		var nth: Null<Int> = null;
		var where: Null<WhereClause> = null;
		final positionals: Array<String> = [];
		for (arg in new GetCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--select':
					select = arg.value();
				case '--nth':
					nth = Std.parseInt(arg.value());
				case '--where':
					if (where != null) throw new UsageFailure('--where is given once');
					where = parseWhere(arg.value());
				case '-h', '--help':
					return null;
				case null:
					positionals.push(a);
			}
		}
		if (where != null) {
			if (select != null || nth != null)
				throw new UsageFailure('--where searches whole documents; it does not combine with --select or --nth');
			if (positionals.length == 0) throw new UsageFailure('expected <file|dir|glob>… after --where');
		} else if (positionals.length == 0 || positionals.length > 2 || (positionals.length == 1 && select == null)) {
			throw new UsageFailure("expected <file|-> <path> (or --select '<sel>' [<path>])");
		}
		return {
			lang: lang,
			select: select,
			nth: nth,
			where: where,
			files: where != null ? positionals : [positionals[0]],
			segments: where == null ? DataPath.parse(positionals.length == 2 ? positionals[1] : '') : []
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
			case Ok(_, node) if (node != null): node;
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
		CliIo.sysPrint('       apq get --where <path>=<value> <file|dir|glob>…\n');
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
		CliIo.sysPrint('  --where <p>=<v>     Search the documents (a directory names its .json files) for the\n');
		CliIo.sysPrint('                      records — the object holding it, at any depth — where <p> prints as\n');
		CliIo.sysPrint('                      <v>; one `<file> <record path>` line each ("." = the root), exit 1 on none\n');
		CliIo.sysPrint('  --lang <name>       The grammar; stdin (-) with no --lang is read as JSON when it\n');
		CliIo.sysPrint('                      starts with { or [\n');
	}

}

/** `apq get`'s argv, read. */
typedef GetArgs = {
	final lang: Null<String>;
	final select: Null<String>;
	final nth: Null<Int>;
	final where: Null<WhereClause>;
	final files: Array<String>;
	final segments: Array<String>;
};

/** A data document read for `apq get`: its grammar, shape, text and tree, and the name messages call it by. */
typedef LoadedDocument = {
	final plugin: GrammarPlugin;
	final shape: RefShape;
	final source: String;
	final tree: QueryNode;
	final label: String;
};
