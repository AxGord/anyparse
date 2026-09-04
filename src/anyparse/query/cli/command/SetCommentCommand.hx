package anyparse.query.cli.command;

import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq set-comment` — the SINGLE-FILE EDIT shape of the command seam.
 *
 * It is the pilot for the 19 address-and-edit commands (`patch`,
 * `replace-node`, `set-doc`, `set-modifier`, `add-element`, `remove-element`,
 * `add-meta` …): a `parseXArgs` producing an options record, an address, and
 * the shared `CliEdit.finishEdit` tail that decides between a written file, a
 * preview on stdout and a diagnostic. Nothing here touches the run context —
 * an edit's answer depends only on its own arguments.
 */
@:nullSafety(Strict)
final class SetCommentCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'set-comment';
	}

	public function summary(): String {
		return 'Replace the comment at a cursor (line run or block)';
	}

	/**
	 * `apq set-comment <file> <line>:<col> (<text> | --from-file | -) [--reformat]
	 * [--write]` — replace the comment at the cursor (see `SetComment`). Line
	 * comments are trivia no other op reaches; a block comment is replaced whole, a
	 * full-line line-comment run as one unit. The replacement must itself be a
	 * comment; the result is writer-formatted and re-parse-validated (canonical-
	 * gated unless `--reformat`).
	 */
	public function run(args: Array<String>, ctx: CliContext): Int {
		final o: SetCommentOpts = parseSetCommentArgs(args);
		if (o.errExit != null) return o.errExit;
		var commentText: Null<String> = o.commentText;
		if (o.fromFile != null || commentText == '-') {
			final resolved: Null<String> = CliArgs.resolveCodeArg('set-comment', commentText == '-' ? '-' : null, o.fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			commentText = resolved;
		}
		final file: Null<String> = o.file;
		final pos: Null<String> = o.pos;
		if (file == null || pos == null || commentText == null) {
			CliIo.stderr('apq set-comment: expected <file> <line>:<col> (<text> | --from-file <path> | -)\n');
			usage();
			return EXIT_USAGE;
		}
		final loc: Null<Position> = CliArgs.parseLineCol(pos);
		if (loc == null) {
			CliIo.stderr('apq set-comment: bad position "$pos" (expected <line>:<col>)\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final commentStr: String = commentText;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq set-comment: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		return CliEdit.finishEdit(
			'set-comment', filePath, o.write, SetComment.setComment(source, loc.line, loc.col, commentStr, o.reformat, plugin, optsJson)
		);
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq set-comment <file> <line>:<col> (<text> | --from-file <path> | -) [--reformat] [--write]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --from-file <path>  Read the comment text from a file instead of the argument\n');
		CliIo.sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		CliIo.sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
	}

	private function parseSetCommentArgs(args: Array<String>): SetCommentOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var fromFile: Null<String> = null;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		var commentText: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--from-file':
					fromFile = CliArgs.expectValue(args, ++i, '--from-file');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					usage();
					return SetCommentCommand.setCommentParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq set-comment: unknown option "$a"\n');
						return SetCommentCommand.setCommentParseExit(EXIT_USAGE);
					}
					if (file == null)
						file = a;
					else if (pos == null)
						pos = a;
					else if (commentText == null)
						commentText = a;
					else {
						CliIo.stderr('apq set-comment: unexpected extra argument "$a"\n');
						return SetCommentCommand.setCommentParseExit(EXIT_USAGE);
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
			commentText: commentText,
			errExit: null
		};
	}

	private static inline function setCommentParseExit(code: Int): SetCommentOpts {
		return {
			lang: '',
			write: false,
			reformat: false,
			fromFile: null,
			file: null,
			pos: null,
			commentText: null,
			errExit: code
		};
	}

}

/**
 * Parsed options for `apq set-comment` — `lang`, `write` / `reformat`, the target `file`, the `pos` address, and the comment body (`commentText` or `fromFile`). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef SetCommentOpts = {
	var lang: String;
	var write: Bool;
	var reformat: Bool;
	var fromFile: Null<String>;
	var file: Null<String>;
	var pos: Null<String>;
	var commentText: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
