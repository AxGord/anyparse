package anyparse.query.cli;

using StringTools;
using Lambda;

import haxe.Exception;
#if (sys || nodejs)
import sys.io.File;
import sys.FileSystem;
#end

/**
 * Process IO for the `apq` CLI — the one place a command reaches the outside
 * world: the two output streams, file reads and the crash-safe staged file
 * write, stdin, and the progress line a long walk prints.
 *
 * It exists because every one of the 69 commands needs some of it: `stderr`
 * alone had 165 call sites inside `Cli` before this module, `sysPrint` 143.
 * Moving a command out of `Cli` onto the command registry (`CliCommand`) is
 * only mechanical once the IO it calls is reachable from outside `Cli`, so
 * this module is the prerequisite half of that decomposition, not a
 * convenience grab-bag.
 *
 * Every member is a pure function of its arguments plus the process — the
 * module holds NO state, which is what keeps a CLI run free of the
 * process-scoped caches invariant 1 forbids in generated code.
 */
@:nullSafety(Strict)
final class CliIo {

	/**
	 * Heartbeat interval for the multi-file walk progress line — emit a
	 * stderr `scanned K/N` every this many files so a corpus-wide walk
	 * never goes silent (a watchdog reading a redirected stream sees
	 * steady byte growth). Tuned so a several-hundred-file `src/` walk
	 * yields ~10–20 lines rather than one-per-file flooding.
	 */
	private static inline final PROGRESS_INTERVAL: Int = 25;

	/**
	 * The suffix every write is staged through, on the far side of the extension on purpose:
	 * a `.hx.apq-tmp` a killed process left behind is invisible to every `*.hx` walk this tool
	 * does, where a `.apq-tmp.hx` would be linted, formatted and reported as a source file.
	 */
	private static inline final STAGED_WRITE_SUFFIX: String = '.apq-tmp';

	/**
	 * The mode bits a staged temporary inherits from the target it will replace: 07777, so the
	 * setuid / setgid / sticky trio travels with the nine permission bits rather than being dropped
	 * by the rename. Inert on a `.hx` source and free to carry.
	 */
	private static inline final PERMISSION_BITS: Int = 0xFFF;

	/**
	 * Read a file as **source for parsing**. Same as `readFile` for plain
	 * `.hx` files; auto-extracts the input section (between the 1st and
	 * 2nd `\n---\n` separators) when the path ends with `.hxtest` AND the
	 * content has the canonical 3-section layout (`config / input /
	 * expected`, as defined by `unit.HxFormatterCorpusHelpers`). This
	 * collapses the recurring `.hxtest` strip-test dance — `awk` /
	 * scratch-file extract followed by parse — into a direct
	 * `hxq strip /path/case.hxtest --replace … --with …`.
	 *
	 * Non-3-section `.hxtest` files (malformed, or a fork variant) pass
	 * through unchanged so the parser sees the raw bytes and the user
	 * gets a normal parse-error trace, not a silent transformation.
	 */
	public static inline function readSourceForParse(path: String): String {
		return readHxtestSectionOrRaw(path, 1);
	}

	public static inline function sysPrint(s: String): Void {
		#if (sys || nodejs)
		Sys.print(s);
		#end
	}

	public static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	public static function readFile(path: String): String {
		#if (sys || nodejs)
		return File.getContent(path);
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	/**
	 * Read all bytes from stdin and decode as UTF-8 source. Used by
	 * `apq ast --stdin` (and `apq probe -`) to accept inline source
	 * via shell pipe / heredoc / process substitution instead of
	 * `--code <s>` or a file path.
	 *
	 * On Node, `Sys.stdin().readAll()` raises `haxe.io.Error.Blocked`
	 * when stdin is a pipe (hxnodejs's sync stdin doesn't survive a
	 * partial read). Fall back to Node's native `fs.readFileSync(0)`
	 * which reads the full pipe to EOF synchronously.
	 */
	public static function readStdin(): String {
		#if nodejs
		final fs: Dynamic = js.Lib.require('fs');
		final buf: Dynamic = fs.readFileSync(0);
		return buf.toString('utf8');
		#elseif sys
		return Sys.stdin().readAll().toString();
		#else
		throw 'apq: stdin requires a sys target';
		#end
	}

	/**
	 * Common backend for the two `.hxtest`-aware readers. `sectionIdx`
	 * is the 0-based section index into the `\n---\n` split — `1` for
	 * the input source, `2` for the expected output. Trims exactly one
	 * leading and one trailing `\n` to mirror
	 * `HxFormatterCorpusHelpers.stripPadNewlines`.
	 */
	public static function readHxtestSectionOrRaw(path: String, sectionIdx: Int): String {
		final content: String = readFile(path);
		if (!path.endsWith('.hxtest')) return content;
		final parts: Array<String> = content.split('\n---\n');
		if (parts.length != 3) return content;
		var section: String = parts[sectionIdx];
		if (section.length > 0 && section.charAt(0) == '\n') section = section.substr(1);
		return section.length > 0 && section.charAt(section.length - 1) == '\n' ? section.substr(0, section.length - 1) : section;
	}

	/**
	 * Per-file walk progress heartbeat (multi-file scans only). Writes a
	 * `scanned <done>/<total>` line to **stderr** — never stdout — so the
	 * walker's machine-readable hit output stays byte-identical while a
	 * long run still produces incremental output. Fires every
	 * `PROGRESS_INTERVAL` files plus once at completion, and is a no-op
	 * for single-file queries (`singleFile`), tiny scans (`total <=
	 * PROGRESS_INTERVAL`), or when `HXQ_NO_PROGRESS` is set (so a caller
	 * merging streams via `2>&1` can suppress it).
	 *
	 * `done` is 1-based (the count of files processed so far, inclusive
	 * of the current one).
	 */
	public static function streamProgress(cmd: String, done: Int, total: Int, singleFile: Bool): Void {
		if (singleFile || total <= PROGRESS_INTERVAL) return;
		#if (sys || nodejs)
		if (Sys.getEnv('HXQ_NO_PROGRESS') != null) return;
		#end
		if (done % PROGRESS_INTERVAL == 0 || done == total) CliIo.stderr('apq $cmd: scanned $done/$total files…\n');
	}

	/**
	 * Write `content` to `path` — through a temporary beside the target, never into the target
	 * itself. One file is a change set of one, so this is `writeFiles` of a single member.
	 *
	 * `File.saveContent` opens with truncation, so a write that fails PART WAY leaves the source
	 * file destroyed rather than unchanged. Measured on a 10 MB volume filled to zero free blocks:
	 * `fmt --write` over five files reported `rewrote 3 of 5 file(s), 2 failed` and left the two
	 * failures at 0 bytes — the per-file catch turns the crash into a message and then goes on to
	 * the next file, so a full disk zeroes a tree one source file at a time. Staging the bytes
	 * beside the target and renaming them into place makes each write all-or-nothing: the same run
	 * leaves every file byte-identical and still reports.
	 *
	 * The rename is what costs something, and it is paid for deliberately — see `stageWrite` for
	 * the writability probe, the symlink resolution and the mode copy that keep it from defeating a
	 * read-only file, replacing a link, or flattening a file's permission bits.
	 */
	public static function writeFile(path: String, content: String): Void {
		writeFiles([
			{
				path: path,
				content: content
			}
		]);
	}

	/**
	 * Write a whole change set, or none of it.
	 *
	 * Every file is staged first and only then renamed into place, so a set one member of
	 * which cannot be written leaves the tree exactly as it found it. Without that a
	 * `rename --scope` over five files whose third is unwritable committed the first two
	 * and died — and a rename applied to some of its files is not a partial success, it is
	 * a tree that no longer compiles.
	 *
	 * The commit loop can still fail part way and nothing could undo that: by then the
	 * originals are gone. It is the narrow half of the window — a rename into a directory
	 * this process has just created a file in — while the whole of ENOSPC, EACCES and a
	 * read-only target is decided in the staging loop above it.
	 */
	public static function writeFiles(writes: Array<{ path: String, content: String }>): Void {
		#if (sys || nodejs)
		final staged: Array<StagedWrite> = [];
		try {
			for (w in writes) staged.push(stageWrite(w.path, w.content));
		} catch (failure: WriteFailure) {
			for (pending in staged) discardStage(pending.staged);
			throw failure;
		}
		for (i in 0...staged.length) try commitStagedWrite(staged[i]) catch (failure: WriteFailure) {
			// The renames already done cannot be undone — the originals are gone. What CAN be
			// tidied is the tail nobody has moved yet, and it must be: an ordinary handled error
			// would otherwise leave a `.apq-tmp` beside every remaining member of the set, which
			// is the one thing the suffix's own doc treats as a killed-process artefact.
			for (j in i + 1...staged.length) discardStage(staged[j].staged);
			throw failure;
		}
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	#if (sys || nodejs)
	/**
	 * Stage `content` for `path` in a sibling temporary, answering the pair `commitStagedWrite`
	 * renames into place.
	 *
	 * Three things a rename changes that an in-place write does not, and every one is repaired
	 * here rather than accepted, because a seat every write in this class goes through cannot
	 * afford to behave differently from the call it replaces:
	 *
	 * - A SYMLINK. `File.saveContent` writes THROUGH it; a rename replaces it with a regular file
	 *   and the link is gone. `FileSystem.fullPath` resolves it first, so the bytes land on the
	 *   same file the in-place write would have hit.
	 * - A READ-ONLY file. `rename(2)` needs write permission on the DIRECTORY, not on the file, so
	 *   a naked stage-and-rename silently overwrites a `chmod 444` file that `File.saveContent`
	 *   refuses with EACCES. Opening the target for append asks the kernel the same question the
	 *   in-place write asked, and writes nothing.
	 * - The MODE. A fresh temporary is created under the process umask, so renaming it over an
	 *   0755 file leaves 0644. Copied across before the rename — but on NODE only: `sys.FileSystem`
	 *   exposes no chmod, and the guard below says why that gap is recorded rather than closed.
	 *
	 * One difference survives, deliberately: a writable file inside a read-only DIRECTORY can no
	 * longer be rewritten, because there is nowhere beside it to stage. Falling back to the
	 * in-place write there would put the truncation window back exactly where this seat exists to
	 * close it, so the write fails and names the reason instead.
	 *
	 * The staging path is `<target>.apq-tmp`, derived and not randomised, which is what lets a test
	 * block it with a directory and pin the mechanism. Two apq PROCESSES writing the same file
	 * concurrently therefore share a temporary — already undefined behaviour before this change,
	 * since both used to truncate the same target, but the failure is now a spurious `ENOENT` on
	 * the loser rather than interleaved bytes.
	 */
	private static function stageWrite(path: String, content: String): StagedWrite {
		// INSIDE the try, both of them: a `fullPath` that throws (the file vanishing between the
		// two calls) would otherwise escape as a bare `Exception`, miss `run`'s WriteFailure-only
		// catch, and produce exactly the raw host trace this seat exists to remove.
		var target: String = path;
		var staged: String = path + STAGED_WRITE_SUFFIX;
		try {
			target = FileSystem.exists(path) ? FileSystem.fullPath(path) : path;
			staged = target + STAGED_WRITE_SUFFIX;
			// The kernel's own answer to the question `File.saveContent` used to ask, asked
			// before anything is staged: `open(…, 'a')` needs W_OK on the file and writes nothing.
			final mode: Null<Int> = if (FileSystem.exists(target)) {
				File.append(target, true).close();
				FileSystem.stat(target).mode & PERMISSION_BITS;
			} else
				null;
			File.saveContent(staged, content);
			// NODE ONLY, and the doc above says so: `sys.FileSystem` has no chmod, so a target
			// without `js.node.Fs` cannot put the mode back and a staged write there resets it to
			// the umask default. js/node is the only runner this CLI ships on, and nothing builds
			// `Cli` for another target — `tools/jvm-portability.hxml` never reaches this module —
			// so the gap is recorded rather than papered over with a per-write `chmod` process.
			#if nodejs
			if (mode != null) js.node.Fs.chmodSync(staged, mode);
			#end
		} catch (exception: Exception) {
			discardStage(staged);
			// `path`, not the resolved `target`: every other line this CLI prints names a file the
			// way the caller spelled it, and a diagnostic that suddenly answers in absolute
			// symlink-resolved form reads as being about a different file.
			throw new WriteFailure(path, exception.message);
		}
		return {
			staged: staged,
			target: target,
			asked: path
		};
	}

	/**
	 * Move a staged temporary onto its target, or report the file — never the temporary — as unwritable. The host message it quotes can still name the temporary; the path this CLI prints is the one the caller gave.
	 */
	private static function commitStagedWrite(pending: StagedWrite): Void {
		try FileSystem.rename(pending.staged, pending.target) catch (exception: Exception) {
			discardStage(pending.staged);
			throw new WriteFailure(pending.asked, exception.message);
		}
	}

	/**
	 * Drop a staged temporary.
	 *
	 * Best effort by construction: every caller is already reporting a write failure, and a
	 * temporary that cannot be removed must not replace the diagnostic the caller is
	 * carrying with one about the cleanup.
	 */
	private static function discardStage(staged: String): Void {
		try {
			if (FileSystem.exists(staged)) FileSystem.deleteFile(staged);
		} catch (exception: Exception) { // noqa: swallowed-exception
			// Deliberately swallowed — see the doc above: this runs only while a `WriteFailure` is
			// already on its way out, and a cleanup that cannot finish must not replace it.
		}
	}
	#end

	/** The plural suffix for a count: `''` for 1, `'s'` otherwise. */
	public static inline function plural(n: Int): String return n == 1 ? '' : 's';

	/**
	 * Emit a stderr nudge when any `.hx` file under `src/` or `test/` is
	 * newer than `bin/test.js` — the next `node bin/test.js` will run
	 * STALE bytes and a 0-delta sweep / clean test-summary can lie. Drives
	 * the documented `[[feedback-rebuild-test-js-after-macro-edit]]`
	 * trap: `bin/apq.js` auto-rebuilds (the hxq shim handles it) but
	 * `bin/test.js` is a separate build artefact whose staleness has no
	 * gate elsewhere in the workflow.
	 *
	 * Silent on `#if !sys`, on missing `bin/test.js` (caller will hit a
	 * clean error from the missing binary), or when nothing under src/
	 * or test/ is newer. Best-effort: a FileSystem failure short-circuits
	 * without raising — the user always gets the requested totals.
	 */
	public static function warnIfTestJsStale(cmd: String): Void {
		#if (sys || nodejs)
		final binPath: String = 'bin/test.js';
		if (!FileSystem.exists(binPath)) return;
		try {
			final binTime: Float = FileSystem.stat(binPath).mtime.getTime();
			if (anyHxNewerThan('src', binTime) || anyHxNewerThan('test', binTime)) {
				CliIo.stderr(
					'apq $cmd: WARNING: src/ or test/ is newer than bin/test.js — re-run `haxe test-js.hxml && node bin/test.js` before '
					+ 'trusting these totals\n'
				);
			}
		} catch (_: Exception) {
			// best-effort: skip the staleness advisory on any FS error
		}
		#end
	}

	private static function anyHxNewerThan(root: String, threshold: Float): Bool {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) return false;
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			try {
				for (name in FileSystem.readDirectory(dir)) {
					final path: String = '$dir/$name';
					if (FileSystem.isDirectory(path)) {
						stack.push(path);
						continue;
					}
					if (!StringTools.endsWith(name, '.hx')) continue;
					if (FileSystem.stat(path).mtime.getTime() > threshold) return true;
				}
			} catch (_: Exception) {
				// best-effort: a stat failure falls through to return false
			}
		}
		return false;
	}

}

/**
 * One file's pending write: `staged` holds the new bytes beside `target`, which is where
 * `Cli.commitStagedWrite` renames them, and `asked` is the spelling any diagnostic quotes.
 */
@:nullSafety(Strict)
private typedef StagedWrite = {
	var staged: String;
	var target: String;

	/** The path as the CALLER spelled it, which is the one a diagnostic must name. */
	var asked: String;
};
