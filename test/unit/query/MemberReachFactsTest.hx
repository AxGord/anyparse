package unit.query;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.ReachDefinesProbe;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.CompilerFacts;
import anyparse.query.MemberReach;
import anyparse.query.ReachLiveness.ReachConfiguration;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `MemberReach` over the compiler's facts (`FactsView`, `CallGraphFacts`): each case compiles its fixture, reads the
 * facts, and asks whether the code between `/*<*\/` and `/*>*\/` in `Main.hx` may change `Main.items`. A function the
 * facts describe whole is read through them; everything else, and every marker, keeps the syntactic reading.
 */
@:nullSafety(Strict)
class MemberReachFactsTest extends Test {

	/** The build every fixture compiles: a js target. */
	private static inline final BUILD: String = '-cp .\n-main Main\n--js out.js\n';

	/** `BUILD` with a classpath of its own per build (`PICK_CLASSPATH`): `other/` when `other` is defined, else `base/`. */
	private static inline final PER_BUILD_CLASSPATH: String = '-cp .\n--macro Cp.pick()\n-main Main\n--js out.js\n';

	/** The initialization macro of `PER_BUILD_CLASSPATH`, compiled by each build and indexed by nothing. */
	private static inline final PICK_CLASSPATH: String = 'class Cp {\n\tpublic static function pick():Void\n'
		+ '\t\thaxe.macro.Compiler.addClassPath(haxe.macro.Context.defined("other") ? "other" : "base");\n}\n';

	/** The library declaration of the built-in array type the index resolves against. */
	private static inline final STD_ARRAY: String = 'extern class Array<T> { public var length(default, null):Int; '
		+ 'public function push(x:T):Int; public function pop():Null<T>; public function indexOf(x:T, ?fromIndex:Int):Int; }';

	/** The library declarations of `Std` and `StringTools` the index resolves against, where a test needs their pure calls known. */
	private static final STD_STD: Map<String, String> = [
		'std/Std.hx' => 'extern class Std { public static function parseFloat(x:String):Float; }',
		'std/StringTools.hx' => 'extern class StringTools { public static function fastCodeAt(s:String, index:Int):Int; }'
	];

	private static inline final REGION_OPEN: String = '/*<*/';
	private static inline final REGION_CLOSE: String = '/*>*/';

	/** A loop in `Main.main` whose body is the region, over the static `Main.items`. */
	private static inline final LOOP_HEAD: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n';

	/** `Obj`, whose `toString` replaces `Main.items`. */
	private static inline final CLEARING_OBJ: String = 'class Obj {\n\tpublic function new() {}\n\n'
		+ '\tpublic function toString():String {\n\t\tMain.items = [];\n\t\treturn "o";\n\t}\n}\n';

	/** `Walker`, an iterator whose `next` replaces `Main.items`. */
	private static inline final CLEARING_WALKER: String = 'class Walker {\n\tpublic function new() {}\n\n'
		+ '\tpublic function hasNext():Bool return false;\n\n\tpublic function next():Int {\n\t\tMain.items = [];\n\t\treturn 0;\n\t}\n}\n';

	/**
	 * The region runs `lib.Vec.splice` (`sharedNameLibrary`) through `Box.put`, and `Walker.next` replaces `Main.items`. The
	 * walk reads `lib/Vec.hx` for `VecIter.zero`, called first: a simple name two types share names no one file to read.
	 */
	private static inline final SHARED_NAME_MAIN: String = 'import lib.Vec;\nimport lib.Vec.VecIter;\n\n' + LOOP_HEAD
		+ '\tstatic function main() {\n\t\tvar w:Walker = new Walker();\n'
		+ '\t\tfor (i in 0...items.length) { /*<*/ Box.put(); /*>*/ }\n\t}\n}\n'
		+ 'class Box {\n\tpublic static function put():Void {\n\t\tVecIter.zero();\n\t\tVec.splice(1);\n\t}\n}\n' + CLEARING_WALKER;

	/** `AE`, an abstract whose `==` replaces `Main.items`. */
	private static inline final CLEARING_EQ: String = 'abstract AE(Int) {\n\tpublic function new(i:Int) this = i;\n\n'
		+ '\t@:op(A == B) public function eq(b:AE):Bool {\n\t\tMain.items = [];\n\t\treturn true;\n\t}\n}\n';

	/** A class with the instance member `Main.items`, whose methods the build types though `main` calls none of them. */
	private static inline final MEMBER_HEAD: String = 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
		+ '\tstatic function main() {}\n';

	/**
	 * `h.grow()` runs the `inline` `Helper.grow`, which changes `items` — `mk()` declares no return type, so the syntax
	 * cannot resolve the call.
	 */
	private static final INLINED_GROW: String = LOOP_HEAD + '\tstatic function mk() return new Helper();\n'
		+ '\tstatic function main() {\n\t\tvar h = mk();\n\t\tfor (i in 0...items.length) { /*<*/ h.grow(); /*>*/ }\n\t}\n}\n'
		+ 'class Helper {\n\tpublic function new() {}\n\tpublic inline function grow():Void Main.items.push(9);\n}\n';

	/** The region converts a `String` to a `Quiet` by the `inline` `@:from` `conversion`, a `@:from` of `Quiet`'s own. */
	private static function inlineConversion(conversion: String): String {
		return LOOP_HEAD + '\tstatic function main() {\n\t\tvar l:Loud = 1;\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ var q:Quiet = "x"; /*>*/ }\n\t}\n}\n'
			+ 'abstract Quiet(String) {\n\t@:from static inline function of(s:String):Quiet ' + conversion + '\n}\n'
			+ 'abstract Loud(Int) {\n\t@:from static function of(i:Int):Loud {\n\t\tMain.items.push(i);\n\t\treturn cast i;\n\t}\n}\n';
	}

	/** `main` calls the local `inline function` `helper`, which changes `items`. */
	private static final LOCAL_INLINE: String = LOOP_HEAD
		+ '\tstatic function main() {\n\t\tinline function helper():Void items.push(9);\n'
		+ '\t\tfor (i in 0...items.length) { /*<*/ helper(); /*>*/ }\n\t}\n}\n';

	/** `pick` returns a `Safe`, whose `grow` changes nothing, and in a build defining `other` a `Grower`, whose `grow` does. */
	private static final CALLEE_PER_BUILD: String = LOOP_HEAD + '\tstatic function pick() {\n\t\t#if other\n\t\treturn new Grower();\n'
		+ '\t\t#else\n\t\treturn new Safe();\n\t\t#end\n\t}\n'
		+ '\tstatic function main() {\n\t\tvar s = pick();\n\t\tfor (i in 0...items.length) { /*<*/ s.grow(); /*>*/ }\n\t}\n}\n'
		+ 'class Safe {\n\tpublic function new() {}\n\tpublic function grow():Void {}\n}\n'
		+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';

	/** `w.grow()` runs the extension `Ext.grow`, or in a build defining `other` the `grow` `W` declares there. */
	private static final MEMBER_PER_BUILD: String = 'using Main.Ext;\n' + LOOP_HEAD + '\tstatic function mk() return new W();\n'
		+ '\tstatic function main() {\n\t\tvar w = mk();\n' + '\t\tfor (i in 0...items.length) { /*<*/ w.grow(); /*>*/ }\n\t}\n}\n'
		+ 'class W {\n\tpublic function new() {}\n\t#if other\n\tpublic function grow():Void Main.items.push(1);\n\t#end\n}\n'
		+ 'class Ext {\n\tpublic static function grow(w:W):Void {}\n}\n';

	/**
	 * `w.go()` in `Runner.run` runs `Quiet.go`, or in a build defining `other`, which brings `Loud` in last, `Loud.go`,
	 * which changes `Store.items`.
	 */
	private static final EXTENSION_PER_BUILD: Map<String, String> = [
		'Main.hx' => 'import Ext.W;\nimport Ext.Store;\nusing Ext.Quiet;\n#if other\nusing Ext.Loud;\n#end\n'
			+ 'class Main {\n\tstatic function main() {\n\t\tRunner.run(new W());\n\t}\n}\n'
			+ 'class Runner {\n\tpublic static function run(w:W):Void {\n'
			+ '\t\tfor (i in 0...Store.items.length) { /*<*/ w.go(); /*>*/ }\n\t}\n}\n',
		'Ext.hx' => 'class Ext {}\n' + 'class W {\n\tpublic function new() {}\n}\n'
			+ 'class Store {\n\tpublic static var items:Array<Int> = [1, 2];\n}\n'
			+ 'class Quiet {\n\tpublic static function go(w:W):Void {}\n}\n'
			+ 'class Loud {\n\tpublic static function go(w:W):Void Store.items.push(1);\n}\n'
	];

	/**
	 * `R.f` takes the `T` its file imports: `b.T`, or in a build defining `other` `a.T`, whose `@:from` runs on the
	 * argument and changes `items`.
	 */
	private static final IMPORT_PER_BUILD: Map<String, String> = [
		'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ R.f(o); /*>*/ }\n\t}\n}\n' + 'class Obj {\n\tpublic function new() {}\n}\n',
		'R.hx' => '#if other\nimport a.T;\n#else\nimport b.T;\n#end\n\nclass R {\n\tpublic static function f(x:T):Void {}\n}\n',
		'a/T.hx' => 'package a;\n\nabstract T(Dynamic) {\n\t@:from static function fromObj(o:Obj):T {\n\t\tMain.items.push(1);\n'
			+ '\t\treturn cast o;\n\t}\n}\n',
		'b/T.hx' => 'package b;\n\nabstract T(Dynamic) from Dynamic {}\n'
	];

	/** `w.go()` runs `Quiet.go`, or in a build defining `other`, which puts `@:using(Main.Loud)` on `W`, `Loud.go`. */
	private static final USING_PER_BUILD: String = 'using Main.Quiet;\n' + LOOP_HEAD
		+ '\tstatic function main() {\n\t\tvar w:W = new W();\n' + '\t\tfor (i in 0...items.length) { /*<*/ w.go(); /*>*/ }\n\t}\n}\n'
		+ '#if other\n@:using(Main.Loud)\n#end\nclass W {\n\tpublic function new() {}\n}\n'
		+ 'class Quiet {\n\tpublic static function go(w:W):Void {}\n}\n'
		+ 'class Loud {\n\tpublic static function go(w:W):Void Main.items.push(1);\n}\n';

	/**
	 * The build macros of the `Mac` module: `keep` hands its class's fields back as they are, `bind` does so only for a class
	 * carrying `@:bind` and changes nothing otherwise (openfl's `initBinding`), `hub` rebuilds every class of the root
	 * package from its own fields (tink's `SyntaxHub`), `rewrite` makes its class's `calm` push onto `Main.items`, `add`
	 * gives its class an `added` doing so, `dyn` one calling what a dynamic value's `items` holds, `prop` makes its class's
	 * `items` a property read through `get_items`, `recall` makes its class's `all` return `Main.make()`, positioned where
	 * the old body was, `loop` makes its class's `f` push onto `Store.items`, and `leak` makes its class's `g` store
	 * `Main.items` in `Other.keep`. The expression macro `t` builds a call of `Words.tr` (TM's `Lang.t`).
	 */
	private static final BUILD_MACROS: String = 'import haxe.macro.Context;\nimport haxe.macro.Expr;\n\nclass Mac {\n'
		+ '\tpublic static macro function keep():Array<Field> return Context.getBuildFields();\n\n'
		+ '\tpublic static macro function bind():Array<Field> {\n\t\tif (!Context.getLocalClass().get().meta.has(":bind")) return null;\n'
		+ '\t\treturn Context.getBuildFields();\n\t}\n\n' + '\tpublic static macro function hub():Array<Field> {\n'
		+ '\t\tfinal c = Context.getLocalClass()?.get();\n'
		+ '\t\tif (c == null || c.pack.length > 0 || c.isExtern || c.module != c.name) return null;\n'
		+ '\t\treturn Context.getBuildFields();\n\t}\n\n' + '\tpublic static macro function rewrite():Array<Field> {\n'
		+ '\t\tfinal fields:Array<Field> = Context.getBuildFields();\n\t\tfor (f in fields) if (f.name == "calm") switch f.kind {\n'
		+ '\t\t\tcase FFun(fn): fn.expr = macro Main.items.push(1);\n\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n'
		+ '\tpublic static macro function add():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\tfields.push({\n\t\t\tname: "added",\n\t\t\tpos: Context.currentPos(),\n\t\t\taccess: [APublic],\n'
		+ '\t\t\tkind: FFun({ args: [], ret: macro:Void, expr: macro Main.items.push(1) })\n\t\t});\n\t\treturn fields;\n\t}\n\n'
		+ '\tpublic static macro function prop():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\tfor (f in fields) if (f.name == "items") switch f.kind {\n'
		+ '\t\t\tcase FVar(t, e):\n\t\t\t\tf.kind = FProp("get", "default", t, e);\n\t\t\t\tf.meta.push({ name: ":isVar", pos: f.pos });\n'
		+ '\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n' + '\tpublic static macro function recall():Array<Field> {\n'
		+ '\t\tfinal fields:Array<Field> = Context.getBuildFields();\n\t\tfor (f in fields) if (f.name == "all") switch f.kind {\n'
		+ '\t\t\tcase FFun(fn): fn.expr = macro @:pos(fn.expr.pos) return Main.make();\n\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n'
		+ '\tpublic static macro function dyn():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\tfields.push({\n\t\t\tname: "added",\n\t\t\tpos: Context.currentPos(),\n\t\t\taccess: [APublic],\n'
		+ '\t\t\tkind: FFun({ args: [], ret: macro:Void, expr: macro (cast null : Dynamic).items(1) })\n\t\t});\n'
		+ '\t\treturn fields;\n\t}\n\n' + '\tpublic static macro function loop():Array<Field> {\n'
		+ '\t\tfinal fields:Array<Field> = Context.getBuildFields();\n\t\tfor (f in fields) if (f.name == "f") switch f.kind {\n'
		+ '\t\t\tcase FFun(fn): fn.expr = macro Store.items.push(1);\n\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n'
		+ '\tpublic static macro function leak():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\tfor (f in fields) if (f.name == "g") switch f.kind {\n'
		+ '\t\t\tcase FFun(fn): fn.expr = macro Other.keep = Main.items;\n\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n'
		+ '\tpublic static macro function t(e:Expr):Expr return macro Words.tr($$e);\n}\n';

	/**
	 * A fixture whose region calls `region` on the `Helper` in `Main.main`, `Helper` extending a `Base` that carries
	 * `@:autoBuild(Mac.<builder>())` (`BUILD_MACROS`): its text declares `calm`, which changes nothing.
	 */
	private static function helperBuiltBy(builder: String, region: String): Map<String, String> {
		return [
			'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfinal h:Helper = new Helper();\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ ' + region + ' /*>*/ }\n\t}\n}\n',
			'Helper.hx' => 'class Helper extends Base {\n\tpublic function calm():Void {}\n}\n',
			'Base.hx' => '@:autoBuild(Mac.' + builder + '())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
	}

	/** The build of a fixture every class of whose root package the global `Mac.hub` rebuilds from its own fields (tink's `SyntaxHub`). */
	private static final HUB_BUILD: String = BUILD + '--macro addGlobalMetadata("", "@:build(Mac.hub())")\n';

	/** The runtime of the expression macro `Mac.t` (`BUILD_MACROS`), and a function the code it builds is handed to. */
	private static final WORDS: String = 'class Words {\n\tpublic static function tr(s:String):String return s;\n\n'
		+ '\tpublic static function say(s:String):Void {}\n}\n';

	/** A class holding `n`, and `q` read through a getter. */
	private static final HOLDER: String = 'class Holder {\n\tpublic var n:Int = 0;\n\tpublic var q(get, never):Int;\n\n'
		+ '\tpublic function new() {}\n\n\tfunction get_q():Int return n;\n}\n';

	/**
	 * A fixture whose region calls `Util.calm`, beside which `Util` declares `member` — code the walk never enters, but part
	 * of what every build compiled of `Util`, which `HUB_BUILD` rebuilds — and `more` files.
	 */
	private static function utilWith(member: String, ?more: Map<String, String>): Map<String, String> {
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Util.calm(); /*>*/ }\n\t}\n}\n',
			'Util.hx' => 'class Util {\n\tpublic static function calm():Void {}\n\n\t' + member + '\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		for (name => text in more ?? []) files[name] = text;
		return files;
	}

	/** `ask` of `files` built by `HUB_BUILD`, listed as the whole list of builds: the facts are the truth. */
	private static function hubAsk(files: Map<String, String>): ReachResult {
		return ask(files, null, true, null, false, HUB_BUILD, null, null, true);
	}

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

	@:pin('control') @:killer('M-FACTS-TRUTH-CONDITIONAL') @:killer('M-FACTS-TRUTH-CONDITIONAL-ALWAYS')
	public function testABodyHoldingADirectiveIsReadFromTheFactsOfTheListedBuilds(): Void {
		// `main` holds a directive: a build the list does not name may type it otherwise, so only under the whole list of builds
		// do the facts, the union of every branch a build takes, name `Safe.grow` for it
		final main: String = LOOP_HEAD + '\tstatic function pick() return new Safe();\n'
			+ '\tstatic function main() {\n\t\tvar s = pick();\n\t\t#if other\n\t\ttrace(s);\n\t\t#end\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ s.grow(); /*>*/ }\n\t\tnew Grower().grow();\n\t}\n}\n'
			+ 'class Safe {\n\tpublic function new() {}\n\tpublic function grow():Void {}\n}\n'
			+ 'class Grower {\n\tpublic function new() {}\n\tpublic function grow():Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main], [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main], [[], ['other']]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-TRUTH-MUTE')
	public function testUnderTheWholeListTheSyntaxsEdgeAtASiteTheFactsTypeIsDropped(): Void {
		// the syntax reads both `using`s and names `Loud.go` for `w.go()` as well as `Quiet.go`, which the compiler picks —
		// `Loud.go` takes a `String`: `main` is read through its facts either way, but only under the whole list of builds does
		// the syntax's edge at a site they type go
		final main: String = 'using Main.Quiet;\nusing Main.Loud;\n' + LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:W = new W();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ w.go(); /*>*/ }\n\t}\n}\n' + 'class W {\n\tpublic function new() {}\n}\n'
			+ 'class Quiet {\n\tpublic static function go(w:W):Void {}\n}\n'
			+ 'class Loud {\n\tpublic static function go(s:String):Void Main.items.push(1);\n}\n';
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
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

	@:pin('control') @:killer('M-FACTS-REACH-ALIKE') @:killer('M-FACTS-TRUTH-CONTEXT-ALWAYS')
	public function testACalleeTypedDifferentlyInAnotherBuildKeepsTheSyntax(): Void {
		// `pick` returns a `Safe` in the build compiled here and a `Grower` in one the list does not name: the facts'
		// `Safe.grow` answers for this build alone, and the syntax, which cannot type `s`, admits every `grow`
		assertMatch(ask(['Main.hx' => CALLEE_PER_BUILD]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-CONTEXT')
	public function testACalleeEveryListedBuildTypesIsReadFromTheirFacts(): Void {
		// under the whole list of builds no other build exists: the facts of the listed ones name `Safe.grow` alone, and
		// `Grower.grow` too once one of them defines `other`
		assertMatch(ask(['Main.hx' => CALLEE_PER_BUILD], [[]], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(
			ask(['Main.hx' => CALLEE_PER_BUILD], [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Reached(_))
		);
	}

	@:pin('control') @:killer('M-FACTS-REACH-GUARDED-NAME')
	public function testAMemberAnotherBuildDeclaresShadowsAnExtension(): Void {
		// in a build defining `other`, `W` declares `grow` itself, and `w.grow()` runs it instead of the extension; the syntax,
		// which cannot type `w`, admits every `grow`
		assertMatch(ask(['Main.hx' => MEMBER_PER_BUILD]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-CONTEXT')
	public function testAMemberOnlyAListedBuildDeclaresShadowsAnExtensionThere(): Void {
		// the extension runs in every listed build, until one of them defines `other` and declares `W.grow` — where no listed
		// build takes that branch, it is dead code whatever the facts say
		assertMatch(ask(['Main.hx' => MEMBER_PER_BUILD], [[]], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(
			ask(['Main.hx' => MEMBER_PER_BUILD], [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Reached(_))
		);
		// a build defining `other` declares a `grow` on another type: every listed build's facts still name the extension,
		// which only the truth lets answer — no other build exists to shadow it
		final elsewhere: String = StringTools.replace(
			MEMBER_PER_BUILD, 'W {\n\tpublic function new() {}\n\t#if other', 'W {\n\tpublic function new() {}\n}\nclass V {\n\t#if other'
		);
		assertMatch(ask(['Main.hx' => elsewhere], [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => elsewhere], [[], ['other']]), r -> !r.match(Proven));
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

	@:pin('control') @:killer('M-FACTS-REACH-SPLICE') @:killer('M-FACTS-TRUTH-SPLICE-ALWAYS')
	public function testAnInlinedCallKeepsItsBodysSyntax(): Void {
		// the compiler splices `grow` into `main` at `grow`'s own range: no fact places it in the loop, so `main` is read by
		// its syntax, which admits every `grow`
		assertMatch(ask(['Main.hx' => INLINED_GROW]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-TRUTH-SPLICED-SEEDS') @:killer('M-GRAPH-FACTS-SPLICED-SITE')
	public function testUnderTheTruthAnInlinedCallIsReachedThroughItsEdge(): Void {
		// under the whole list of builds `main` is read through its facts, the splice of `grow` among them: they place its
		// `inlined` call at `grow`, not in the loop, so it is `main`'s wherever the region lies in it — the edge to `grow`,
		// whose text changes `items`, is the only thing that says the region runs it
		assertMatch(truthAsk(['Main.hx' => INLINED_GROW]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-SPLICE') @:killer('M-FACTS-SPLICED-WITHIN') @:killer('M-FACTS-TRUTH-SITES-SPLICED')
	public function testUnderTheTruthAnInlineConversionIsItsEdgeAlone(): Void {
		// the `inline` `@:from` of `Quiet` is spliced into `main`, which its syntax alone does not spell: read by its syntax,
		// `main` admits every conversion in play, `Loud`'s that changes `items` among them. Under the whole list of builds its
		// facts name the one conversion that runs, which changes nothing
		final main: String = inlineConversion('return cast s;');
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-TRUTH-SPLICED-SEEDS') @:killer('M-GRAPH-FACTS-SPLICED-SITE')
	public function testUnderTheTruthAnInlineConversionThatChangesTheMemberIsReached(): Void {
		// the facts place the spliced conversion at `Quiet.of`, not in the region: the region runs it all the same
		final main: String = inlineConversion('{\n\t\tMain.items.push(1);\n\t\treturn cast s;\n\t}');
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-FACTS-SPLICED-SITE')
	public function testUnderTheTruthAnEdgeSplicedFromAnotherFileIsNoSiteOfItsCaller(): Void {
		// `Helper.grow` is spliced into `run` at `Helper.hx`'s ranges, which in `Main.hx` fall in a branch no build compiles: an
		// edge filed under `Main.hx` at such a range would be read as dead code there, and `run` as running nothing
		final dead: String = '#if never\n/*' + StringTools.lpad('', 'x', 200) + '*/\n#end\n';
		final main: String = dead + LOOP_HEAD + '\tstatic function mk() return new Helper();\n\tstatic function run():Void mk().grow();\n'
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ run(); /*>*/ }\n\t}\n}\n';
		final helper: String = 'class Helper {\n\tpublic function new() {}\n\tpublic inline function grow():Void Main.items.push(9);\n}\n';
		assertMatch(truthAsk(['Main.hx' => main, 'Helper.hx' => helper]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-FACTS-SPLICED-SITE') @:killer('M-GRAPH-FACTS-SPLICED-FILE') @:killer('M-FACTS-TRUTH-SPLICE')
	@:access(anyparse.query.MemberReach)
	public function testAFunctionSplicedFromAnotherFileIsTheNodeItsCalleeDeclares(): Void {
		// `Lib.wrap` is spliced into `run`, lambda and all, at `Lib.hx`'s ranges: the edges carry no site of `Main.hx`, and the
		// lambda is the node the graph declares in `Lib.hx`
		final main: String = MEMBER_HEAD + '\tfunction run():Void Lib.wrap(this);\n}\n';
		final lib: String = 'class Lib {\n\tpublic static inline function wrap(m:Main):Void {\n\t\tvar f = () -> m.items.pop();\n'
			+ '\t\tf();\n\t}\n}\n';
		final edges: Array<{
			to: String,
			file: String,
			kind: String,
			placed: Bool
		}> = withReach(['Main.hx' => main, 'Lib.hx' => lib], null, true, false, null, null, null, true, (reach, dir) -> {
			final g: CallGraph = reach.graph();
			[
				for (e in g.outEdges('Main.run'))
					{
						to: e.to,
						file: Path.withoutDirectory(g.node(e.to)?.file ?? ''),
						kind: e.kind.label(),
						placed: e.span != null
					}
			];
		});
		Assert.isTrue(edges.exists(e -> e.to == 'Lib.wrap' && e.kind == 'call' && !e.placed), 'the splice has a site: $edges');
		Assert.isTrue(edges.exists(e -> e.to != 'Lib.wrap' && e.file == 'Lib.hx' && e.kind == 'ref' && !e.placed), 'no lambda: $edges');
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-SPLICE') @:killer('M-FACTS-TRUTH-HAZARDS-SPLICED') @:killer('M-FACTS-SPLICED-WITHIN')
	public function testUnderTheTruthUntypedCodeBesideAnInlinedCallIsReadThroughTheFacts(): Void {
		// `h` is spliced into `f` at `h`'s own range: under the whole list of builds `f` is read through its facts all the same,
		// which record the untyped field read beside it
		final main: String = MEMBER_HEAD
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ var z = untyped this.zz; h(); /*>*/ }\n\t}\n'
			+ '\tinline function h():Void k();\n\tfunction k():Void {}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-SPLICED-WITHIN-UNPLACED') @:killer('M-FACTS-TRUTH-SITES-SPLICED') @:killer('M-FACTS-SPLICED-WITHIN')
	public function testUnderTheTruthASplicedStringConversionIsTheRegions(): Void {
		// `b.add(o)` splices `StringBuf.add`, whose `+=` converts `o` to a string: the facts place that conversion in
		// `StringBuf.hx`, and the region runs it — `Obj.toString` changes `items`
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar o = new Obj();\n\t\tvar b = new StringBuf();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ b.add(o); /*>*/ }\n\t}\n}\n'
			+ 'class Obj {\n\tpublic function new() {}\n\tpublic function toString():String {\n\t\tMain.items.push(1);\n\t\treturn "o";\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-REFLECTION-INLINED')
	public function testUnderTheTruthAnInlinedReflectiveCallIsADynamicName(): Void {
		// `sf` is `Reflect.setField`, `inline` on js: its splice leaves no reflective call among the facts, and the syntax
		// does not see one under another name
		final main: String = 'import Reflect.setField as sf;\n' + MEMBER_HEAD + '\tfunction f():Void {\n\t\tvar n = "it" + "ems";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ sf(this, n, [1]); /*>*/ }\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-SPLICE-HARMLESS') @:killer('M-GRAPH-FACTS-SPLICE-HARMLESS')
	@:killer('M-FACTS-SPLICE-SITE') @:killer('M-FACTS-SPLICE-BODY')
	public function testUnderTheTruthWhatAPureLibraryCallSplicedInIsNoneOfTheRegions(): Void {
		// `Std.parseFloat` is `inline` on js, its body a `js.Syntax.code`, and so is `StringTools.fastCodeAt`, its body a call
		// of `charCodeAt` off a structure: each splice is a call of a function that runs no project code, whose edge answers
		// for all it does — the target code and the unresolved call its body spells are none of the region's
		final main: String = LOOP_HEAD + '\tstatic function main() {\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ var f = Std.parseFloat("1"); /*>*/ }\n\t}\n}\n';
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, null, null, true, STD_STD), r -> r.match(Proven));
		final local: String = 'class Main {\n\tstatic function main() run([1], "ab");\n'
			+ '\tstatic function run(xs:Array<Int>, s:String):Void {\n'
			+ '\t\tfor (i in 0...xs.length) { /*<*/ var c = StringTools.fastCodeAt(s, xs[i]); /*>*/ }\n\t}\n}\n';
		assertMatch(askLocal(['Main.hx' => local], 'xs', true, false, null, STD_STD), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SPLICED-SITES') @:killer('M-GRAPH-FACTS-SPLICE-TAG') @:killer('M-GRAPH-FACTS-INLINED-SITE')
	@:killer('M-FACTS-SPLICE-SITE') @:killer('M-FACTS-SPLICE-SITE-INNERMOST') @:killer('M-FACTS-SPLICE-BODY')
	public function testUnderTheTruthASpliceElsewhereInTheFunctionIsNoneOfTheRegions(): Void {
		// the `inline` `@:from` of `Quiet` that changes `items` is spliced into `main` before the loop: it runs where its call
		// stood, which the region does not hold. Read by its syntax, `main` admits every conversion in play
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar q:Quiet = "x";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ k(); /*>*/ }\n\t}\n\tstatic function k():Void {}\n}\n'
			+ 'abstract Quiet(String) {\n\t@:from static inline function of(s:String):Quiet {\n\t\tMain.items.push(1);\n'
			+ '\t\treturn cast s;\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SPLICED-BENIGN') @:killer('M-REACH-SPLICED-CULPRIT') @:killer('M-REACH-WHERE-WRITTEN-RANGE')
	@:killer('M-GRAPH-FACTS-SPLICE-TAG')
	public function testUnderTheTruthASplicedPushOnAFreshLocalOfItsMethodChangesNothingShared(): Void {
		// `Helper.count` is spliced into the region, and into `tally`, which the region calls: the array its body pushes to is
		// a fresh local of `count`, a new one each time the body runs, as `count`'s own text says
		final helper: String = 'class Helper {\n\tpublic static inline function count(n:Int):Int {\n\t\tfinal a:Array<Int> = [];\n'
			+ '\t\ta.push(n);\n\t\treturn a.length;\n\t}\n}\n';
		function run(region: String): String {
			return 'class Main {\n\tstatic function main() run([1]);\n\tstatic function tally(n:Int):Int return Helper.count(n);\n'
				+ '\tstatic function run(xs:Array<Int>):Void {\n\t\tfor (i in 0...xs.length) { /*<*/ var n = $region; /*>*/ }\n\t}\n}\n'
				+ helper;
		}
		assertMatch(askLocal(['Main.hx' => run('Helper.count(xs[i])')], 'xs'), r -> r.match(Proven));
		assertMatch(askLocal(['Main.hx' => run('tally(xs[i])')], 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-GRAPH-LOCAL-INLINE')
	public function testALocalInlineFunctionKeepsItsBodysSyntax(): Void {
		// a local `inline function` is spliced at its own declaration inside the same body, where no marker says so: its
		// syntax is a function of its own, though the grammar gives it a kind apart from a local one, and the call is its edge
		assertMatch(ask(['Main.hx' => LOCAL_INLINE]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-GRAPH-TRUTH-MUTE-UNTYPED')
	public function testUnderTheWholeListTheCallOfALocalInlineFunctionKeepsItsEdge(): Void {
		// `main` is read through its facts, and the compiler types nothing at `helper()`, whose body it splices where it is
		// declared: the syntax's edge there is the only thing that says the call runs it
		assertMatch(ask(['Main.hx' => LOCAL_INLINE], null, true, null, false, null, null, null, true), r -> !r.match(Proven));
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

	public function testAnEscapeTheCompilerTypesCostsOnlyItsOwnFamilyUnderTheTruth(): Void {
		// the escapes read off the facts of every build say an `Other` escaped, which a `C` never is
		final main: String = 'class Main {\n\tstatic function mk() return new Other();\n'
			+ '\tstatic function main() {\n\t\tvar d:Dynamic = mk();\n\t\tvar o:Other = new Other();\n\t\tnew C().loop(o);\n\t}\n}\n'
			+ 'class C {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tpublic function loop(o:Other):Void {\n\t\tfor (i in 0...items.length) { /*<*/ Poker.poke(o); /*>*/ }\n\t}\n}\n'
			+ 'class Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
			+ 'class Poker {\n\tpublic static function poke(o:Other):Void o.items.push(9);\n}\n';
		final c: MemberRef = { owner: 'C', name: 'items' };
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		assertMatch(ask(['Main.hx' => main], null, true, c, true, null, null, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-TRUTH-FACTS')
	@:killer('M-ESCAPES-FACTS-REFLECTION-INLINED') @:killer('M-FACTS-ALIAS-TYPEDEF')
	public function testEscapesReadOffEveryBuildsFactsLetAThrownValueRunOnlyItsOwnToString(): Void {
		// `lib.Text.fail` throws a `Plain` it holds, whose conversion runs the `toString` of what a `Plain` may be: a
		// `Plain`, or an instance that left the type system. `Obj` never did: `Text.keep` is library code the facts read,
		// which lets nothing it is handed go anywhere — the syntax, which reads no library code, lets it escape
		assertMatch(truthLibAsk('', 'throw last;'), r -> r.match(Proven));
		assertMatch(ask(escapingObj(''), null, true, null, true, null, plainText('throw last;')), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-FLOW')
	public function testAValueFlowingIntoACatchAllEscapesUnderTheTruth(): Void {
		assertMatch(truthLibAsk('var d:Dynamic = o;', 'throw last;'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-INSTANCES') @:killer('M-ESCAPES-FACTS-PARAMETER')
	public function testAValueAGenericClassLetsGoEscapesUnderTheTruth(): Void {
		// `Box<Obj>` binds `Box.T` to `Obj`, whose values `show` hands to a catch-all
		final box: String = 'class Box<T> {\n\tvar v:T;\n\n\tpublic function new(v:T) this.v = v;\n\n'
			+ '\tpublic function show():Void {\n\t\tvar d:Dynamic = v;\n\t}\n}\n';
		assertMatch(truthLibAsk('new Box<Obj>(o).show();', 'throw last;', ['Box.hx' => box]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-GENERIC-METHOD') @:killer('M-FACTS-GENS')
	public function testAValueAGenericMethodLetsGoEscapesUnderTheTruth(): Void {
		// the call binds `keep`'s `A` to `Obj`, whose value its body hands to a catch-all
		final pick: String = 'class Pick {\n\tpublic static function keep<A>(x:A):Void {\n\t\tvar d:Dynamic = x;\n\t}\n}\n';
		assertMatch(truthLibAsk('Pick.keep(o);', 'throw last;', ['Pick.hx' => pick]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-HANDED') @:killer('M-FACTS-HANDS')
	public function testAValueHandedToAnExternEscapesUnderTheTruth(): Void {
		// target code, which no fact describes, may keep what it is handed and give it back untyped
		final ext: String = '@:native("Object") extern class Ext {\n\tstatic function keep(o:Main.Obj):Void;\n}\n';
		assertMatch(truthLibAsk('Ext.keep(o);', 'throw last;', ['Ext.hx' => ext]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-CLOSURE')
	public function testTheReceiverOfAMethodReadAsAValueEscapesUnderTheTruth(): Void {
		assertMatch(truthLibAsk('var f:() -> String = o.toString;', 'throw last;'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-DYNAMIC-RECEIVER')
	public function testTheReceiverOfAFieldReachedByNameEscapesUnderTheTruth(): Void {
		// untyped code reads a field of `o` by a name no declaration resolves: any of its fields may be what it reads
		assertMatch(truthLibAsk('var u:Dynamic = untyped o.zz;', 'throw last;'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-PRODUCED')
	public function testAClassAProducerNamesEscapesUnderTheTruth(): Void {
		// `js_enums_as_arrays` keeps `Type.resolveClass` a call (its default is inlined, which loses the name): the class a literal
		// name names escapes, and only that one
		final build: String = BUILD + '-D js_enums_as_arrays\n';
		assertMatch(truthLibAsk('Type.createInstance(Type.resolveClass("Obj"), []);', 'throw last;', null, build), r -> !r.match(Proven));
		assertMatch(truthLibAsk('Type.resolveClass("lib.Plain");', 'throw last;', null, build), r -> r.match(Proven));
		assertMatch(
			truthLibAsk('var n:String = "lib.Plain";\n\t\tType.resolveClass(n);', 'throw last;', null, build), r -> !r.match(Proven)
		);
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-PROJECT-NATIVE')
	public function testProjectTargetCodeLetsAnyValueEscapeUnderTheTruth(): Void {
		assertMatch(truthLibAsk('js.Syntax.code("0");', 'throw last;'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-TRACE') @:killer('M-ESCAPES-TRUTH-FACTS')
	public function testATraceTheTargetLowersLetsOnlyWhatItIsHandedEscapeUnderTheTruth(): Void {
		// js lowers `trace` to a native identifier, which makes nothing: the escapes stay known
		assertMatch(truthLibAsk('trace(1);', 'throw last;'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-EXTENDS-EXTERN')
	public function testAnInstanceOfAClassExtendingAnExternEscapesUnderTheTruth(): Void {
		// the extern's target code runs with a `Kid` as its own `this`
		final kid: String = '@:native("Object") extern class ExtBase {\n\tfunction new();\n}\n\n'
			+ 'class Kid extends ExtBase {\n\tpublic function new() super();\n\n'
			+ '\tpublic function toString():String {\n\t\tMain.items = [];\n\t\treturn "k";\n\t}\n}\n';
		assertMatch(truthLibAsk('var k:Kid = new Kid();', 'throw last;', ['Kid.hx' => kid]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-FIELDS') @:killer('M-ESCAPES-FACTS-ENUM') @:killer('M-ESCAPES-FACTS-STRUCTURE')
	@:killer('M-ESCAPES-FACTS-PLACE-ARGS') @:killer('M-ESCAPES-FACTS-TYPE-ARGS')
	public function testWhatAnEscapedValueHoldsEscapesWithItUnderTheTruth(): Void {
		// code holding an object without a type reaches what it holds by name: a variable, an enum value's argument, a
		// structure's field, an element of an array handed on as one of catch-alls, the value of a box handed on as a box of
		// a catch-all
		final held: Map<String, String> = [
			'Held.hx' => 'class Held {\n\tpublic var o:Main.Obj;\n\n\tpublic function new(o:Main.Obj) this.o = o;\n}\n',
			'Wrap.hx' => 'enum Wrap {\n\tW(o:Main.Obj);\n}\n',
			'Box.hx' => 'class Box<T> {\n\tpublic var v:T;\n\n\tpublic function new(v:T) this.v = v;\n}\n'
		];
		for (escape in [
			'var d:Dynamic = new Held(o);',
			'var d:Dynamic = Wrap.W(o);',
			'var d:Dynamic = { o: o };',
			'var objs:Array<Obj> = [o];\n\t\tvar all:Array<Dynamic> = objs;',
			'var box:Box<Obj> = new Box(o);\n\t\tvar any:Box<Dynamic> = box;'
		]) assertMatch(truthLibAsk(escape, 'throw last;', held), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-SUBTYPES')
	public function testAnEscapedValueMayBeAnyOfItsSubtypesUnderTheTruth(): Void {
		// a `Base` escaped, which a `Kid` may be
		final kid: Map<String, String> = [
			'Base.hx' => 'class Base {\n\tpublic function new() {}\n}\n',
			'Kid.hx' => 'class Kid extends Base {\n\tpublic function new() super();\n\n'
				+ '\tpublic function toString():String {\n\t\tMain.items = [];\n\t\treturn "k";\n\t}\n}\n'
		];
		assertMatch(truthLibAsk('var b:Base = new Kid();\n\t\tvar d:Dynamic = b;', 'throw last;', kid), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-STRING-EXACT') @:killer('M-REACH-EXACT-SITE') @:killer('M-FACTS-VIEW-EXACT')
	@:killer('M-FACTS-FLOW-EXACT') @:killer('M-FACTS-VIEW-EXACT-CONVERSION') @:killer('M-FACTS-EXACT-WRITTEN')
	@:killer('M-FACTS-VIEW-EXACT-OPERAND')
	public function testAFreshObjectConvertedRunsOnlyItsOwnClassToStringUnderTheTruth(): Void {
		// `Obj` escaped, so a `Plain` read from a place may be one; a `Plain` just built never is — thrown from a local holding
		// nothing else, or concatenated, which the compiler converts by a call of `Std.string`
		assertMatch(truthLibAsk('var d:Dynamic = o;', 'var p:Plain = new Plain();\n\t\tthrow p;'), r -> r.match(Proven));
		assertMatch(truthLibAsk('var d:Dynamic = o;', 'throw "" + new Plain();'), r -> r.match(Proven));
		assertMatch(truthLibAsk('var d:Dynamic = o;', 'var p:Plain = new Plain();\n\t\tp = last;\n\t\tthrow p;'), r -> !r.match(Proven));
		assertMatch(truthLibAsk('var d:Dynamic = o;', 'throw "" + (failing ? new Plain() : last);'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-THROW-EXCEPTION')
	public function testAThrownExceptionIsConvertedToNoString(): Void {
		// the exception wrapping throws an instance of a class extending `haxe.Exception` as it is: `Err.toString` never runs
		final err: String = 'class Err extends haxe.Exception {\n\toverride public function toString():String {\n'
			+ '\t\tMain.items = [];\n\t\treturn "e";\n\t}\n}\n';
		assertMatch(truthLibAsk('', 'var e:Err = new Err("x");\n\t\tthrow e;', ['Err.hx' => err]), r -> r.match(Proven));
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

	@:pin('control') @:killer('M-FACTS-REACH-BUILDS') @:killer('M-REACH-REWRITTEN-UNTRUE')
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

	@:pin('control') @:killer('M-FACTS-REACH-SYNTAX-UNION') @:killer('M-GRAPH-TRUTH-MUTE-ALWAYS')
	public function testAnExtensionAnotherBuildBringsInIsKeptFromTheSyntax(): Void {
		// a build defining `other` brings in `Loud` last, and `w.go()` runs its `go`: the facts of `Runner.run`, which name
		// no type of this file, say `Quiet.go`; the syntax reads both `using`s and records the edge the facts may not take away
		final store: MemberRef = { owner: 'Store', name: 'items' };
		assertMatch(ask(EXTENSION_PER_BUILD, null, true, store), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-GRAPH-TRUTH-MUTE')
	public function testAnExtensionOnlyAListedBuildBringsInIsReadFromItsFacts(): Void {
		// `Runner.run` is read through its facts either way; under the whole list of builds the syntax's edge to `Loud.go`,
		// which only a build defining `other` brings in, is its reading of a site every build typed, and is dropped
		final store: MemberRef = { owner: 'Store', name: 'items' };
		assertMatch(ask(EXTENSION_PER_BUILD, [[]], true, store, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(EXTENSION_PER_BUILD, [[], ['other']], true, store, false, null, null, null, true), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-REACH-GUARDED-IMPORT')
	public function testATypeInAFileImportingUnderAConditionKeepsTheSyntax(): Void {
		// `R.f` takes the `T` its file imports: `b.T` here, and in a build defining `other` `a.T`, whose `@:from` runs on the
		// argument and grows `items` — no edge names that conversion, and the facts of this build hold none
		assertMatch(ask(IMPORT_PER_BUILD), r -> !r.match(Proven));
	}

	public function testATypeInAFileImportingUnderAConditionIsReadFromTheListedBuilds(): Void {
		// `b.T` has no conversion to run, until a listed build defines `other` and the call converts to `a.T`. Under `[[]]`
		// two gates prove it each on its own - the skipped context test and `a/T.hx`, which no listed build compiles - so
		// no single arm breaks it; a fixture where a build compiles `a.T` waits for the implicit admissions (S6)
		assertMatch(ask(IMPORT_PER_BUILD, [[]], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(IMPORT_PER_BUILD, [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Reached(_)));
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

	@:pin('control') @:killer('M-FACTS-TEXT-SPELLED')
	public function testAMacroBuiltTypeAnswersFromItsTextOnlyWhenItsFactsAreItsText(): Void {
		// `Line` inherits an `@:autoBuild`: the text of `all` answers for the local it initialises only when the compiled body
		// is that text. A macro keeping the fields leaves it so; one replacing the body with `return Main.kept` does not
		final main: String = 'class Main {\n\tpublic static var kept:Array<Int> = [1];\n\tstatic function main() {\n'
			+ '\t\tfinal xs:Array<Int> = new Line().all();\n\t\tfor (i in 0...xs.length) { /*<*/ kept.push(xs[i]); /*>*/ }\n\t}\n}\n';
		final line: String = 'class Line extends Base {\n\tpublic function all():Array<Int> {\n\t\tfinal out:Array<Int> = [1];\n'
			+ '\t\tout.push(2);\n\t\treturn out;\n\t}\n}\n';
		final mac: String = 'import haxe.macro.Context;\nimport haxe.macro.Expr;\n\nclass Mac {\n'
			+ '\tpublic static macro function keep():Array<Field> return Context.getBuildFields();\n\n'
			+ '\tpublic static macro function rewrite():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
			+ '\t\tfor (f in fields) if (f.name == "all") switch f.kind {\n\t\t\tcase FFun(fn): fn.expr = macro return Main.kept;\n'
			+ '\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n\n'
			+ '\tpublic static macro function retarget():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
			+ '\t\tfor (f in fields) if (f.name == "all") switch f.kind {\n'
			+ '\t\t\tcase FFun(fn): fn.expr = macro @:pos(fn.expr.pos) return Main.kept;\n\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n}\n';
		function files(builder: String): Map<String, String> {
			return [
				'Main.hx' => main,
				'Line.hx' => line,
				'Mac.hx' => mac,
				'Base.hx' => '@:autoBuild(Mac.$builder())\nclass Base {\n\tpublic function new() {}\n}\n'
			];
		}
		assertMatch(askLocal(files('keep'), 'xs'), r -> r.match(Proven));
		assertMatch(askLocal(files('keep'), 'xs', false), r -> !r.match(Proven));
		assertMatch(askLocal(files('rewrite'), 'xs'), r -> !r.match(Proven));
		// the new body sits where the old one did: its facts are in place, but no text there spells `kept`
		assertMatch(askLocal(files('retarget'), 'xs'), r -> !r.match(Proven));
	}

	public function testAnOverrideOnlyTheFactsSeeRefusesAFreshSource(): Void {
		// the analysis is told the index holds every compiled type, but `pack.Sub` — compiled, indexed by nothing — overrides
		// `all` with a shared array: only the facts know it, and by its package-qualified name
		// the directive keeps `main` read by its syntax: its facts would otherwise name the dispatch to `Sub.all` at the call
		final main: String = 'import pack.Line;\n\nclass Main {\n\tpublic static var kept:Array<Int> = [1];\n\tstatic function main() {\n'
			+ '\t\t#if never\n\t\tkept = [];\n\t\t#end\n'
			+ '\t\tfinal line:Line = new pack.Sub();\n\t\tfinal xs:Array<Int> = line.all();\n'
			+ '\t\tfor (i in 0...xs.length) { /*<*/ kept.push(xs[i]); /*>*/ }\n\t}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'pack/Line.hx' => 'package pack;\n\nclass Line {\n\tpublic function new() {}\n\n\tpublic function all():Array<Int> return [];\n}\n'
		];
		final sub: Map<String, String> = [
			'pack/Sub.hx' => 'package pack;\n\nclass Sub extends Line {\n\toverride public function all():Array<Int> return Main.kept;\n}\n'
		];
		assertMatch(askLocal(files, 'xs', true, true, sub), r -> !r.match(Proven));
		files['Main.hx'] = StringTools.replace(main, 'new pack.Sub()', 'new Line()');
		assertMatch(askLocal(files, 'xs', true, true), r -> r.match(Proven));
	}

	public function testALibraryFileNoBuildCompilesHidesNoOverride(): Void {
		// `Broken.hx` does not parse and spells both `Worker` and `run`, but no build reads it: the facts say so, and it
		// holds no override of `Worker.run`. Without the facts it stays a blind spot
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:Worker = new Worker();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ w.run(); /*>*/ }\n\t}\n}\n';
		final library: Map<String, String> = [
			'Worker.hx' => 'class Worker {\n\tpublic function new() {}\n\tpublic function run():Void {}\n}\n',
			'Broken.hx' => 'package x {\n\tclass Worker extends Worker {\n\t\tfunction run() Main.items.push(1);\n\t}\n}\n'
		];
		assertMatch(ask(['Main.hx' => main], null, true, null, true, null, library), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main], null, false, null, true, null, library), r -> r.match(Unknown(SkipParse(_))));
	}

	public function testTheBuildsSubtypesOfALibraryTypeAreKnownFromTheirFacts(): Void {
		// no oracle list vouches for the classpath, but under the listed builds the facts name every subtype of `Worker`: none,
		// so a dispatch on it reaches no override the index cannot see — unless a compiled subtype the index does not hold
		// overrides `run`
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:Worker = new Worker();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ w.run(); /*>*/ }\n\t}\n}\n';
		final library: Map<String, String> = [
			'Worker.hx' => 'class Worker {\n\tpublic function new() {}\n\tpublic function run():Void {}\n}\n'
		];
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, library, null, true), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, library), r -> !r.match(Proven));
		final withSub: String = StringTools.replace(main, '\t\tfor (i', '\t\tvar s:Worker = new Sub();\n\t\ts.run();\n\t\tfor (i');
		final hidden: Map<String, String> = [
			'Sub.hx' => 'class Sub extends Worker {\n\tpublic function new() super();\n\toverride public function run():Void Main.items.push(1);\n}\n'
		];
		assertMatch(ask(['Main.hx' => withSub], null, true, null, false, null, library, hidden, true), r -> !r.match(Proven));
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
		assertMatch(ask(['Main.hx' => USING_PER_BUILD]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-CONTEXT')
	public function testATypeBringingExtensionsInUnderAConditionIsReadFromTheListedBuilds(): Void {
		// `Quiet.go` runs in every listed build, until one of them defines `other` and puts `@:using(Main.Loud)` on `W`
		assertMatch(ask(['Main.hx' => USING_PER_BUILD], [[]], true, null, false, null, null, null, true), r -> r.match(Proven));
		assertMatch(
			ask(['Main.hx' => USING_PER_BUILD], [[], ['other']], true, null, false, null, null, null, true), r -> r.match(Reached(_))
		);
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

	@:pin('control') @:killer('M-REACH-TYPED-IMPLICIT-TEXT')
	public function testAStoredFunctionValueMayConvertWhatItIsHandedUnderTheTruth(): Void {
		// the lambda `fmt` holds is read through its facts, and still reaches no toucher by an edge: its concatenation is a
		// string conversion the facts keep as a site, which the walk never enters
		final main: String = LOOP_HEAD + '\tstatic var fmt:Dynamic -> String;\n'
			+ '\tstatic function main() {\n\t\tfmt = v -> "<" + v;\n\t\tvar o:Obj = new Obj();\n\t\tvar s:String = "";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ s += fmt(o); /*>*/ }\n\t}\n}\n' + CLEARING_OBJ;
		assertMatch(truthAsk(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-TYPED-IMPLICIT-ITER')
	public function testAStoredFunctionValueMayIterateWhatItIsHandedUnderTheTruth(): Void {
		// the lambda `f` holds iterates a structure, which runs the `next` of whatever it holds: a site the facts keep, in code
		// the walk never enters
		final main: String = LOOP_HEAD + '\tstatic var f:Iterator<Int> -> Int;\n'
			+ '\tstatic function main() {\n\t\tf = it -> {\n\t\t\tvar n:Int = 0;\n\t\t\tfor (x in it) n++;\n\t\t\tn;\n\t\t};\n'
			+ '\t\tvar w:Walker = new Walker();\n\t\tfor (i in 0...items.length) { /*<*/ f(w); /*>*/ }\n\t}\n}\n' + CLEARING_WALKER;
		assertMatch(truthAsk(['Main.hx' => main]), r -> !r.match(Proven));
	}

	public function testAStoredFunctionValueMayRunAnOperatorOverloadOnlyThroughItsFactsUnderTheTruth(): Void {
		// the lambda `f` holds runs `AE.eq` through the `==` its facts name as a call: an edge, by which it reaches the toucher
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool;\n'
			+ '\tstatic function main() {\n\t\tf = a -> a == a;\n\t\tfor (i in 0...items.length) { /*<*/ f(new AE(1)); /*>*/ }\n\t}\n}\n'
			+ CLEARING_EQ;
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-ADMIT-SYNTAX-READ-FIELD') @:killer('M-REACH-UNREAD-NARROWED')
	@:killer('M-FACTS-ABSTRACT-CTOR-NAME')
	public function testCodeReadThroughItsFactsRunsNoOperatorOverloadItNamesNoCallOfUnderTheTruth(): Void {
		// the lambda `f` holds compares nothing: code read by its syntax might run `AE.eq` with no call the graph holds, code
		// read through its facts, where they are the truth, names every operator it runs as a call
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool;\n'
			+ '\tstatic function main() {\n\t\tf = a -> true;\n\t\tfor (i in 0...items.length) { /*<*/ f(new AE(1)); /*>*/ }\n\t}\n}\n'
			+ CLEARING_EQ;
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ADMIT-SYNTAX-READ-UNTRUE')
	public function testFactsThatAreNotTheTruthNarrowNothingCodeTheWalkNeverEntersRuns(): Void {
		// the lambda `f` holds is read through facts that hold for every build either way; only under a list of builds declared
		// whole does the walk take them for all that code it never enters runs
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool;\n'
			+ '\tstatic function main() {\n\t\tf = a -> true;\n\t\tvar a:AE = cast 1;\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ f(a); /*>*/ }\n\t}\n}\n' + CLEARING_EQ;
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ADMIT-SYNTAX-READ-FACETED')
	public function testAFunctionValueReadByItsSyntaxMayRunAnyOperatorOverloadUnderTheTruth(): Void {
		// the lambda `f` holds is an expression macro's expansion, whose facts do not replace its syntax
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool;\n'
			+ '\tstatic function main() {\n\t\tf = a -> Mac.yes();\n\t\tfor (i in 0...items.length) { /*<*/ f(new AE(1)); /*>*/ }\n\t}\n}\n'
			+ CLEARING_EQ;
		final mac: String = 'class Mac {\n\tpublic static macro function yes() return macro Math.random() < 2;\n}\n';
		assertMatch(truthAsk(['Main.hx' => main, 'Mac.hx' => mac]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ADMIT-SYNTAX-READ-UNSEEN') @:killer('M-REACH-UNREAD-RECHECK')
	public function testLibraryCodeNotReadYetMayRunAnyOperatorOverloadUnderTheTruth(): Void {
		// the string conversions the facts leave implicit may run the library `Thing.toString`, whose file the walk has not
		// read: once the graph holds it, code the walk cannot see may run any implicitly-called member
		final main: String = LOOP_HEAD + '\tstatic var f:AE -> Bool;\n\tstatic var t:lib.Thing = null;\n'
			+ '\tstatic function main() {\n\t\tf = a -> true;\n\t\tfor (i in 0...items.length) { /*<*/ f(new AE(1)); /*>*/ }\n\t}\n}\n'
			+ CLEARING_EQ;
		final thing: String = 'package lib;\n\nclass Thing {\n\tpublic function new() {}\n\n'
			+ '\tpublic function toString():String return "t";\n}\n';
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, ['lib/Thing.hx' => thing], null, true), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-THROW-TEXT') @:killer('M-SITES-THROW-TEXT')
	public function testAThrownValueIsConvertedToAString(): Void {
		// the exception wrapping the compiler adds after typing hands `o` to `Std.string`, which runs `Obj.toString`
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ try throw o catch (e:Dynamic) {} /*>*/ }\n\t}\n}\n' + CLEARING_OBJ;
		assertMatch(truthAsk(['Main.hx' => main]), r -> !r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> !r.match(Proven));
		assertMatch(ask(['Main.hx' => main], null, false), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-ITER')
	public function testALoopOverAProjectIteratorRunsItsNextUnderTheTruth(): Void {
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar w:Walker = new Walker();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ for (x in w) {} /*>*/ }\n\t}\n}\n' + CLEARING_WALKER;
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-SOLE-MEMBER-DECLARED')
	public function testAMemberAnotherTypeOfItsNameMayDeclareKeepsTheNameShared(): Void {
		// a declaration of `splice` no build typed may still run under another name (`@:genericBuild`): it leaves `Vec.splice`
		// a name two types share
		final dead: Map<String, String> = sharedNameLibrary();
		dead['dead/Vec.hx'] = 'package dead;\n\nclass Vec {\n\tpublic static function splice(i:Int):Int return i;\n}\n';
		assertMatch(ask(['Main.hx' => SHARED_NAME_MAIN], null, true, null, false, null, dead, null, true), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-SOLE-MEMBER-NONE') @:killer('M-REACH-SHARED-NAME-SOLE') @:killer('M-REACH-ITERABLE-RETURNS')
	public function testALibraryMemberOnlyOneTypeOfItsNameDeclaresIsReadThroughItsFacts(): Void {
		// `lib.Vec` and `other.Vec` share a simple name, but only `lib.Vec` declares `splice`, whose loop the syntax cannot
		// type — so it may run any `next`, `Walker`'s among them — and the facts type as `VecIter`'s (openfl's `Vector.splice`
		// beside `haxe.ds.Vector`)
		assertMatch(
			ask(['Main.hx' => SHARED_NAME_MAIN], null, true, null, false, null, sharedNameLibrary(), null, true), r -> r.match(Proven)
		);
		assertMatch(ask(['Main.hx' => SHARED_NAME_MAIN], null, true, null, false, null, sharedNameLibrary()), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-WIRED')
	@:access(anyparse.query.MemberReach)
	public function testTheFactsAreTheTruthOnlyUnderTheWholeListOfTheirBuilds(): Void {
		// the facts of every build of a list declared whole, none dropped, are what every build the project ships resolves;
		// builds no list names vouch for nothing, and a configuration that left no facts leaves no view at all
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tBroken.f();\n\t}\n}\n'
			+ 'class Broken {\n\tpublic static function f():Void {\n\t\t#if APQ_BROKEN nope(); #end\n\t}\n}\n';
		function truth(configurations: Array<Array<String>>, listed: Bool): Null<Bool> {
			return withReach(
				['Main.hx' => main], configurations, true, false, null, null, null, listed, (reach, dir) -> reach._scope.facts?.truth
			);
		}
		Assert.equals(true, truth([[], ['other']], true), 'the facts of the listed builds are not the truth');
		Assert.equals(false, truth([[], ['other']], false), 'the facts are the truth with no list of builds');
		Assert.isNull(truth([[], ['APQ_BROKEN']], true), 'a table missing a configuration made a view');
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-UNLISTED') @:killer('M-FACTS-TRUTH-COUNT') @:killer('M-FACTS-TRUTH-NAMES')
	@:killer('M-FACTS-TRUTH-ORDER')
	@:access(anyparse.query.MemberReach)
	public function testTheTruthNeedsTheFactsToNameExactlyTheListedBuilds(): Void {
		final facts: CompilerFacts = CompilerFacts.create(file -> null, file -> file);
		facts.configurations.push('b.hxml -D y');
		facts.configurations.push('b.hxml');
		function listed(names: Array<String>): Array<ReachConfiguration> {
			return [
				for (n in names)
					{
						name: n,
						defined: [],
						everDefined: [],
						compiled: [],
						types: []
					}
			];
		}
		Assert.isTrue(MemberReach.factsAreTruth(facts, listed(['b.hxml', 'b.hxml -D y'])), 'the order of the list counted');
		Assert.isFalse(MemberReach.factsAreTruth(facts, null), 'facts were the truth with no list of builds');
		Assert.isFalse(MemberReach.factsAreTruth(null, listed(['b.hxml'])), 'no facts were the truth');
		Assert.isFalse(MemberReach.factsAreTruth(facts, listed([])), 'facts were the truth under an empty list');
		Assert.isFalse(MemberReach.factsAreTruth(facts, listed(['b.hxml'])), 'facts of a build the list does not name were the truth');
		Assert.isFalse(
			MemberReach.factsAreTruth(facts, listed(['b.hxml', 'b.hxml -D y', 'b.hxml -D z'])),
			'facts missing a listed build were the truth'
		);
		Assert.isFalse(MemberReach.factsAreTruth(facts, listed(['b.hxml', 'b.hxml -D z'])), 'facts of other builds were the truth');
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-HAZARDS') @:killer('M-FACTS-TRUTH-HAZARDS-UNLISTED')
	@:killer('M-FACTS-TRUTH-UNTYPED-KEPT')
	public function testUntypedCodeTheFactsRecordIsReadThroughThemUnderTheTruth(): Void {
		// `untyped this.zz` reads a field the class lacks: the compiler types it as a Dynamic field read, a fact like any
		// other, so under the whole list of builds the untyped expression hides nothing; with no such list it stays blind
		final main: String = MEMBER_HEAD
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ var z = untyped this.zz; /*>*/ }\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-FACETED')
	public function testABodyTheFactsDoNotDescribeWholeKeepsItsSyntacticHazards(): Void {
		// `g` expands a macro, which may run code no fact places: `g` is read by its syntax, and its untyped expression stays a
		// blind spot however whole the list of builds
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '\tfunction g():Void {\n\t\tvar z = untyped this.zz;\n\t\tMac.nop();\n\t}\n}\n';
		final mac: String = 'class Mac {\n\tpublic static macro function nop() return macro Math.abs(1);\n}\n';
		assertMatch(truthAsk(['Main.hx' => main, 'Mac.hx' => mac]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-FOLDED-BY-ID')
	public function testAMemberDeclaredInEachBranchIsReadByIdUnderTheTruth(): Void {
		// `g` is declared twice, one declaration per branch: the graph folds the two into one node, whose facts are those of
		// `Main.g` over every build — under the whole list of them, only the first branch is compiled, and its untyped read is a
		// field access the compiler typed. With no such list `g` is read by its syntax
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '#if !other\n\tfunction g():Void {\n\t\tvar z = untyped this.zz;\n\t}\n#else\n\tfunction g():Void {}\n#end\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-REACH-FOLDED-BODIES')
	public function testTheSecondDeclarationOfAFoldedMemberIsReadByItsText(): Void {
		// the branch holding the untyped read is the second declaration of `g`: read by its text wherever the facts do not
		// replace the syntax — with no facts, and with facts the list of builds is not the whole of — and under the whole list
		// by the facts of the one branch the builds compile, whose read the compiler typed
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '#if other\n\tfunction g():Void {}\n#else\n\tfunction g():Void {\n\t\tvar z = untyped this.zz;\n\t}\n#end\n}\n';
		assertMatch(ask(['Main.hx' => main], null, false), r -> r.match(Unknown(Untyped(_, _))));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-TOUCH-FOLDED-ACCESSES')
	public function testATouchOnlyTheFactsSeeInASecondDeclarationIsFoundUnderTheTruth(): Void {
		// `stuff` is `Main.items` imported under another name, pushed to by the declaration of `go` the build compiles — the
		// second of the two the graph folds: the facts of that declaration are the node's, though its first holds none
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Other.go(); /*>*/ }\n'
			+ '\t\tOther.go();\n\t}\n}\n';
		final other: String = 'import Main.items as stuff;\n\nclass Other {\n#if other\n\tpublic static function go():Void {}\n#else\n'
			+ '\tpublic static function go():Void stuff.push(1);\n#end\n}\n';
		assertMatch(truthAsk(['Main.hx' => main, 'Other.hx' => other]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-FIELD-KINDS')
	public function testAPropertyOneBuildReadsThroughAGetterIsNotReadStraight(): Void {
		// the build defining `other` declares `items` with a getter, the other one without: a reader of `items` there sees
		// what the getter hands out, so the builds together do not read it straight from its storage
		function fixture(other: String): Map<String, String> {
			final main: String = 'class Main {\n#if other\n\t@:isVar public var items(' + other + '):Array<Int> = [];\n#else\n'
				+ '\t@:isVar public var items(default, set):Array<Int> = [];\n#end\n\tpublic function new() {}\n'
				+ '\tfunction set_items(v:Array<Int>):Array<Int> {\n\t\titems = v;\n\t\treturn v;\n\t}\n'
				+ '\tfunction get_items():Array<Int> return items;\n'
				+ '\tstatic function main() {\n\t\tvar m = new Main();\n\t\tm.f();\n\t}\n'
				+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ h(); /*>*/ }\n\t}\n\tfunction h():Void {}\n}\n';
			return ['Main.hx' => main];
		}
		function write(files: Map<String, String>): ReachResult {
			return withReach(files, [[], ['other']], true, false, null, null, null, true, (reach, dir) -> {
				final source: String = files['Main.hx'] ?? '';
				reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(source)), { owner: 'Main', name: 'items' }, Write);
			});
		}
		assertMatch(write(fixture('default, set')), r -> r.match(Proven));
		assertMatch(write(fixture('get, set')), r -> r.match(Unknown(UnresolvedDispatch(_, _, _))));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-UNTYPED-ALL') @:killer('M-FACTS-TRUTH-UNTYPED-SHAPE')
	public function testAnUntypedIndexAccessKeepsItsHazardUnderTheTruth(): Void {
		// on js `this["items"]` IS the field: no fact names it — the compiler records an index read and a Dynamic `push`
		final main: String = MEMBER_HEAD
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ untyped this["items"].push(1); /*>*/ }\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-NATIVES') @:killer('M-FACTS-TRUTH-NATIVE-CALLS-KEPT')
	@:killer('M-FACTS-TRUTH-NATIVE-METAS-DROPPED')
	public function testTheFactsNameTheNativeCallsUnderTheTruth(): Void {
		// the facts name `js.Syntax.code` whatever spells it; a class of the project merely named `Syntax` is no native code,
		// though the syntax cannot tell; a native-code meta is nothing the facts record, so the syntax keeps it
		function region(code: String): String {
			return MEMBER_HEAD + '\tstatic function g():Void {}\n\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ ' + code
				+ ' /*>*/ }\n\t}\n}\nclass Syntax {\n\tpublic static function code(s:String):Void {}\n}\n';
		}
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("0");')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('Syntax.code("0");')]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => region('Syntax.code("0");')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('@:functionCode("0") g();')]), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TRUTH-REFLECTION') @:killer('M-FACTS-TRUTH-REFLECTION-TWIN')
	public function testAReflectiveCallTheSyntaxDoesNotSeeNamesNothingUnderTheTruth(): Void {
		// `rf` is `Reflect.field` under another name: the facts see the call, and the literal they record is the first of any
		// argument, not the name; a call the syntax sees keeps the literal name it reads
		final main: String = 'import Reflect.field as rf;\n' + MEMBER_HEAD + '\tfunction f():Void {\n\t\tvar n = "it" + "ems";\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ rf(this, n); /*>*/ }\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(DynamicName(_, _))));
		final seen: String = MEMBER_HEAD
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ Reflect.field(this, "other"); /*>*/ }\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => seen]), r -> !r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-REACH-DEAD-FILE-SEEDS') @:killer('M-FACTS-DEAD-FILE-NEVER')
	@:killer('M-FACTS-DEAD-FILE-UNTRUE')
	public function testAProjectFileNoBuildCompilesRunsNothing(): Void {
		// no build compiles `Dead.hx` — nothing imports it — so under the whole list of builds its touch runs nowhere and its
		// text, which does not even parse, hides nothing; with no such list a build may compile it
		final main: String = MEMBER_HEAD + '\tfunction f(s:Shape):Void {\n\t\tfor (i in 0...items.length) { /*<*/ s.draw(this); /*>*/ }\n'
			+ '\t}\n}\ninterface Shape {\n\tfunction draw(m:Main):Void;\n}\n'
			+ 'class Live implements Shape {\n\tpublic function new() {}\n\tpublic function draw(m:Main):Void {}\n}\n';
		final dead: String = 'class Dead implements Shape {\n\tpublic function new() {}\n'
			+ '\tpublic function draw(m:Main):Void {\n\t\tm.items.push(1);\n\t}\n}\n';
		final files: Map<String, String> = ['Main.hx' => main, 'Dead.hx' => dead];
		assertMatch(truthAsk(files), r -> r.match(Proven));
		assertMatch(ask(files), r -> r.match(Reached(_)));
		final broken: Map<String, String> = ['Main.hx' => main, 'Broken.hx' => 'class Broken {\n\tfunction f() { ( }\n}\n'];
		assertMatch(truthAsk(broken), r -> r.match(Proven));
		assertMatch(ask(broken), r -> r.match(Unknown(SkipParse(_))));
	}

	@:pin('control') @:killer('M-FACTS-DEAD-FILE-REWRITTEN')
	@:access(anyparse.query.MemberReach)
	public function testAFileTheRunWroteMayBeCompiled(): Void {
		// a file the run wrote after the compiles — one a fix created, say — holds text no build read: it may be compiled
		final broken: String = 'class Broken {\n\tfunction f() { ( }\n}\n';
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '\tfunction g():Void {}\n}\n';
		final result: ReachResult = withReach(
			['Main.hx' => main, 'Broken.hx' => broken], null, true, false, null, null, null, true, (reach, dir) -> {
				reach._scope.facts?.table.invalidate(Path.join([dir, 'Broken.hx']));
				reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(main)), { owner: 'Main', name: 'items' }, Mutate);
			}
		);
		assertMatch(result, r -> r.match(Unknown(SkipParse(_))));
	}

	@:pin('control') @:killer('M-FACTS-DEAD-FILE-VALUES')
	public function testAProjectFileNoBuildCompilesLetsNoValueEscape(): Void {
		// `o.items` is another type's `items`: it touches `Main.items` only if a `Main` may have escaped into an `Other`, which
		// the escapes over the project answer — a file no build compiles, which the graph does not hold, is none of it.
		// `poke` calls a function named `items`, so its facts leave it to the syntax, which asks the escapes
		final main: String = MEMBER_HEAD + '\tfunction f(o:Other):Void {\n\t\tfor (i in 0...items.length) { /*<*/ Poker.poke(o); /*>*/ }\n'
			+ '\t}\n}\nclass Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
			+ 'class Poker {\n\tstatic function items():Void {}\n'
			+ '\tpublic static function poke(o:Other):Void {\n\t\titems();\n\t\to.items.push(9);\n\t}\n}\n';
		final files: Map<String, String> = ['Main.hx' => main, 'Idle.hx' => 'class Idle {\n\tpublic function new() {}\n}\n'];
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		assertMatch(ask(files, null, true, null, true, null, null, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-DEAD-FILE-ENTRY') @:killer('M-REACH-DEAD-FILE-LOCAL-ENTRY')
	public function testCodeNoBuildCompilesHasNoAnswerUnderTheTruth(): Void {
		// the graph holds nothing of `Dead.hx`, so no call from it is walked: an answer would read "proven" off nothing
		final main: String = MEMBER_HEAD + '\tpublic static function grow(xs:Array<Int>):Void {\n\t\txs.push(1);\n\t}\n'
			+ '\tpublic static function touch():Void {\n\t\tnew Main().items.push(1);\n\t}\n}\n';
		final dead: String =
			'class Dead {\n\tstatic function run(xs:Array<Int>):Void {\n\t\t/*<*/ Main.touch(); Main.grow(xs); /*>*/\n\t}\n}\n';
		function question(listed: Bool, local: Bool): ReachResult {
			return withReach(['Main.hx' => main, 'Dead.hx' => dead], null, true, false, null, null, null, listed, (reach, dir) -> {
				final file: String = Path.join([dir, 'Dead.hx']);
				if (!local) return reach.mayReach(Region(file, regionOf(dead)), { owner: 'Main', name: 'items' }, Mutate);
				final at: Int = dead.lastIndexOf('xs', dead.indexOf(REGION_CLOSE));
				return reach.mayMutateNamed(file, 'xs', new Span(at, at + 2), regionOf(dead));
			});
		}
		assertMatch(question(true, false), r -> r.match(Unknown(OutOfScope(_))));
		assertMatch(question(false, false), r -> r.match(Reached(_)));
		assertMatch(question(true, true), r -> r.match(Unknown(OutOfScope(_))));
		assertMatch(question(false, true), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-IDLE-INDEX')
	public function testATypeNoBuildCompilesIsNoSecondDeclarationOfItsNameUnderTheTruth(): Void {
		// nothing imports `dead/Main.hx` or `dead/Grid.hx`, so no build compiles the second `Main` or the second `Grid`: under
		// the whole list of builds each name is the one type they typed, the member's owner and the type the walk enters
		// alike. With no such list a build may compile the other one, and a name declared twice is ambiguous
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ Grid.run(); /*>*/ }\n\t}\n}\n'
			+ 'class Grid {\n\tpublic static function run():Void {}\n}\n';
		final owner: Map<String, String> = [
			'Main.hx' => main,
			'dead/Main.hx' => 'package dead;\n\nclass Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
		];
		assertMatch(truthAsk(owner), r -> r.match(Proven));
		assertMatch(ask(owner), r -> r.match(Unknown(Ambiguous('Main'))));
		final entered: Map<String, String> = [
			'Main.hx' => main,
			'dead/Grid.hx' => 'package dead;\n\nclass Grid {\n\tpublic static function run():Void {}\n}\n'
		];
		assertMatch(truthAsk(entered), r -> r.match(Proven));
		assertMatch(ask(entered), r -> r.match(Unknown(Ambiguous('Grid'))));
	}

	@:pin('control') @:killer('M-REACH-AMBIGUOUS-SOLE-ANY') @:killer('M-FACTS-SOLE-TYPED-ONLY') @:killer('M-FACTS-SOLE-STANDS-ANY')
	public function testTwoTypesUnderOneNameStayAmbiguousUnderTheTruth(): Void {
		// the graph knows a type by its simple name: `a.Grid` and `b.Grid` are two types the builds compile, whose members it
		// cannot tell apart; a `Grid` of a file a build compiles that no build typed (`#if never`) may still be one, under
		// another name; and `c.Grid`, which the index does not hold, is a type the builds typed beside the one `Grid` whose
		// copy per build it holds
		function grid(pack: String): String {
			return 'package $pack;\n\nclass Grid {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n';
		}
		function question(made: String, files: Map<String, String>, ?build: String, ?unindexed: Map<String, String>): ReachResult {
			files['Main.hx'] = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n\t}\n'
				+ '\tfunction calm():Void {}\n\tstatic function other():Void {\n\t\t' + made + '\n\t}\n}\n';
			final builds: Null<Array<Array<String>>> = build == null ? null : [[], ['other']];
			return ask(files, builds, true, { owner: 'Grid', name: 'items' }, false, build, null, unindexed, true);
		}
		final two: ReachResult = question('new a.Grid();\n\t\tnew b.Grid();', ['a/Grid.hx' => grid('a'), 'b/Grid.hx' => grid('b')]);
		assertMatch(two, r -> r.match(Unknown(Ambiguous('Grid'))));
		final unbuilt: ReachResult = question('new a.Grid();\n\t\tnew b.Grid.Other();', [
			'a/Grid.hx' => grid('a'),
			'b/Grid.hx' => 'package b;\n\n#if never\nclass Grid {}\n#end\nclass Other {\n\tpublic function new() {}\n}\n'
		]);
		assertMatch(unbuilt, r -> r.match(Unknown(Ambiguous('Grid'))));
		final base: String = 'class Grid {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n';
		final unheld: ReachResult = question(
			'new Grid();\n\t\tnew c.Grid();', ['base/Grid.hx' => base, 'other/Grid.hx' => base], PER_BUILD_CLASSPATH,
			['c/Grid.hx' => grid('c'), 'Cp.hx' => PICK_CLASSPATH]
		);
		assertMatch(unheld, r -> r.match(Unknown(Ambiguous('Grid'))));
	}

	@:pin('control') @:killer('M-FACTS-FOLDED-BY-ID') @:killer('M-FACTS-SOLE-NEVER') @:killer('M-REACH-AMBIGUOUS-SOLE-NONE')
	public function testATypeDeclaredOncePerBuildIsOneTypeUnderTheTruth(): Void {
		// `Grid` is declared once per build — in each branch of a region, or in a file of each build's own classpath — and each
		// build types its own: all are `Grid`, one type. Under the whole list of builds the graph node folding the declarations
		// of `run` is read by its id, its facts those of every build, each declaration's call; a question about its member is
		// no ambiguity, only a type with no one declaration site. With no such list the syntax reads them, and a name the index
		// declares twice is ambiguous
		function grid(called: String): String {
			return 'class Grid {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n\tpublic function run():Void ' + called
				+ '();\n\tfunction ' + called + '():Void {}\n}\n';
		}
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n\t}\n'
			+ '\tfunction calm():Void {}\n\tstatic function other():Void {\n\t\tnew Grid().run();\n\t}\n}\n';
		final both: Array<Array<String>> = [[], ['other']];
		final branches: Map<String, String> = ['Main.hx' => main + '#if other\n' + grid('a') + '#else\n' + grid('b') + '#end\n'];
		final files: Map<String, String> = ['Main.hx' => main, 'base/Grid.hx' => grid('b'), 'other/Grid.hx' => grid('a')];
		final picker: Map<String, String> = ['Cp.hx' => PICK_CLASSPATH];
		function calls(fixture: Map<String, String>, ?build: String, ?unindexed: Map<String, String>, listed: Bool): Array<String> {
			return withReach(fixture, both, true, false, build, null, unindexed, listed, (reach, dir) -> {
				final facts: Array<FactNode> = reach.graph().facts?.faceted['Grid.run'] ?? [];
				[for (n in facts) for (c in n.calls) c.target ?? ''];
			});
		}
		for (read in [calls(branches, true), calls(files, PER_BUILD_CLASSPATH, picker, true)])
			Assert.isTrue(read.contains('Grid.a') && read.contains('Grid.b'), 'read $read');
		Assert.same([], calls(branches, false));
		Assert.same([], calls(files, PER_BUILD_CLASSPATH, picker, false));
		final member: MemberRef = { owner: 'Grid', name: 'items' };
		final typed: ReachResult = ask(files, both, true, member, false, PER_BUILD_CLASSPATH, null, picker, true);
		assertMatch(typed, r -> r.match(Unknown(OutOfScope(_))));
		assertMatch(ask(files, both, true, member, false, PER_BUILD_CLASSPATH, null, picker), r -> r.match(Unknown(Ambiguous('Grid'))));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-NEVER') @:killer('M-TOUCH-TYPED-SHAPE-NONE') @:killer('M-TOUCH-TYPED-CALL')
	@:killer('M-TOUCH-TYPED-OWNER')
	public function testATouchOnlyTheFactsSeeIsFoundUnderTheTruth(): Void {
		// `stuff` is `Main.items` imported under another name: no text of `Other.grow` spells `items`, the facts name the
		// field it pushes to. `Bag.items` is another type's field of the same name
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Other.REGION(); /*>*/ }\n'
			+ '\t\tOther.grow();\n\t\tOther.calm();\n\t}\n}\n';
		final other: String = 'import Main.items as stuff;\n\nclass Other {\n\tpublic static function grow():Void stuff.push(1);\n\n'
			+ '\tpublic static function calm():Void Bag.items.push(1);\n}\n\nclass Bag {\n\tpublic static var items:Array<Int> = [];\n}\n';
		function files(called: String): Map<String, String> {
			return ['Main.hx' => StringTools.replace(main, 'REGION', called), 'Other.hx' => other];
		}
		assertMatch(truthAsk(files('grow')), r -> r.match(Reached(_)));
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		assertMatch(ask(files('calm'), null, true, null, true, null, null, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-VALUE') @:killer('M-TOUCH-TYPED-UNTRUE')
	public function testAMethodClosureOfTheMemberEscapesUnderTheTruth(): Void {
		// `items.push` read as a value holds `items` for whoever calls it later: the facts use the read as a value, where the
		// syntax sees a harmless field read. With no list of builds the syntax answers, as it did
		final main: String = LOOP_HEAD
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n\t\tkeep();\n\t}\n'
			+ '\tstatic function calm():Void {}\n\tstatic function keep():Void {\n\t\tvar p = items.push;\n\t\tp(1);\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(Escape(_, _))));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-CALLED')
	public function testAFieldTheCompilerCallsLeavesItsFunctionToTheSyntaxUnderTheTruth(): Void {
		// `d.items(1)` calls whatever a dynamic receiver's `items` holds: the facts record a call and no field read, so `poke`
		// is read by its syntax, where the receiver may be the one holding the member and its value is handed to a call
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n'
			+ '\t\tpoke(null);\n\t}\n\tstatic function calm():Void {}\n\tstatic function poke(d:Dynamic):Void d.items(1);\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-FRESH') @:killer('M-TOUCH-TYPED-SYNTAX-TOO')
	public function testAWriteTheCompilerSeesStoringOnlyFreshValuesLetsNothingEscape(): Void {
		// every value `reset` stores is built right there, which the syntax cannot see through the conditional
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n'
			+ '\t\treset(true);\n\t}\n\tstatic function calm():Void {}\n'
			+ '\tstatic function reset(c:Bool):Void {\n\t\titems = c ? [] : null;\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => main]), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-SELF')
	public function testAConstructorTouchingItsOwnObjectIsExcusedUnderTheTruth(): Void {
		// the object `new Main()` builds is not the one the loop runs on: its constructor writes its own `items`
		final main: String = 'class Main {\n\tpublic var items:Array<Int> = [];\n'
			+ '\tpublic function new() {\n\t\tthis.items = [];\n\t\titems.push(0);\n\t}\n'
			+ '\tstatic function main() {\n\t\tnew Main().f();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ var m = new Main(); /*>*/ }\n\t}\n}\n';
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		assertMatch(ask(['Main.hx' => main], null, true, null, true, null, null, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-TYPED-ARRAY-NEVER') @:killer('M-REACH-TYPED-ARRAY-ANY')
	public function testAnUnannotatedArrayMemberIsAnArrayUnderTheTruth(): Void {
		// `items` declares no type, so the index cannot say `items.indexOf` is the array's own reader and not a method that
		// changes it; the facts type it `Array<Int>`. A `Bag` with an `indexOf` of its own is no array
		function fixture(init: String): Map<String, String> {
			final main: String = 'class Main {\n\tpublic var items = ' + init + ';\n\tpublic function new() {}\n'
				+ '\tstatic function main() {\n\t\tvar m = new Main();\n\t\tm.items.push(1);\n\t\tm.f();\n\t}\n'
				+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ var k = items.indexOf(i); /*>*/ }\n\t}\n}\n'
				+ 'class Bag {\n\tpublic var length:Int = 0;\n\tpublic function new() {}\n\tpublic function push(v:Int):Void length++;\n'
				+ '\tpublic function indexOf(v:Int):Int return length++;\n}\n';
			return ['Main.hx' => main];
		}
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		assertMatch(ask(fixture('[]'), null, true, null, true, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(fixture('[]')), r -> r.match(Reached(_)));
		assertMatch(truthAsk(fixture('new Bag()')), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-PROPERTY-STRAIGHT') @:killer('M-REACH-PROPERTY-GETTER')
	@:killer('M-REACH-FACTS-FIELDS-UNTRUE')
	public function testAPropertyReadStraightFromItsStorageIsAnsweredUnderTheTruth(): Void {
		// a write of `items` runs `set_items`, a call the facts name, whose body writes the storage by a field access, and a
		// read reads the storage itself; a getter decides what a reader sees whatever the storage holds, `@:isVar` or not
		function fixture(accessors: String, region: String): Map<String, String> {
			final main: String = 'class Main {\n\t@:isVar public var items(' + accessors
				+ '):Array<Int> = [];\n\tpublic function new() {}\n'
				+ '\tfunction set_items(v:Array<Int>):Array<Int> {\n\t\titems = v;\n\t\treturn v;\n\t}\n'
				+ '\tfunction get_items():Array<Int> return items;\n'
				+ '\tstatic function main() {\n\t\tvar m = new Main();\n\t\tm.f();\n\t\tm.g();\n\t}\n'
				+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ ' + region + ' /*>*/ }\n\t}\n'
				+ '\tfunction h():Void {}\n\tfunction g():Void {\n\t\titems = [1];\n\t}\n}\n';
			return ['Main.hx' => main];
		}
		assertMatch(askAs(fixture('default, set', 'h();'), Write, true), r -> r.match(Proven));
		assertMatch(askAs(fixture('default, set', 'g();'), Write, true), r -> r.match(Reached(_)));
		assertMatch(askAs(fixture('default, set', 'h();'), Write, false), r -> r.match(Unknown(UnresolvedDispatch(_, _, _))));
		assertMatch(askAs(fixture('get, set', 'h();'), Write, true), r -> r.match(Unknown(UnresolvedDispatch(_, _, _))));
	}

	@:pin('control') @:killer('M-REACH-REWRITTEN-TRUTH') @:killer('M-REACH-REWRITTEN-UNTRUE')
	public function testCodeABuildMacroLeftAsItsTextIsAnsweredUnderTheTruth(): Void {
		// `Main` inherits `Base`'s `@:autoBuild`, whose macro hands the fields back as they are: the facts, the code every build
		// compiled, are `Main`'s text, so no touch of `items` hides in code the text does not show. Without the whole list of
		// builds, a build the list does not name may run the macro to other effect
		final main: String = 'class Main extends Base {\n\tpublic var items:Array<Int> = [1];\n'
			+ '\tstatic function main() {\n\t\tnew Main().f();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n\t}\n\tfunction calm():Void {}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Base.hx' => '@:autoBuild(Mac.keep())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(truthAsk(files), r -> r.match(Proven));
		assertMatch(ask(files), r -> r.match(Unknown(Reification(_, _))));
		// the region runs `Helper.calm`, of a class under `Base`'s `@:autoBuild`: kept as its text, it is walked as any other
		assertMatch(truthAsk(helperBuiltBy('keep', 'h.calm();')), r -> r.match(Proven));
		assertMatch(ask(helperBuiltBy('keep', 'h.calm();')), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-OWNER-IDS') @:killer('M-GRAPH-ADOPT-NONE') @:killer('M-GRAPH-ADOPT-UNRECORDED')
	@:killer('M-TOUCH-ADOPTED-SYNTAX')
	public function testACalleeABuildMacroRewroteToTouchTheMemberReachesItUnderTheTruth(): Void {
		// `Mac.rewrite` makes `Helper.calm` push onto `items`, which its text never names: the facts, read by the node's id
		// since the body lies in `Mac.hx`, show the touch
		assertMatch(truthAsk(helperBuiltBy('rewrite', 'h.calm();')), r -> r.match(Reached(_)));
		assertMatch(ask(helperBuiltBy('rewrite', 'h.calm();')), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-GRAPH-ADOPT-NONE') @:killer('M-TOUCH-ADOPTED-SYNTAX')
	public function testAMethodABuildMacroAddedTouchingTheMemberReachesItUnderTheTruth(): Void {
		// `Mac.add` gives `Helper` an `added` that pushes onto `items`: no text declares it, the region calls it. Its facts make
		// it a node of the graph, which the call the facts name reaches
		assertMatch(truthAsk(helperBuiltBy('add', 'h.added();')), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-TOUCH-ADOPTED-UNREAD')
	public function testAMethodABuildMacroAddedTheFactsCannotReadTouchesTheMemberUnderTheTruth(): Void {
		// `Mac.dyn`'s `added` calls what a dynamic value's `items` holds, a call the facts do not read as an access of the
		// member, and no text holds the body to read instead: it touches the member and lets its value go
		assertMatch(truthAsk(helperBuiltBy('dyn', 'h.added();')), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-REACH-ENTRY-REWRITTEN') @:killer('M-REACH-ENTRY-MEMBER') @:killer('M-REACH-TEXTUAL-ALWAYS')
	public function testARegionOfABodyABuildMacroReplacedIsNoProofUnderTheTruth(): Void {
		// `Mac.loop` replaces `Main.f`, the region's function, by a push onto `Store.items`: the region's text is none of what
		// runs, whatever the owner of the member
		final main: String = 'class Main extends Base {\n\tstatic function main() {\n\t\tnew Main().f();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0...Store.items.length) { /*<*/ var k = i; /*>*/ }\n\t}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Store.hx' => 'class Store {\n\tpublic static var items:Array<Int> = [1];\n}\n',
			'Base.hx' => '@:autoBuild(Mac.loop())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		final store: MemberRef = { owner: 'Store', name: 'items' };
		assertMatch(ask(files, null, true, store, false, null, null, null, true), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-REACH-ENTRY-REWRITTEN') @:killer('M-REACH-ENTRY-LOCAL')
	public function testALocalOfABodyABuildMacroReplacedIsNoProofUnderTheTruth(): Void {
		// `Mac.loop` replaces `Main.f`, where the region and the local are, by a push onto `Store.items`: the text declaring the
		// local is none of what runs
		final main: String = 'class Main extends Base {\n\tpublic static var kept:Array<Int> = [1];\n'
			+ '\tstatic function main() {\n\t\tnew Main().f();\n\t}\n\tfunction f():Void {\n\t\tfinal xs:Array<Int> = [1];\n'
			+ '\t\tfor (i in 0...xs.length) { /*<*/ kept.push(xs[i]); /*>*/ }\n\t}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Store.hx' => 'class Store {\n\tpublic static var items:Array<Int> = [1];\n}\n',
			'Base.hx' => '@:autoBuild(Mac.loop())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(askLocal(files, 'xs'), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-FIELDS-ANY')
	public function testAVariableABuildMacroMadeAPropertyKeepsItsOwnerUnknownUnderTheTruth(): Void {
		// `Mac.prop` makes `items` a property its text never declares: a read of it runs `get_items`, which hands out `shared`,
		// the array `calm` pushes onto. The text's plain variable is not what every build compiled
		final main: String = 'class Main extends Base {\n\tpublic var items:Array<Int> = [1];\n'
			+ '\tpublic static var shared:Array<Int> = [2];\n\tstatic function main() {\n\t\tnew Main().f();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ calm(); /*>*/ }\n\t}\n'
			+ '\tfunction calm():Void {\n\t\tshared.push(3);\n\t}\n\tfunction get_items():Array<Int> {\n\t\treturn shared;\n\t}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Base.hx' => '@:autoBuild(Mac.prop())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(truthAsk(files), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-CALLS-ANY')
	public function testALocalACalleeRebuiltInPlaceHandsOutIsNoProofUnderTheTruth(): Void {
		// `Mac.recall` gives `Line.all` the body `return Main.make()` at the old body's range: every fact of it is in place, but no
		// text there spells `make`, whose `kept` the region changes. The text of `all` would hand out a fresh array
		final main: String = 'class Main {\n\tpublic static var kept:Array<Int> = [1];\n'
			+ '\tpublic static function make():Array<Int> {\n\t\treturn kept;\n\t}\n\tstatic function main() {\n'
			+ '\t\tfinal xs:Array<Int> = new Line().all();\n\t\tfor (i in 0...xs.length) { /*<*/ kept.push(xs[i]); /*>*/ }\n\t}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Line.hx' => 'class Line extends Base {\n\tpublic function all():Array<Int> {\n\t\tfinal out:Array<Int> = [1];\n'
				+ '\t\tout.push(2);\n\t\treturn out;\n\t}\n}\n',
			'Base.hx' => '@:autoBuild(Mac.recall())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(askLocal(files, 'xs'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-EXPANSION') @:killer('M-FACTS-TEXT-EXPANSION-SPLICED')
	@:killer('M-FACTS-EXPANSION-NESTED')
	public function testAnExpressionMacroAnInlinedMethodCallsLeavesItsCallerItsTextUnderTheTruth(): Void {
		// TM's `GridUtils.saveGridJSON`: the inlined `Shown.mask` calls the expression macro `Mac.t`, whose expansion lies in
		// `Mac.hx`, in no range of `Util` nor of `Shown`. The call `Shown.mask` writes built it, so `Util` is its text still
		final shown: String = 'class Shown {\n\tpublic static inline function mask():Void Words.say(\'$${Mac.t(\'Open\')}...\');\n}\n';
		final files: Map<String, String> = utilWith(
			'public static function other():Void {\n\t\tShown.mask();\n\t}', ['Shown.hx' => shown, 'Words.hx' => WORDS]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
		assertMatch(ask(files, null, true, null, false, HUB_BUILD), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-EXPANSION') @:killer('M-FACTS-TEXT-EXPANSION-BODY')
	@:killer('M-FACTS-EXPANSION-RECORDED') @:killer('M-FACTS-MACRO-CALLEE')
	public function testAnExpressionMacroTheTextCallsLeavesItsTypeItsTextUnderTheTruth(): Void {
		// `Util.other` calls the expression macro `Mac.t` itself (TM's `t(...)` everywhere): the code its expansion holds is
		// the text's, although no range of `Util` holds it
		final files: Map<String, String> = utilWith('public static function other():Void Words.say(Mac.t(\'x\'));', ['Words.hx' => WORDS]);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	public function testCodeABuildMacroBuiltIsNoExpansionTheTextWritesUnderTheTruth(): Void {
		// `Mac.leak` makes `Main.g` store `items` in `Other.keep`: the code lies in the declared range of a macro — `leak`
		// itself — as an expression macro's expansion would, but no text of `g` calls it. The escape is in no text, and the
		// region changes what `Other.keep` holds. No pin: what reads the facts of `g` refuses it too, apart from
		// `FactsProvenance.expansionWritten`, which answers only whether `Main` is its text
		final main: String = 'class Main extends Base {\n\tpublic static var items:Array<Int> = [1, 2];\n'
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Other.keep.push(1); /*>*/ }\n\t}\n'
			+ '\tfunction g():Void {}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Other.hx' => 'class Other {\n\tpublic static var keep:Array<Int> = [];\n}\n',
			'Base.hx' => '@:autoBuild(Mac.leak())\nclass Base {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(truthAsk(files), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-LITERAL')
	public function testAConstructionALiteralWritesIsItsTextUnderTheTruth(): Void {
		// the compiler constructs an `EReg` at a regex literal and a `Map` at an array literal a map is expected of (TM's
		// `GridUtils.loadGridJSON`, openfl's `TextField.set_htmlText`)
		final files: Map<String, String> = utilWith(
			'public static function other():Map<Int, String> {\n\t\tfinal r:EReg = ~/a+/;\n\t\tfinal m:Map<Int, String> = [];\n'
			+ '\t\treturn m;\n\t}'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-LITERAL-FLAGS')
	public function testARegexLiteralWithFlagsIsItsTextUnderTheTruth(): Void {
		// the compiler's position of the `EReg` it constructs leaves the literal's flags out (openfl's
		// `TextField.set_htmlText`: `~/\s+/g`)
		final files: Map<String, String> = utilWith('public static function other():EReg return ~/a+/gi;');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-ABSTRACT-NEW')
	public function testAConstructionOfAnAbstractIsItsTextUnderTheTruth(): Void {
		// `new Map()` is a construction of `Map`'s implementation class (openfl's `DisplayObject.__broadcastEvents`)
		final files: Map<String, String> = utilWith('public static function other():Map<String, Int> return new Map<String, Int>();');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-PURE-CALL')
	public function testATypeCheckTheCompilerCallsIsItsTextUnderTheTruth(): Void {
		// `o is Util` is a call of `Std.isOfType`, which runs no project code (openfl's `DisplayObject.dispatchEvent`)
		final files: Map<String, String> = utilWith('public static function other(o:Dynamic):Bool return o is Util;');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-CONVERSION-CALL')
	public function testAConversionTheCompilerCallsIsItsTextUnderTheTruth(): Void {
		// a concatenated array is converted by a call of `Std.string`, which the truth reads as a conversion site
		final files: Map<String, String> = utilWith('public static function other(a:Array<Int>):String return \'a\' + a;');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-ACCESSOR-NAME')
	public function testAnAccessorCalledByItsOwnNameIsItsTextUnderTheTruth(): Void {
		// `set_v(2)` calls the setter by its own name, not through the property (openfl's `TextField.set_text`)
		final files: Map<String, String> = utilWith(
			'public static var v(get, set):Int;\n\n\tstatic function get_v():Int return 1;\n\n'
			+ '\tstatic function set_v(x:Int):Int return x;\n\n\tpublic static function other():Void set_v(2);'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-JOINED-SPLICES')
	public function testAFieldTheCompilerPlacesAcrossTwoInlinedGettersIsItsTextUnderTheTruth(): Void {
		// `a.nn` inlines `get_nn`, whose `base` inlines `get_base`: the compiler places the read of `n` from the one's code to
		// the other's (TM's `FileSystemItemData.filePath`)
		final ab: String = 'abstract Ab(Holder) from Holder {\n\tpublic var base(get, never):Holder;\n\n'
			+ '\tinline function get_base():Holder return this;\n\n\tpublic var nn(get, never):Int;\n\n'
			+ '\tinline function get_nn():Int return base.n;\n}\n';
		final files: Map<String, String> = utilWith(
			'public static function other(a:Ab):Int return a.nn;', ['Ab.hx' => ab, 'Holder.hx' => HOLDER]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-JOINED-ACCESS')
	public function testAMemberOfWhatAnInlinedGetterReturnsIsItsTextUnderTheTruth(): Void {
		// `Mgr.instance` inlines `get_instance`: the compiler places the call of `get_q` from that code in `Mgr.hx` to the end of
		// `.q` in `Util.hx` (TM's `PopupManager.instance.notification`, openfl's `textFormatRanges[i].end`)
		final mgr: String = 'class Mgr {\n\tpublic static var instance(get, never):Holder;\n\n\tstatic var held:Null<Holder> = null;\n\n'
			+ '\tstatic inline function get_instance():Holder return held ?? throw \'none\';\n}\n';
		// the doc puts `.q` past every offset of `Mgr.hx`: the compiler keeps the larger end of the parts it joins, whatever
		// their files, so the range ends in `Util.hx` only there, as in TM
		final doc: String = '/**\n\t * The `q` of the manager\'s holder, read through `get_q` on what the inlined `get_instance` returns,\n'
			+ '\t * past every offset of `Mgr.hx`.\n\t */\n\t';
		final files: Map<String, String> = utilWith(
			doc + 'public static function other():Int return Mgr.instance.q;', ['Mgr.hx' => mgr, 'Holder.hx' => HOLDER]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-JOINED-CONVERSION') @:killer('M-FACTS-TEXT-JOINED-PLACED')
	public function testAConversionOfAFieldOfWhatAnInlinedIndexReturnsIsItsTextUnderTheTruth(): Void {
		// `${m[k].e}` inlines `Map.get`: the compiler places the conversion of `.e`, as the read of it, from that code in
		// `Map.hx` to the end of `.e` in `Util.hx` (TM's `drill.Node.parse`)
		final box: String = 'enum En {\n\tA;\n}\n\nclass Box {\n\tpublic var e:En = A;\n\n\tpublic function new() {}\n}\n';
		// the doc puts `.e` past every offset of `Map.get` in `Map.hx`: the compiler keeps the smaller start and the larger end of
		// the parts it joins, whatever their files, so the range starts in `Map.hx` and ends in `Util.hx` only then, as in TM
		final doc: String = '/**\n\t * ' + [for (i in 0...70) 'The enum value of the box a key maps to, converted.'].join('\n\t * ')
			+ '\n\t */\n\t';
		final files: Map<String, String> = utilWith(
			doc + 'public static function other(m:Map<String, Box>, k:String):String return \'x $${m[k].e}\';', ['Box.hx' => box]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-PURE-CALL') @:killer('M-FACTS-TEXT-ABSTRACT-NEW')
	public function testALibraryClassTheWalkEntersIsItsTextUnderTheTruth(): Void {
		// openfl's `DisplayObject`, rebuilt from its own fields by a global macro: the walk enters `Disp.calm`, of a class whose
		// `check` tests a type and whose `made` constructs a `Map`
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfinal d:Disp = new Disp();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ d.calm(); /*>*/ }\n\t}\n}\n';
		final disp: String = 'class Disp {\n\tpublic function new() {}\n\n\tpublic function calm():Void {}\n\n'
			+ '\tpublic function check(o:Dynamic):Bool return o is Disp;\n\n'
			+ '\tpublic function made():Map<String, Int> return new Map<String, Int>();\n}\n';
		final files: Map<String, String> = ['Main.hx' => main, 'Mac.hx' => BUILD_MACROS];
		assertMatch(ask(files, null, true, null, false, HUB_BUILD, ['Disp.hx' => disp], null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-REWRITTEN-TRUTH')
	public function testABuildMacroOnlyTheCompilerSawChangingNothingIsNoneUnderTheTruth(): Void {
		// the listed twin of `testABuildMacroOnlyTheCompilerSawIsUnknown`: the `@:build` a global `addGlobalMetadata` puts on
		// `Main` hands back no fields, so what every build compiled is `Main`'s text
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ helper(); /*>*/ }\n\t}\n'
			+ '\tstatic function helper():Void {}\n}\n';
		final mac: String = 'class Mac {\n\tpublic static macro function b():Array<haxe.macro.Expr.Field> return null;\n}\n';
		final build: String = BUILD + '--macro addGlobalMetadata("Main", "@:build(Mac.b())", false)\n';
		assertMatch(ask(['Main.hx' => main, 'Mac.hx' => mac], null, true, null, false, build, null, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-REWRITTEN-TRUTH') @:killer('M-REACH-REWRITTEN-UNTRUE')
	public function testAnArrayMemberOfASubclassUnderAnAncestorsAutoBuildIsAnsweredUnderTheTruth(): Void {
		// TM's `GridScale extends Sprite`: an ancestor's `@:autoBuild` that changes nothing but a class carrying `@:bind`, and a
		// global build rebuilding every class from its own fields, over a subclass looping over its own private array
		final main: String = 'class Main extends Mid {\n\tprivate final _points:Array<Int> = [];\n'
			+ '\tstatic function main() {\n\t\tnew Main().f();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0..._points.length) { /*<*/ calm(\'$${_points[i]}\'); /*>*/ }\n\t}\n'
			+ '\tfunction calm(s:String):Void {}\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => main,
			'Mid.hx' => 'class Mid extends Top {}\n',
			'Top.hx' => '@:autoBuild(Mac.bind())\nclass Top {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		final build: String = BUILD + '--macro addGlobalMetadata("", "@:build(Mac.hub())")\n';
		final points: MemberRef = { owner: 'Main', name: '_points' };
		assertMatch(ask(files, null, true, points, false, build, null, null, true), r -> r.match(Proven));
		assertMatch(ask(files, null, true, points, false, build), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-INLINED-RECEIVER')
	public function testAKeyValueLoopOverTheMemberLetsNothingEscapeUnderTheTruth(): Void {
		// TM's `GridScale`: `for (i => p in _points)` is the inlined `_points.keyValueIterator()`, whose receiver the compiler
		// binds to a local of its own and hands to `new ArrayKeyValueIterator(_this)` — a read the facts took for a value
		// handed on. It is the receiver of a call of the array's own reader, as the syntax spells it; so is the one of
		// `iterator()`, whose result is stored. The value loop and the indexed one are lowered with no call at all
		final main: String = 'class Main {\n\tprivate final _points:Array<P> = [];\n\tpublic var it:Iterator<P> = [].iterator();\n'
			+ '\tpublic function new() {}\n\tstatic function main() {\n\t\tfinal m = new Main();\n\t\tm.f();\n\t\tm.g();\n\t}\n'
			+ '\tfunction g():Void {\n\t\tfor (i => p in _points) p.x = i;\n\t\tfor (p in _points) p.x = 0;\n'
			+ '\t\tit = _points.iterator();\n\t}\n'
			+ '\tfunction f():Void {\n\t\tfor (i in 0..._points.length) { /*<*/ _points[i].x = i; poke(); /*>*/ }\n\t}\n'
			+ '\tfunction poke():Void Other.poke(this);\n}\n' + 'class P {\n\tpublic var x:Int = 0;\n\tpublic function new() {}\n}\n'
			+ 'class Other {\n\tpublic static var seen:Null<Main> = null;\n\tpublic static function poke(m:Main):Void seen = m;\n}\n';
		final points: MemberRef = { owner: 'Main', name: '_points' };
		assertMatch(ask(['Main.hx' => main], null, true, points, false, null, null, null, true), r -> r.match(Proven));
		// the syntax reads a loop's iterable, and a call of the array's own reader, as no escape
		assertMatch(ask(['Main.hx' => main], null, false, points), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-RECEIVER-BLOCK') @:killer('M-FACTS-RECEIVER-PARAM')
	public function testAMemberAnInlinedMethodTakesAsAnArgumentStillEscapesUnderTheTruth(): Void {
		// `Keeper.push` and `Keeper.pop` bear the array's own method names, and each keeps the array it is handed: `push`
		// through a local of its own named as the compiler names a receiver, `pop` through a parameter so named, which the
		// compiler binds as it binds a receiver. Neither is the receiver, so the read escapes. So does the member handed to
		// the constructor of an iterator of the project's, stored
		function fixture(use: String): Map<String, String> {
			final main: String = 'class Main {\n\tprivate final _points:Array<Int> = [];\n\tpublic function new() {}\n'
				+ '\tstatic function main() {\n\t\tfinal m = new Main();\n\t\tm.f();\n\t\tm.g(new Keeper());\n\t}\n'
				+ '\tfunction g(k:Keeper):Void {\n\t\t' + use + '\n\t}\n'
				+ '\tfunction f():Void {\n\t\tfor (i in 0..._points.length) { /*<*/ Keeper.grow(); /*>*/ }\n\t}\n}\n'
				+ 'class Keeper {\n\tpublic static var held:Array<Int> = [];\n\tpublic var it:Null<Walk> = null;\n'
				+ '\tpublic var count:Int = 0;\n\tpublic function new() {}\n\tpublic static function grow():Void held.push(1);\n'
				+ '\tpublic inline function push(a:Array<Int>):Array<Int> {\n\t\tvar _this = a;\n\t\treturn _this;\n\t}\n'
				+ '\tpublic inline function pop(_this:Array<Int>):Void {\n\t\theld = _this;\n\t\tcount = _this.length;\n\t}\n}\n'
				+ 'class Walk {\n\tfinal a:Array<Int>;\n\tvar i:Int = 0;\n\tpublic inline function new(a:Array<Int>) this.a = a;\n'
				+ '\tpublic inline function hasNext():Bool return i < a.length;\n\tpublic inline function next():Int return a[i++];\n}\n';
			return ['Main.hx' => main];
		}
		final points: MemberRef = { owner: 'Main', name: '_points' };
		for (use in ['Keeper.held = k.push(_points);', 'k.pop(_points);', 'k.it = new Walk(_points);'])
			assertMatch(ask(fixture(use), null, true, points, false, null, null, null, true), r -> r.match(Unknown(Escape(_, _))));
	}

	/**
	 * A fixture whose region calls `lib.Text.fail` (`plainText`) beside an `Obj` (`CLEARING_OBJ`), whose `toString` replaces
	 * `Main.items`, held in `o` and handed to the library's `Text.keep`; `escape` is a statement of `main` that may let it go.
	 */
	private static function escapingObj(escape: String): Map<String, String> {
		return [
			'Main.hx' => 'import lib.Text;\n\n' + LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n'
				+ '\t\tText.keep(o);\n\t\t' + escape + '\n\t\tfor (i in 0...items.length) { /*<*/ Text.fail(); /*>*/ }\n\t}\n}\n'
				+ CLEARING_OBJ
		];
	}

	/**
	 * The library `lib.Text`, whose `fail` runs `thrown` when `failing`, beside `Plain`, a class with no `toString`, `last`, one,
	 * and `keep`, a generic function that does nothing with what it is handed.
	 */
	private static function plainText(thrown: String): Map<String, String> {
		return [
			'lib/Text.hx' => 'package lib;\n\nclass Plain {\n\tpublic function new() {}\n}\n\nclass Text {\n'
				+ '\tpublic static var last:Plain = new Plain();\n\n\tpublic static var failing:Bool = false;\n\n'
				+ '\tpublic static function keep<A>(x:A):Void {}\n\n\tpublic static function fail():Void {\n' + '\t\tif (failing) {\n\t\t'
				+ thrown + '\n\t\t}\n\t}\n}\n'
		];
	}

	/**
	 * `ask` of `escapingObj(escape)` beside `more`, `lib.Text.fail` running `thrown`, under the whole list of builds — which
	 * must compile: a build that fails leaves no facts, and the answer would be the syntax's.
	 */
	@:access(anyparse.query.MemberReach)
	private static function truthLibAsk(
		escape: String, thrown: String, ?more: Map<String, String>, ?build: String, ?pos: haxe.PosInfos
	): ReachResult {
		final files: Map<String, String> = escapingObj(escape);
		for (name => text in more ?? []) files[name] = text;
		return withReach(files, null, true, false, build, plainText(thrown), null, true, (reach, dir) -> {
			Assert.isTrue(reach._scope.facts?.truth == true, 'the fixture did not compile', pos);
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(files['Main.hx'] ?? '')), { owner: 'Main', name: 'items' }, Mutate);
		});
	}

	/**
	 * `lib.Vec`, whose static `splice` iterates a `VecIter` through `id`, which the syntax cannot type, and `other.Vec`, of
	 * the same simple name, declaring no `splice`.
	 */
	private static function sharedNameLibrary(): Map<String, String> {
		return [
			'lib/Vec.hx' => 'package lib;\n\nclass VecIter {\n\tfinal a:Array<Int>;\n\tvar i:Int = 0;\n\n'
				+ '\tpublic function new(a:Array<Int>) this.a = a;\n\n\tpublic function hasNext():Bool return i < a.length;\n\n'
				+ '\tpublic function next():Int return a[i++];\n\n\tpublic static function zero():Int return 0;\n}\n\n'
				+ 'class Vec {\n\tpublic static var peer:other.Vec = null;\n\n\tstatic var data:Array<Int> = [];\n\n'
				+ '\tstatic function id<X>(x:X):X return x;\n\n'
				+ '\tpublic static function splice(item:Int):Int {\n\t\tvar n:Int = 0;\n\t\tfor (x in id(new VecIter(data))) n++;\n'
				+ '\t\treturn n;\n\t}\n}\n',
			'other/Vec.hx' => 'package other;\n\nclass Vec {\n\tpublic function new() {}\n\n\tpublic function size():Int return 0;\n}\n'
		];
	}

	/**
	 * The answer for `member` (by default `Main.items`) over the region of `Main.hx` among `files`, compiled by `build` under
	 * each define set of `configurations` and read through the facts unless `withFacts` is false; `classpathComplete` is
	 * the analysis's word that the index holds every type the builds compile. `library` files compile beside
	 * them and are indexed, but are no part of the project: the walk reads one only when it follows code into it.
	 * `unindexed` files are written and compiled but indexed by nothing — code only the compiler sees. `listed` hands the
	 * analysis the builds as the whole list of them — one per define set, as a run probes them (`ReachDefinesProbe`).
	 * `declared` library declarations are indexed alone, as the built-in array type's is: written nowhere, compiled by nothing.
	 */
	private static function ask(
		files: Map<String, String>, ?configurations: Array<Array<String>>, withFacts: Bool = true, ?member: MemberRef,
		classpathComplete: Bool = false, ?build: String, ?library: Map<String, String>, ?unindexed: Map<String, String>,
		listed: Bool = false, ?declared: Map<String, String>
	): ReachResult {
		return withReach(files, configurations, withFacts, classpathComplete, build, library, unindexed, listed, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(source)), member ?? { owner: 'Main', name: 'items' }, Mutate);
		}, declared);
	}

	/** `ask` of `files` for `access` instead of `Mutate`, under the whole list of their builds when `listed`. */
	private static function askAs(files: Map<String, String>, access: ReachAccess, listed: Bool): ReachResult {
		return withReach(files, null, true, false, null, null, null, listed, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(source)), { owner: 'Main', name: 'items' }, access);
		});
	}

	/** `ask` of `files` under the whole list of their builds, where the facts are the truth (`FactsView.truth`). */
	private static function truthAsk(files: Map<String, String>): ReachResult {
		return ask(files, null, true, null, false, null, null, null, true);
	}

	/**
	 * Whether the region of `Main.hx` may change what the local `name`, read last in it, holds (see `ask`), answered under
	 * the builds listed as the whole list of them — or, with `classpathComplete`, under the analysis's word that the index
	 * holds every type they compile.
	 */
	private static function askLocal(
		files: Map<String, String>, name: String, withFacts: Bool = true, classpathComplete: Bool = false, ?unindexed: Map<String, String>,
		?declared: Map<String, String>
	): ReachResult {
		return withReach(files, null, withFacts, classpathComplete, null, null, unindexed, !classpathComplete, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			final at: Int = source.lastIndexOf(name, source.indexOf(REGION_CLOSE));
			reach.mayMutateNamed(Path.join([dir, 'Main.hx']), name, new Span(at, at + name.length), regionOf(source));
		}, declared);
	}

	/** The fixture of `ask` written, compiled and indexed, `question` asked of its analysis, and the fixture removed. */
	private static function withReach<T>(
		files: Map<String, String>, configurations: Null<Array<Array<String>>>, withFacts: Bool, classpathComplete: Bool,
		build: Null<String>, library: Null<Map<String, String>>, unindexed: Null<Map<String, String>>, listed: Bool,
		question: (MemberReach, String) -> T, ?declared: Map<String, String>
	): T {
		final entries: Array<{ name: String, source: String }> = [for (name => text in files) { name: name, source: text }];
		for (name => text in library ?? []) entries.push({ name: name, source: text });
		for (name => text in unindexed ?? []) entries.push({ name: name, source: text });
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
		final std: Array<{ file: String, source: String }> = [{ file: 'std/Array.hx', source: STD_ARRAY }];
		for (name => text in declared ?? []) std.push({ file: name, source: text });
		final index: SymbolIndex = SymbolIndex.build(project.concat(libraries).concat(std), plugin);
		// the builds as a run probes them: every define each one sees, the target's and the compiler's included
		final builds: Null<Array<ReachConfiguration>> = listed ? ReachDefinesProbe.probeAll(oracles)?.configurations : null;
		final reach: MemberReach = new MemberReach(
			plugin, project, index, true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED, builds, () -> classpathComplete, facts
		);
		final result: T = question(reach, dir);
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
