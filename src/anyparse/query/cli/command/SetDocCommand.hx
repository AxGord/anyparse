package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq set-doc` — `lang`, `write` / `reformat`, the target `file`, the address (`pos` / `selectExpr` / `matchExpr` / `nth`), and the doc body (`docText` or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef SetDocOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var fromFile: Null<String>;
	var file: Null<String>;
	var pos: Null<String>;
	var selectExpr: Null<String>;
	var matchExpr: Null<String>;
	var nth: Null<Int>;
	var docText: Null<String>;
	// Non-null = parsing hit a terminal case; the caller returns it immediately.
	var errExit: Null<Int>;
};

/**
 * `apq set-doc` — add/replace a declaration's doc-comment at a cursor.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class SetDocCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'set-doc';
	}

	public function summary(): String {
		return 'Add/replace a declaration\'s doc-comment at a cursor';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSetDoc(args);
	}

	public function usage(): Void {
		printSetDocUsage();
	}

	private static inline function setDocParseExit(code: Int): SetDocOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			fromFile: null,
			file: null,
			pos: null,
			selectExpr: null,
			matchExpr: null,
			nth: null,
			docText: null,
			errExit: code
		};
	}

	/**
	 * `apq new <path> (--class | --implements <iface>) [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive
	 * the package + class name from <path>, assemble the scaffold (interface
	 * method stubs with sliced signatures + carried imports, or verbatim
	 * `--field` members), and run it through the writer so the result is
	 * canonical-or-rejected and the file is never written on a parse failure.
	 * Create-only: an existing path is refused. `--bodies -` reads `@@ <method>`
	 * sections from stdin (see `NewFile`); a method without a section is left as
	 * a NotImplementedException stub (reported on stderr). Without `--write` the
	 * source goes to stdout.
	 * `apq new <path> (--class | --implements <iface> | --kind <k>) [--extends <T>]...
	 * [--open] [--field <m>]... [--bodies -] [--write]` — create a new module
	 * deterministically: derive the package + class name from <path>, assemble the
	 * scaffold (interface method stubs with sliced signatures + carried imports, or
	 * verbatim `--field` members), and run it through the writer so the result is
	 * canonical-or-rejected and the file is never written on a parse failure.
	 * `--kind` (default class) picks class / interface / enum / typedef; `--extends`
	 * adds a superclass (class) or super-interfaces (interface); `--open` drops the
	 * `final` on a class. Create-only: an existing path is refused. `--bodies -`
	 * reads `@@ <method>` sections from stdin (see `NewFile`); a method without a
	 * section is left as a NotImplementedException stub (reported on stderr).
	 * Without `--write` the source goes to stdout.
	 * `apq new <path> (--class | --implements <iface> | --kind <k>) [--extends <T>]...
	 * [--open] [--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive the
	 * package + class name from <path>, assemble the scaffold (interface method
	 * stubs with sliced signatures + carried imports, or verbatim `--field`
	 * members), and run it through the writer so the result is canonical-or-
	 * rejected and the file is never written on a parse failure. `--kind` (default
	 * class) picks class / interface / enum / typedef / abstract; `--extends` adds
	 * a superclass (class) / super-interfaces (interface) / struct extension
	 * (typedef); `--underlying`/`--from`/`--to` shape an abstract; `--open` drops
	 * the `final` on a class. Create-only: an existing path is refused. `--bodies -`
	 * reads `@@ <method>` sections from stdin (see `NewFile`); a method without a
	 * section is left as a NotImplementedException stub (reported on stderr).
	 * Without `--write` the source goes to stdout.
	 * `apq set-doc <file> <line>:<col> (<text> | --from-file | -) [--reformat]
	 * [--write]` — add or replace the doc-comment of the declaration at the
	 * cursor (see `SetDoc`). The text (inline / file / stdin via `resolveCodeArg`)
	 * is formatted into a doc-comment block and spliced before the decl, leaving
	 * the declaration itself untouched; the result is writer-formatted and
	 * re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runSetDoc(args: Array<String>): Int {
		final o: SetDocOpts = parseSetDocArgs(args);
		if (o.errExit != null) return o.errExit;
		var docText: Null<String> = o.docText;
		if (o.fromFile != null || docText == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('set-doc', docText == '-' ? '-' : null, o.fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			docText = resolved;
		}
		final file: Null<String> = o.file;
		final pos: Null<String> = o.pos;
		if (file == null || (pos == null && o.selectExpr == null && o.matchExpr == null) || docText == null) {
			CliIo.stderr(
				"apq set-doc: expected <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') (<text> | --from-file <path> | -)\n"
			);
			printSetDocUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final docStr: String = docText;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq set-doc: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(o.lang));
		final loc: Null<Position> = CliEdit.resolveAddressPos('set-doc', source, plugin, pos, o.selectExpr, o.matchExpr, o.nth);
		if (loc == null) return EXIT_RUNTIME;
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = SetDoc.setDoc(source, loc.line, loc.col, docStr, o.reformat, plugin, optsJson);
		return CliEdit.finishEdit('set-doc', filePath, o.write, result);
	}

	private static function printSetDocUsage(): Void {
		CliIo.sysPrint(
			"Usage: apq set-doc <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') (<text> | --from-file <path> | -) ["
			+ '--reformat] [--write]\n'
		);
		CliUsage.printSelectorAddressingSection();
		CliIo.sysPrint('  --from-file <path>  Read the doc text from a file instead of the argument\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliUsage.printWriteLangHelp();
		CliIo.sysPrint('Add or replace the doc-comment of the addressed declaration. The text is\n');
		CliIo.sysPrint('formatted into a doc-comment block and spliced before the declaration; an\n');
		CliIo.sysPrint('existing leading doc comment is replaced, the declaration itself is left\n');
		CliIo.sysPrint('untouched. The text may be inline, --from-file, or - for stdin\n');
		CliIo.sysPrint('(heredoc-friendly, multi-line). Writer-formatted + validated.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The text is PLAIN prose, one line per doc line: this op owns the ` * `\n');
		CliIo.sysPrint('gutter and adds it. A gutter you write yourself is stripped rather than\n');
		CliIo.sysPrint('doubled, and only the two spellings the writer emits count as one, so a\n');
		CliIo.sysPrint('`* bullet` and an indented code sample keep what they were given.\n');
	}

	private static function parseSetDocArgs(args: Array<String>): SetDocOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var fromFile: Null<String> = null;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var docText: Null<String> = null;

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
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSetDocUsage();
					return setDocParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq set-doc: unknown option "$a"\n');
						return setDocParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (pos == null && selectExpr == null && matchExpr == null && CliArgs.isPosSpec(a))
						pos = a;
					else if (docText == null)
						docText = a;
					else {
						CliIo.stderr('apq set-doc: unexpected extra argument "$a"\n');
						return setDocParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			reformat: reformat,
			fromFile: fromFile,
			file: file,
			pos: pos,
			selectExpr: selectExpr,
			matchExpr: matchExpr,
			nth: nth,
			docText: docText,
			errExit: null
		};
	}

}
