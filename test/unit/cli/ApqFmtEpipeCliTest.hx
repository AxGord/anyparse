package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `apq fmt <file>` (no `--write`/`--list`) prints the formatted source to
 * stdout in one call. A downstream reader that closes early (`apq fmt f.hx
 * | head -c 1`) makes a later write to that pipe fail with `EPIPE` — before
 * `Cli.main`'s stdout/stderr `'error'` listener existed, an unhandled
 * `'error'` event on a Node stream is an uncaught exception: a raw
 * `Error: write EPIPE` stack trace on stderr and a non-zero exit, in place
 * of the quiet `rc 0` a well-behaved Unix CLI gives a closed reader.
 *
 * The discriminating pair this test asserts together — exit code AND
 * absence of the crash text — is what a fix that merely swallowed the exit
 * code (leaving the stack trace) or merely suppressed the trace (leaving a
 * non-zero exit) would each fail on one half of.
 */
@:nullSafety(Strict)
class ApqFmtEpipeCliTest extends Test {

	/**
	 * Runs `node bin/apq.js fmt <fixture> | head -c 1` under `bash -c` so
	 * `PIPESTATUS[0]` names apq's OWN exit code, not `head`'s — a plain
	 * pipeline's `$?` would read the last command's status and miss
	 * exactly the crash this test exists to catch. apq's stderr is
	 * captured separately (redirected on the LEFT side of the pipe) so
	 * an `Error: write EPIPE` stack trace is visible even though the
	 * pipeline as a whole still exits 0 via `head`.
	 */
	public function testEpipeOnStdoutExitsQuietly(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('epipe_fmt', bigFixtureSource());
		final exitFile: String = CliFixture.writeAs('epipe_fmt_exit', 'txt', '');
		final errFile: String = CliFixture.writeAs('epipe_fmt_err', 'txt', '');
		final script: String =
			'node bin/apq.js fmt "$fixture" 2>"$errFile" | head -c 1 >/dev/null; echo -n "$${PIPESTATUS[0]}" > "$exitFile"';
		js.node.ChildProcess.spawnSync('bash', ['-c', script], cast { encoding: 'utf8' });
		final exitCode: String = File.getContent(exitFile).trim();
		final stderrText: String = File.getContent(errFile);
		Assert.equals('0', exitCode, 'apq should exit 0 on a closed stdout reader, like git/cat; stderr was:\n$stderrText');
		Assert.isFalse(stderrText.contains('EPIPE'), 'stderr should carry no EPIPE crash text:\n$stderrText');
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(exitFile);
		FileSystem.deleteFile(errFile);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `apq fmt` prints its whole output in one `Sys.print` call; a source
	 * short enough to fit the pipe's kernel buffer in one write never
	 * meets a closed reader mid-write, so this needs to be comfortably
	 * larger than any plausible pipe buffer (16-64 KiB) rather than a
	 * one-line fixture.
	 */
	private static function bigFixtureSource(): String {
		final buf: StringBuf = new StringBuf();
		buf.add('class Big {\n');
		for (i in 0...5000) buf.add('\tvar f$i:Int = 0;\n');
		buf.add('}\n');
		return buf.toString();
	}

}
