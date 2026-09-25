package unit.query;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CompilerFacts;
import anyparse.query.MemberReach;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `MemberReach` over the compiler's facts (`FactsView`, `CallGraphFacts`): each case compiles its fixture, reads the
 * facts, and asks whether the code between `/*<*\/` and `/*>*\/` in `Main.hx` may change `Main.items`. A function the
 * facts describe whole is read through them; everything else, and every marker, keeps the syntactic reading.
 */
@:nullSafety(Strict)
class MemberReachFactsTest extends Test {

	/** The build every fixture compiles: a js target. */
	private static inline final BUILD: String = '-cp .\n-main Main\n--js out.js\n';

	/** The library declaration of the built-in array type the index resolves against. */
	private static inline final STD_ARRAY: String = 'extern class Array<T> { public var length(default, null):Int; '
		+ 'public function push(x:T):Int; public function pop():Null<T>; public function indexOf(x:T, ?fromIndex:Int):Int; }';

	private static inline final REGION_OPEN: String = '/*<*/';
	private static inline final REGION_CLOSE: String = '/*>*/';

	/** A loop in `Main.main` whose body is the region, over the static `Main.items`. */
	private static inline final LOOP_HEAD: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n';

	@:pin('control') @:killer('M-FACTS-REACH-EDGES')
	public function testTheCompilerResolvesACallTheSyntaxCannot(): Void {
		// `pick()` declares no return type, so the syntax cannot tell which `grow` runs and admits every one so named; the
		// facts name `Safe.grow`
		final main: String = LOOP_HEAD + '\tstatic function pick() return new Safe();\n'
			+ '\tstatic function main() {\n\t\tvar s = pick();\n\t\tfor (i in 0...items.length) { /*<*/ s.grow(); /*>*/ }\n\t\tnew Grower().grow();\n\t}\n}\n'
			+ 'class Safe {\n\tpublic function new() {}\n\tpublic function grow():Void {}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main], null, false), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-BIND')
	public function testABoundMethodRunsWheneverItsClosureIsCalled(): Void {
		// `g.grow.bind(1)` is a closure the compiler makes and the graph holds no node for: calling it runs `Grower.grow`,
		// which the syntax cannot name — `mk()` declares no return type
		final main: String = LOOP_HEAD + '\tstatic function mk() return new Grower();\n'
			+ '\tstatic function main() {\n\t\tvar g = mk();\n\t\tvar f = g.grow.bind(1);\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ f(); /*>*/ }\n\t}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow(n:Int):Void Main.items.push(n);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-ALIKE')
	public function testACalleeTypedDifferentlyInAnotherBuildKeepsTheSyntax(): Void {
		// `pick` returns a `Safe` in the build compiled here and a `Grower` in one the list does not name: the facts'
		// `Safe.grow` answers for this build alone, and the syntax, which cannot type `s`, admits every `grow`
		final main: String = LOOP_HEAD + '\tstatic function pick() {\n\t\t#if other\n\t\treturn new Grower();\n\t\t#else\n'
			+ '\t\treturn new Safe();\n\t\t#end\n\t}\n'
			+ '\tstatic function main() {\n\t\tvar s = pick();\n\t\tfor (i in 0...items.length) { /*<*/ s.grow(); /*>*/ }\n\t}\n}\n'
			+ 'class Safe {\n\tpublic function new() {}\n\tpublic function grow():Void {}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-GUARDED-NAME')
	public function testAMemberAnotherBuildDeclaresShadowsAnExtension(): Void {
		// in a build defining `other`, `W` declares `grow` itself, and `w.grow()` runs it instead of the extension; the syntax,
		// which cannot type `w`, admits every `grow`
		final main: String = 'using Main.Ext;\n' + LOOP_HEAD + '\tstatic function mk() return new W();\n'
			+ '\tstatic function main() {\n\t\tvar w = mk();\n' + '\t\tfor (i in 0...items.length) { /*<*/ w.grow(); /*>*/ }\n\t}\n}\n'
			+ 'class W {\n\tpublic function new() {}\n\t#if other\n\tpublic function grow():Void Main.items.push(1);\n\t#end\n}\n'
			+ 'class Ext {\n\tpublic static function grow(w:W):Void {}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-OVERRIDES')
	public function testTheCompilersHierarchyReachesAnOverride(): Void {
		// `Mutator` extends `Worker` through an alias the name-based hierarchy does not see through: only the facts know the
		// override a dispatch on `Worker` reaches
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:Worker = new Mutator();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ w.run(); /*>*/ }\n\t}\n}\n'
			+ 'typedef W = Worker;\nclass Worker {\n\tpublic function new() {}\n\tpublic function run():Void {}\n}\n'
			+ 'class Mutator extends W {\n\toverride public function run():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-VALUE')
	public function testACallOfAValueAdmitsTheValueChannel(): Void {
		// `hook` holds whatever function was stored in it: the call is no edge, but any function used as a value may run
		final main: String = LOOP_HEAD + '\tstatic var hook:() -> Void = () -> {};\n'
			+ '\tstatic function main() {\n\t\thook = () -> { items.push(1); };\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ hook(); /*>*/ }\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-SPLICE')
	public function testAnInlinedCallKeepsItsBodysSyntax(): Void {
		// the compiler splices `grow` into `main` at `grow`'s own range: no fact places it in the loop, so `main` is read by
		// its syntax, which admits every `grow` — `mk()` declares no return type
		final main: String = LOOP_HEAD + '\tstatic function mk() return new Helper();\n'
			+ '\tstatic function main() {\n\t\tvar h = mk();\n\t\tfor (i in 0...items.length) { /*<*/ h.grow(); /*>*/ }\n\t}\n}\n'
			+ 'class Helper {\n\tpublic function new() {}\n\tpublic inline function grow():Void Main.items.push(9);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-LOCAL-INLINE')
	public function testALocalInlineFunctionKeepsItsBodysSyntax(): Void {
		// a local `inline function` is spliced at its own declaration inside the same body, where no marker says so: its
		// syntax is a function of its own, though the grammar gives it a kind apart from a local one, and the call is its edge
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tinline function helper():Void items.push(9);\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ helper(); /*>*/ }\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-NESTED-OWNER')
	public function testAFunctionWithoutFactsOfItsOwnIsNotReadThroughANestedOnes(): Void {
		// the compiler types a local `inline function` into its caller: the only function body inside its text is the
		// lambda it hands on, whose facts say nothing of the `g.grow()` beside it, which the syntax admits by name
		final main: String = LOOP_HEAD + '\tstatic function mk() return new Grower();\n\tstatic function later(f:() -> Void):Void {}\n'
			+ '\tstatic function main() {\n\t\tinline function run():Void {\n\t\t\tlater(() -> {});\n\t\t\tvar g = mk();\n\t\t\tg.grow();\n\t\t}\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ run(); /*>*/ }\n\t}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-ESCAPE-TYPED')
	public function testAnEscapeTheCompilerTypesCostsOnlyItsOwnFamily(): Void {
		// `mk()` returns an `Other` into a `Dynamic`: the syntax cannot type it and so lets any instance anywhere, the facts
		// say an `Other` escaped — which a `C` never is, so `poke` reaches no `C`'s `items`
		final main: String = 'class Main {\n\tstatic function mk() return new Other();\n'
			+ '\tstatic function main() {\n\t\tvar d:Dynamic = mk();\n\t\tvar o:Other = new Other();\n\t\tnew C().loop(o);\n\t}\n}\n'
			+ 'class C {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tpublic function loop(o:Other):Void {\n\t\tfor (i in 0...items.length) { /*<*/ Poker.poke(o); /*>*/ }\n\t}\n}\n'
			+ 'class Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
			+ 'class Poker {\n\tpublic static function poke(o:Other):Void o.items.push(9);\n}\n';
		final c: MemberRef = { owner: 'C', name: 'items' };
		assertMatch(ask(['Main.hx' => main], null, true, c, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-TOUCH-TYPED')
	public function testATouchThroughAnInferredReceiverIsTypedByTheCompiler(): Void {
		// `o` declares no type: the syntax cannot tell whose `items` `poke` grows, the facts say an `Other`'s
		final main: String = 'class Main {\n\tstatic function main() {\n\t\tnew C().loop();\n\t}\n}\n'
			+ 'class C {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tpublic function loop():Void {\n\t\tfor (i in 0...items.length) { /*<*/ Poker.poke(); /*>*/ }\n\t}\n}\n'
			+ 'class Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
			+ 'class Poker {\n\tpublic static function poke():Void {\n\t\tvar o = new Other();\n\t\to.items.push(9);\n\t}\n}\n';
		final c: MemberRef = { owner: 'C', name: 'items' };
		assertMatch(ask(['Main.hx' => main], null, true, c, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-MACRO')
	public function testAMacroExpansionIsUnknown(): Void {
		// the expansion of `Mac.gen()` grows `items` in code no fact and no syntax names
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Mac.gen(); /*>*/ }\n\t}\n}\n';
		final mac: String = 'class Mac {\n\tpublic static macro function gen() return macro Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main, 'Mac.hx' => mac]), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-REACH-DROPPED')
	public function testAConfigurationWithoutFactsLeavesTheSyntax(): Void {
		// one configuration fails to compile: the table holds less than the builds do, so nothing is read through it — not
		// even `main`, which every configuration typed alike
		final main: String = LOOP_HEAD + '\tstatic function pick() return new Safe();\n'
			+ '\tstatic function main() {\n\t\tvar s = pick();\n\t\tfor (i in 0...items.length) { /*<*/ s.grow(); /*>*/ }\n'
			+ '\t\tnew Grower().grow();\n\t\tBroken.f();\n\t}\n}\n'
			+ 'class Safe {\n\tpublic function new() {}\n\tpublic function grow():Void {}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n'
			+ 'class Broken {\n\tpublic static function f():Void {\n\t\t#if APQ_BROKEN nope(); #end\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main], [[], ['APQ_BROKEN']]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-REFLECT-VALUE')
	public function testAReflectiveMemberReadAsAValueIsUnknown(): Void {
		// `f` is `Reflect.field`: whatever calls it reaches a member by a name nothing here sees
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Dynamic = {};\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ var f = Reflect.field; f(o, "x"); /*>*/ }\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-REACH-BUILDS')
	public function testABuildMacroOnlyTheCompilerSawIsUnknown(): Void {
		// a global `addGlobalMetadata` puts a `@:build` on `Main` its text never spells
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ helper(); /*>*/ }\n\t}\n'
			+ '\tstatic function helper():Void {}\n}\n';
		final mac: String = 'class Mac {\n\tpublic static macro function b():Array<haxe.macro.Expr.Field> return null;\n}\n';
		final build: String = BUILD + '--macro addGlobalMetadata("Main", "@:build(Mac.b())", false)\n';
		assertMatch(ask(['Main.hx' => main, 'Mac.hx' => mac], null, true, null, false, build), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-REACH-GENERIC')
	public function testAGenericInstanceIsItsGenericClass(): Void {
		// the compiler builds `Box_Int` for `Box<Int>`: its call is `Box`'s method, which the syntax cannot name — `mk()`
		// declares no return type
		final main: String = LOOP_HEAD + '\tstatic function mk() return new Box<Int>();\n\tstatic function main() {\n\t\tvar b = mk();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ b.grow(); /*>*/ }\n\t}\n}\n'
			+ '@:generic class Box<T> {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-NATIVE-IDENT')
	public function testANativeIdentifierAdmitsWhatItMayCall(): Void {
		// `trace` is the compiler's own identifier: it runs `haxe.Log.trace`, which the program may replace
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\thaxe.Log.trace = (v, ?p) -> { items.push(1); };\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ trace(i); /*>*/ }\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-CONSTRUCTION')
	public function testAConstructionRunsTheInitializersOfItsGeneratedConstructor(): Void {
		// `Kid` declares no constructor: `new K()` runs its initializers, one of which grows `items` — through an alias the
		// syntax does not construct through
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ new K(); /*>*/ }\n\t}\n}\n'
			+ 'typedef K = Kid;\n' + 'class Base {\n\tpublic function new() {}\n}\n'
			+ 'class Kid extends Base {\n\tvar x:Int = Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-SYNTAX-UNION')
	public function testAnExtensionAnotherBuildBringsInIsKeptFromTheSyntax(): Void {
		// a build defining `other` brings in `Loud` last, and `w.go()` runs its `go`: the facts of `Runner.run`, which name
		// no type of this file, say `Quiet.go`; the syntax reads both `using`s and records the edge the facts may not take away
		final main: String = 'import Ext.W;\nimport Ext.Store;\nusing Ext.Quiet;\n#if other\nusing Ext.Loud;\n#end\n'
			+ 'class Main {\n\tstatic function main() {\n\t\tRunner.run(new W());\n\t}\n}\n'
			+ 'class Runner {\n\tpublic static function run(w:W):Void {\n'
			+ '\t\tfor (i in 0...Store.items.length) { /*<*/ w.go(); /*>*/ }\n\t}\n}\n';
		final ext: String = 'class Ext {}\n' + 'class W {\n\tpublic function new() {}\n}\n'
			+ 'class Store {\n\tpublic static var items:Array<Int> = [1, 2];\n}\n'
			+ 'class Quiet {\n\tpublic static function go(w:W):Void {}\n}\n'
			+ 'class Loud {\n\tpublic static function go(w:W):Void Store.items.push(1);\n}\n';
		final store: MemberRef = { owner: 'Store', name: 'items' };
		assertMatch(ask(['Main.hx' => main, 'Ext.hx' => ext], null, true, store), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-GUARDED-IMPORT')
	public function testATypeInAFileImportingUnderAConditionKeepsTheSyntax(): Void {
		// `R.f` takes the `T` its file imports: `b.T` here, and in a build defining `other` `a.T`, whose `@:from` runs on the
		// argument and grows `items` — no edge names that conversion, and the facts of this build hold none
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ R.f(o); /*>*/ }\n\t}\n}\n' + 'class Obj {\n\tpublic function new() {}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'R.hx' => '#if other\nimport a.T;\n#else\nimport b.T;\n#end\n\nclass R {\n\tpublic static function f(x:T):Void {}\n}\n',
			'a/T.hx' => 'package a;\n\nabstract T(Dynamic) {\n\t@:from static function fromObj(o:Obj):T {\n\t\tMain.items.push(1);\n'
				+ '\t\treturn cast o;\n\t}\n}\n',
			'b/T.hx' => 'package b;\n\nabstract T(Dynamic) from Dynamic {}\n'
		];
		assertMatch(ask(files), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-LIBRARY-DYNAMIC')
	public function testALibraryDynamicMethodNotReadYetIsFollowed(): Void {
		// `LibObj.grow` is a `dynamic` method of a library file the graph has not read: the call is a read of the field, and
		// its body — the value it holds until replaced — grows `items`; the syntax, which cannot type `o`, names no `grow`
		final main: String = LOOP_HEAD + '\tstatic function mk() return new LibObj();\n'
			+ '\tstatic function main() {\n\t\tvar o = mk();\n\t\tfor (i in 0...items.length) { /*<*/ o.grow(); /*>*/ }\n\t}\n}\n';
		final lib: String = 'class LibObj {\n\tpublic function new() {}\n\tpublic dynamic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, ['LibObj.hx' => lib]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-ABSTRACT-TEXT-ANY')
	public function testAConversionOfAnAbstractRunsWhatItsOwnConversionDoes(): Void {
		// the library abstract `Wrap`'s own `toString` converts the value it wraps, as `Any`'s does, and the walk never enters
		// it: it reaches no toucher by an edge; `a.string()` is `Std.string(a)`, which the syntax does not name
		final main: String = 'using Std;\n' + LOOP_HEAD
			+ '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n\t\tvar s:String = "";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ final a:Wrap = o; s += a.string(); /*>*/ }\n\t}\n}\n'
			+ 'class Obj {\n\tpublic function new() {}\n\tpublic function toString():String {\n\t\tMain.items.push(1);\n\t\treturn "o";\n\t}\n}\n';
		final wrap: String = 'abstract Wrap(Dynamic) from Dynamic {\n\tpublic function toString():String return Std.string(this);\n}\n';
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, ['Wrap.hx' => wrap]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-UNREAD-VALUE')
	public function testAStoredFunctionValueMayConvertWhatItIsHanded(): Void {
		// `fmt` holds a lambda the walk never enters — it reaches no toucher by an edge — whose `Std.string` runs `toString`
		final main: String = LOOP_HEAD + '\tstatic var fmt:Dynamic -> String = v -> Std.string(v);\n'
			+ '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n\t\tvar s:String = "";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ s += fmt(o); /*>*/ }\n\t}\n}\n'
			+ 'class Obj {\n\tpublic function new() {}\n\tpublic function toString():String {\n\t\tMain.items.push(1);\n\t\treturn "o";\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-USING-META') @:killer('M-GRAPH-USING-META') @:killer('M-INDEX-GUARDED-META-LIFT')
	public function testATypeBringingExtensionsInUnderAConditionIsUnknown(): Void {
		// a build defining `other` puts `@:using(Main.Loud)` on `W`, and `w.go()` runs `Loud.go`: neither the facts nor the
		// `using` the file spells name it
		final main: String = 'using Main.Quiet;\n' + LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:W = new W();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ w.go(); /*>*/ }\n\t}\n}\n'
			+ '#if other\n@:using(Main.Loud)\n#end\nclass W {\n\tpublic function new() {}\n}\n'
			+ 'class Quiet {\n\tpublic static function go(w:W):Void {}\n}\n'
			+ 'class Loud {\n\tpublic static function go(w:W):Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-REACH-UNREAD-IMPLICIT')
	public function testAStoredFunctionValueMayRunAnOperatorOverload(): Void {
		// `f` holds a lambda the walk never enters — it reaches no toucher by an edge — whose `==` runs `AE.eq`
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool = a -> a == a;\n'
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ f(new AE(1)); /*>*/ }\n\t}\n}\n'
			+ 'abstract AE(Int) {\n\tpublic inline function new(i:Int) this = i;\n\n'
			+ '\t@:op(A == B) public function eq(b:AE):Bool return Main.items.push(1) == 0;\n}\n';
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	/**
	 * The answer for `member` (by default `Main.items`) over the region of `Main.hx` among `files`, compiled by `build` under
	 * each define set of `configurations` and read through the facts unless `withFacts` is false; `classpathComplete` is
	 * the analysis's word that the index holds every type the builds compile. `library` files compile beside
	 * them and are indexed, but are no part of the project: the walk reads one only when it follows code into it.
	 */
	private static function ask(
		files: Map<String, String>, ?configurations: Array<Array<String>>, withFacts: Bool = true, ?member: MemberRef,
		classpathComplete: Bool = false, ?build: String, ?library: Map<String, String>
	): ReachResult {
		final entries: Array<{ name: String, source: String }> = [for (name => text in files) { name: name, source: text }];
		for (name => text in library ?? []) entries.push({ name: name, source: text });
		entries.push({ name: 'build.hxml', source: build ?? BUILD });
		final dir: String = CliFixture.writeTree('reach_facts', entries);
		final oracles: Array<OracleConfig> = [for (d in configurations ?? [[]]) { hxml: 'build.hxml', dir: dir, defines: d }];
		final facts: Null<CompilerFacts> = withFacts ? TypedFactsProbe.probeAll(oracles) : null;
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final project: Array<{ file: String, source: String }> = [
			for (name => text in files)
				{
					file: Path.join([dir, name]),
					source: text
				}
		];
		final libraries: Array<{ file: String, source: String }> = [
			for (name => text in library ?? [])
				{
					file: Path.join([dir, name]),
					source: text
				}
		];
		final index: SymbolIndex = SymbolIndex.build(
			project.concat(libraries).concat([{ file: 'std/Array.hx', source: STD_ARRAY }]), plugin
		);
		final reach: MemberReach = new MemberReach(
			plugin, project, index, true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED, null, () -> classpathComplete, facts
		);
		final source: String = files['Main.hx'] ?? '';
		final result: ReachResult = reach.mayReach(
			Region(Path.join([dir, 'Main.hx']), regionOf(source)), member ?? { owner: 'Main', name: 'items' }, Mutate
		);
		CliFixture.removeDir(dir);
		return result;
	}

	private static function regionOf(src: String): Span {
		final from: Int = src.indexOf(REGION_OPEN) + REGION_OPEN.length;
		return new Span(from, src.indexOf(REGION_CLOSE));
	}

	private static function assertMatch(result: ReachResult, expected: ReachResult -> Bool, ?pos: haxe.PosInfos): Void {
		Assert.isTrue(expected(result), 'got $result', pos);
	}

}
