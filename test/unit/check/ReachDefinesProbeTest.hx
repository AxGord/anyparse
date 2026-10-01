package unit.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.ReachDefinesProbe;
import anyparse.core.TempScratch;
import anyparse.query.ReachLiveness.ReachConfiguration;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `ReachDefinesProbe`: the define sets one probe transcript reports — exactly one compile arm, the set the first
 * initialization macro saw, the set once typing ended — or nothing; and the stored probe, taken again whenever the
 * compile input it was recorded for changed.
 */
@:nullSafety(Strict)
class ReachDefinesProbeTest extends Test {

	@:pin('control') @:killer('M-DEFINES-ONE-ARM')
	public function testOnlyAOneArmTranscriptWithBothSetsAnswers(): Void {
		final one: String = 'Defines: js;true\nParsed src/Main.hx\nAPQ-REACH-EARLY-DEFINES js;nodejs\nAPQ-REACH-FINAL-DEFINES js;nodejs;late\n'
			+ 'APQ-REACH-TYPE Main src/Main.hx\nAPQ-REACH-TYPE Sub src/Main.hx\nParsed src/Main.hx\n';
		final read: Null<ReachConfiguration> = ReachDefinesProbe.parse('test-js.hxml', one);
		Assert.notNull(read);
		if (read != null) {
			Assert.equals('js,nodejs', read.defined.join(','));
			Assert.equals('js,nodejs,late', read.everDefined.join(','));
			Assert.equals('src/Main.hx', read.compiled.join(','));
			Assert.equals('Main@src/Main.hx,Sub@src/Main.hx', [for (t in read.types) '${t.name}@${t.file}'].join(','));
		}
		// the macro joins the LAST arm only: an earlier arm's defines are not in the transcript
		Assert.isNull(ReachDefinesProbe.parse('two.hxml', 'Defines: js\n' + one));
		Assert.isNull(ReachDefinesProbe.parse('no-final.hxml', 'Defines: js\nAPQ-REACH-EARLY-DEFINES js\n'));
	}

	@:pin('control') @:killer('M-DEFINES-VALUES-STABLE')
	public function testAValueIsTheDefinesWhereTheFirstAndLastSetsAgree(): Void {
		// `v` holds `4.307` from the first initialization macro to the end of typing; `w` changed in between, so which value a
		// file saw depends on when it was parsed; `late` was not defined for every file at all
		final transcript: String = 'Defines: js\nAPQ-REACH-EARLY-DEFINES js;v;w\nAPQ-REACH-EARLY-VALUE ["v","4.307"]\n'
			+ 'APQ-REACH-EARLY-VALUE ["w","1"]\nAPQ-REACH-FINAL-DEFINES js;v;w;late\nAPQ-REACH-FINAL-VALUE ["v","4.307"]\n'
			+ 'APQ-REACH-FINAL-VALUE ["w","2"]\nAPQ-REACH-FINAL-VALUE ["late","1"]\n';
		final read: Null<ReachConfiguration> = ReachDefinesProbe.parse('b.hxml', transcript);
		Assert.notNull(read);
		if (read != null) Assert.equals('v=4.307', [for (k => v in read.values) '$k=$v'].join(','));
		Assert.isNull(ReachDefinesProbe.parse('broken.hxml', transcript + 'APQ-REACH-FINAL-VALUE ["v"]\n'));
	}

	@:pin('control') @:killer('M-DEFINES-VALUES-MACRO')
	public function testTheProbeReadsTheValueEachDefineCarries(): Void {
		// the compiler's own `haxe_ver`, a command-line value, and one an initialization macro changes, which has none
		final dir: String = scratchDir();
		write(dir, 'macro/Init.hx', 'class Init { public static function go() haxe.macro.Compiler.define("APQ_W", "2"); }');
		write(dir, 'src/Main.hx', 'class Main { static function main() {} }');
		write(dir, 'build.hxml', '-cp src\n-cp macro\n-main Main\n--interp\n-D APQ_V=4.5\n-D APQ_W=1\n--macro Init.go()\n');
		final read: Null<ReachConfiguration> =
			ReachDefinesProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])?.configurations[0];
		Assert.notNull(read);
		if (read != null) {
			Assert.equals('4.5', read.values['APQ_V']);
			Assert.notNull(read.values['haxe_ver']);
			Assert.isFalse(read.values.exists('APQ_W'), 'a value an initialization macro changed was read as every file\'s');
		}
		remove(dir);
	}

	@:pin('control') @:killer('M-DEFINES-EARLY')
	public function testADefineAnInitializationMacroSetsIsNotDefinedForEveryFile(): Void {
		// `first` types `B` before `second` defines `APQ_LATE`, so `B`'s `#if !APQ_LATE` IS compiled; a callback `first`
		// registers types and then defines as well. Neither name is defined for every file — both are ever defined.
		final dir: String = scratchDir();
		write(
			dir, 'macro/Init.hx',
			'class Init {\n\tpublic static function first() {\n\t\thaxe.macro.Context.getType("B");\n'
			+ '\t\thaxe.macro.Context.onAfterInitMacros(() -> { haxe.macro.Context.getType("C"); haxe.macro.Compiler.define("APQ_CB"); });\n'
			+ '\t}\n\tpublic static function second() haxe.macro.Compiler.define("APQ_LATE");\n}\n'
		);
		write(dir, 'src/B.hx', 'class B { public static function f():Void {} }');
		write(dir, 'src/C.hx', 'class C { public static function f():Void {} }');
		write(dir, 'src/Main.hx', 'class Main { static function main() B.f(); }');
		write(dir, 'build.hxml', '-cp src\n-cp macro\n-main Main\n--interp\n--macro Init.first()\n--macro Init.second()\n');
		final read: Null<ReachConfiguration> =
			ReachDefinesProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])?.configurations[0];
		Assert.notNull(read);
		if (read != null) {
			for (late in ['APQ_LATE', 'APQ_CB']) {
				Assert.isFalse(read.defined.contains(late), '$late was read as defined for every file');
				Assert.isTrue(read.everDefined.contains(late), '$late was read as never defined');
			}
		}
		remove(dir);
	}

	@:pin('control') @:killer('M-SPAWN-ORDER')
	public function testOverlappingProbesAnswerInTheOraclesOrder(): Void {
		// The probes of several configurations run at once; each answer still belongs to the configuration it probed.
		final dir: String = scratchDir();
		write(dir, 'src/Main.hx', 'class Main { static function main() {} }');
		write(dir, 'build.hxml', '-cp src\n-main Main\n--interp\n');
		final oracles: Array<OracleConfig> = [
			for (d in ['APQ_ONE', 'APQ_TWO', 'APQ_THREE']) { hxml: 'build.hxml', dir: dir, defines: [d] }
		];
		final builds: Null<anyparse.query.ReachLiveness.ReachBuilds> = ReachDefinesProbe.probeAll(oracles);
		Assert.notNull(builds);
		if (builds != null) for (i in 0...oracles.length)
			Assert.isTrue(builds.configurations[i].defined.contains(oracles[i].defines[0]), 'configuration $i answered another probe');
		remove(dir);
	}

	public function testEveryRunProbesTheBuildsAgain(): Void {
		// A macro may depend on a file the compile never parses — here one whose mere existence defines a name. Nothing
		// keyed by what the compile read can see that change, so no probe outlives the run that took it.
		final dir: String = scratchDir();
		final flag: String = Path.join([dir, 'flag.txt']);
		write(
			dir, 'macro/Init.hx',
			'class Init { public static function go() if (sys.FileSystem.exists("$flag")) ' + 'haxe.macro.Compiler.define("APQ_FLAG"); }'
		);
		write(dir, 'src/Main.hx', 'class Main { static function main() {} }');
		write(dir, 'build.hxml', '-cp src\n-cp macro\n-main Main\n--interp\n--macro Init.go()\n');
		final oracle: OracleConfig = { hxml: 'build.hxml', dir: dir, defines: [] };
		final first: Null<ReachConfiguration> = ReachDefinesProbe.probeAll([oracle])?.configurations[0];
		File.saveContent(flag, '');
		final second: Null<ReachConfiguration> = ReachDefinesProbe.probeAll([oracle])?.configurations[0];
		Assert.isFalse(first?.everDefined.contains('APQ_FLAG') ?? true);
		Assert.isTrue(second?.everDefined.contains('APQ_FLAG') ?? false, 'an earlier run\'s probe answered a later one');
		remove(dir);
	}

	/** A fresh directory under the temp root. */
	private static function scratchDir(): String {
		final dir: String = Path.join([TempScratch.root(), 'apq-reach-defines-test-${Std.random(0x7fffffff)}']);
		FileSystem.createDirectory(dir);
		return dir;
	}

	/** Write `text` to `name` under `dir`, creating its directory. */
	private static function write(dir: String, name: String, text: String): Void {
		final path: String = Path.join([dir, name]);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

	/** Delete `dir` with everything under it, and `also`. */
	private static function remove(dir: String, ?also: String): Void {
		if (also != null) try FileSystem.deleteFile(also) catch (exception: Exception) {}
		function wipe(path: String): Void {
			if (FileSystem.isDirectory(path)) {
				for (entry in FileSystem.readDirectory(path)) wipe(Path.join([path, entry]));
				FileSystem.deleteDirectory(path);
			} else
				FileSystem.deleteFile(path);
		}
		try wipe(dir) catch (exception: Exception) {}
	}

	@:pin('control') @:killer('M-DEFINES-TYPES') @:killer('M-DEFINES-IMPL')
	public function testEveryTypedTypeIsReportedWithItsFile(): Void {
		// A macro defines a subtype of `Base` no source file declares: the build types it, so the probe names it — the
		// index then cannot declare it, and the classpath is not complete. An abstract's implementation class is not listed.
		final dir: String = scratchDir();
		write(
			dir, 'macro/Def.hx',
			'class Def { public static function go() haxe.macro.Context.onAfterInitMacros(() -> haxe.macro.Context.defineType('
			+ '{ pack: [], name: "Made", pos: haxe.macro.Context.currentPos(), fields: [], '
			+ 'kind: TDClass({ pack: [], name: "Base" }) })); }'
		);
		write(dir, 'src/Base.hx', 'class Base { public function new() {} }');
		write(
			dir, 'src/Main.hx',
			'abstract Wrap(Int) { public inline function new(i:Int) this = i; } '
			+ 'class Main { static function main() { new Base(); new Wrap(1); Type.resolveClass("Made"); } }'
		);
		write(dir, 'build.hxml', '-cp src\n-cp macro\n-main Main\n--interp\n--macro Def.go()\n--macro keep("Made")\n');
		final read: Null<ReachConfiguration> =
			ReachDefinesProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])?.configurations[0];
		Assert.notNull(read);
		if (read != null) {
			final names: Array<String> = [for (t in read.types) t.name];
			for (name in ['Main', 'Base', 'Wrap', 'Made']) Assert.isTrue(names.contains(name), '$name was not reported');
			Assert.isFalse(names.exists(n -> n.indexOf('_Impl_') >= 0), 'an abstract implementation class was reported');
			final main: Null<{ name: String, file: String }> = read.types.find(t -> t.name == 'Main');
			Assert.isTrue(main != null && StringTools.endsWith(main.file, 'src/Main.hx'), 'Main was reported against ${main?.file}');
		}
		remove(dir);
	}

}
