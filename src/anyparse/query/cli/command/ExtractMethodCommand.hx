package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq extract-method` — `lang`, `write` / `reformat`, the target `file`, the statement-run bounds (`startPos` / `endPos`), and the new method `name`. `errExit` non-null means arg parsing hit a terminal case (incl. a malformed position) the caller returns immediately.
 */
@:nullSafety(Strict)
typedef ExtractMethodOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var file: Null<String>;
	var startPos: Null<Position>;
	var endPos: Null<Position>;
	var name: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / malformed
	// position -> EXIT_USAGE); the caller returns this immediately and ignores the rest.
	var errExit: Null<Int>;
};

/**
 * `apq extract-method` — extract a statement run into a local function (closure).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ExtractMethodCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'extract-method';
	}

	public function summary(): String {
		return 'Extract a statement run into a local function (closure)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractMethod(args);
	}

	public function usage(): Void {
		printExtractMethodUsage();
	}

	private static inline function extractMethodParseExit(code: Int): ExtractMethodOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			file: null,
			startPos: null,
			endPos: null,
			name: null,
			errExit: code
		};
	}

	/**
	 * `apq extract-method <file> <startL>:<startC> <endL>:<endC> <name>
	 * [--write] [--reformat]` — extract the contiguous run of statements
	 * bounded by the two positions into a fresh local function `<name>`
	 * (a closure capturing the enclosing scope), replacing the run with a
	 * call. A local declared in the run and used after it becomes the
	 * call's return value (at most one). The run must be sibling statements
	 * of one `{ }` block with no return / break / continue. Because the op
	 * synthesises a new function, the result is WRITER-FORMATTED — the
	 * source must already be canonical unless `--reformat` is passed.
	 * `<line>:<col>` use the `apq refs` print convention. Without `--write`
	 * the rewritten source is emitted to stdout; with `--write` it
	 * overwrites in place.
	 */
	private static function runExtractMethod(args: Array<String>): Int {
		final o: ExtractMethodOpts = parseExtractMethodArgs(args);
		if (o.errExit != null) return o.errExit;
		// parseExtractMethodArgs proved these non-null before returning with
		// errExit:null; Strict won't narrow struct fields, so re-bind into
		// locals and throw on the provably-unreachable null state.
		final filePath: Null<String> = o.file;
		final startPos: Null<Position> = o.startPos;
		final endPos: Null<Position> = o.endPos;
		final nameStr: Null<String> = o.name;
		if (filePath == null || startPos == null || endPos == null || nameStr == null)
			throw new Exception('apq extract-method: null arg after validation (unreachable)');
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq extract-method: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final shape: RefShape = plugin.refShape();
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final result: EditResult = ExtractMethod.extractMethod(
			source, startPos.line, startPos.col, endPos.line, endPos.col, nameStr, o.reformat, plugin, shape, optsJson
		);
		return CliEdit.finishEdit('extract-method', filePath, o.write, result);
	}

	private static function printExtractMethodUsage(): Void {
		CliIo.sysPrint('Usage: apq extract-method <file> <startLine>:<col> <endLine>:<col> <name> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Extract the contiguous run of statements bounded by the two positions into\n');
		CliIo.sysPrint('a fresh local function <name> (a closure), replacing the run with a call.\n');
		CliIo.sysPrint('A local defined in the run and used after it becomes the return value.\n');
		CliUsage.printOptionsEditTail();
	}

	private static function parseExtractMethodArgs(args: Array<String>): ExtractMethodOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var startSpec: Null<String> = null;
		var endSpec: Null<String> = null;
		var name: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printExtractMethodUsage();
					return extractMethodParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq extract-method: unknown option "$a"\n');
						return extractMethodParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (startSpec == null)
						startSpec = a;
					else if (endSpec == null)
						endSpec = a;
					else if (name == null)
						name = a;
					else {
						CliIo.stderr('apq extract-method: unexpected extra argument "$a"\n');
						return extractMethodParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		if (file == null || startSpec == null || endSpec == null || name == null) {
			CliIo.stderr('apq extract-method: expected <file> <startLine>:<col> <endLine>:<col> <name>\n');
			printExtractMethodUsage();
			return extractMethodParseExit(EXIT_USAGE);
		}
		final startPos: Null<Position> = CliArgs.parseLineCol(startSpec);
		if (startPos == null) {
			CliIo.stderr('apq extract-method: malformed start position "$startSpec" — expected <line>:<col>\n');
			return extractMethodParseExit(EXIT_USAGE);
		}
		final endPos: Null<Position> = CliArgs.parseLineCol(endSpec);
		if (endPos != null) return {
			lang: lang,
			write: write,
			reformat: reformat,
			file: file,
			startPos: startPos,
			endPos: endPos,
			name: name,
			errExit: null
		};
		CliIo.stderr('apq extract-method: malformed end position "$endSpec" — expected <line>:<col>\n');
		return extractMethodParseExit(EXIT_USAGE);
	}

}
