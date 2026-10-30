package anyparse.query.cli.command;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ExitCode.*;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * Parsed options for `apq extract-method` — `lang`, `write` / `reformat`, the target `file`, the
 * statement-run bounds (`startPos` / `endPos`), and the new method `name`. `errExit` non-null means
 * arg parsing hit a terminal case (incl. a malformed position) the caller returns immediately.
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

	/** `--member`: extract into a new private member of the enclosing type instead of a local closure. */
	var member: Bool;
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
final class ExtractMethodCommand implements CliCommand implements PostWriteFix {

	public function new() {}

	public function name(): String {
		return 'extract-method';
	}

	public function summary(): String {
		return 'Extract a statement run into a local function (closure)';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--member', '--reformat', '--write'], []);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractMethod(args, ctx.postWriteFix);
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
			member: false,
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
	private static function runExtractMethod(args: Array<String>, fix: Bool): Int {
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
			source, startPos.line, startPos.col, endPos.line, endPos.col, nameStr, o.reformat, plugin, shape, optsJson, o.member
		);
		return CliEdit.finishEdit('extract-method', filePath, o.write, result, fix ? plugin : null);
	}

	private static function printExtractMethodUsage(): Void {
		CliIo.sysPrint('Usage: apq extract-method <file> <startLine>:<col> <endLine>:<col> <name> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Extract the contiguous run of statements bounded by the two positions into\n');
		CliIo.sysPrint('a fresh local function <name> (a closure), replacing the run with a call.\n');
		CliIo.sysPrint('A local defined in the run and used after it becomes the return value.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('  --member        Extract into a new PRIVATE member of the enclosing type, placed\n');
		CliIo.sysPrint('                  after the member holding the run: the locals the run reads\n');
		CliIo.sysPrint('                  become typed parameters, the locals read after it the return\n');
		CliIo.sysPrint('                  value (the inverse of inline-method). Refuses a local it would\n');
		CliIo.sysPrint('                  have to copy that the function assigns, or one with no written\n');
		CliIo.sysPrint('                  type.\n');
		CliUsage.printOptionsEditTail();
		CliUsage.printPostWriteFixTail();
	}

	private static function parseExtractMethodArgs(args: Array<String>): ExtractMethodOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var startSpec: Null<String> = null;
		var endSpec: Null<String> = null;
		var name: Null<String> = null;
		var member: Bool = false;

		for (arg in new ExtractMethodCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--member':
					member = true;
				case '-h', '--help':
					printExtractMethodUsage();
					return extractMethodParseExit(EXIT_OK);
				case null:
					if (file == null) {
						file = a;
					} else if (startSpec == null) {
						startSpec = a;
					} else if (endSpec == null) {
						endSpec = a;
					} else if (name == null) {
						name = a;
					} else {
						CliIo.stderr('apq extract-method: unexpected extra argument "$a"\n');
						return extractMethodParseExit(EXIT_USAGE);
					}
			}
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
			member: member,
			errExit: null
		};
		CliIo.stderr('apq extract-method: malformed end position "$endSpec" — expected <line>:<col>\n');
		return extractMethodParseExit(EXIT_USAGE);
	}

}
