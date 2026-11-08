package unit.dev;

import anyparse.check.LintConfig;
import anyparse.check.oracle.OracleCache;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.OracleProvider.OracleOutcome;
import dev.Binaries;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
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
			final oracle: OracleConfig = LintConfig.discover(Path.join([tree, 'apq.json'])).compilerOracles(new HaxeQueryPlugin())[0];
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
		final oracle: OracleConfig = LintConfig.discover(Path.join([tree, 'apq.json'])).compilerOracles(new HaxeQueryPlugin())[0];
		return OracleCache.fingerprint(oracle.hxml, oracle.dir, oracle.defines);
	}

	/** The verdict stored for the project's declared build under `fingerprint`. */
	private static function held(tree: String, fingerprint: String): Null<OracleOutcome> {
		final oracle: OracleConfig = LintConfig.discover(Path.join([tree, 'apq.json'])).compilerOracles(new HaxeQueryPlugin())[0];
		return OracleCache.lookup(oracle.hxml, oracle.dir, fingerprint, oracle.defines);
	}

}
