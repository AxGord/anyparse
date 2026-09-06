package unit.cli;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq lit` (and the shared `CliWalk.effectiveAutoLimit` / `limitEntries` / `reportCapHit` seam it
 * and six sibling walkers go through) truncates by `--limit` SILENTLY and in file order — an
 * explicit `--limit 40` over a big scope can cut the visible output at some alphabetically early
 * file with nothing on stderr to say so (S106 chased a structure that did not exist because of
 * exactly this — the census needed `--limit 9999`, and nothing told it to). `reportCapHit` is the
 * fix: one stderr line naming the cap, how many files made it into the output, how many files the
 * scan scope held, and the last file whose hits are shown — stdout and the exit code untouched.
 *
 * Three fixture files each carry two hits of the same literal, so the cap boundary lands
 * predictably: `--limit 3` keeps A whole (2 hits) and trims B to 1, dropping C entirely.
 */
@:nullSafety(Strict)
class ApqLitCapHitCliTest extends Test {

	// --- branch 1: the cap IS hit — files/hits beyond it are silently dropped without this note ---

	public function testCapHitNamesTheLimitFilesAndLastFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_lit_cap_hit', [needleFile('A'), needleFile('B'), needleFile('C')]);
		var code: Int = -1;
		var out: String = '';
		final err: String = CliFixture.captureStderr(() ->
			out = CliFixture.captureStdout(() -> code = Cli.run(['lit', 'needle', dir, '--limit', '3']))
		);
		Assert.equals(0, code, err);
		Assert.stringContains('apq lit: stopped at --limit 3 after 2 of 3 files (last: $dir/B.hx)', err, err);
		Assert.stringContains('pass a larger --limit for a census', err, err);
		Assert.stringContains('A.hx', out, 'a file that fits under the cap is still shown on stdout');
		Assert.isFalse(out.indexOf('C.hx') >= 0, 'a file the cap never reached must not appear on stdout: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	// --- branch 2: the cap is NOT hit — a limit wide enough to hold every hit must stay silent ---

	public function testUnderTheCapStaysSilent(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_lit_cap_not_hit', [needleFile('A'), needleFile('B'), needleFile('C')]);
		var code: Int = -1;
		var out: String = '';
		final err: String = CliFixture.captureStderr(() ->
			out = CliFixture.captureStdout(() -> code = Cli.run(['lit', 'needle', dir, '--limit', '100']))
		);
		Assert.equals(0, code, err);
		Assert.isFalse(err.indexOf('stopped at --limit') >= 0, 'a limit that holds every hit must not report a cap: $err');
		Assert.stringContains('C.hx', out, 'every file fits under a generous limit');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	// --- branch 3: `--limit 0` is the documented zero-hits trap — the note must still fire ---

	public function testLimitZeroStillNamesTheCapAsZero(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_lit_cap_zero', [needleFile('A'), needleFile('B'), needleFile('C')]);
		var code: Int = -1;
		var out: String = '';
		final err: String = CliFixture.captureStderr(() ->
			out = CliFixture.captureStdout(() -> code = Cli.run(['lit', 'needle', dir, '--limit', '0']))
		);
		Assert.equals(0, code, 'hits exist even though --limit 0 shows none, so the walk still reports "found something": $err');
		Assert.stringContains('apq lit: stopped at --limit 0 after 0 of 3 files', err, err);
		Assert.equals(
			'', out, '--limit 0 already showed nothing on stdout before this slice; the new stderr note must not change that: $out'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	private static inline function needleFile(name: String): { name: String, source: String } {
		return { name: '$name.hx', source: 'class $name { var s1:String = "needle"; var s2:String = "needle"; }' };
	}

}
