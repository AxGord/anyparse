package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.FactsTypeOracle;
import anyparse.check.HaxeSpawn;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The oracle-assisted `--fix` phase typed by the compiler's facts, end to end over a real compile of two configurations:
 * a local, a parameter, a return type and a field are annotated with the type every configuration gave them, with no
 * display server started; a type the configurations disagree on, an unknown one and a branch no build compiles are
 * declined and counted by reason; and the annotated program prints what the original printed, in both builds.
 *
 * The fixture holds the soundness probes: an inferred `Int`/`Float`, an empty array bound later, an abstract with `@:from`,
 * a class and a method type parameter, a function type, a structure, `Dynamic` from `Json.parse`, a type another package
 * declares, and non-ASCII text before every site.
 */
class FactsTypeOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'import haxe.Json;\n' + '\n' + 'typedef Doc = {name:String};\n' + '\n'
		+ 'abstract Meters(Float) from Float to Float {\n' + '\t@:from static function fromInt(i:Int):Meters\n'
		+ '\t\treturn new Meters(i * 100.0);\n' + '\n' + '\tinline function new(f:Float)\n' + '\t\tthis = f;\n' + '}\n' + '\n'
		+ 'class Box<T> {\n' + '\tpublic var v:T;\n' + '\tpublic var count = Box.size();\n' + '\n' + '\tpublic function new(v:T) {\n'
		+ '\t\tthis.v = v;\n' + '\t}\n' + '\n' + '\tpublic function get() {\n' + '\t\tfinal x = v;\n' + '\t\treturn x;\n' + '\t}\n' + '\n'
		+ '\tpublic function pair<U>(u:U) {\n' + '\t\tfinal t = {a: v, b: u};\n' + '\t\treturn t;\n' + '\t}\n' + '\n'
		+ '\tpublic function scale(k) {\n' + '\t\treturn k * 2.5;\n' + '\t}\n' + '\n' + '\tstatic function size():Int {\n'
		+ '\t\treturn 3;\n' + '\t}\n' + '}\n' + '\n' + 'class Main {\n' + '\tstatic function helper(x) {\n' + '\t\treturn x + 1;\n'
		+ '\t}\n' + '\n' + '\tstatic function main() {\n' + '\t\t// é 😀 non-ASCII before the sites\n' + '\t\tvar i = helper(1) + 0;\n'
		+ '\t\tvar f = i * 1.5;\n' + '\t\tvar a = [];\n' + '\t\ta.push(({name: \'x\'} : Doc));\n' + '\t\tvar m:Meters = 3;\n'
		+ '\t\tvar mm = m;\n' + '\t\tvar fn = function(x:Int, ?y:String) return x > 0;\n' + '\t\tvar anon = {a: 1, b: \'x\'};\n'
		+ '\t\tvar dyn = Json.parse(\'{"k":1}\');\n' + '\t\tvar bx = new Box(3);\n' + '\t\tvar g = bx.get();\n' + '\t\tvar n = null;\n'
		+ '\t\tn = 1.5;\n' + '\t\tvar o = sub.Other.make();\n' + '\t\t#if never\n' + '\t\tvar hidden = i;\n' + '\t\t#end\n'
		+ '\t\tvar conf = #if alt helper(1) #else helper(1) * 1.5 #end;\n'
		+ '\t\tSys.println(\'$$i,$$f,$${a.length},$$mm,$${fn(1)},$${anon.a},$${dyn.k},$$g,$$n,$${o.name},$$conf,$${bx.pair(\'s\').b},$${bx.scale(2)},$${bx.count}\');\n'
		+ '\t}\n' + '}\n';
	private static final OTHER: String = 'package sub;\n' + '\n' + 'class Other {\n' + '\tpublic var name:String = \'o\';\n' + '\n'
		+ '\tpublic function new() {}\n' + '\n' + '\tpublic static function make():Other {\n' + '\t\treturn new Other();\n' + '\t}\n'
		+ '}\n';
	private static final APQLINT: String = '{"compilerOracle":[{"hxml":"check.hxml"},{"hxml":"check.hxml","defines":["alt"]}],'
		+ '"resolutionRoots":["."],"rules":{"explicit-local-type":{"enabled":true}}}';
	private static inline final BUFFER: Int = 1 << 20;
	private static final MOVED: String = 'abstract Meters(Float) to Float {\n' + '\tpublic function new(f:Float)\n' + '\t\tthis = f;\n'
		+ '\n' + '\t@:from static function fromInt(i:Int):Meters\n' + '\t\treturn new Meters(i * 100.0);\n' + '}\n' + '\n' + 'class P1 {\n'
		+ '\tpublic static function big():Int\n' + '\t\treturn 7;\n' + '\n' + '\tstatic function a() {\n'
		+ '\t\tvar r = new Meters(1.5);\n' + '\t\tSys.println((r : Float));\n' + '\t}\n' + '\n' + '\tpublic static function run() {\n'
		+ '\t\tvar r = big();\n' + '\t\tSys.println((r : Float));\n' + '\t\ta();\n' + '\t}\n' + '}\n';
	private static final SWAPPED: String = 'abstract Feet(Float) to Float {\n' + '\tpublic function new(f:Float)\n' + '\t\tthis = f;\n'
		+ '\n' + '\t@:to function toInt():Int\n' + '\t\treturn Std.int(this);\n' + '\n' + '\t@:from static function fromInt(i:Int):Feet\n'
		+ '\t\treturn new Feet(i * 100.0);\n' + '}\n' + '\n' + 'class P2 {\n' + '\tpublic static function id<T>(x:T):T\n'
		+ '\t\treturn x;\n' + '\n' + '\tpublic static function run() {\n' + '\t\tb(7);\n' + '\t\ta(new Feet(1.5));\n' + '\t}\n' + '\n'
		+ '\tstatic function a(v:Feet) {\n' + '\t\tvar r = id(v);\n' + '\t\tSys.println((r : Float));\n' + '\t}\n' + '\n'
		+ '\tpublic static function b(v:Int) {\n' + '\t\tvar r = id(v);\n' + '\t\tSys.println((r : Float));\n' + '\t}\n' + '}\n';
	private static final UNTOUCHED: String = 'class Ctl {\n' + '\tpublic static function run():Void {\n'
		+ '\t\tfinal lens = [\'ab\', \'c\'].map(s -> s.length);\n' + '\t\tSys.println(lens);\n' + '\t}\n' + '\n'
		+ '\tpublic static function shout():String {\n' + '\t\treturn \'lou\' + \'d\';\n' + '\t}\n' + '}\n';
	private static final REORDER_MAIN: String = 'class Main {\n' + '\tpublic static function main():Void {\n' + '\t\tP1.run();\n'
		+ '\t\tP2.run();\n' + '\t\tCtl.run();\n' + '\t\tSys.println(Ctl.shout());\n' + '\t}\n' + '}\n';
	private static final REORDER_APQLINT: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],'
		+ '"rules":{"explicit-local-type":{"enabled":true},"member-order":{"enabled":true}}}';
	#end

	@:pin('control') @:killer('M-ASSISTED-FACTS-FIRST') @:killer('M-ASSISTED-DECLINE-CENSUS') @:killer('M-EXPLICIT-TYPE-ORACLE-PARAMS')
	@:killer('M-EXPLICIT-TYPE-ORACLE-FIELDS') @:killer('M-FACTS-DYNAMIC-SOURCE')
	public function testTheFactsTypeEveryDeclarationKindAndKeepTheProgram(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('factsoracle', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'sub/Other.hx', source: OTHER },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n--interp\n' },
			{ name: 'apqlint.json', source: APQLINT }
		]);
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final before: Array<String> = [run(dir, []), run(dir, ['-D', 'alt'])];
		final asked: Int = CompilerDisplayOracle.invocations;
		final err: String = CliFixture.captureStderr(() ->
			Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', '--rule', 'explicit-type', dir])
		);
		final packed: String = File.getContent('$dir/Main.hx').replace(' ', '');
		Assert.equals(asked, CompilerDisplayOracle.invocations, 'no display server was asked');
		for (annotated in [
			'vari:Int=helper(1)+0',
			'varf:Float=i*1.5',
			'vara:Array<Doc>=[]',
			'varfn:(Int,?Null<String>)->Bool=',
			'varanon:{a:Int,b:String}=',
			'varbx:Box<Int>=',
			'varg:Int=',
			'varn:Null<Float>=null',
			'functionget():T',
			'finalx:T=v',
			'functionpair<U>(u:U):{a:T,b:U}',
			'functionscale(k:Int):Float',
			'staticfunctionhelper(x:Int):Int',
			'publicvarcount:Int='
		]) Assert.isTrue(packed.indexOf(annotated) >= 0, 'annotated: $$annotated\n$$packed');
		for (left in ['vardyn=Json', 'varconf=#if']) Assert.isTrue(packed.indexOf(left) >= 0, 'left alone: $$left\n$$packed');
		Assert.isTrue(err.indexOf('oracle-assisted explicit-local-type DECLINED') >= 0, err);
		Assert.isTrue(err.indexOf('the oracle configurations type it differently') >= 0, err);
		Assert.isTrue(err.indexOf(FactsTypeOracle.DECLINE_DYNAMIC_SOURCE) >= 0, err);
		Assert.equals(before[0], run(dir, []), 'the default build prints what it printed');
		Assert.equals(before[1], run(dir, ['-D', 'alt']), 'the alt build prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A run that reorders members (`member-order`, no `--rule`, so the facts are compiled before the first write) and then
	 * asks the facts of the ORIGINAL text: a local whose member was moved declines — its line would otherwise be matched to
	 * a same-shaped line of another member (`MOVED`), or two identical bodies to each other (`SWAPPED`) — while a member the
	 * reorder only shifted, in a file an edit also rewrote elsewhere, is still annotated (`UNTOUCHED`). Every build prints
	 * what it printed.
	 *
	 * Pinned as a guard only: whether the facts compile reads a file before or after the run writes it is a race the run
	 * does not decide, so the placement itself is pinned in `EditJournalTest` and `FactsTypeOracleTest`.
	 */
	@:pin('guard')
	public function testAReorderedFileIsPlacedOnlyThroughTheEditsItsRunApplied(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('factsreorder', [
			{ name: 'Main.hx', source: REORDER_MAIN },
			{ name: 'P1.hx', source: MOVED },
			{ name: 'P2.hx', source: SWAPPED },
			{ name: 'Ctl.hx', source: UNTOUCHED },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n--interp\n' },
			{ name: 'apqlint.json', source: REORDER_APQLINT }
		]);
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final before: String = run(dir, []);
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', dir]));
		Assert.equals(before, run(dir, []), 'the program prints what it printed');
		final moved: String = File.getContent('$dir/P1.hx').replace(' ', '');
		// facts compiled after the write may type it rightly (`Int`); never with the moved-over line's `Meters`
		Assert.isTrue(moved.indexOf('r:Meters=big()') < 0, moved);
		Assert.isTrue(
			File.getContent('$dir/Ctl.hx').replace(' ', '').indexOf('finallens:Array<Int>=') >= 0, 'the shifted member is annotated'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function run(dir: String, defines: Array<String>): String {
		return HaxeSpawn.run(['check.hxml'].concat(defines), dir, BUFFER).out;
	}
	#end

}
