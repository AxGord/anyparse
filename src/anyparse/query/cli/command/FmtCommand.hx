package anyparse.query.cli.command;

import anyparse.format.WhitespaceInvariant;
import anyparse.format.comment.CommentInventory;
import anyparse.query.Cli.FmtRunResult;
import anyparse.query.FormatFixedPoint.FormatFixedPointResult;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq fmt` — `lang`, `write` (rewrite in place) vs `list` (name changed files only), and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef FmtOpts = {
	var lang: String;
	var write: Bool;
	var list: Bool;

	/**
	 * Read-only audit: format each file in memory and require the output to differ
	 * from the input by WHITESPACE only. Never writes. See
	 * `anyparse.format.WhitespaceInvariant` for what the rule does and does not know.
	 */
	var verify: Bool;

	/**
	 * Gate the ONE-PASS canonical property: a file whose writer needed more than
	 * one rewrite to reach its fixed point is reported and the run exits
	 * non-zero. Off by default, because a project whose config reaches the
	 * writer's convergence tail must still be able to run `fmt --write`; on for
	 * the gates, where `writeRoundTrip(s) == s` after ONE pass is the property
	 * every writer-emit op is built on.
	 */
	var onePass: Bool;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * Per-file outcome of `apq fmt`: whether the file `changed`, whether formatting `failed`, and `fatalExit` (non-null = an unrecoverable per-file outcome, e.g. no writer wired for the lang, that aborts the remaining files).
 */
@:nullSafety(Strict)
typedef FmtFileResult = {
	var changed: Bool;
	var failed: Bool;

	/**
	 * `--verify` only: the output differed from the input by more than whitespace.
	 * Counted apart from `failed`, which in this mode is dominated by files that
	 * could not be formatted at all (a parse failure, a comment-loss refusal) —
	 * reporting those as invariant breaches would name the wrong defect.
	 */
	@:optional var diverged: Bool;

	/**
	 * `--one-pass` only: the writer needed more than one rewrite to settle this
	 * file. Counted apart from `failed` because the file was formatted fine —
	 * and, under `--write`, still written to that fixed point. What did not hold
	 * is the ONE-PASS property, which is a statement about the WRITER.
	 */
	@:optional var unsettled: Bool;

	/**
	 * `--write` only: the formatted bytes were correct and the host refused the write
	 * (a read-only file, a full volume). Counted INSIDE `failed` — the run could not
	 * answer for the file — and separately, because the two causes need different
	 * readers: a parse failure is a fact about the SOURCE and a write failure is a
	 * fact about the ENVIRONMENT, and one word for both is what let an all-EACCES
	 * run over a `cp -R` tree read as "nothing to do" and pass as a measurement arm.
	 *
	 * A READ failure is an environment fact too and still rides under the shared
	 * word — `chmod 000` on one file of two gives `rewrote 1 of 2 file(s), 1 failed`,
	 * the same shape one syscall to the left. It is left alone deliberately: the
	 * write side is the one that produced the vacuous arm, and a second word wants
	 * its own fixture rather than a widened claim here.
	 */
	@:optional var unwritable: Bool;
	// Non-null = a fatal per-file outcome (no writer wired for the lang);
	// the caller returns this immediately, aborting the remaining files.
	var fatalExit: Null<Int>;
};

/**
 * `apq fmt` — canonicalise Haxe source (writer round-trip; --write / --list).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class FmtCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'fmt';
	}

	public function summary(): String {
		return 'Canonicalise Haxe source (writer round-trip; --write / --list)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runFmt(args);
	}

	public function usage(): Void {
		printFmtUsage();
	}

	private static inline function fmtParseExit(code: Int): FmtOpts {
		return {
			lang: '',
			write: false,
			list: false,
			verify: false,
			onePass: false,
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq fmt <file/dir/glob>... [--write] [--list]` — canonicalise Haxe
	 * source by re-emitting it through the writer (the same whole-file pipeline
	 * the writer-emit ops use), formatted by the project `hxformat.json`
	 * discovered from each file's directory. This is the deterministic
	 * file-level counterpart of the node-level writer-emit ops: it is what
	 * makes a freshly written file byte-canonical (the create recipe's
	 * finisher) and is the measuring stick for the canonical gate
	 * (`writeRoundTrip(s) == s`). With no flags on a single concrete file the
	 * formatted source goes to stdout; on multiple files / a directory `--list`
	 * mode is implied (gofmt `-l`: print the paths whose output differs). A
	 * file that fails to parse is reported and skipped; the exit code is
	 * non-zero if any file failed. A file whose re-emission would drop a
	 * comment is reported the same way and left byte-identical — see the
	 * comment-loss obligation on `GrammarPlugin.writeRoundTrip`. Every one of
	 * those behaviours lives in `fmtRun` / `formatOneFile`; this entry only
	 * prints what the run decided to say.
	 */
	private static function runFmt(args: Array<String>): Int {
		final run: FmtRunResult = fmtRun(args);
		if (run.summary.length > 0) CliIo.stderr(run.summary);
		return run.exit;
	}

	/**
	 * `apq fmt`'s whole run, with the summary handed BACK instead of printed.
	 *
	 * The seam exists for the summary alone. Three recorded defects in this family
	 * were a count line disagreeing with the tree it described, and each was found
	 * by hand on a real tree because nothing could assert it: `Sys.stderr()` on
	 * hxnodejs is a raw fd, so no in-process test can read what the user reads.
	 * Returning the line lets a test drive a REAL directory through the REAL loop
	 * and assert it in every direction — over-report, under-report, and failure.
	 */
	public static function fmtRun(args: Array<String>): FmtRunResult {
		final o: FmtOpts = parseFmtArgs(args);
		if (o.errExit != null) {
			// Re-bound: a narrowed FIELD never reaches an anonymous-structure literal
			// whose expected field is non-nullable.
			final parsedExit: Int = o.errExit;
			return { exit: parsedExit, summary: '' };
		}
		warnCommentGuardDeclined();
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq fmt: expected <file/dir/glob>...\n');
			printFmtUsage();
			return { exit: EXIT_USAGE, summary: '' };
		}

		final io = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq fmt: ${CliArgs.quotedSpecs(o.inputSpecs)} matched no .hx files\n');
			return { exit: EXIT_RUNTIME, summary: '' };
		}
		final plugin: GrammarPlugin = io.plugin;

		// No --write and no -l on a single concrete file → emit the formatted
		// source to stdout (gofmt's one-file default). Multiple files / a dir
		// without --write → list mode (names of files that would change).
		final listMode: Bool = !o.verify && (o.list || (!o.write && !io.singleFile));

		var changed: Int = 0;
		var failed: Int = 0;
		var unwritable: Int = 0;
		var diverged: Int = 0;
		var unsettled: Int = 0;
		for (path in paths) {
			final r: FmtFileResult = formatOneFile(plugin, o.lang, path, o.write && !o.verify, listMode, o.verify, o.onePass);
			if (r.fatalExit != null) {
				// Re-bound for the same reason as `parsedExit` above.
				final fatal: Int = r.fatalExit;
				return { exit: fatal, summary: '' };
			}
			if (r.changed) changed++;
			// Nested rather than a sibling `if`, because `unwritable` is a SUBSET of
			// `failed` and the summary subtracts one from the other. A later return site
			// marking a refused write without marking a failure would send `formatFailed`
			// negative — where its own `> 0` guard drops the clause in silence — and would
			// exit `EXIT_OK` for a run that wrote nothing, which is the exact misreading
			// the counter exists to end.
			if (r.failed) {
				failed++;
				if (r.unwritable == true) unwritable++;
			}
			if (r.diverged == true) diverged++;
			if (r.unsettled == true) unsettled++;
		}

		final summary: String = fmtSummary(o, listMode, {
			scanned: paths.length,
			changed: changed,
			failed: failed,
			unwritable: unwritable,
			diverged: diverged,
			unsettled: unsettled
		});
		// ω-one-pass-gate: its own clause in the exit condition. A file that needed a
		// second rewrite was still formatted — folding it into `failed` would make
		// `--write` claim it left the file alone, which is the opposite of what
		// happened.
		//
		// A write the host refused rides in `failed` and therefore already exits
		// non-zero, and it stays that way deliberately: a `--write` run that could
		// write nothing did not leave the tree canonical, so a caller that gates on the
		// status must not read it as success — the same call `test-summary` makes for a
		// transcript it could not parse. Only the SUMMARY needed splitting; the status
		// was never the half that lied.
		return {
			exit: failed > 0 || unsettled > 0 ? EXIT_RUNTIME : EXIT_OK,
			summary: summary
		};
	}

	/**
	 * The per-mode run summary `apq fmt` RETURNS for its caller to print.
	 *
	 * Every mode states BOTH quantities — how many files the run considered and
	 * how many it acted on. One number alone is what let `formatted 0 file(s),
	 * 3 failed` read as "the run was inert" on an 870-file tree: nothing on the
	 * line separated that reading from the true one. `--list` said nothing at
	 * all unless a file failed, so its drift count was reported nowhere.
	 *
	 * A String rather than a `stderr` call because `Sys.stderr()` on hxnodejs
	 * is a raw fd — a line that only ever reaches fd 2 can be pinned by no
	 * in-process test, and every defect in this family is a count line that
	 * disagreed with the tree it described.
	 */
	private static function fmtSummary(
		o: FmtOpts, listMode: Bool, n: {
			scanned: Int,
			changed: Int,
			failed: Int,
			unwritable: Int,
			diverged: Int,
			unsettled: Int
		}
	): String {
		final out: StringBuf = new StringBuf();
		// Never folded into the mode lines below: a failure is not a rewrite that did
		// not happen, it is a file the run could not answer for at all.
		//
		// And the two CAUSES of a failure are never folded into each other either.
		// `failed` is a file the run could not answer FOR — it did not parse, or its
		// re-emission would drop a comment; an unwritable one it answered for exactly
		// and the HOST refused the write. Under one word, `rewrote 0 of 2625 file(s),
		// 1692 failed` on a `cp -R` copy whose mode bits stayed `444` read as a
		// source-side verdict and was accepted as a measurement arm — the run had
		// written nothing at all, and both arms of the comparison were the untouched
		// copy. The tail stays shared because only a `--write` run reaches the write
		// site at all, and `--write` outranks `--list` in the mode chain below — NOT
		// because `listMode` excludes it: `fmt <dir> --write --list` sets both, and the
		// line it prints is the `--write` one, clause included.
		final formatFailed: Int = n.failed - n.unwritable;
		final failTail: String = (formatFailed > 0 ? ', ${formatFailed} failed' : '')
			+ (n.unwritable > 0 ? ', ${n.unwritable} could not be written' : '');
		if (o.verify)
			// Three numbers, because a single one reads as a clean audit for the wrong
			// reason: `changed` is the scan's real denominator (a file the writer would
			// not rewrite cannot diverge), and `failed - diverged` is the files it could
			// not format at all — each already printed its own reason.
			out.add(
				'apq fmt --verify: ${n.diverged} of ${n.changed} reformatted file(s) changed more than whitespace'
				+ ' (${n.scanned} scanned, ${n.failed - n.diverged} could not be formatted)\n'
			);
		else if (o.write)
			out.add('apq fmt: rewrote ${n.changed} of ${n.scanned} file(s)$failTail\n');
		else if (listMode)
			// Printed even at zero, and even with nothing failing. `--list` names the
			// drifted files on stdout and used to say NOTHING on a clean tree, so a run
			// that scanned a whole project and a run that matched three files were the
			// same silence. A failure is counted here too — it is not always a parse
			// failure any more, a file whose re-emission would drop a comment is refused
			// as well, and each one printed its own reason above.
			out.add('apq fmt --list: ${n.changed} of ${n.scanned} file(s) would be rewritten$failTail\n');
		// Its OWN line, never folded into the mode summaries above: the count is
		// about the WRITER, and every mode — preview, list, write, verify — reports
		// it the same way.
		if (n.unsettled > 0)
			out.add(
				'apq fmt --one-pass: ${n.unsettled} file(s) needed more than one writer rewrite'
				+ ' — the one-pass canonical gate `writeRoundTrip(s) == s` does not hold for them\n'
			);
		return out.toString();
	}

	/**
	 * Warn once per run when the comment guard's escape hatch is set. It
	 * exists for writer development on the read-only probes, but it is
	 * process-wide: left in a shell profile or a CI environment it silently
	 * re-arms comment DELETION on every write path. A rewrite command that
	 * runs under it says so.
	 */
	public static function warnCommentGuardDeclined(): Void {
		if (CommentInventory.guardDeclined())
			CliIo.stderr('apq: ${CommentInventory.DECLINE_ENV} is set — the comment-loss guard is OFF; a rewrite may DELETE comments\n');
	}

	private static function printFmtUsage(): Void {
		CliIo.sysPrint('Usage: apq fmt <file/dir/glob>... [--write] [--list] [--verify] [--one-pass]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --write, -w     Rewrite each file in place with its canonical form\n');
		CliIo.sysPrint('  --list, -l      Print paths whose output differs (gofmt -l); no rewrite\n');
		CliIo.sysPrint('  --verify        Audit: the output must differ from the input by WHITESPACE\n');
		CliIo.sysPrint('                  only. Reports every other divergence; never writes\n');
		CliIo.sysPrint('  --one-pass      Also require every file to reach its fixed point in ONE\n');
		CliIo.sysPrint('                  writer rewrite; exit non-zero otherwise. Composes with\n');
		CliIo.sysPrint('                  every mode above and changes none of them\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Canonicalise Haxe source by re-emitting it through the writer, formatted\n');
		CliIo.sysPrint('by the project hxformat.json discovered from each file\'s directory. With\n');
		CliIo.sysPrint('no flags on a single file the formatted source goes to stdout; on multiple\n');
		CliIo.sysPrint('files or a directory, --list mode is implied. A file that fails to parse is\n');
		CliIo.sysPrint('reported and skipped; the exit code is non-zero if any file failed.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A file whose re-emission would DROP a comment (an inline comment in a seam\n');
		CliIo.sysPrint('the parser has no capture slot for, e.g. `if (/* c */ x)`) is reported with\n');
		CliIo.sysPrint('the comment and left byte-identical rather than rewritten without it.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('--one-pass catches the class NO other tree-level gate can see: `fmt` writes\n');
		CliIo.sysPrint('the writer\'s FIXED POINT, so a file the writer settles only on its second\n');
		CliIo.sysPrint('rewrite is reported canonical by --list while the next writer-emit op\n');
		CliIo.sysPrint('refuses it — that op\'s gate is one round trip, not the fixed point. Off by\n');
		CliIo.sysPrint('default so a project whose config reaches the writer\'s convergence tail can\n');
		CliIo.sysPrint('still run --write; on for a gate.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('--verify catches what the writer round-trip cannot: a writer defect whose\n');
		CliIo.sysPrint('output this parser still accepts is invisible to a tree-level gate, so\n');
		CliIo.sysPrint('self-status, --list and lint all report green on a tree that no longer\n');
		CliIo.sysPrint('compiles. Note that some policies change tokens on purpose — a trailing\n');
		CliIo.sysPrint('comma, braces around a single statement, an optional semicolon — and those\n');
		CliIo.sysPrint('are reported too; read the diff rather than treating any hit as a bug.\n');
	}

	private static function parseFmtArgs(args: Array<String>): FmtOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var list: Bool = false;
		var verify: Bool = false;
		var onePass: Bool = false;
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
				case '--verify':
					verify = true;
				case '--one-pass':
					onePass = true;
				case '-h', '--help':
					printFmtUsage();
					return fmtParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq fmt: unknown option "$a"\n');
						return fmtParseExit(EXIT_USAGE);
					}
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			list: list,
			verify: verify,
			onePass: onePass,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function formatOneFile(
		plugin: GrammarPlugin, lang: String, path: String, write: Bool, listMode: Bool, verify: Bool = false, onePass: Bool = false
	): FmtFileResult {
		final source: String = try CliIo.readFile(path) catch (exception: Exception) {
			CliIo.stderr('apq fmt: $path: ${exception.message}\n');
			return { changed: false, failed: true, fatalExit: null };
		};
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(path);
		// The FIXED POINT, not one round trip. `--list` and `--write` decide from
		// the same `formatted == source` comparison, so they cannot disagree within
		// a run — they disagreed ACROSS runs, because a writer whose output is not
		// its own fixed point left `--write` one pass short of where the next
		// `--list` looked. `FormatFixedPoint` carries the measured instance.
		final roundTrip: (text:String) -> Null<String> = text -> plugin.writeRoundTrip(text, optsJson);
		final fixedPoint: FormatFixedPointResult = try FormatFixedPoint.run(roundTrip, source) catch (exception: Exception) {
			CliIo.stderr('apq fmt: $path: ${exception.message}\n');
			return { changed: false, failed: true, fatalExit: null };
		};
		final formatted: Null<String> = fixedPoint.text;
		if (formatted == null) {
			CliIo.stderr('apq fmt: no writer for lang "$lang"\n');
			return { changed: false, failed: false, fatalExit: EXIT_RUNTIME };
		}
		// Every mode fails here, deliberately. A file `--list` reports and `--write`
		// cannot settle is the exact disagreement this postcondition exists to
		// close, so no mode may report it as ordinary drift — and writing a
		// non-fixed-point would churn the bytes again on the next run.
		if (!fixedPoint.converged) {
			CliIo.stderr('apq fmt: $path: ${fixedPoint.failure}; left unchanged\n');
			return { changed: false, failed: true, fatalExit: null };
		}
		// Converged, but not on the first rewrite: the file is formatted correctly
		// and the WRITER is the defect. Reported rather than swallowed — a silent
		// loop would hide it behind output that now looks stable. Same sentence the
		// mutation ops now print off `EditResult.Ok`'s `rewrites`, from one copy, so
		// a user who meets the note twice can tell it is one finding.
		CliEdit.warnRewrites('fmt', path, fixedPoint.rewrites);
		// ω-one-pass-gate: `--one-pass` turns that note into a VERDICT. The project's
		// canonical gate is `writeRoundTrip(s) == s` after ONE pass, and every
		// writer-emit op is built on it — but a tree holding a file the writer only
		// settles on its SECOND rewrite answers `fmt --list` EMPTY, because `fmt`
		// writes the fixed point, while the next op on that same file refuses it as
		// non-canonical. So the class has no tree-level gate at all unless one is
		// asked for, and it cannot be the default: a project whose config reaches the
		// writer's convergence tail must still be able to run `fmt --write`.
		// Reported apart from `failed`: the file formatted correctly and, under
		// `--write`, was written to its fixed point — what did not hold is a property
		// of the WRITER.
		final unsettled: Bool = onePass && fixedPoint.rewrites > 1;
		final isCanonical: Bool = formatted == source;
		if (verify) {
			// A file already at its fixed point cannot diverge, so the scan is skipped
			// for the overwhelming majority of a canonical tree.
			if (isCanonical) return {
				changed: false,
				failed: false,
				unsettled: unsettled,
				fatalExit: null
			};
			final divergence: Null<Divergence> = WhitespaceInvariant.firstDivergence(source, formatted);
			if (divergence == null) return {
				changed: true,
				failed: false,
				unsettled: unsettled,
				fatalExit: null
			};
			CliIo.sysPrint('$path:${divergence.line}: formatting changed more than whitespace\n');
			CliIo.sysPrint('  source: ${divergence.expected}\n');
			CliIo.sysPrint('  writer: ${divergence.actual}\n');
			return {
				changed: true,
				failed: true,
				fatalExit: null,
				diverged: true,
				unsettled: unsettled
			};
		}
		if (write) {
			if (!isCanonical) {
				// A write that THROWS took the whole run down mid-tree: an uncaught host
				// error, no summary line at all, and every file already rewritten left
				// with nothing said about it — the extreme of the count-line family, since
				// the count never reaches the reader. Read failures were caught here from
				// the start; the write side was not, and a read-only file is the ordinary
				// way to meet it.
				//
				// It stays a per-file failure only because the write is now all-or-nothing.
				// Continuing past a TRUNCATING write is what turned a full disk into a tree
				// of empty source files: measured, five files on a volume with no free
				// blocks gave `rewrote 3 of 5 file(s), 2 failed` and two files of 0 bytes.
				try CliIo.writeFile(path, formatted) catch (failure: WriteFailure) {
					CliIo.stderr('apq fmt: ${failure.message}\n');
					return {
						changed: false,
						failed: true,
						unwritable: true,
						unsettled: unsettled,
						fatalExit: null
					};
				}
				return {
					changed: true,
					failed: false,
					unsettled: unsettled,
					fatalExit: null
				};
			}
		} else if (listMode) {
			if (!isCanonical) {
				CliIo.sysPrint('$path\n');
				return {
					changed: true,
					failed: false,
					unsettled: unsettled,
					fatalExit: null
				};
			}
		} else
			CliIo.sysPrint(formatted);
		return {
			changed: false,
			failed: false,
			unsettled: unsettled,
			fatalExit: null
		};
	}

}
