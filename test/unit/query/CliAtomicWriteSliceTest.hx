package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The one seat every `apq` write goes through, and the two failures it had none of.
 *
 * `writeFile` was reached UNCAUGHT from 31 call sites, so one unwritable file took the whole run
 * down with a raw host error, no summary line, and part of the tree already rewritten — measured:
 * `lint --fix` over three files with the second read-only rewrote the first, died on the second,
 * and never reached the third. And the write itself was `File.saveContent`, which opens with
 * TRUNCATION, so a write that fails part way leaves the source file destroyed rather than
 * unchanged. Measured on a 10 MB volume filled to zero free blocks: `fmt --write` over five files
 * reported `rewrote 3 of 5 file(s), 2 failed` and left two of them at 0 bytes — the per-file catch
 * turns the crash into a message and then goes on to zero the next file.
 *
 * Neither condition can be staged from inside a test process: a full filesystem needs a
 * filesystem, and the sentence the run prints goes to `Sys.stderr`, a raw fd on hxnodejs that no
 * in-process assertion can read. So every pin here is on a PROPERTY instead — the exit code `run`
 * answers, the bytes on disk after a refused write, and the staging path itself, blocked with a
 * directory so that the stage fails at exactly the point a full disk would have made it fail.
 *
 * Measured at base: the two run-level pins ERROR, the uncaught `EACCES` never reaching their
 * assertions at all; the staging pin FAILS on both of its own; the other three pass. Those three
 * are green at base BY CONSTRUCTION and say so on their own doc — an in-place write kept a file's
 * mode, wrote THROUGH a symlink, and refused a read-only file for free, and a rename does none of
 * the three — so each is proved by MUTATION instead. Dropping the mode copy flips exactly the mode
 * pin; dropping the `fullPath` resolution flips exactly the symlink pin; removing the writability
 * probe flips the read-only pin AND both run-level pins, because `chmod 444` is the unwritable
 * condition all three are built on. Collapsing `writeFiles` to a loop of `writeFile` flips exactly
 * the change-set pin and leaves the run-level one green, which is what tells the batch staging
 * apart from the catch it rides on.
 */
@:nullSafety(Strict)
final class CliAtomicWriteSliceTest extends Test {

	#if (sys || nodejs)
	/** The permission half of a `FileStat.mode`. */
	private static inline final PERMISSION_BITS: Int = 0xFFF;

	/**
	 * 0755 — a mode no umask produces by accident, so a lost one cannot look like the default.
	 */
	private static inline final EXECUTABLE_MODE: Int = 0x1ED;

	/** A file the writer would reformat — the shape `fmt --write` acts on. */
	private static final DRIFTED: String = 'class D {\n    public function new() {}\n}\n';
	#end

	/**
	 * An unwritable file is a diagnostic and an exit code, not a crash.
	 *
	 * RED at base, and not by this assertion: the uncaught `EACCES` escapes `Cli.run`, so utest
	 * records an ERROR for the test and the line below is never reached at all.
	 */
	public function testAnUnwritableFileNoLongerTakesTheRunDown(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureTree();
		if (skipWithoutWriteBarrier(dir, '$dir/B.hx')) return;
		Assert.notEquals(0, Cli.run(['lint', dir, '--rule', 'unused-local', '--fix', '--no-oracle']));
		unlockAndRemove(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A change set is written whole, or not at all.
	 *
	 * The same three files twice. Locked, the run writes NONE of them; unlocked, it writes ALL three
	 * — and the second half is what stops the first from being a statement about a tree nothing ever
	 * touched. At base neither half is reached: the uncaught `EACCES` escapes `Cli.run` and the test
	 * ERRORS before any assertion runs. The discriminating measurement is the MUTATION — collapse
	 * `writeFiles` to a loop of `writeFile` and the locked run rewrites A, fails on B and never sees
	 * C, so `changedSince` answers 1 where this asserts 0, while the run-level pin beside it stays
	 * green. That is what tells the batch staging apart from the central catch it rides on.
	 *
	 * The two `stagedLeftovers` assertions are green at base by construction — `.apq-tmp` never
	 * existed there — and stay green under that mutation too. They guard the discard paths, which
	 * nothing else here reaches.
	 */
	public function testAChangeSetIsWrittenWholeOrNotAtAll(): Void {
		#if (sys || nodejs)
		final locked: String = fixtureTree();
		if (skipWithoutWriteBarrier(locked, '$locked/B.hx')) return;
		final before: Map<String, String> = snapshot(locked);
		Assert.notEquals(0, Cli.run(['lint', locked, '--rule', 'unused-local', '--fix', '--no-oracle']));
		Assert.equals(0, changedSince(before), 'one unwritable member leaves the whole set unwritten');
		Assert.equals(0, stagedLeftovers(locked), 'and no staging temporary is left behind');
		unlockAndRemove(locked);
		final open: String = fixtureTree();
		final openBefore: Map<String, String> = snapshot(open);
		Assert.equals(0, Cli.run(['lint', open, '--rule', 'unused-local', '--fix', '--no-oracle']));
		Assert.equals(3, changedSince(openBefore), 'with nothing locked the identical run writes every one of them');
		Assert.equals(0, stagedLeftovers(open), 'a successful write leaves no staging temporary either');
		CliFixture.removeDir(open);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A write that cannot be STAGED leaves its target byte-identical.
	 *
	 * The condition staging exists for — a write that fails part way — needs a full filesystem,
	 * which a test process cannot arrange. What it CAN arrange is the staging path itself: a
	 * directory sitting where the temporary would go makes the stage fail with `EISDIR` at exactly
	 * the point `ENOSPC` would, and the target has to come back untouched. That pins both halves of
	 * the mechanism at once — the target file is never opened, and the temporary is the sibling
	 * `<target>.apq-tmp`.
	 *
	 * RED at base, which writes straight into the target and has no idea the blocked path exists.
	 */
	public function testAStagingFailureLeavesTheTargetUntouched(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_stage_block', [{ name: 'D.hx', source: DRIFTED }]);
		FileSystem.createDirectory('$dir/D.hx.apq-tmp');
		Assert.notEquals(0, Cli.run(['fmt', '$dir/D.hx', '--write']));
		Assert.equals(DRIFTED, File.getContent('$dir/D.hx'), 'the target keeps every byte it had');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The file's permission bits survive the rewrite.
	 *
	 * GREEN AT BASE BY CONSTRUCTION, and it has to be said out loud: `File.saveContent` truncates a
	 * file in place and never touches its mode, so this control cannot go red against the code it
	 * replaces. It guards the REPAIR instead — a rename installs a temporary created under the
	 * process umask, so without `stageWrite`'s mode copy an 0755 file comes back 0644. Proved by
	 * MUTATION: dropping the `chmodSync` line flips this test, and of the six here only this one.
	 *
	 * Asserted together with the rewrite, so a run that did nothing cannot satisfy it.
	 *
	 * Guarded `#if (sys || nodejs)` like the rest of this file, while the copy it pins is `#if
	 * nodejs` — `sys.FileSystem` exposes no chmod. Nothing builds `Cli` for another sys target, so
	 * the two conditions cannot disagree in practice; the test's is the one stating what the seat
	 * OUGHT to do everywhere.
	 */
	public function testTheFilesModeSurvivesTheRewrite(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_stage_mode', [{ name: 'D.hx', source: DRIFTED }]);
		final target: String = '$dir/D.hx';
		Sys.command('chmod', ['755', target]);
		if (mode(target) != EXECUTABLE_MODE) {
			CliFixture.removeDir(dir);
			Assert.pass('this filesystem does not carry permission bits — skipped');
			return;
		}
		Assert.equals(0, Cli.run(['fmt', target, '--write']));
		Assert.notEquals(DRIFTED, File.getContent(target), 'the file was actually rewritten');
		Assert.equals(EXECUTABLE_MODE, mode(target), 'and came back with the mode it had');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A symlinked target stays a symlink, and its file gets the bytes.
	 *
	 * GREEN AT BASE BY CONSTRUCTION, like the mode control above: `File.saveContent` writes
	 * THROUGH a symlink, while a rename replaces it with a regular file and the link is gone.
	 * `stageWrite` resolves the path first so the rename lands on the file the in-place write would
	 * have hit. Proved by MUTATION: dropping the `FileSystem.fullPath` resolution flips this test,
	 * and of the six here only this one.
	 */
	public function testASymlinkedTargetStaysASymlink(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_stage_link', [{ name: 'D.hx', source: DRIFTED }]);
		final link: String = '$dir/L.hx';
		if (Sys.command('ln', ['-s', 'D.hx', link]) != 0 || Sys.command('test', ['-L', link]) != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('this host does not make symlinks — skipped');
			return;
		}
		Assert.equals(0, Cli.run(['fmt', link, '--write']));
		Assert.equals(0, Sys.command('test', ['-L', link]), 'the link is still a link');
		Assert.notEquals(DRIFTED, File.getContent('$dir/D.hx'), 'and the file it points at carries the rewrite');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `chmod 444` still stops a write, which a bare stage-and-rename would not have.
	 *
	 * `rename(2)` needs write permission on the DIRECTORY, not on the file, so a naked
	 * stage-and-rename silently replaces a read-only file that `File.saveContent` refuses — measured
	 * on node directly: the in-place write threw `EACCES`, the temporary and rename succeeded and
	 * left the file at 0644. `stageWrite` asks the kernel the same question by opening the target for
	 * append, which writes nothing.
	 *
	 * GREEN AT BASE BY CONSTRUCTION, and deliberately so: it is driven through `fmt`, the one op that
	 * already caught its write, so the base run reports the same refusal for a different reason. Its
	 * whole job is to stop the rename from taking that refusal away, and the only proof of that is
	 * the MUTATION — with the append probe removed the run exits 0 and the locked file comes back
	 * rewritten and 0644. That mutation flips the two run-level pins with it, because `chmod 444` is
	 * the unwritable condition all three are built on; it is the class doc that carries the full
	 * mutation table.
	 */
	public function testAReadOnlyFileIsStillRefused(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_stage_ro', [{ name: 'D.hx', source: DRIFTED }]);
		final target: String = '$dir/D.hx';
		if (skipWithoutWriteBarrier(dir, target)) return;
		Assert.notEquals(0, Cli.run(['fmt', target, '--write']));
		Assert.equals(DRIFTED, File.getContent(target), 'the read-only file keeps every byte it had');
		unlockAndRemove(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Three canonical files with one `unused-local` each: `lint --fix` rewrites all three, so a count of changed files measures the run. */
	private static function fixtureTree(): String {
		return CliFixture.writeDir('apq_stage_set', [
			{ name: 'A.hx', source: fixable('A') },
			{ name: 'B.hx', source: fixable('B') },
			{ name: 'C.hx', source: fixable('C') }
		]);
	}

	/** One canonical module named `name` carrying exactly one `unused-local` finding. */
	private static function fixable(name: String): String {
		return 'class $name {\n\n\tpublic function new() {}\n\n\tpublic function foo():Int {\n\t\tfinal unusedLocal:Int = 5;'
			+ '\n\t\treturn 1;\n\t}\n\n}\n';
	}

	/** `path`'s permission bits. */
	private static function mode(path: String): Int {
		return FileSystem.stat(path).mode & PERMISSION_BITS;
	}

	/**
	 * Make `path` read-only, or tear the fixture down and pass — a run as root has no write
	 * barrier to test against, which is the same guard the `fmt` count pins carry.
	 */
	private static function skipWithoutWriteBarrier(dir: String, path: String): Bool {
		Sys.command('chmod', ['444', path]);
		if (Sys.command('test', ['-w', path]) != 0) return false;
		unlockAndRemove(dir);
		Assert.pass('chmod 444 is not a write barrier here (running as root?) — skipped');
		return true;
	}

	/** Unlock everything under `dir` so the recursive delete can remove it, then delete it. */
	private static function unlockAndRemove(dir: String): Void {
		if (FileSystem.exists(dir)) for (entry in FileSystem.readDirectory(dir)) Sys.command('chmod', ['644', '$dir/$entry']);
		CliFixture.removeDir(dir);
	}

	/** Every `.hx` under `dir`, by path. */
	private static function snapshot(dir: String): Map<String, String> {
		final out: Map<String, String> = [];
		for (entry in FileSystem.readDirectory(dir)) if (entry.endsWith('.hx')) out['$dir/$entry'] = File.getContent('$dir/$entry');
		return out;
	}

	/** How many of `before`'s files hold different bytes now. */
	private static function changedSince(before: Map<String, String>): Int {
		var changed: Int = 0;
		for (path => source in before) if (File.getContent(path) != source) changed++;
		return changed;
	}

	/** Staging temporaries still sitting in `dir` — every write path is supposed to remove its own. */
	private static function stagedLeftovers(dir: String): Int {
		var left: Int = 0;
		for (entry in FileSystem.readDirectory(dir)) if (entry.endsWith('.apq-tmp')) left++;
		return left;
	}
	#end

}
