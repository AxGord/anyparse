package anyparse.query.cli.command;

import anyparse.query.ReplaceNode;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq replace-node` — `lang`, `write` / `reformat`, the address (`selectExpr` / `atSpec` / `matchExpr` / `nth` / `kind`), `withDoc`, and the replacement source (`newSource` or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef ReplaceNodeOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var selectExpr: Null<String>;
	var atSpec: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var kind: Null<String>;
	var withDoc: Bool;
	var file: Null<String>;
	var newSource: Null<String>;
	var fromFile: Null<String>;
	// Non-null = parsing hit a terminal case; the caller returns it immediately.
	var errExit: Null<Int>;
};

/**
 * `apq replace-node` — replace a node's source span (--select / --at; writer-formatted).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ReplaceNodeCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'replace-node';
	}

	public function summary(): String {
		return 'Replace a node\'s source span (--select / --at; writer-formatted)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runReplaceNode(args);
	}

	public function usage(): Void {
		printReplaceNodeUsage();
	}

	private static inline function replaceNodeParseExit(code: Int): ReplaceNodeOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			selectExpr: null,
			atSpec: null,
			matchExpr: null,
			nth: null,
			kind: null,
			withDoc: false,
			file: null,
			newSource: null,
			fromFile: null,
			errExit: code
		};
	}

	/**
	 * `apq replace-node <file> (--select <sel> | --at <line>:<col>) <newSource> [--reformat] [--write]`
	 * — replace the source span of a single node with `<newSource>`. The
	 * target is addressed by an `ast`-style `--select` selector (which must
	 * match exactly one node) OR by a cursor `--at <line>:<col>` in the same
	 * column convention `apq refs` prints. The result is WRITER-FORMATTED:
	 * the whole file is re-emitted through the writer (which also re-parse-
	 * validates), so the replacement is laid out by the grammar's rules. The
	 * file must already be canonical, else it is refused unless `--reformat`
	 * is given. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A target that resolves
	 * to no / multiple nodes, a non-canonical file without `--reformat`, or
	 * an unparseable result, exits non-zero with the file untouched.
	 */
	private static function runReplaceNode(args: Array<String>): Int {
		final o: ReplaceNodeOpts = parseReplaceNodeArgs(args);
		if (o.errExit != null) return o.errExit;
		var newSource: Null<String> = o.newSource;
		if (o.fromFile != null || newSource == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('replace-node', newSource, o.fromFile, true);
			if (resolved == null) return EXIT_RUNTIME;
			newSource = resolved;
		}
		final file: Null<String> = o.file;
		if (file == null || newSource == null) {
			CliIo.stderr(
				"apq replace-node: expected <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) ("
				+ '<newSource> | --from-file <path> | -)\n'
			);
			printReplaceNodeUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final newSrc: String = newSource;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq replace-node: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final target: Null<ReplaceTarget> = CliEdit.resolveEditTarget(
			'replace-node', source, filePath, plugin, o.selectExpr, o.matchExpr, o.atSpec, o.nth, o.kind
		);
		if (target == null) return EXIT_RUNTIME;

		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit(
			'replace-node', filePath, o.write, ReplaceNode.replaceNode(source, target, newSrc, o.reformat, plugin, o.withDoc, optsJson)
		);
	}

	private static function printReplaceNodeUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq replace-node <file> (--select '<sel>' | --match '<pattern>' | --at <line>[:<col>]) ("
			+ '<newSource> | --from-file <path> | -) [--reformat] [--write]\n'
		);
		CliUsage.printSelectorAddressingOptions();
		CliIo.sysPrint('  --kind <Kind>       With --at: the innermost node of <Kind> at the cursor.\n');
		CliIo.sysPrint('                      With --select / --match: LIFT the resolved node to its\n');
		CliIo.sysPrint('                      innermost enclosing <Kind> (a pattern matches the Call —\n');
		CliIo.sysPrint('                      lift to ExprStmt to replace the whole statement)\n');
		CliIo.sysPrint('  --with-doc          Also replace the leading doc comment (rewrite its docs)\n');
		CliIo.sysPrint('  --from-file <path>  Read <newSource> from a file instead of the argument\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('The new source may be inline, read from a file with --from-file, or read\n');
		CliIo.sysPrint('from stdin when it is the literal `-` (heredoc-friendly for code with `$`\n');
		CliIo.sysPrint('or quotes the shell would mangle). Replace the source span of a single\n');
		CliIo.sysPrint('node with <newSource>. Provide exactly one of --select / --match / --at.\n');
		CliIo.sysPrint('The result is WRITER-FORMATTED — the whole file is re-emitted through the\n');
		CliIo.sysPrint('writer (which also re-parse-validates), so the replacement is laid out by\n');
		CliIo.sysPrint("the grammar's rules. The file must already be canonical; otherwise it is\n");
		CliIo.sysPrint('refused unless --reformat is given. Quote <newSource> if it contains\n');
		CliIo.sysPrint('spaces. A target that resolves to no / multiple nodes, a non-canonical\n');
		CliIo.sysPrint('file without --reformat, or an unparseable result, exits non-zero with\n');
		CliIo.sysPrint('the file untouched.\n');
	}

	private static function parseReplaceNodeArgs(args: Array<String>): ReplaceNodeOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var selectExpr: Null<String> = null;
		var atSpec: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var kind: Null<String> = null;
		var withDoc: Bool = false;
		var file: Null<String> = null;
		var newSource: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--at':
					atSpec = CliArgs.expectValue(args, ++i, '--at');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--kind':
					kind = CliArgs.expectValue(args, ++i, '--kind');
				case '--with-doc':
					withDoc = true;
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printReplaceNodeUsage();
					return replaceNodeParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq replace-node: unknown option "$a"\n');
						return replaceNodeParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (newSource == null)
						newSource = a;
					else {
						CliIo.stderr('apq replace-node: unexpected extra argument "$a"\n');
						return replaceNodeParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			reformat: reformat,
			selectExpr: selectExpr,
			atSpec: atSpec,
			matchExpr: matchExpr,
			nth: nth,
			kind: kind,
			withDoc: withDoc,
			file: file,
			newSource: newSource,
			fromFile: fromFile,
			errExit: null
		};
	}

}
