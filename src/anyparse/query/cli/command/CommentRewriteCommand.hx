package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq comment-rewrite` — `lang`, `write` / `list` / `reformat`, `regex` mode,
 * `allowWide`, the `find` / `replace` texts, and `inputSpecs`. `errExit` non-null means arg parsing
 * hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef CommentRewriteOpts = {
	var lang: String;
	var write: Bool;
	var list: Bool;
	var reformat: Bool;
	var regex: Bool;
	// A replacement is refused when it pushes a comment line past the configured width — the last
	// half of this op no gate could see. `--allow-wide` waives it for a line meant to stay long.
	var allowWide: Bool;
	var find: Null<String>;
	var replace: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq comment-rewrite` — text find/replace inside comments (write-twin of lit; --regex).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class CommentRewriteCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'comment-rewrite';
	}

	public function summary(): String {
		return 'Text find/replace inside comments (write-twin of lit; --regex)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runCommentRewrite(args);
	}

	public function usage(): Void {
		printCommentRewriteUsage();
	}

	private static inline function commentRewriteParseExit(code: Int): CommentRewriteOpts {
		return {
			lang: '',
			write: false,
			list: false,
			reformat: false,
			regex: false,
			allowWide: false,
			find: null,
			replace: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runCommentRewrite(args: Array<String>): Int {
		final o: CommentRewriteOpts = parseCommentRewriteArgs(args);
		if (o.errExit != null) return o.errExit;
		final find: Null<String> = o.find;
		final replace: Null<String> = o.replace;
		if (find == null || replace == null || o.inputSpecs.length == 0) {
			CliIo.stderr('apq comment-rewrite: expected <find> <replace> <file/dir/glob>...\n');
			printCommentRewriteUsage();
			return EXIT_USAGE;
		}

		final findStr: String = find;
		final replaceStr: String = replace;
		final io = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq comment-rewrite: ${CliArgs.quotedSpecs(o.inputSpecs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final listMode: Bool = o.list || (!o.write && !io.singleFile);

		final tally: { changed: Int, failed: Int } = rewriteCommentFiles(
			paths, findStr, replaceStr, plugin, o.write, listMode, o.regex, o.reformat, o.allowWide
		);
		final failed: Int = tally.failed;

		if (o.write)
			CliIo.stderr('apq comment-rewrite: rewrote ${tally.changed} file(s)${failed > 0 ? ', $failed failed' : ''}\n');
		else if (listMode && failed > 0)
			CliIo.stderr('apq comment-rewrite: $failed file(s) failed\n');
		// "rewrote 0 file(s)" reads as "the text was there and needed no change", which is the one
		// thing it never means. Say that nothing MATCHED, and say where the two matching modes
		// differ — a literal find sees a body whose line breaks are one space, a regex sees the raw
		// body with its ` * ` prefixes, and that asymmetry is what a silent zero hides.
		if (tally.changed == 0 && failed == 0) {
			CliIo.stderr('apq comment-rewrite: no comment body in ${paths.length} file(s) contains the find text\n');
			CliIo.stderr(
				o.regex
					? 'apq comment-rewrite: (a --regex find is matched against the RAW body — a multi-line pattern needs \\s+\\*\\s+)\n'
					: 'apq comment-rewrite: (a literal find is matched with every line break collapsed to one space, in the find too)\n'
			);
		}
		return failed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printCommentRewriteUsage(): Void {
		CliIo.sysPrint('Usage: apq comment-rewrite <find> <replace> <file/dir/glob>... [--regex] [--write] [--list]\n');
		CliIo.sysPrint('       [--allow-wide]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Text search-and-replace scoped to COMMENT bodies (the write-twin of\n');
		CliIo.sysPrint('apq lit). Code and comment delimiters are never touched; strings are\n');
		CliIo.sysPrint('skipped. The result is canonical + re-parse-validated.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("A replacement holding real newlines (a shell $'a\\nb' literal) is re-prefixed\n");
		CliIo.sysPrint("with the comment's own continuation, so write plain lines — a ` * ` you add\n");
		CliIo.sysPrint('yourself is stripped, not doubled.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint("  --regex        <find> is a regex; <replace> a template where ${0}/${N}\n");
		CliIo.sysPrint("                 expand to group N and ${N+K}/${N-K} shift group N by K\n");
		CliIo.sysPrint('  --write, -w    Rewrite each file in place (default: stdout for one file,\n');
		CliIo.sysPrint('                 list of changed paths for a dir / multiple files)\n');
		CliIo.sysPrint('  --list, -l     Print paths whose comments would change; no rewrite\n');
		CliIo.sysPrint('  --reformat     Canonicalise the whole file (allow a non-canonical input)\n');
		CliIo.sysPrint('  --allow-wide   Accept a replacement that pushes a comment line past the\n');
		CliIo.sysPrint('                 configured wrapping.maxLineLength (refused by default)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('MATCHING. A LITERAL find is matched against a body whose line breaks — and the\n');
		CliIo.sysPrint('` * ` continuation after each of them — are collapsed to ONE SPACE. The find is\n');
		CliIo.sysPrint('normalised the same way, so a multi-line find works written either with those\n');
		CliIo.sysPrint('prefixes or without them. A --regex find is matched against the RAW body\n');
		CliIo.sysPrint('instead, prefixes included, so a multi-line pattern needs `\\s+\\*\\s+`.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("SPLICING. Write plain lines and real newlines (a shell $'a\\nb' literal): each\n");
		CliIo.sysPrint("new line gets the comment's own continuation, and a ` * ` you add yourself is\n");
		CliIo.sysPrint("stripped rather than doubled. The continuation is read off the block's own\n");
		CliIo.sysPrint('first interior line, so a GUTTER-LESS block keeps its indentation and a\n');
		CliIo.sysPrint('star-guttered one keeps its star; a one-line /** … */ that grows past one line\n');
		CliIo.sysPrint('is re-opened so its closer gets a line of its own.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('WIDTH is not re-wrapped either, but it is no longer silent: a replacement that\n');
		CliIo.sysPrint('leaves a comment line past wrapping.maxLineLength is REFUSED, naming the line,\n');
		CliIo.sysPrint('because neither `fmt --list` nor any lint rule reports one. An edit that only\n');
		CliIo.sysPrint('touches a line already over-width is fine — the gate compares how many such\n');
		CliIo.sysPrint('lines there are and how wide the widest is, so shortening one is not gaining\n');
		CliIo.sysPrint('one. Break it where you want it broken, or pass --allow-wide.\n');
	}

	private static function parseCommentRewriteArgs(args: Array<String>): CommentRewriteOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var list: Bool = false;
		var reformat: Bool = false;
		var regex: Bool = false;
		var allowWide: Bool = false;
		var find: Null<String> = null;
		var replace: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--write', '-w':
					write = true;
				case '--list', '-l':
					list = true;
				case '--reformat':
					reformat = true;
				case '--regex':
					regex = true;
				case '--allow-wide':
					allowWide = true;
				case '-h', '--help':
					printCommentRewriteUsage();
					return commentRewriteParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq comment-rewrite: unknown option "$a"\n');
						return commentRewriteParseExit(EXIT_USAGE);
					}
					if (find == null)
						find = a;
					else if (replace == null)
						replace = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			list: list,
			reformat: reformat,
			regex: regex,
			allowWide: allowWide,
			find: find,
			replace: replace,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function rewriteCommentFiles(
		paths: Array<String>, findStr: String, replaceStr: String, plugin: GrammarPlugin, write: Bool, listMode: Bool, regex: Bool,
		reformat: Bool, allowWide: Bool
	): { changed: Int, failed: Int } {
		final op: String = 'comment-rewrite';
		var changed: Int = 0;
		var failed: Int = 0;
		for (path in paths) {
			final source: String = try CliIo.readFile(path) catch (exception: Exception) {
				CliIo.stderr('apq comment-rewrite: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			final optsJson: Null<String> = CliArgs.discoverFormatConfig(path);
			switch CommentRewrite.rewrite(source, findStr, replaceStr, regex, reformat, plugin, optsJson, allowWide) {
				case Ok(text, rewrites):
					CliEdit.warnRewrites(op, path, rewrites);
					final isChanged: Bool = text != source;
					// Symmetric with the `readFile` catch at the head of this loop, and safe to
					// continue on now that a failed write leaves its file byte-identical: this op
					// walks a file set, so one unwritable member is a per-file failure like an
					// unreadable one, not a reason to abandon the rest.
					if (write) {
						if (isChanged) try {
							CliIo.writeFile(path, text);
							changed++;
						} catch (failure: WriteFailure) {
							CliIo.stderr('apq comment-rewrite: ${failure.message}\n');
							failed++;
						}
					} else if (listMode) {
						if (isChanged) {
							CliIo.sysPrint('$path\n');
							changed++;
						}
					} else {
						// The PREVIEW arm counts too. It did not, and the single-file default is a
						// preview, so every `apq comment-rewrite <find> <replace> <one file>` printed
						// the rewritten file on stdout and then said on stderr that no comment body
						// contained the find text — a false negative on the op's own diagnostic, and
						// the shape a user reaches for first when checking what an edit would do.
						CliEdit.previewEdit(op, path, text);
						if (isChanged) changed++;
					}
				case Err(message):
					CliIo.stderr('apq comment-rewrite: $path: $message\n');
					failed++;
			}
		}
		return { changed: changed, failed: failed };
	}

}
