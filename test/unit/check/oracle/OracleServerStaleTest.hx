package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.OracleServerPool;

/**
 * A warm server's green is believed only when every change the run made reached the server. `server/invalidate` reaches a
 * module the server holds; it cannot reach an ambient import file that appears or vanishes, a module that appears in front
 * of one the server resolved, or a file a macro reads, so the pool replaces the server then. Each test compiles through a
 * real server, changes the tree so that a cold compile is red, and asks for the compile again. Only the two moves the
 * compiler never notices itself are controls: it tracks an `import.hx` it read, and checks a shadowing module by a directory
 * time of whole-second granularity, so those two are guards a cut of the pool's rule does not always turn red.
 */
final class OracleServerStaleTest extends Test {

	private static final HXML: String = '-cp .\n-main Main\n--no-output\n';
	private static final MAIN: String = 'class Main {\n\tstatic function main() {\n\t\tfinal n: Int = Val.x;\n\t\ttrace(n);\n\t}\n}\n';
	private static final INT_VAL: String = 'class Val {\n\tpublic static final x: Int = 1;\n}\n';
	private static final STRING_VAL: String = 'class Val {\n\tpublic static final x: String = "s";\n}\n';
	private static final IMPORT_OTHER_VAL: String = 'import other.Val;\n';

	@:pin('control')
	@:killer('M-POOL-INVALIDATION-REACHES-EVERYTHING')
	public function testAnAmbientImportFileThatAppearsIsSeen(): Void {
		final after: Null<HaxeRun> = compiledAfter([
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Val.hx', source: INT_VAL },
			{ name: 'other/Val.hx', source: 'package other;\n\n$STRING_VAL' },
			{ name: 'build.hxml', source: HXML }
		], ['import.hx'], root -> sys.io.File.saveContent('$root/import.hx', IMPORT_OTHER_VAL));
		assertRed(after, 'an import file created in the source root rebinds Val, which a stale server does not see');
	}

	@:pin('guard')
	public function testAnAmbientImportFileThatVanishesIsSeen(): Void {
		final after: Null<HaxeRun> = compiledAfter([
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Val.hx', source: STRING_VAL },
			{ name: 'other/Val.hx', source: 'package other;\n\n$INT_VAL' },
			{ name: 'import.hx', source: IMPORT_OTHER_VAL },
			{ name: 'build.hxml', source: HXML }
		], ['import.hx'], root -> sys.FileSystem.deleteFile('$root/import.hx'));
		assertRed(after, 'without its import file Val is the one beside Main, which a stale server does not see');
	}

	@:pin('guard')
	public function testAModuleThatAppearsInFrontOfTheOneResolvedIsSeen(): Void {
		final after: Null<HaxeRun> = compiledAfter([
			{ name: 'front/Marker.hx', source: 'class Marker {}\n' },
			{ name: 'back/Main.hx', source: MAIN },
			{ name: 'back/Val.hx', source: INT_VAL },
			{ name: 'build.hxml', source: '-cp back\n-cp front\n-main Main\n--no-output\n' }
		], ['front/Val.hx'], root -> sys.io.File.saveContent('$root/front/Val.hx', STRING_VAL));
		assertRed(after, 'a module in a root searched first hides the one Main resolved before');
	}

	@:pin('control')
	@:killer('M-POOL-INVALIDATION-REACHES-EVERYTHING')
	public function testAFileAMacroReadsThatMovesIsSeen(): Void {
		final after: Null<HaxeRun> = compiledAfter([
			{
				name: 'Main.hx',
				source: '@:build(Reader.check())\nclass Main {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n'
			},
			{
				name: 'Reader.hx',
				source: 'import haxe.macro.Context;\n\nclass Reader {\n\tpublic static function check() {\n'
				+ '\t\tif (sys.io.File.getContent("data.json") != "ok") Context.error("data says no", Context.currentPos());\n'
				+ '\t\treturn null;\n\t}\n}\n'
			},
			{ name: 'data.json', source: 'ok' },
			{ name: 'build.hxml', source: HXML }
		], ['data.json'], root -> sys.io.File.saveContent('$root/data.json', 'no'));
		assertRed(after, 'a macro read a file that is no module: invalidating it reaches nothing');
	}

	/**
	 * The compile through a warm server after `change` of a tree the server compiled green: a pool over the tree `files`
	 * writes whose written paths are `watched` (relative to the tree), null when no server answered.
	 */
	private static function compiledAfter(
		files: Array<{ name: String, source: String }>, watched: Array<String>, change: (root:String) -> Void
	): Null<HaxeRun> {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_stale', files);
		final config: OracleConfig = { hxml: 'build.hxml', dir: root, defines: [] };
		final pool: OracleServerPool = new OracleServerPool(() -> watched.map(path -> '$root/$path'));
		var after: Null<HaxeRun> = null;
		CliFixture.always(() -> {
			pool.stop();
			CliFixture.removeDir(root);
		}, () -> {
			pool.start([config]);
			Assert.isTrue(pool.running(), 'a server came up');
			Assert.equals(0, pool.compile([config])[0]?.status, 'the tree starts green');
			change(root);
			after = pool.compile([config])[0];
		});
		return after;
		#else
		return null;
		#end
	}

	private static function assertRed(run: Null<HaxeRun>, why: String): Void {
		#if nodejs
		Assert.notNull(run, 'a server answered');
		Assert.isTrue(run != null && run.status != 0, why);
		#else
		Assert.pass('non-node target');
		#end
	}

}
