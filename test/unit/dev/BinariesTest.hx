package unit.dev;

import anyparse.check.LintConfig;
import anyparse.check.haxe.oracle.OracleCache;
import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.OracleProvider.OracleOutcome;
import dev.Binaries;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import testkit.TestConfigs;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `Binaries.compileBuilds` hands the oracle what its builds proved: a declared build that compiled green is a stored
 * `Confirmed` under the content fingerprint, so a lint over the same content reads it instead of compiling again.
 */
@:nullSafety(Strict)
final class BinariesTest extends Test {

	private static final GOOD: String = 'class Good {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final BROKEN: String = 'class Good {\n\tstatic function main() {\n\t\tMac.m();\n\t\tvar x:Int = "no";\n\t}\n}\n';

	/** A module with a macro: a compile with `-v` prints a line per macro it types, which a quote must not pick up. */
	private static final MACRO: String =
		'import haxe.macro.Expr;\n\nclass Mac {\n\tpublic static macro function m(): Expr {\n\t\treturn macro null;\n\t}\n}\n';

	public function testAGreenDeclaredBuildIsStoredAsTheOraclesVerdict(): Void {
		TempDir.with(dir -> {
			final tree: String = project(dir, GOOD);
			final fingerprint: Null<String> = fingerprintOf(tree);
			if (fingerprint == null) {
				Assert.pass('no compiler probe on this host');
				return;
			}
			Assert.isNull(held(tree, fingerprint), 'nothing is known before the build');
			Assert.isTrue(Binaries.compileBuilds(tree, dir.file('build.log'), [['check.hxml', '--no-output']], Unpooled).match(Passed));
			Assert.isTrue(held(tree, fingerprint)?.match(Confirmed) == true, 'the build is the oracle\'s Confirmed');
		});
	}

	public function testARedBuildAndAnUndeclaredOneStoreNothing(): Void {
		TempDir.with(dir -> {
			final tree: String = project(dir, BROKEN);
			final fingerprint: Null<String> = fingerprintOf(tree);
			if (fingerprint == null) {
				Assert.pass('no compiler probe on this host');
				return;
			}
			switch Binaries.compileBuilds(tree, dir.file('red.log'), [['check.hxml', '--no-output']], Unpooled) {
				case Failed(why):
					Assert.stringContains('should be Int', why, 'a red build quotes the compiler\'s error');
					Assert.isFalse(why.contains('Parsed ') || why.contains('Typing macro'), 'not a line of the -v chatter');
				case other:
					Assert.fail('a broken build must fail, got $other');
			}
			final logged: String = File.getContent(dir.file('red.log'));
			Assert.isFalse(logged.contains('Parsed ') || logged.contains('Typing macro'), 'the -v chatter stays out of the log');
			Assert.isNull(held(tree, fingerprint), 'a red build is not stored');
			File.saveContent(Path.join([tree, 'Good.hx']), GOOD);
			File.saveContent(Path.join([tree, 'other.hxml']), '-cp .\n-main Good\n');
			final other: Null<String> = OracleCache.fingerprint('other.hxml', tree);
			Assert.isTrue(Binaries.compileBuilds(tree, dir.file('other.log'), [['other.hxml', '--no-output']], Unpooled).match(Passed));
			Assert.isNull(
				other == null ? null : OracleCache.lookup('other.hxml', tree, other), 'a build the project does not declare is not stored'
			);
		});
	}

	public function testABuildDeclaredOnlyWithDefinesStoresNothing(): Void {
		TempDir.with(dir -> {
			final tree: String = project(dir, GOOD, '{"compilerOracle":[{"hxml":"check.hxml","defines":["flag"]}]}');
			final oracle: OracleConfig = TestConfigs.oracles(TestConfigs.discover(Path.join([tree, 'apq.json'])), new HaxeQueryPlugin())[0];
			final withDefines: Null<String> = OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines);
			final plain: Null<String> = OracleCache.fingerprint(oracle.hxml, oracle.dir);
			if (withDefines == null || plain == null) {
				Assert.pass('no compiler probe on this host');
				return;
			}
			Assert.isTrue(Binaries.compileBuilds(tree, dir.file('defines.log'), [['check.hxml', '--no-output']], Unpooled).match(Passed));
			Assert.isNull(OracleCache.lookup(oracle.hxml, oracle.dir, withDefines, oracle.defines), 'not under its defines');
			Assert.isNull(OracleCache.lookup(oracle.hxml, oracle.dir, plain), 'nor under the plain key');
		});
	}

	/** A build leaf stands for the typecheck leaf the project declares (`checkOf`): its green is that configuration's verdict. */
	public function testABuildLeafsGreenIsTheVerdictOfItsDeclaredTypecheckLeaf(): Void {
		TempDir.with(dir -> {
			final tree: String = project(dir, GOOD, '{"compilerOracle":"leaf-check.hxml"}');
			File.saveContent(Path.join([tree, 'leaf.hxml']), '-cp .\n-main Good\n-D codegen\n');
			File.saveContent(Path.join([tree, 'leaf-check.hxml']), '-cp .\n-main Good\n');
			final fingerprint: Null<String> = fingerprintOf(tree);
			if (fingerprint == null) {
				Assert.pass('no compiler probe on this host');
				return;
			}
			Assert.isNull(held(tree, fingerprint), 'nothing is known before the build');
			Assert.isTrue(Binaries.compileBuilds(tree, dir.file('leaf.log'), [['leaf.hxml', '--no-output']], Unpooled).match(Passed));
			Assert.isTrue(held(tree, fingerprint)?.match(Confirmed) == true, 'the leaf\'s build is the typecheck leaf\'s Confirmed');
		});
	}

	/** The builds that run at once hold one thread each when each leases its own, the caller's lease under one, and nothing unpooled. */
	@:pin('control')
	@:killer('M-BINARIES-HELD-BY-OWN')
	public function testTheBuildsHoldTheThreadsTheirModeLeases(): Void {
		Assert.equals(1, Binaries.heldBy(Own('/p/scripts/wf-run', 10), 1));
		Assert.equals(2, Binaries.heldBy(Own('/p/scripts/wf-run', 10), 3));
		Assert.equals(4, Binaries.heldBy(Held(4), 3));
		Assert.isNull(Binaries.heldBy(Unpooled, 3));
	}

	/** The threads of the builds that run: one each under their own lease, the caller's as it stands, none unpooled or with no build. */
	@:pin('control')
	@:killer('M-BINARIES-HELD-ZERO-BUILDS')
	public function testNoBuildHoldsNoThreads(): Void {
		Assert.equals(2, Binaries.heldBy(Own('/p/scripts/wf-run', 8), 3));
		Assert.equals(4, Binaries.heldBy(Held(4), 2));
		Assert.isNull(Binaries.heldBy(Unpooled, 2));
		Assert.isNull(Binaries.heldBy(Own('/p/scripts/wf-run', 8), 0));
		Assert.isNull(Binaries.heldBy(Held(4), 0));
	}

	/**
	 * At most `Binaries.WIDTH` of a tree's builds run at once under their own
	 * leases: the longest fills the wall, the others follow one another beside it.
	 */
	@:pin('control')
	@:killer('M-BINARIES-BUILD-WIDTH-UNBOUNDED')
	public function testThreeBuildsRunTwoAtOnceUnderTheirOwnLeases(): Void {
		TempDir.with(dir -> {
			final log: String = dir.file('builds.log');
			final wfRun: String = pausingWfRun(dir, log);
			final tree: String = dir.file('tree');
			FileSystem.createDirectory(tree);
			File.saveContent(Path.join([tree, 'apq.json']), '{}');
			Assert.isTrue(
				Binaries.compileBuilds(tree, dir.file('build.log'), [['a.hxml'], ['b.hxml'], ['c.hxml']], Own(wfRun, 8)).match(Passed)
			);
			var running: Int = 0;
			var most: Int = 0;
			var started: Int = 0;
			for (line in File.getContent(log).trim().split('\n')) {
				running += line == 's' ? 1 : -1;
				if (line == 's') started++;
				if (running > most) most = running;
			}
			Assert.equals(3, started);
			Assert.equals(Binaries.WIDTH, most);
		});
	}

	/** Only builds under their own leases are capped at `Binaries.WIDTH`: a caller's lease or no pool starts every build at once. */
	@:pin('control')
	@:killer('M-BINARIES-WIDTH-CAPS-HELD')
	public function testOnlyOwnLeasesCapTheBuildsStartedTogether(): Void {
		Assert.equals(2, Binaries.width(Own('/p/scripts/wf-run', 8), 3));
		Assert.equals(3, Binaries.width(Held(4), 3));
		Assert.equals(3, Binaries.width(Unpooled, 3));
	}

	/** A project of `source` as `Good.hx`, its `check.hxml`, and the `apq.json` that declares that build. */
	private static function project(dir: TempDir, source: String, config: String = '{"compilerOracle":"check.hxml"}'): String {
		final tree: String = dir.file('tree');
		FileSystem.createDirectory(tree);
		File.saveContent(Path.join([tree, 'Good.hx']), source);
		File.saveContent(Path.join([tree, 'Mac.hx']), MACRO);
		File.saveContent(Path.join([tree, 'check.hxml']), '-cp .\n-main Good\n');
		File.saveContent(Path.join([tree, 'apq.json']), config);
		return tree;
	}

	/** The fingerprint the project's declared build has now, as a lint would take it. */
	private static function fingerprintOf(tree: String): Null<String> {
		final oracle: OracleConfig = TestConfigs.oracles(TestConfigs.discover(Path.join([tree, 'apq.json'])), new HaxeQueryPlugin())[0];
		return OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines);
	}

	/** The verdict stored for the project's declared build under `fingerprint`. */
	private static function held(tree: String, fingerprint: String): Null<OracleOutcome> {
		final oracle: OracleConfig = TestConfigs.oracles(TestConfigs.discover(Path.join([tree, 'apq.json'])), new HaxeQueryPlugin())[0];
		return OracleCache.lookup(oracle.hxml, oracle.dir, fingerprint, oracle.defines);
	}

	/**
	 * A `wf-run` in `dir` that skips its own options and, in place of the
	 * build it was asked to run, appends `s` to `log`, pauses and appends `e`.
	 */
	private static function pausingWfRun(dir: TempDir, log: String): String {
		final wfRun: String = dir.file('wf-run');
		File.saveContent(wfRun, '#!/bin/sh\nwhile [ "$$1" != "--" ]; do shift; done\necho s >> $log\nsleep 1\necho e >> $log\n');
		js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wfRun);
		return wfRun;
	}

}
