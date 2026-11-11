package unit.cli;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.query.Cli;
import anyparse.query.FormatConfigDiscovery;

using StringTools;

/**
 * `apq: <hxformat.json>: N key(s) hxq does not implement …` is printed by `FormatConfigDiscovery.discover`, once per
 * config PATH per run through the run's `RunLedger`, while the discovery itself is memoised by DIRECTORY.
 *
 * The two keys differ on purpose, so a fixture that puts every file in the SAME directory as the config cannot tell
 * working dedup from none: the second file is a memo hit of the first's directory. The once-per-run pin therefore uses
 * TWO directories that walk up to the SAME `hxformat.json` (`dir/A.hx` and `dir/sub/B.hx`, no config in `sub/`), so only
 * the ledger's per-path dedup holds the count at one.
 *
 * The other half: the memo outlives a run and the ledger does not, so a later run in the same engine process reports a
 * config the memo already holds.
 */
@:nullSafety(Strict)
class ApqFmtConfigWarnCliTest extends Test {

	/** The config text both report fixtures share: one unknown key and one unreadable value. */
	private static final BAD_CONFIG: String = '{"indentation": {"character": "space"}, "noSuchKnob": 1}';

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
		final named: Array<String> = FormatConfigDiscovery.reportedPaths().filter(p -> p.indexOf(dir) >= 0);
		Assert.equals(1, named.length, 'expected exactly one reported config path under $dir, got ${named.join(', ')}');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A second run over a directory the memo already answers still reports the config: what a run has said is the run's. */
	@:pin('control')
	@:killer('M-FMT-CONFIG-MEMO-HIT-SILENT')
	public function testALaterRunReportsAConfigTheMemoAlreadyHolds(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('cfgwarn_rerun', [
			{ name: 'hxformat.json', source: '{"noSuchKnobAtAll": 1}' },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		Assert.equals(0, Cli.run(['fmt', '--list', '$dir/A.hx']));
		Assert.equals(0, Cli.run(['fmt', '--list', '$dir/A.hx']), 'the second run reads the memoised directory');
		final named: Array<String> = FormatConfigDiscovery.reportedPaths().filter(p -> p.indexOf(dir) >= 0);
		Assert.equals(1, named.length, 'the second run reported nothing about the config under $dir');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * `writer-equals --config` names its config file itself, outside the input's ancestor chain, and that file is reported like a
	 * discovered one: once, by its path, with the unreadable indent among its clauses.
	 */
	@:pin('control')
	@:killer('M-WRITER-EQUALS-CONFIG-UNREPORTED')
	public function testWriterEqualsReportsTheConfigItIsHanded(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('cfgwarn_writer_equals', [
			{ name: 'A.hx', source: 'class A {}\n' },
			{ name: 'exp.hx', source: 'class A {}\n' }
		]);
		final cfgDir: String = '$dir-cfg';
		sys.FileSystem.createDirectory(cfgDir);
		sys.io.File.saveContent('$cfgDir/my.json', BAD_CONFIG);
		final stderr: String = CliFixture.captureStderr(() ->
			Cli.run(['writer-equals', '--config', '$cfgDir/my.json', '$dir/A.hx', '$dir/exp.hx'])
		);
		final lines: Array<String> = reportLines(stderr, '$cfgDir/my.json');
		Assert.equals(1, lines.length, 'expected one report line naming $cfgDir/my.json, got: $stderr');
		Assert.stringContains('indentation.character "space"', lines.join('\n'));
		CliFixture.removeDir(cfgDir);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only: stderr is captured through fs.writeSync');
		#end
	}

	/** A run over two files under one config prints ONE line for it on stderr, with every clause the config earns. */
	@:pin('control')
	@:killer('M-FMT-CONFIG-REPORT-UNPRINTED')
	public function testTheReportIsOneLineWithEveryClause(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('cfgwarn_one_line', [
			{ name: 'hxformat.json', source: BAD_CONFIG },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		sys.FileSystem.createDirectory('$dir/sub');
		sys.io.File.saveContent('$dir/sub/B.hx', 'class B {}\n');
		final stderr: String = CliFixture.captureStderr(() -> Cli.run(['fmt', '--list', '$dir/A.hx', '$dir/sub/B.hx']));
		final lines: Array<String> = reportLines(stderr, dir);
		Assert.equals(1, lines.length, 'expected one report line, got: $stderr');
		Assert.stringContains('noSuchKnob', lines.join('\n'));
		Assert.stringContains('indentation.character "space"', lines.join('\n'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only: stderr is captured through fs.writeSync');
		#end
	}

	/** The silence switch silences the whole report, the unreadable indent included. */
	@:pin('control')
	@:killer('M-FMT-CONFIG-SILENCE-IGNORED')
	public function testTheSilenceSwitchSilencesTheReport(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('cfgwarn_silenced', [
			{ name: 'hxformat.json', source: BAD_CONFIG },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		final before: Null<String> = Sys.getEnv(HaxeFormatConfigDiagnostics.SILENCE_VAR);
		Sys.putEnv(HaxeFormatConfigDiagnostics.SILENCE_VAR, '1');
		final stderr: String = CliFixture.captureStderr(() -> Cli.run(['fmt', '--list', '$dir/A.hx']));
		Sys.putEnv(HaxeFormatConfigDiagnostics.SILENCE_VAR, before ?? '');
		Assert.same([], reportLines(stderr, dir), 'the silenced run still reported: $stderr');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only: stderr is captured through fs.writeSync');
		#end
	}

	/** The `apq: ` config-report lines of `stderr` that name a path under `dir`. */
	private static function reportLines(stderr: String, dir: String): Array<String> {
		return stderr.split('\n').filter((line: String) -> line.startsWith('apq: ') && line.indexOf(dir) >= 0);
	}

}
