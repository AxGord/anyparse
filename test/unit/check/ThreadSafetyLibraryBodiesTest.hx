package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PositiveSinks;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Opt-in `libraryBodies`: the bodies of the libraries one shipped build compiles are walked, so a library call that blocks
 * inside the library is a sink at the PROJECT call site, its chain going on to the library's sink. Before, a call into a
 * library with a Haxe body ended in the graph, and blocking I/O inside it was invisible. The libraries are read under the
 * build's defines (a branch it does not compile runs nothing), a value the library hands to a `spawns` call runs
 * elsewhere, a project type's call is no library override's, and `nonBlocking` waives a library native.
 */
class ThreadSafetyLibraryBodiesTest extends Test {

	/** The build: the project's own classpath, the library's, a define spelled with a dash and the target. */
	private static inline final HXML: String = '-cp .\n-cp vendorlib\n-D gate-on\n-cpp out\n';

	/**
	 * The library: a native read only under every define of the build — the hxml's, the oracle entry's, the target's and
	 * the compiler's — and files the build does not compile: another target's package and file, and a plain file the
	 * target's own copy stands in for.
	 */
	private static final LIBRARY: Array<{ name: String, source: String }> = [
		{
			name: 'vendorlib/vendor/Loader.hx',
			source: 'package vendor; class Loader { static var prim:Dynamic = cpp.Lib.load("v", "read_file", 1);'
				+ ' public static function load(p:String):String {'
				+ ' #if (gate_on && cpp && haxe_ver >= 4 && ORACLE_FLAG) return readNow(p); #else return p; #end }'
				+ ' public static function cached(p:String):String { #if !gate_on return readNow(p); #else return p; #end }'
				+ ' public static function later(p:String):Void sys.thread.Thread.create(() -> readNow(p));'
				+ ' public static function quiet(p:String):String return p;'
				+ ' static function readNow(p:String):String return prim(p); }'
		},
		{
			name: 'vendorlib/vendor/Base.hx',
			source: 'package vendor; class Base { public function new() {} public function work():Void {} }'
				+ ' class Sub extends Base { override public function work():Void Loader.load("w"); }'
		},
		{
			name: 'vendorlib/other/Mine.hx',
			source: 'package other; import vendor.Loader; class Mine { public function work():Void Loader.load("m"); }'
		},
		{ name: 'vendorlib/vendor/Hold.hx', source: 'package vendor; class Hold { public static function run():Void Loader.load("h"); }' },
		{ name: 'vendorlib/vendor/Hold.cpp.hx', source: 'package vendor; class Hold { public static function run():Void {} }' },
		{ name: 'vendorlib/vendor/Quiet.hx', source: 'package vendor; class Quiet { public static function run():Void {} }' },
		{
			name: 'vendorlib/vendor/Quiet.php.hx',
			source: 'package vendor; class Quiet { public static function run():Void Loader.load("q"); }'
		},
		{
			name: 'vendorlib/php/Db.hx',
			source: 'package php; import vendor.Loader; class Db { public static function query():Void Loader.load("d"); }'
		},
		{
			name: 'vendorlib/Sys.hx',
			source: 'import vendor.Loader; class Sys { public static function sleep(s:Float):Void Loader.load("s"); }'
		}
	];

	private static final PROJECT: String = 'import vendor.Loader; import vendor.Base; import vendor.Hold; import vendor.Quiet; import php.Db;'
		+ ' class Mine extends Base {} class A { static function main():Void { Loader.load("x"); Loader.cached("y"); Loader.later("z");'
		+ ' Loader.quiet("q"); Hold.run(); Quiet.run(); Db.query(); } static function viaBase(b:Base):Void b.work();'
		+ ' static function viaMine(m:Mine):Void m.work(); static function nap():Void Sys.sleep(0); }';

	/** What the fixture reports with the libraries walked: the library calls that block, and a builtin sink of its own. */
	private static final WALKED: Array<String> = [
		'warning A A.main | Loader.load',
		'warning A A.nap | Sys.sleep',
		'warning A A.viaBase | Base.work'
	];

	/** The options walking the fixture's libraries. */
	private static inline final OPTIONS: String = '"libraryBodies":["build.hxml"],"spawns":["Thread.create"]';

	/**
	 * A library call whose body reaches the library's native is a sink where the project calls it, its chain going on into
	 * the library to the native; a value the library hands to a `spawns` call runs elsewhere; a builtin sink stays the
	 * runtime's, with no library chain; the run says how many library calls block.
	 */
	@:pin('control') @:killer('M-TS-LIB-OFF') @:killer('M-TS-LIB-NOT-SINKS') @:killer('M-TS-LIB-CHAIN-OFF') @:killer('M-TS-LIB-NOTICE')
	@:killer('M-TS-LIB-KNOWN') @:killer('M-TS-LIB-AWAY-OFF')
	public function testALibraryCallThatBlocksInsideIsASink(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(OPTIONS);
		Assert.same(WALKED, graded(found));
		final load: Null<Violation> = found.find(v -> v.data?.subject == 'Loader.load');
		Assert.same(['A.main', 'Loader.load', 'Loader.readNow', 'Loader.prim'], load?.data?.chain, 'the chain goes into the library');
		Assert.isTrue(load?.message.indexOf('inside the library: Loader.load -> Loader.readNow -> Loader.prim') ?? -1 > 0, load?.message);
		final sleep: Null<Violation> = found.find(v -> v.data?.subject == 'Sys.sleep');
		Assert.isTrue(sleep?.message.indexOf('inside the library') == -1, 'a builtin sink carries no library chain: ${sleep?.message}');
		Assert.isTrue(notice(found).indexOf('2 library call(s) whose bodies block') > 0, notice(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The libraries are read as the build compiles them: under every define it sets — the hxml's (a dash read as the
	 * underscore a condition spells), its oracle entry's, the target's, the compiler version's — and without the files it
	 * never compiles: another target's package (`php/Db.hx`) or file (`Quiet.php.hx`), and a plain file its target's own
	 * copy stands in for (`Hold.hx` beside `Hold.cpp.hx`).
	 */
	@:pin('control') @:killer('M-TS-LIB-DEFINES-OFF') @:killer('M-TS-LIB-DASH') @:killer('M-TS-LIB-ORACLE-DEFINES')
	@:killer('M-TS-LIB-TARGET-DEFINES') @:killer('M-TS-LIB-VERSION-DEFINES') @:killer('M-TS-LIB-OTHER-TARGET-FILE')
	@:killer('M-TS-LIB-SHADOWED') @:killer('M-TS-LIB-TARGET-PACKAGE')
	public function testTheLibrariesAreReadAsTheBuildCompilesThem(): Void {
		#if (sys || nodejs)
		Assert.same(WALKED, graded(run(OPTIONS)));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A call on a library type may run any override the library declares (`Base.work` runs `Sub.work`); one on a project
	 * type runs its nearest library superclass's member and no library override, whatever library type shares its name
	 * (`Mine` beside the library's `other.Mine`).
	 */
	@:pin('control') @:killer('M-TS-LIB-VIRTUAL-OFF') @:killer('M-TS-LIB-PROJECT-OVERRIDES') @:killer('M-TS-LIB-PROJECT-TYPE')
	public function testAProjectTypeRunsNoLibraryOverride(): Void {
		#if (sys || nodejs)
		Assert.same(WALKED, graded(run(OPTIONS)));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Without the option the library stays a boundary: nothing it does inside is seen. */
	public function testWithoutTheOptionTheLibraryIsABoundary(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A A.nap | Sys.sleep'], graded(run('"spawns":["Thread.create"]')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `nonBlocking` waives a native the library declares, on evidence, and is not said to waive nothing. */
	@:pin('control') @:killer('M-TS-LIB-WAIVE-OFF') @:killer('M-TS-LIB-WAIVE-SAID')
	public function testNonBlockingWaivesALibraryNative(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run('$OPTIONS,"nonBlocking":["Loader.prim the fixture prim answers at once"]');
		Assert.same(['warning A A.nap | Sys.sleep'], graded(found));
		Assert.isFalse(found.exists(v -> v.file == '' && v.message.indexOf('waives no builtin sink') >= 0), 'said to waive nothing');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An entry naming no `compilerOracle` hxml walks nothing and says so. */
	@:pin('control') @:killer('M-TS-LIB-UNKNOWN-SAID')
	public function testAnUnknownBuildIsSaid(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run('"libraryBodies":["nope.hxml"],"spawns":["Thread.create"]');
		Assert.same(['warning A A.nap | Sys.sleep'], graded(found));
		Assert.isTrue(found.exists(v -> v.file == '' && v.message.indexOf('"nope.hxml" names no compilerOracle entry') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A library or a classpath the build names that the run cannot find is said by name: nothing under it is walked. */
	@:pin('control') @:killer('M-TS-LIB-LOST-LIB-SAID') @:killer('M-TS-LIB-LOST-CP-SAID')
	public function testALibraryTheBuildCannotFindIsSaid(): Void {
		#if (sys || nodejs)
		final config: String =
			'{"compilerOracle":[{"hxml":"lost.hxml"}],"rules":{"thread-safety":{"closedWorld":false,"libraryBodies":["lost.hxml"]}}}';
		final project: String = 'class A { static function main():Void Sys.sleep(0); }';
		final dir: String = CliFixture.writeTree('threadsafety_lib_lost', [
			{ name: 'apqlint.json', source: config },
			{ name: 'lost.hxml', source: '-cp .\n-cp nowhere\n-lib no_such_haxelib_fx2\n-cpp out\n' },
			{ name: 'F0.hx', source: project }
		]);
		final found: Array<Violation> = Linter.run([{ file: '$dir/F0.hx', source: project }], new HaxeQueryPlugin(), [new ThreadSafety()]);
		CliFixture.removeDir(dir);
		final said: Array<String> = [for (v in found) if (v.file == '') v.message];
		Assert.isTrue(
			said.exists(m -> m.indexOf('the library "-lib no_such_haxelib_fx2"') >= 0 && m.indexOf('does not resolve') >= 0),
			said.join('\n')
		);
		Assert.isTrue(said.exists(m -> m.indexOf('/nowhere"') >= 0 && m.indexOf('does not exist') >= 0), said.join('\n'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The findings of the fixture project under the `thread-safety` options `options` (JSON members), the notice kept. */
	private static function run(options: String): Array<Violation> {
		final config: String =
			'{"compilerOracle":[{"hxml":"build.hxml","defines":["ORACLE_FLAG"]}],"rules":{"thread-safety":{"closedWorld":false,$options}}}';
		final dir: String = CliFixture.writeTree('threadsafety_lib', [
			{ name: 'apqlint.json', source: config },
			{ name: 'build.hxml', source: HXML },
			{ name: 'F0.hx', source: PROJECT }
		].concat(LIBRARY));
		final found: Array<Violation> = Linter.run([{ file: '$dir/F0.hx', source: PROJECT }], new HaxeQueryPlugin(), [new ThreadSafety()]);
		CliFixture.removeDir(dir);
		return found;
	}

	/** The findings of `found` with data as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	/** The run's notice of the sinks it applied. */
	private static function notice(found: Array<Violation>): String {
		return found.find(v -> v.file == '' && StringTools.startsWith(v.message, PositiveSinks.NOTICE))?.message ?? '';
	}
	#end

}
