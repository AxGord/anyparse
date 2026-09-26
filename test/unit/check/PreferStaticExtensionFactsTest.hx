package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
import anyparse.check.HaxeSpawn;
import anyparse.check.LintConfig;
import anyparse.check.PreferStaticExtension;
import anyparse.check.StaticExtensionFacts;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.CompilerFacts;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `prefer-static-extension` over the compiler's facts (`StaticExtensionFacts`): a receiver the structural walk cannot
 * type is typed by every configuration of a real compile, and its extension form is proven only when no type of its
 * hierarchy declares the method, none carries a `@:using`, it hosts members itself, and the static function's first
 * parameter takes it with no implicit conversion. Each site of `MAIN` is one of those gates, marked `// <site>` on
 * its line; the program prints what it printed once the proven sites are rewritten.
 */
class PreferStaticExtensionFactsTest extends Test {

	/** The build every fixture compiles. */
	private static inline final BUILD: String = '-cp .\n-main Main\n--interp\n';

	/** The modules the rule rewrites. */
	private static inline final CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["Main.Util", "StringTools"]}}}';

	/** Every receiver below is a local initialized from a function with no declared return type: no structural type. */
	private static final MAIN: String = [
		'class Util {',
		'\tpublic static function f(x:Base):String return "Util.f";',
		'\tpublic static function g(x:I):String return "Util.g";',
		'\tpublic static function h<T>(x:T):String return "Util.h";',
		'\tpublic static function k(x:W):String return "Util.k";',
		'\tpublic static function z(x:Base):String return "Util.z";',
		'\tpublic static function t(x:Tp):String return "Util.t";',
		'\tpublic static function d(x:Base):String return "Util.d";',
		'}',
		'class Other {',
		'\tpublic static function t(x:Tp):String return "Other.t";',
		'}',
		'class Base {',
		'\tpublic function new() {}',
		'}',
		'class Base2 extends Base {',
		'\tpublic function f():String return "Base2.f";',
		'}',
		'class Sub2 extends Base2 {}',
		'interface I {',
		'\tfunction g():String;',
		'}',
		'class Impl implements I {',
		'\tpublic function new() {}',
		'',
		'\tpublic function g():String return "Impl.g";',
		'}',
		'class Inner {',
		'\tpublic function new() {}',
		'',
		'\tpublic function h():String return "Inner.h";',
		'}',
		'@:forward abstract Fwd(Inner) {',
		'\tpublic function new() this = new Inner();',
		'}',
		'abstract W(String) from String {}',
		'@:using(Main.Other) class Tp {',
		'\tpublic function new() {}',
		'}',
		'class A extends Base {}',
		'class B extends Base {}',
		'class Main {',
		'\tstatic function mkSub() return new Sub2();',
		'\tstatic function mkBase() return new Base2();',
		'\tstatic function mkI() return (new Impl() : I);',
		'\tstatic function mkF() return new Fwd();',
		'\tstatic function mkS() return " s ";',
		'\tstatic function mkT() return new Tp();',
		'\tstatic function mkD() return (new Base() : Dynamic);',
		'\tstatic function mkM() return (new Base() : Dynamic);',
		'\tstatic function pick() {',
		'\t\t#if alt',
		'\t\treturn new A();',
		'\t\t#else',
		'\t\treturn new B();',
		'\t\t#end',
		'\t}',
		'',
		'\tstatic function main() {',
		'\t\tfinal s: Null<Sub2> = mkSub();',
		'\t\tfinal b: Null<Base2> = mkBase();',
		'\t\tfinal i: Null<I> = mkI();',
		'\t\tfinal w: Null<Fwd> = mkF();',
		'\t\tfinal str: Null<String> = mkS();',
		'\t\tfinal tp: Null<Tp> = mkT();',
		'\t\tfinal dy: Null<Dynamic> = mkD();',
		'\t\tfinal v: Null<#if alt A #else B #end> = pick();',
		'\t\tfinal mo = mkM();',
		'\t\tSys.println(Util.f(s)); // super',
		'\t\tSys.println(Util.z(b)); // proven',
		'\t\tSys.println(Util.g(i)); // iface',
		'\t\tSys.println(Util.h(w)); // forward',
		'\t\tSys.println(Util.k(str)); // from',
		'\t\tSys.println(StringTools.trim(str)); // std',
		'\t\tSys.println(Util.t(tp)); // using',
		'\t\tSys.println(Util.d(dy)); // dynamic',
		'\t\tSys.println(Util.z(v)); // configs',
		'\t\tSys.println(Util.d(mo)); // inferred',
		'\t}',
		'}',
		''
	].join('\n');

	@:pin('control') @:killer('M-PSE-FACTS-OFF') @:killer('M-PSE-FACTS-NULL')
	public function testAReceiverOnlyTheFactsTypeIsRewritten(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		for (site in ['proven', 'std', 'configs']) Assert.equals('fix', seen[site], '$site: $seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-SHADOW')
	public function testAMemberOfASupertypeOrAnInterfaceDropsTheSite(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		for (site in ['super', 'iface']) Assert.equals('drop', seen[site], '$site: $seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-HOSTS')
	public function testAForwardingAbstractIsNoMemberHost(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		Assert.equals('report', seen['forward'], '$seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-USING')
	public function testATypeWithItsOwnUsingIsNotRewritten(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		Assert.equals('report', seen['using'], '$seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-PARAM')
	public function testAnAbstractParameterIsNotRewritten(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		Assert.equals('report', seen['from'], '$seen');
	}

	/**
	 * An overloaded extern static: the facts field records only its first signature, whose parameter takes the receiver,
	 * so only the overload count keeps the site from being judged by a signature the call may not have chosen.
	 */
	@:pin('control') @:killer('M-PSE-FACTS-OVERLOAD')
	public function testAnOverloadIsNotRewritten(): Void {
		final source: String = 'class Base {\n\tpublic function new() {}\n}\n@:native("Ext") extern class Ext {\n'
			+ '\toverload static function o(x:Base):String;\n\n\toverload static function o(x:Int):String;\n}\nclass Main {\n'
			+ '\tstatic function mk() return new Base();\n\n\tstatic function main() {\n\t\tfinal b: Null<Base> = mk();\n'
			+ '\t\ttrace(Ext.o(b)); // overload\n\t}\n}\n';
		final seen: Null<Map<String, String>> = verdicts(
			[[]], source, source, '-cp .\n-main Main\n--js out.js\n', '{"rules": {"prefer-static-extension": {"types": ["Main.Ext"]}}}'
		);
		if (seen == null) return;
		Assert.equals('report', seen['overload'], '$seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-DYNAMIC')
	public function testADynamicReceiverIsDropped(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		Assert.equals('drop', seen['dynamic'], '$seen');
	}

	/**
	 * `mo` has no annotation, so its type is the one `Util.d(mo)` bound: at `mo.d()` it is not bound yet, the call is a
	 * dynamic field call, and the program fails at run time — while still compiling.
	 */
	@:pin('control') @:killer('M-PSE-FACTS-INFERRED')
	public function testAReceiverWhoseTypeTheCallMayHaveInferredIsNotRewritten(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]]);
		if (seen == null) return;
		Assert.equals('report', seen['inferred'], '$seen');
	}

	/** Pinned as a guard: the agreement is `CompilerFacts.typeOfExpressionAt`'s, which `FactsTypeOracleTest` pins. */
	@:pin('guard')
	public function testAReceiverTwoConfigurationsTypeDifferentlyIsNotRewritten(): Void {
		final seen: Null<Map<String, String>> = verdicts([[], ['alt']]);
		if (seen == null) return;
		Assert.equals('report', seen['configs'], '$seen');
		Assert.equals('fix', seen['proven'], '$seen');
	}

	@:pin('control') @:killer('M-PSE-FACTS-TEXT')
	public function testFactsOfAnotherTextProveNothing(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]], '$MAIN// edited since the compile\n');
		if (seen == null) return;
		Assert.equals('report', seen['proven'], '$seen');
	}

	@:pin('control') @:killer('M-PSE-FIRST-PARAM')
	public function testTheFirstParameterOfAFactsSignature(): Void {
		Assert.equals('Iterable<$$map.A>', StaticExtensionFacts.firstParamOf('(Iterable<$$map.A>,($$map.A)->$$map.B)->Array<$$map.B>'));
		Assert.equals('($$a.A)->Bool', StaticExtensionFacts.firstParamOf('(($$a.A)->Bool,Int)->Int'));
		Assert.equals('{a:Int,b:String}', StaticExtensionFacts.firstParamOf('({a:Int,b:String})->Void'));
		Assert.equals('Map<String,Array<Int>>', StaticExtensionFacts.firstParamOf('(Map<String,Array<Int>>,Int)->Void'));
		Assert.isNull(StaticExtensionFacts.firstParamOf('()->Int'));
		Assert.isNull(StaticExtensionFacts.firstParamOf('String'));
	}

	/** `--fix` end to end: the proven sites are rewritten with the `using` they need, and the program prints what it printed. */
	@:pin('guard')
	public function testTheRewrittenProgramPrintsWhatItPrinted(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('pse_facts_e2e', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: BUILD },
			{
				name: 'apqlint.json',
				source: '{"compilerOracle":"check.hxml","rules":{"prefer-static-extension":{"types":["Main.Util","StringTools"]}}}'
			}
		]);
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		CliFixture.captureStderr(() -> Cli.run(['fmt', '--write', '$dir/Main.hx']));
		final before: String = HaxeSpawn.run(['check.hxml'], dir, 1 << 20).out;
		final err: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-static-extension', dir]));
		final after: String = File.getContent('$dir/Main.hx');
		for (rewritten in ['b.z()', 'str.trim()', 'v.z()', 'using Main.Util;'])
			Assert.isTrue(after.indexOf(rewritten) >= 0, '$rewritten\n$after\n$err');
		for (kept in [
			'Util.h(w)',
			'Util.k(str)',
			'Util.t(tp)',
			'Util.f(s)',
			'Util.g(i)',
			'Util.d(dy)',
			'Util.d(mo)'
		]) Assert.isTrue(after.indexOf(kept) >= 0, '$kept\n$after');
		Assert.equals(before, HaxeSpawn.run(['check.hxml'], dir, 1 << 20).out, 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The verdict per marked site of `source` (default `MAIN`), compiled from `compiled` (default `MAIN`) by `build` under
	 * each define set of `configurations`, with `config` as the project's options: `fix`, `report`, or `drop` for a site
	 * with no finding. Null when haxe is unavailable.
	 */
	private static function verdicts(
		configurations: Array<Array<String>>, ?source: String, ?compiled: String, build: String = BUILD, config: String = CONFIG
	): Null<Map<String, String>> {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('pse_facts', [
			{ name: 'Main.hx', source: compiled ?? MAIN },
			{ name: 'build.hxml', source: build }
		]);
		final oracles: Array<OracleConfig> = [for (d in configurations) { hxml: 'build.hxml', dir: dir, defines: d }];
		if (!CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return null;
		}
		final facts: Null<CompilerFacts> = TypedFactsProbe.probeAll(oracles);
		if (facts == null || facts.configurations.length != configurations.length) {
			CliFixture.removeDir(dir);
			Assert.fail('the fixture compiled but left no facts: ${[for (d in facts?.dropped ?? []) d.reason]}');
			return null;
		}
		final text: String = source ?? MAIN;
		final files: Array<{ file: String, source: String }> = [{ file: Path.join([dir, 'Main.hx']), source: text }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: true
			},
			facts: () -> facts
		});
		final check: PreferStaticExtension = new PreferStaticExtension();
		final json: String = config;
		check.setConfigResolver(_ -> LintConfig.parse(json));
		final found: Array<Violation> = check.run(files, plugin);
		CliFixture.removeDir(dir);
		final lines: Array<String> = text.split('\n');
		final out: Map<String, String> = [];
		for (line in lines) {
			final mark: Int = line.indexOf('// ');
			if (mark >= 0 && (line.indexOf('Sys.println') >= 0 || line.indexOf('trace(') >= 0)) out[line.substr(mark + 3)] = 'drop';
		}
		for (v in found) {
			final from: Int = v.span?.from ?? -1;
			final line: String = lines[text.substring(0, from).split('\n').length - 1];
			final mark: Int = line.indexOf('// ');
			if (mark >= 0) out[line.substr(mark + 3)] = v.message.indexOf(' can be ') >= 0 ? 'fix' : 'report';
		}
		return out;
		#else
		Assert.pass('non-sys target');
		return null;
		#end
	}

}
