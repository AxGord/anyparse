package unit.cli;

#if (sys || nodejs)
import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * T734: `apq: <hxformat.json>: N key(s) hxq does not implement …` is printed
 * by `HaxeFormatConfigDiagnostics.warn`, the sole caller of which is
 * `FormatConfigDiscovery.discover`. `warn` dedupes on its own
 * `reported: Array<String>` (a config PATH, not a source file); `discover`
 * separately memoises by DIRECTORY, and only calls `warn` on a directory
 * cache MISS — so a fixture that puts every file in the SAME directory as
 * the config never exercises `reported`'s dedup at all: the second file's
 * `discover` call returns from the directory cache before `warn` is ever
 * reached a second time, regardless of what `reported` does.
 *
 * Measured by mutation (S160 review, T734 round 2): deleting
 * `if (reported.contains(path)) return;` from `warn` entirely and rerunning
 * this class's ORIGINAL same-directory fixture still passed — proof the
 * fixture could not tell working dedup from none at all. The fix is TWO
 * DIFFERENT directories that both walk up to the SAME `hxformat.json`
 * (`dir/A.hx` and `dir/sub/B.hx`, no config in `sub/`): `sub` is a genuine
 * directory-cache miss of its own, so `discover` reaches `warn` a SECOND
 * time for the SAME config path, and only `reported`'s own dedup — not the
 * directory cache — can still hold the line count at one.
 *
 * Investigation found the dedup already correct (measured directly with
 * `apq fmt --list` on two real files, and via the JVM portability probe's
 * 482-file run — one line either way); this test is the pin so a future
 * change to the memo key (e.g. switching it to something per-directory
 * instead of per-config-path) fails loudly here instead of only reading as
 * "noisier gate transcripts".
 */
@:nullSafety(Strict)
class ApqFmtConfigWarnCliTest extends Test {

	@:access(anyparse.grammar.haxe.HaxeFormatConfigDiagnostics)
	public function testTwoFilesSharingOneBadConfigReportItOnce(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('cfgwarn_once', [
			{ name: 'hxformat.json', source: '{"noSuchKnobAtAll": 1}' },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		final subDir: String = '$dir/sub';
		sys.FileSystem.createDirectory(subDir);
		sys.io.File.saveContent('$subDir/B.hx', 'class B {}\n');
		Assert.equals(0, Cli.run(['fmt', '--list', '$dir/A.hx', '$subDir/B.hx']), 'both fixtures are already canonical');
		final named: Array<String> = HaxeFormatConfigDiagnostics.reported.filter(p -> p.indexOf(dir) >= 0);
		Assert.equals(1, named.length, 'expected exactly one reported config path under $dir, got ${named.join(', ')}');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

}
