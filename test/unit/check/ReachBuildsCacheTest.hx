package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage;
import anyparse.check.ReachBuildsCache;
import anyparse.query.Cli;
import anyparse.query.ReachLiveness.ReachBuilds;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The builds an oracle run probed, read back by a run that compiles nothing (`--no-oracle`) only while the compile input
 * hashes as it did. The fixture is the shape the builds decide: an enum abstract whose `#else` branch, which no declared
 * build takes, aliases a target type, so the value passed is of the abstract only when the run knows the builds.
 */
class ReachBuildsCacheTest extends Test {

	#if (sys || nodejs)
	private static final ENUM: String =
		'package lib;\n\n#if !flash\nenum abstract E(Int) {\n\tvar X = 1;\n}\n#else\ntypedef E = flash.Other;\n#end\n';
	private static final MAKER: String = 'import lib.E;\n\nclass W {\n\tpublic static function make(?w:Float, ?e:E, ?hint:String):Void\n'
		+ '\t\tif (hint != null) Sys.sleep(1);\n}\n';
	private static final MAIN: String = 'import lib.E;\n\nclass Main {\n\tstatic function main():Void\n\t\tW.make(1, E.X);\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static final RULES: String =
		'"resolutionRoots":["."],"reachConfigurationsComplete":true,"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}';
	#end

	/**
	 * A tree no oracle run has seen knows no build, so the alias branch is read and the sleep is reached; the oracle run
	 * knows the build and reaches nothing, and a `--no-oracle` run after it answers the same from what it stored.
	 */
	@:pin('control') @:killer('M-REACH-STORED-UNREAD') @:killer('M-REACH-STORE-OFF')
	public function testANoOracleRunReadsTheBuildsAnOracleRunStored(): Void {
		#if nodejs
		final dir: Null<String> = tree('stored', '{"compilerOracle":[{"hxml":"check.hxml"}],$RULES}');
		if (dir == null) return;
		Assert.isTrue(sleeps(dir, true), 'no oracle run yet: no build known');
		Assert.isFalse(sleeps(dir, false), 'the oracle run knows the build');
		Assert.isFalse(sleeps(dir, true), 'the next run reads the builds it stored');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * A source edited after the oracle run, or an hxml, or the configuration's defines, is another compile input: the
	 * stored builds are not read and the run knows no build. The source restored hashes as stored again.
	 */
	@:pin('control') @:killer('M-REACH-KEY-UNCHECKED')
	public function testAnEditedInputIsNotReadFromTheStore(): Void {
		#if nodejs
		final dir: Null<String> = tree('edited', '{"compilerOracle":[{"hxml":"check.hxml"}],$RULES}');
		if (dir == null) return;
		Assert.isFalse(sleeps(dir, false));
		File.saveContent('$dir/W.hx', '$MAKER// edited\n');
		Assert.isTrue(sleeps(dir, true), 'an edited source');
		File.saveContent('$dir/W.hx', MAKER);
		Assert.isFalse(sleeps(dir, true), 'the source restored');
		File.saveContent('$dir/check.hxml', '$HXML-D apq_reach_edited\n');
		Assert.isTrue(sleeps(dir, true), 'an edited hxml');
		File.saveContent('$dir/check.hxml', HXML);
		File.saveContent('$dir/apqlint.json', '{"compilerOracle":[{"hxml":"check.hxml","defines":["apq_reach_edited"]}],$RULES}');
		Assert.isTrue(sleeps(dir, true), 'a configuration with another define');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * A generated hxml whose declared input changed is not current, whatever the hxml holds: the oracle run would
	 * generate it again, so the builds stored for the old generation are not read.
	 */
	@:pin('control') @:killer('M-REACH-GENERATION-UNCHECKED')
	public function testAGenerationNoLongerCurrentIsNotReadFromTheStore(): Void {
		#if nodejs
		final generated: String =
			'"compilerOracle":[{"hxml":"check.hxml","generate":"cp base.hxml check.hxml","generateInputs":["base.hxml"]}]';
		final dir: Null<String> = tree('generated', '{$generated,$RULES}');
		if (dir == null) return;
		File.saveContent('$dir/base.hxml', HXML);
		Assert.isFalse(sleeps(dir, false));
		Assert.isFalse(sleeps(dir, true), 'the generation is current');
		File.saveContent('$dir/base.hxml', '$HXML# edited\n');
		Assert.isTrue(sleeps(dir, true), 'its input changed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * A build that parsed a file outside the directories the fingerprint walked is not stored, since that file can change
	 * with no fingerprint changing; and a stored library source that no longer hashes as it did is not read.
	 */
	@:pin('control') @:killer('M-REACH-ROOTS-UNCHECKED') @:killer('M-REACH-LIBRARY-UNCHECKED')
	public function testAReadTheFingerprintCannotSeeIsNeitherStoredNorRead(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree('roots', '{"compilerOracle":[{"hxml":"check.hxml"}],$RULES}');
		if (dir == null) return;
		final outside: String = CliFixture.writeTree('rootsoutside', [{ name: 'Far.hx', source: 'class Far {}\n' }]);
		final oracles: Array<OracleConfig> = [{ hxml: '$dir/check.hxml', dir: dir, defines: [] }];
		final far: String = OracleCoverage.canonical(outside, 'Far.hx');
		ReachBuildsCache.store(oracles, ReachBuildsCache.fingerprint(oracles), builds(far, far));
		Assert.isNull(ReachBuildsCache.load(oracles), 'a read outside is not stored');
		ReachBuildsCache.store(oracles, ReachBuildsCache.fingerprint(oracles), builds(OracleCoverage.canonical(dir, 'Main.hx'), far));
		final read: Null<ReachBuilds> = ReachBuildsCache.load(oracles);
		if (read == null) {
			Assert.fail('the stored builds are read');
			return;
		}
		Assert.equals('interp', read.configurations[0].values['target.name']);
		Assert.same([{ name: 'Far', file: far }], read.configurations[0].types);
		Assert.same([{ file: far, source: 'class Far {}\n' }], read.library);
		File.saveContent(far, 'class Far { static var x:Int = 1; }\n');
		Assert.isNull(ReachBuildsCache.load(oracles), 'a library source edited');
		CliFixture.removeDir(outside);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The fixture tree with `apqlint`, or null (after passing) where no compiler typechecks it. */
	private static function tree(name: String, apqlint: String): Null<String> {
		final dir: String = CliFixture.writeTree('reachcache$name', [
			{ name: 'lib/E.hx', source: ENUM },
			{ name: 'W.hx', source: MAKER },
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	/** Whether a thread-safety lint of `dir` — compiling nothing when `noOracle` — reaches the sleep. */
	private static function sleeps(dir: String, noOracle: Bool): Bool {
		final args: Array<String> = ['lint', '--rule', 'thread-safety'].concat(noOracle ? ['--no-oracle'] : []).concat([dir]);
		final out: String = CliFixture.captureStdout(() -> CliFixture.captureStderr(Cli.run.bind(args)));
		return out.indexOf('blocking "Sys.sleep"') >= 0;
	}

	/** One interp build that parsed `parsed` and typed `Far` in `library`, whose source is read from disk. */
	private static function builds(parsed: String, library: String): ReachBuilds {
		return {
			configurations: [
				{
					name: 'check.hxml',
					defined: ['interp'],
					everDefined: ['interp'],
					values: ['target.name' => 'interp'],
					compiled: [library],
					types: [{ name: 'Far', file: library }],
					parsed: [parsed]
				}
			],
			library: [{ file: library, source: File.getContent(library) }]
		};
	}
	#end

}
