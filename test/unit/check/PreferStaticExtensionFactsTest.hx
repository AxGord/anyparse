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
import anyparse.check.StaticExtensionFacts.ExtensionFactsVerdict;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.CompilerFacts;
import anyparse.query.StdResolver;
import anyparse.runtime.Span;
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

	/** `Util` is an alias of `Other`; the configured `Util` is another module (`testAnImportAliasOfTheModuleNameDropsTheSite`). */
	private static final ALIAS_MAIN: String = 'import Other as Util;\n\nclass Main {\n\tstatic function mk()\n\t\treturn new Base();\n\n'
		+ '\tstatic function main() {\n\t\tfinal b:Null<Base> = mk();\n\t\tfinal c:Base = new Base();\n'
		+ '\t\tSys.println(Util.f(b)); // facts\n\t\tSys.println(Util.f(c)); // structural\n\t}\n}\n';

	/** `Util.f` and `Other.f`, both taking a `Base`. */
	private static final TWIN_MODULES: String = 'class Util {\n\tpublic static function f(x:Base):String\n\t\treturn "Util.f";\n}\n\n'
		+ 'class Other {\n\tpublic static function f(x:Base):String\n\t\treturn "Other.f";\n}\n\n';

	/** `Base`, and a `Main` calling `Util.f` on a receiver each path types: a facts site and a structural one. */
	private static final BASE_MAKER: String = 'class Base {\n\tpublic function new() {}\n}\n\nclass Main {\n\tstatic function mk()\n\t\treturn new Base();\n\n'
		+ '\tstatic function main() {\n\t\tfinal b:Null<Base> = mk();\n\t\tfinal c:Base = new Base();\n'
		+ '\t\tSys.println(Util.f(b)); // facts\n\t\tSys.println(Util.f(c)); // structural\n\t}\n}\n';

	/** Receivers whose type, superclass or interface carries `@:using(Main.Other)`. */
	private static final USING_MAIN: String = 'class Util {\n\tpublic static function t(x:Tp):String\n\t\treturn "Util.t";\n\n'
		+ '\tpublic static function u(x:Sub):String\n\t\treturn "Util.u";\n\n\tpublic static function v(x:Impl):String\n\t\treturn "Util.v";\n}\n\n'
		+ 'class Other {\n\tpublic static function t(x:Tp):String\n\t\treturn "Other.t";\n\n\tpublic static function u(x:Tp):String\n\t\treturn "Other.u";\n\n'
		+ '\tpublic static function v(x:I):String\n\t\treturn "Other.v";\n}\n\n'
		+ '@:using(Main.Other) class Tp {\n\tpublic function new() {}\n}\n\nclass Sub extends Tp {}\n\n@:using(Main.Other) interface I {}\n\n'
		+ 'class Impl implements I {\n\tpublic function new() {}\n}\n\n'
		+ 'class Main {\n\tstatic function mkSub()\n\t\treturn new Sub();\n\n\tstatic function mkImpl()\n\t\treturn new Impl();\n\n'
		+ '\tstatic function main() {\n\t\tfinal tp:Tp = new Tp();\n\t\tfinal s:Sub = new Sub();\n\t\tfinal i:Impl = new Impl();\n'
		+ '\t\tfinal sn:Null<Sub> = mkSub();\n\t\tfinal im:Null<Impl> = mkImpl();\n'
		+ '\t\tSys.println(Util.t(tp)); // own\n\t\tSys.println(Util.u(s)); // super\n\t\tSys.println(Util.v(i)); // iface\n'
		+ '\t\tSys.println(Util.u(sn)); // super facts\n\t\tSys.println(Util.v(im)); // iface facts\n\t}\n}\n';

	/** Only `Util` is configured. */
	private static inline final UTIL_CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["Util"]}}}';

	/** `Util.f(b)` on a facts receiver and on a structural one, in a file that `using Zeta` may reach. */
	private static final SUBTYPE_MAIN: String = 'class Main {\n\tstatic function mk()\n\t\treturn new Base();\n\n'
		+ '\tstatic function main() {\n\t\tfinal b:Null<Base> = mk();\n\t\tfinal c:Base = new Base();\n'
		+ '\t\tSys.println(Util.f(b)); // facts\n\t\tSys.println(Util.f(c)); // structural\n\t\tSys.println(Zeta.g());\n\t}\n}\n';

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

	/**
	 * `import Other as Util` rebinds the configured module's name: `Util.f(b)` calls `Other.f`, while the rewrite's
	 * `using Util` binds the configured module's `f` — both inline, so no call fact at the site names either.
	 */
	@:pin('control') @:killer('M-PSE-CHANNEL-ALIAS')
	public function testAnImportAliasOfTheModuleNameDropsTheSite(): Void {
		// with `Other.f` out of `using` the conflict gate sees no rival the inserted `using Util` could bring: only what the
		// written name binds to drops the site
		for (meta in ['', '@:noUsing ']) {
			final seen: Null<Map<String, String>> =
				verdicts([[]], ALIAS_MAIN, ALIAS_MAIN, BUILD, '{"rules": {"prefer-static-extension": {"types": ["Util"]}}}', [
					'Base.hx' => 'class Base {\n\tpublic var n:Int = 1;\n\n\tpublic function new() {}\n\n\tpublic static function touch():String\n\t\treturn Util.f(new Base());\n}\n',
					'Other.hx' => 'class Other {\n\t' + meta
					+ 'public static inline function f(x:Base):String\n\t\treturn "Other.f " + x.n;\n}\n',
					'Util.hx' => 'class Util {\n\tpublic static inline function f(x:Base):String\n\t\treturn "Util.f " + x.n;\n}\n'
				]);
			if (seen == null) return;
			for (site in ['facts', 'structural']) Assert.equals('drop', seen[site], '$meta$site: $seen');
		}
	}

	/** A `using` in a conditional region binds in the builds that compile it: `Other.f` there, not the configured `Util.f`. */
	@:pin('control') @:killer('M-PSE-CHANNEL-REGION-USING')
	public function testAConditionalUsingProvidingTheMethodDropsTheSite(): Void {
		final source: String = '#if !nope\nusing Main.Other;\n#end\n\n' + TWIN_MODULES + BASE_MAKER;
		final seen: Null<Map<String, String>> = verdicts([[]], source, source);
		if (seen == null) return;
		for (site in ['facts', 'structural']) Assert.equals('drop', seen[site], '$site: $seen');
	}

	/** `@:noUsing` keeps `Util.f` out of `using`: the rewrite would not compile. */
	@:pin('control') @:killer('M-PSE-CHANNEL-NO-USING')
	public function testANoUsingFunctionDropsTheSite(): Void {
		final source: String = 'class Util {\n\t@:noUsing public static function f(x:Base):String\n\t\treturn "Util.f";\n}\n\n' + BASE_MAKER;
		final seen: Null<Map<String, String>> = verdicts([[]], source, source);
		if (seen == null) return;
		for (site in ['facts', 'structural']) Assert.equals('drop', seen[site], '$site: $seen');
	}

	/**
	 * `using Zeta` brings the statics of every type `Zeta.hx` declares: `Extra.f` there binds `b.f()` (`Util.f` before), so
	 * the site is dropped — whether the `using` is the file's or an ambient `import.hx`'s.
	 */
	@:pin('control') @:killer('M-PSE-USING-MODULE-WIDE')
	public function testAUsingOfAModuleWeighsEveryTypeItDeclares(): Void {
		for (ambient in [false, true]) {
			final main: String = (ambient ? '' : 'using Zeta;\n\n') + SUBTYPE_MAIN;
			final extra: Map<String, String> = subtypeModules();
			if (ambient) extra['import.hx'] = 'using Zeta;\n';
			final seen: Null<Map<String, String>> = verdicts([[]], main, main, BUILD, UTIL_CONFIG, extra);
			if (seen == null) return;
			for (site in ['facts', 'structural']) Assert.equals('drop', seen[site], 'ambient=$ambient $site: $seen');
		}
	}

	/** A `typedef` of a class in the used module brings that class's statics too (`using tink.CoreApi` works that way). */
	@:pin('control') @:killer('M-PSE-USING-ALIAS-HOST')
	public function testAUsingOfAModuleFollowsItsTypedefs(): Void {
		final main: String = 'using Zeta;\n\n' + SUBTYPE_MAIN;
		final extra: Map<String, String> = subtypeModules();
		extra['Zeta.hx'] = 'class Zeta {\n\tpublic static function g():Int\n\t\treturn 0;\n}\n\ntypedef Extra = Hidden;\n';
		extra['Hidden.hx'] = 'class Hidden {\n\tpublic static function f(x:Base):String\n\t\treturn "Hidden.f";\n}\n';
		final seen: Null<Map<String, String>> = verdicts([[]], main, main, BUILD, UTIL_CONFIG, extra);
		if (seen == null) return;
		Assert.equals('drop', seen['structural'], '$seen');
	}

	/** The facts half of the same gate: `Extra.f` in the facts of `Zeta.hx`'s module drops the site on its own. */
	@:pin('control') @:killer('M-PSE-FACTS-USING-MODULE-WIDE')
	public function testTheFactsWeighEveryTypeAUsedModuleDeclares(): Void {
		#if (sys || nodejs)
		final main: String = 'using Zeta;\n\n' + SUBTYPE_MAIN;
		final entries: Array<{ name: String, source: String }> = [{ name: 'Main.hx', source: main }, { name: 'build.hxml', source: BUILD }];
		for (name => text in subtypeModules()) entries.push({ name: name, source: text });
		final dir: String = CliFixture.writeTree('pse_facts_using', entries);
		final facts: Null<CompilerFacts> = CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)
			? TypedFactsProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])
			: null;
		if (facts == null) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final call: Int = main.indexOf('Util.f(b)');
		final recv: Int = call + 'Util.f('.length;
		final judged: ExtensionFactsVerdict = StaticExtensionFacts.judge(
			facts, Path.join([dir, 'Main.hx']), main, new Span(call, call + 'Util.f(b)'.length), new Span(recv, recv + 1), 'Util', 'f',
			['Zeta']
		);
		CliFixture.removeDir(dir);
		Assert.equals(Shadowed, judged);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The `using Util` the rewrite inserts brings every type of `Util.hx`: `Extra.f` there binds `b.f()` instead of
	 * `Util.f`, so the configured module's own neighbours drop the site.
	 */
	@:pin('control') @:killer('M-PSE-USING-SELF-MODULE')
	public function testTheConfiguredModulesOwnNeighboursDropTheSite(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]], SUBTYPE_MAIN, SUBTYPE_MAIN, BUILD, UTIL_CONFIG, selfModules());
		if (seen == null) return;
		for (site in ['facts', 'structural']) Assert.equals('drop', seen[site], '$site: $seen');
	}

	/** The facts half: with no `using` in the file, the inserted one's neighbours alone drop the site. */
	@:pin('control') @:killer('M-PSE-FACTS-USING-SELF-MODULE')
	public function testTheFactsWeighTheConfiguredModulesNeighbours(): Void {
		#if (sys || nodejs)
		final entries: Array<{ name: String, source: String }> = [
			{ name: 'Main.hx', source: SUBTYPE_MAIN },
			{ name: 'build.hxml', source: BUILD }
		];
		for (name => text in selfModules()) entries.push({ name: name, source: text });
		final dir: String = CliFixture.writeTree('pse_facts_self', entries);
		final facts: Null<CompilerFacts> = CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)
			? TypedFactsProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])
			: null;
		if (facts == null) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final call: Int = SUBTYPE_MAIN.indexOf('Util.f(b)');
		final recv: Int = call + 'Util.f('.length;
		final judged: ExtensionFactsVerdict = StaticExtensionFacts.judge(
			facts, Path.join([dir, 'Main.hx']), SUBTYPE_MAIN, new Span(call, call + 'Util.f(b)'.length), new Span(recv, recv + 1), 'Util',
			'f', []
		);
		CliFixture.removeDir(dir);
		Assert.equals(Shadowed, judged);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A receiver type's `@:using` binds before the file's `using` — on the type itself, on a superclass and on an
	 * interface alike; the structural path and the facts path each keep such a site report-only.
	 */
	@:pin('control') @:killer('M-PSE-CLOSURE-USING')
	public function testAUsingOnTheReceiverTypeKeepsTheSiteReportOnly(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]], USING_MAIN, USING_MAIN);
		if (seen == null) return;
		for (site in ['own', 'super', 'iface']) Assert.equals('report', seen[site], '$site: $seen');
		for (site in ['super facts', 'iface facts']) Assert.equals('report', seen[site], '$site: $seen');
	}

	@:pin('control') @:killer('M-PSE-CLOSURE-USING-SUPER')
	public function testAUsingOnASupertypeKeepsTheSiteReportOnly(): Void {
		final seen: Null<Map<String, String>> = verdicts([[]], USING_MAIN, USING_MAIN);
		if (seen == null) return;
		for (site in ['super', 'iface']) Assert.equals('report', seen[site], '$site: $seen');
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

	/** The std `StringTools` module, which the index resolves a written `StringTools` against; none without a std. */
	private static function stdStringTools(): Array<{ file: String, source: String }> {
		#if (sys || nodejs)
		final std: Null<String> = StdResolver.stdDir();
		return std == null ? [] : [
			{ file: Path.join([std, 'StringTools.hx']), source: File.getContent(Path.join([std, 'StringTools.hx'])) }
		];
		#else
		return [];
		#end
	}

	/** `Util.f`, `Base`, and a module `Zeta` whose SUB-type `Extra` declares a static `f` taking a `Base`. */
	private static function subtypeModules(): Map<String, String> {
		return [
			'Base.hx' => 'class Base {\n\tpublic function new() {}\n}\n',
			'Util.hx' => 'class Util {\n\tpublic static function f(x:Base):String\n\t\treturn "Util.f";\n}\n',
			'Zeta.hx' => 'class Zeta {\n\tpublic static function g():Int\n\t\treturn 0;\n}\n\n'
				+ 'class Extra {\n\tpublic static function f(x:Base):String\n\t\treturn "Extra.f";\n}\n'
		];
	}

	/** `subtypeModules`, with `Extra` declared in the configured `Util.hx` itself. */
	private static function selfModules(): Map<String, String> {
		final out: Map<String, String> = subtypeModules();
		out['Util.hx'] = 'class Util {\n\tpublic static function f(x:Base):String\n\t\treturn "Util.f";\n}\n\n'
			+ 'class Extra {\n\tpublic static function f(x:Base):String\n\t\treturn "Extra.f";\n}\n';
		out['Zeta.hx'] = 'class Zeta {\n\tpublic static function g():Int\n\t\treturn 0;\n}\n';
		return out;
	}

	/**
	 * The verdict per marked site of `source` (default `MAIN`), compiled from `compiled` (default `MAIN`) by `build` under
	 * each define set of `configurations`, with `config` as the project's options: `fix`, `report`, or `drop` for a site
	 * with no finding. Null when haxe is unavailable.
	 */
	private static function verdicts(
		configurations: Array<Array<String>>, ?source: String, ?compiled: String, build: String = BUILD, config: String = CONFIG,
		?extra: Map<String, String>
	): Null<Map<String, String>> {
		#if (sys || nodejs)
		final written: Array<{ name: String, source: String }> = [
			{ name: 'Main.hx', source: compiled ?? MAIN },
			{ name: 'build.hxml', source: build }
		];
		for (name => text in extra ?? []) written.push({ name: name, source: text });
		final dir: String = CliFixture.writeTree('pse_facts', written);
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
		final main: String = Path.join([dir, 'Main.hx']);
		final files: Array<{ file: String, source: String }> = [{ file: main, source: text }];
		for (name => code in extra ?? []) files.push({ file: Path.join([dir, name]), source: code });
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new LibrarySources(stdStringTools()),
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
		for (v in found) if (v.file == main) {
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
