package unit.query;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage;
import anyparse.check.ReachDefinesProbe;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.CompilerFacts;
import anyparse.query.MemberReach;
import anyparse.query.ReachLiveness.ReachConfiguration;
import anyparse.query.StdResolver;
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

	/** The build of a fixture whose std calls no rebinding `Reflect.callMethod` of its own: the interpreter. */
	private static inline final INTERP_BUILD: String = '-cp .\n-main Main\n--interp\n';

	/** The build of a fixture whose std is hxcpp's, typechecked only: C++. */
	private static inline final CPP_BUILD: String = '-cp .\n-main Main\n-cpp out\n';

	/** `BUILD` with a classpath of its own per build (`PICK_CLASSPATH`): `other/` when `other` is defined, else `base/`. */
	private static inline final PER_BUILD_CLASSPATH: String = '-cp .\n--macro Cp.pick()\n-main Main\n--js out.js\n';

	/** The initialization macro of `PER_BUILD_CLASSPATH`, compiled by each build and indexed by nothing. */
	private static inline final PICK_CLASSPATH: String = 'class Cp {\n\tpublic static function pick():Void\n'
		+ '\t\thaxe.macro.Compiler.addClassPath(haxe.macro.Context.defined("other") ? "other" : "base");\n}\n';

	/** The library declaration of the built-in array type the index resolves against. */
	private static inline final STD_ARRAY: String = 'extern class Array<T> { public var length(default, null):Int; '
		+ 'public function push(x:T):Int; public function pop():Null<T>; public function indexOf(x:T, ?fromIndex:Int):Int; '
		+ 'public function join(sep:String):String; public function new():Void; }';

	/** The library declaration of the string type the index resolves against, where a test needs its `split` known. */
	private static final STD_STRING: Map<String, String> = [
		'std/String.hx' => 'extern class String { public var length(default, null):Int; public function split(delimiter:String):Array<String>; }'
	];

	/** The library declarations of `Std` and `StringTools` the index resolves against, where a test needs their pure calls known. */
	private static final STD_STD: Map<String, String> = [
		'std/Std.hx' => 'extern class Std { public static function parseFloat(x:String):Float; }',
		'std/StringTools.hx' => 'extern class StringTools { public static function fastCodeAt(s:String, index:Int):Int; }'
	];

	private static inline final REGION_OPEN: String = '/*<*/';
	private static inline final REGION_CLOSE: String = '/*>*/';

	/** A loop in `Main.main` whose body is the region, over the static `Main.items`. */
	private static inline final LOOP_HEAD: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n';

	/** `lib.Buf`, whose inline generic `put` converts what it is handed to a string. */
	private static inline final SPLICED_BUF: String = 'package lib;\n\nclass Buf {\n\tpublic var s:String = "";\n\n'
		+ '\tpublic function new() {}\n\n\tpublic inline function put<T>(x:T):Void\n\t\ts += x;\n}\n';

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

	/**
	 * `a.Grid`, built by `Mac.<mine>()` when given, and `b.Grid`, by `Mac.<other>()`, share a simple name, and each declares
	 * `items` and `calm` (`BUILD_MACROS`); `a.Grid.f` loops over its `items`, and `Main.main` over `g.items` of an `a.Grid`,
	 * each region running nothing. With `base`, the declaration of `a.Base`, `a.Grid` extends it and declares no `items`.
	 */
	private static function pinnedGrids(mine: Null<String>, other: Null<String>, ?base: String): Map<String, String> {
		function built(by: Null<String>): String {
			return by == null ? '' : '@:build(Mac.' + by + '())\n';
		}
		final head: String = base == null
			? 'class Grid {\n\tpublic var items:Array<Int> = [];\n\n\tpublic function new() {}\n'
			: 'class Grid extends Base {\n\tpublic function new() super();\n';
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfinal g:a.Grid = new a.Grid();\n\t\tg.f();\n'
				+ '\t\tfor (i in 0...g.items.length) { /*<*/ var n:Int = i; /*>*/ }\n\t\tnew b.Grid().calm();\n\t}\n}\n',
			'a/Grid.hx' => 'package a;\n\n' + built(mine) + head
				+ '\n\tpublic function f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ var n:Int = i; /*>*/ }\n\t}\n\n'
				+ '\tpublic function calm():Void {}\n}\n',
			'b/Grid.hx' => 'package b;\n\n' + built(other)
				+ 'class Grid {\n\tpublic var items:Array<Int> = [];\n\n\tpublic function new() {}\n\n\tpublic function calm():Void {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		if (base != null) files['a/Base.hx'] = base;
		return files;
	}

	/** The build of a fixture every class of whose root package the global `Mac.hub` rebuilds from its own fields (tink's `SyntaxHub`). */
	private static final HUB_BUILD: String = BUILD + '--macro addGlobalMetadata("", "@:build(Mac.hub())")\n';

	/** The runtime of the expression macro `Mac.t` (`BUILD_MACROS`), and a function the code it builds is handed to. */
	private static final WORDS: String = 'class Words {\n\tpublic static function tr(s:String):String return s;\n\n'
		+ '\tpublic static function say(s:String):Void {}\n}\n';

	/**
	 * The expression macros of `Mac`: `gen` expands to a push onto `Main.items`, `t` to a call of `Words.tr` (TM's `Lang.t`),
	 * `show` to a call of `Words.say` handed `Main.obj` converted to a string.
	 */
	private static final EXPRESSION_MACROS: String = 'class Mac {\n\tpublic static macro function gen() return macro Main.items.push(1);\n\n'
		+ '\tpublic static macro function t(e:haxe.macro.Expr) return macro Words.tr($$e);\n\n'
		+ '\tpublic static macro function show() return macro Words.say("" + Main.obj);\n}\n';

	/** `valueCallFixture` storing a callback of the type `Rx.map` calls, which grows `items`. */
	private static function matching(more: String, ?region: String, ?base: String, ?map: String): String {
		return valueCallFixture('(Rx)->String', '(x:Rx) -> { items.push(1); return "k"; }', more, region, base, map);
	}

	/**
	 * `Main.hx` whose region releases a value into `p`, a `Pool` constructed with `args`, whose `release` calls its `dynamic`
	 * `clean`, which its constructor replaces with its `clean` parameter when handed one, and `set` with its own, which no
	 * call here hands anything; `Main.grow`, which grows `items`,
	 * is read as a value into `Main.keep`; `more` statements run before the loop.
	 */
	private static function poolFixture(args: String, more: String): String {
		return LOOP_HEAD + '\tpublic static var keep:Null<(Int)->Void> = null;\n\n\tstatic function grow(x:Int):Void items.push(x);\n\n'
			+ '\tstatic function main() {\n\t\tkeep = grow;\n\t\tfinal p:Pool = new Pool(' + args + ');\n' + more
			+ '\t\tfor (i in 0...items.length) { /*<*/ p.release(1); /*>*/ }\n\t}\n}\n'
			+ 'class Pool {\n\tpublic function new(?make:()->Int, ?clean:(Int)->Void) {\n\t\tif (clean != null) this.clean = clean;\n\t}\n\n'
			+ '\tpublic dynamic function clean(x:Int):Void {}\n\n\tpublic function release(x:Int):Void clean(x);\n\n'
			+ '\tpublic function set(c:(Int)->Void):Void this.clean = c;\n}\n';
	}

	/**
	 * `poolFixture` constructing `p` with no argument, running `more` first, of a `Pool` declaring no `set`: a construction by
	 * reflection lets a `Pool` leave the type system, and untyped code may then invoke a `set` with anything.
	 */
	private static function settlessPool(more: String): String {
		return StringTools.replace(poolFixture('', more), '\n\n\tpublic function set(c:(Int)->Void):Void this.clean = c;', '');
	}

	/**
	 * `Main.hx` whose region fires `h`, a `Hook`, whose `fire` calls its `dynamic` `run`, which `main` replaces with a
	 * function expression growing nothing; `Main.grow`, which grows `items`, is read as a value into `Main.keep`; `more`
	 * statements run before the loop.
	 */
	private static function hookFixture(more: String): String {
		return LOOP_HEAD + '\tpublic static var keep:Null<(Int)->Void> = null;\n\n\tstatic function grow(x:Int):Void items.push(x);\n\n'
			+ '\tstatic function main() {\n\t\tkeep = grow;\n\t\tfinal h:Hook = new Hook();\n\t\th.run = x -> {};\n' + more
			+ '\t\tfor (i in 0...items.length) { /*<*/ h.fire(); /*>*/ }\n\t}\n}\n'
			+ 'class Hook {\n\tpublic function new() {}\n\n\tpublic dynamic function run(x:Int):Void {}\n\n'
			+ '\tpublic function fire():Void run(1);\n}\n';
	}

	/** Statements of `hookFixture` storing `keep` into `h`'s `run` by a name computed at run time. */
	private static inline final COMPUTED_STORE: String =
		'\t\tvar d:Dynamic = h;\n\t\tvar n:String = "run";\n\t\tReflect.setField(d, n, keep);\n';

	/** `Rx.map` calling a local copy of its parameter (`valueCallFixture`): what it calls is no parameter. */
	private static inline final BY_TYPE: String =
		'public function map(f:(Rx)->String):String {\n\t\tfinal h:(Rx)->String = f;\n\t\treturn h(this);\n\t}';

	/**
	 * `Main.hx` whose `main` runs `statement` before its loop over `items`, whose region runs nothing; `Main.obj` holds a
	 * `Clear`, whose `toString` grows `items`.
	 */
	private static function expandedBefore(statement: String): String {
		return LOOP_HEAD + '\tpublic static var obj:Clear = new Clear();\n\n\tstatic function main() {\n\t\t' + statement + '\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ var n:Int = i; /*>*/ }\n\t}\n}\n'
			+ 'class Clear {\n\tpublic function new() {}\n\n\tpublic function toString():String {\n\t\tMain.items.push(1);\n\t\treturn "c";\n\t}\n}\n';
	}

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

	/**
	 * `gen.Ev<T>`, a `@:genericBuild` class whose macro (`GENERIC_BUILDER`) defines one class per type argument, as lime's
	 * `Event<T>` does: a construction the text writes `new Ev<…>()` constructs that class, whose name no text spells.
	 */
	private static final GENERIC_EV: String = 'package gen;\n\n@:genericBuild(gen.Gen.build())\nclass Ev<T> {\n'
		+ '\tpublic function new() {}\n\n\tpublic function add(x:T):Void {}\n}\n';

	/**
	 * The macros of `GENERIC_EV`: `build` defines `gen._Ev_<argument>` once per type argument, holding `Ev`'s fields and
	 * `fire`, which pushes onto `Main.items` (lime's `dispatch`); `swap`, a build macro, constructs an `Ev<String>` wherever
	 * the text of its type constructs an `Ev<Int>`, at that construction's position.
	 */
	private static final GENERIC_BUILDER: String = 'package gen;\n\nimport haxe.macro.Context;\nimport haxe.macro.Expr;\n'
		+ 'import haxe.macro.Type;\n\nclass Gen {\n\tpublic static function build():ComplexType {\n'
		+ '\t\tfinal arg:Type = switch Context.getLocalType() {\n\t\t\tcase TInst(_, [t]): t;\n\t\t\tcase _: throw "arity";\n\t\t}\n'
		+ '\t\tfinal name:String = "_Ev_" + ~/[^A-Za-z0-9]/g.replace(haxe.macro.TypeTools.toString(arg), "_");\n'
		+ '\t\tif (!defined(name)) {\n\t\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\t\tfields.push({name: "fire", access: [APublic], pos: Context.currentPos(), '
		+ 'kind: FFun({args: [], ret: macro :Void, expr: macro Main.items.push(1)})});\n'
		+ '\t\t\tContext.defineType({pos: Context.currentPos(), pack: ["gen"], name: name, kind: TDClass(), fields: fields, '
		+ 'params: [{name: "T"}]});\n\t\t}\n'
		+ '\t\treturn TPath({pack: ["gen"], name: name, params: [TPType(Context.toComplexType(arg))]});\n\t}\n\n'
		+ '\tstatic function defined(name:String):Bool {\n'
		+ '\t\treturn try {\n\t\t\tContext.getType("gen." + name);\n\t\t\ttrue;\n\t\t} catch (e:haxe.Exception) false;\n\t}\n\n'
		+ '\tpublic static function swap():Array<Field> {\n\t\tfinal fields:Array<Field> = Context.getBuildFields();\n'
		+ '\t\tfunction rewrite(e:Expr):Expr {\n\t\t\treturn switch e.expr {\n'
		+ '\t\t\t\tcase ENew({name: "Ev", params: [TPType(TPath({name: "Int"}))]}, args):\n'
		+ '\t\t\t\t\t{expr: ENew({pack: [], name: "Ev", params: [TPType(macro :String)]}, args), pos: e.pos};\n'
		+ '\t\t\t\tcase _: haxe.macro.ExprTools.map(e, rewrite);\n\t\t\t}\n\t\t}\n'
		+ '\t\tfor (f in fields) switch f.kind {\n\t\t\tcase FFun(fn) if (fn.expr != null): fn.expr = rewrite(fn.expr);\n'
		+ '\t\t\tcase _:\n\t\t}\n\t\treturn fields;\n\t}\n}\n';

	/**
	 * `utilWith(member)`, `Util` importing `gen.Ev` (`GENERIC_EV`) and carrying `meta`, the region calling `Util.calm`; with
	 * `region`, the region runs that instead.
	 */
	private static function genericFixture(member: String, meta: String = '', ?region: String): Map<String, String> {
		final files: Map<String, String> = utilWith(member, ['gen/Ev.hx' => GENERIC_EV, 'gen/Gen.hx' => GENERIC_BUILDER]);
		files['Util.hx'] = 'import gen.Ev;\n\n' + meta + (files['Util.hx'] ?? '');
		if (region != null) files['Main.hx'] = StringTools.replace(files['Main.hx'] ?? '', 'Util.calm();', region);
		return files;
	}

	/** Why each configuration the last `withReach` probed has no facts: a fixture that does not compile. */
	private static var lastDropped: Array<String> = [];

	/**
	 * `ask` of `files` built by `HUB_BUILD`, listed as the whole list of builds: the facts are the truth — and a fixture
	 * that does not compile fails the test, rather than answering from its syntax alone.
	 */
	private static function hubAsk(files: Map<String, String>): ReachResult {
		final result: ReachResult = ask(files, null, true, null, false, HUB_BUILD, null, null, true);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile');
		return result;
	}

	/**
	 * A fixture whose region runs `region` in `Main.main`'s loop over `items`, beside `Main.sink`, which takes any value and
	 * does nothing, and `more` files; `HUB_BUILD` rebuilds every class of it.
	 */
	private static function hubFixture(region: String, more: Map<String, String>): Map<String, String> {
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD + '\tpublic static function sink(x:Dynamic):Void {}\n\n\tstatic function main() {\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ ' + region + ' /*>*/ }\n\t}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		for (name => text in more) files[name] = text;
		return files;
	}

	/**
	 * The answer for a region running `Gen.calm()` where each build (`a`, `b`) reads `Gen` from its own copy, `gen/<build>`,
	 * a library the index holds — lime's `ApplicationMain`, generated into each build's own directory. `copies` holds each
	 * copy's text: one no build names is indexed and read by none, one `unread` names is read by its build but indexed by
	 * nothing. `Mac.hub` rebuilds every root-package class unless `plain`. With `ownDirs` each build runs in its copy's
	 * directory, which its facts then name the copy relative to (an iOS build's Xcode directory). Under the whole list of
	 * builds when `listed`.
	 */
	private static function copiesAsk(
		copies: Map<String, String>, listed: Bool, ownDirs: Bool = false, plain: Bool = false, ?unread: Array<String>
	): ReachResult {
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Gen.calm(); /*>*/ }\n\t}\n}\n';
		final hub: String = plain ? '' : '--macro addGlobalMetadata("", "@:build(Mac.hub())")\n';
		// in build order: the first build's copy is where its facts place a node first
		final names: Array<String> = [for (b in ['a', 'b']) ownDirs ? 'gen/$b/build_$b.hxml' : 'build_$b.hxml'];
		final hxmls: Map<String, String> = [];
		for (b in ['a', 'b']) {
			if (ownDirs)
				hxmls['gen/$b/build_$b.hxml'] = '-cp ../..\n-cp .\n-main Main\n--js out.js\n' + hub
			else
				hxmls['build_$b.hxml'] = '-cp .\n-cp gen/$b\n-main Main\n--js out_$b.js\n' + hub;
		}
		final library: Map<String, String> = [];
		final unindexed: Map<String, String> = [for (name => text in hxmls) name => text];
		for (name => text in copies) {
			if ((unread ?? []).contains(name))
				unindexed['gen/$name/Gen.hx'] = text
			else
				library['gen/$name/Gen.hx'] = text;
		}
		final result: ReachResult = ask(
			['Main.hx' => main, 'Mac.hx' => BUILD_MACROS, 'Words.hx' => WORDS],
			null, true, null, false, null, library, unindexed, listed, null, null, names
		);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile');
		return result;
	}

	/**
	 * A copy of `copiesAsk`'s `Gen` whose `label` is `label`, carrying `meta` before its declaration, whose `calm` runs
	 * `body` — by default, an expression macro's expansion and a local function reading `label` — after `idle`.
	 */
	private static function genCopy(label: String, ?meta: String, ?body: String): String {
		return (meta ?? '') + 'class Gen {\n\tpublic static var label:String = "' + label + '";\n\n'
			+ '\tpublic static function idle():Void {\n\t\ttrace("an idle method of a length past the copies\' difference");\n\t}\n\n'
			+ '\tpublic static function calm():Void {\n\t\t'
			+ (body ?? 'Words.say(Mac.t("x"));\n\t\tfinal f:Int->Int = n -> n + label.length;\n\t\ttrace(f(1));') + '\n\t}\n}\n';
	}

	/** `Other`, whose `dump` returns `access`: a member of its own object read by the name `n` it is handed. */
	private static function reflectingOther(access: String): String {
		return 'class Other {\n\tpublic function new() {}\n\n\tpublic function dump(n:String):Dynamic return ' + access + ';\n}\n';
	}

	/**
	 * `truthAsk` of `files` with the std `Reflect` the build compiles declared where the build reads it: its accessors by name
	 * reach members by the name they are handed in `untyped` code, which the walk enters as it does TM's. The fixture must
	 * compile: a build that fails leaves no facts, and the syntax would answer. With `interp` the build is `INTERP_BUILD`,
	 * whose std calls no rebinding `Reflect.callMethod` of its own and reads no member by a computed name, as js's does
	 * (`Type.createEnum`, `haxe.DynamicAccess`).
	 */
	private static function reflectAsk(
		files: Map<String, String>, interp: Bool = false, ?holders: Array<String>, ?pos: haxe.PosInfos
	): ReachResult {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.fail('no Haxe std to read `Reflect` from', pos);
			return Unknown(OutOfScope('no std'));
		}
		final path: String = OracleCoverage.canonical(Sys.getCwd(), Path.join([std, interp ? 'Reflect.hx' : 'js/_std/Reflect.hx']));
		final result: ReachResult = ask(
			files, null, true, null, false, interp ? INTERP_BUILD : null, null, null, true,
			[path => sys.io.File.getContent(path)],
			holders
		);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile', pos);
		return result;
	}

	/** `WORDS` with `rep`, an inline function handing its first argument to a library call. */
	private static final WORDS_REP: String = 'class Words {\n\tpublic static function tr(s:String):String return s;\n\n'
		+ '\tpublic static function say(s:Dynamic):Void {}\n\n'
		+ '\tpublic static inline function rep(s:String, a:String, b:String):String return StringTools.replace(s, a, b);\n}\n';

	/** `Shown.run`, an inline function calling the closure it is handed and handing its string to a library call. */
	private static final SHOWN_RUN: String = 'class Shown {\n\tpublic static inline function run(f:() -> Void, s:String):Void {\n'
		+ '\t\tf();\n\t\tWords.say(s);\n\t}\n}\n';

	/**
	 * TM's `FileSystemItemData`: an abstract over an enum whose getters inline into each other — `children` and `folder`
	 * read a field of what the inline `base` returns — with `count`, an inline counting what it is handed, `childCount`
	 * calling it with the bare property, and `forEachChild` calling back on each child.
	 */
	private static final FS: String = 'enum FsInternal {\n\tMaster(item:FsBase);\n\tSlave(item:FsBase);\n}\n\n'
		+ 'class FsBase {\n\tpublic var children:Null<Array<Fs>> = null;\n\tpublic var folder:Bool = false;\n\n\tpublic function new() {}\n}\n\n'
		+ 'abstract Fs(FsInternal) from FsInternal {\n\tpublic var base(get, never):FsBase;\n\tpublic var children(get, never):Null<Array<Fs>>;\n'
		+ '\tpublic var folder(get, never):Bool;\n\n\tpublic static function make():Fs return Master(new FsBase());\n\n'
		+ '\tprivate inline function get_base():FsBase {\n\t\treturn switch this {\n\t\t\tcase Master(item): item;\n\t\t\tcase Slave(item): item;\n\t\t};\n\t}\n\n'
		+ '\tprivate inline function get_children():Null<Array<Fs>> return base.children;\n\n'
		+ '\tprivate inline function get_folder():Bool return base.folder;\n\n'
		+ '\tpublic static inline function count(c:Null<Array<Fs>>):Int return c == null ? 0 : c.length;\n\n'
		+ '\tpublic inline function childCount():Int return count(children);\n\n'
		+ '\tpublic inline function isFolderWithChild():Bool return folder && childCount() > 0;\n\n'
		+ '\tpublic inline function forEachChild(callback:(child:Fs)->Void):Void {\n\t\tif (!folder) return;\n'
		+ '\t\tfinal children:Null<Array<Fs>> = children;\n\t\tif (children != null) for (child in children) callback(child);\n\t}\n}\n';

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

	@:pin('control') @:killer('M-FACTS-TRUTH-REFLECTION-INLINED') @:killer('M-FACTS-SPLICED-REFLECTION-NAMED')
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

	@:pin('control') @:killer('M-ESCAPES-FACTS-DECLARED-ANY') @:killer('M-ESCAPES-FACTS-DECLARED-NONE')
	@:killer('M-ESCAPES-FACTS-DECLARED-PRODUCED')
	public function testAClassAComputedNameMakesIsOneTheProjectDeclaresUnderTheTruth(): Void {
		// a name computed at run time makes a class value of any class, unless the project declares which ones it may be
		// (`reflectiveClasses`): then of those only, matched by their qualified names
		final build: String = BUILD + '-D js_enums_as_arrays\n';
		final computed: String = 'var n:String = "lib.Plain";\n\t\tType.createInstance(Type.resolveClass(n), []);';
		assertMatch(truthLibAsk(computed, 'throw last;', null, build), r -> !r.match(Proven));
		assertMatch(truthLibAsk(computed, 'throw last;', null, build, ['lib.*']), r -> r.match(Proven));
		assertMatch(truthLibAsk(computed, 'throw last;', null, build, ['lib.*', 'Obj']), r -> !r.match(Proven));
		// a literal name still names its one class, whatever the project declares
		assertMatch(truthLibAsk('Type.resolveClass("Obj");', 'throw last;', null, build, ['lib.*']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-DECLARED-PRODUCED') @:killer('M-ESCAPES-FACTS-DECLARED-READER')
	public function testAProducerReadAsAValueMakesOnlyADeclaredClassUnderTheTruth(): Void {
		// a producer read as a value, or the class declaring one, is handed names the facts cannot read
		final build: String = BUILD + '-D js_enums_as_arrays\n';
		final value: String = 'var f:String -> Class<Dynamic> = Type.resolveClass;\n\t\tf("lib.Plain");';
		assertMatch(truthLibAsk(value, 'throw last;', null, build), r -> !r.match(Proven));
		assertMatch(truthLibAsk(value, 'throw last;', null, build, ['lib.*']), r -> r.match(Proven));
		final reader: String = 'var t:Dynamic = Type;\n\t\tt.resolveClass("lib.Plain");';
		assertMatch(truthLibAsk(reader, 'throw last;', null, build), r -> !r.match(Proven));
		assertMatch(truthLibAsk(reader, 'throw last;', null, build, ['lib.*']), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-DECLARED-SUBTYPES') @:killer('M-GLOB-QUALIFIED-SEGMENT')
	public function testADeclaredGlobMatchesTheClassItselfByItsQualifiedNameUnderTheTruth(): Void {
		// `lib.Base` declared lets no subtype of it be made by a computed name: `Holder`, which holds `o`, is matched by its
		// own name; a star stays within one segment, so `lib.deep.*` matches no `lib.deep.inner.Keeper`, and a double star does
		final build: String = BUILD + '-D js_enums_as_arrays\n';
		final computed: String = 'var n:String = "lib.Base";\n\t\tType.createInstance(Type.resolveClass(n), []);\n'
			+ '\t\tHolder.kept = o;\n\t\tlib.deep.inner.Keeper.kept = o;';
		final more: Map<String, String> = [
			'lib/Base.hx' => 'package lib;\n\nclass Base {\n\tpublic function new() {}\n}\n',
			'Holder.hx' => 'class Holder extends lib.Base {\n\tpublic static var kept:Main.Obj;\n}\n',
			'lib/deep/inner/Keeper.hx' => 'package lib.deep.inner;\n\nclass Keeper {\n\tpublic static var kept:Main.Obj;\n}\n'
		];
		assertMatch(truthLibAsk(computed, 'throw last;', more, build, ['lib.Base', 'lib.deep.*']), r -> r.match(Proven));
		assertMatch(truthLibAsk(computed, 'throw last;', more, build, ['Holder']), r -> !r.match(Proven));
		assertMatch(truthLibAsk(computed, 'throw last;', more, build, ['lib.deep.**']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SPLICE-ONLY') @:killer('M-FACTS-INLINED-EDGE')
	public function testAnInlinedGenericBodyConvertsOnlyWhatEachCallHandsItUnderTheTruth(): Void {
		// `Buf.put` converts its `T`, which may be any escaped object; spliced into `Text.fail` it converts what that call hands
		// it: a string converts nothing, an `Obj` runs its `toString`
		final buf: Map<String, String> = ['lib/Buf.hx' => SPLICED_BUF];
		final escaped: String = 'var d:Dynamic = o;';
		assertMatch(truthLibAsk(escaped, 'new Buf().put("x");', buf), r -> r.match(Proven));
		assertMatch(truthLibAsk(escaped, 'new Buf().put(new Main.Obj());', buf), r -> !r.match(Proven));
		// read as a value, its body is the closure the reading function holds, at its declared types: in the function holding
		// the splice, and in one the walk reaches after it read the spliced body
		final both: String = 'new Buf().put("y");\n\t\t\tvar f:String -> Void = new Buf().put;\n\t\t\tf("x");';
		assertMatch(truthLibAsk(escaped, both, buf), r -> !r.match(Proven));
		final later: Map<String, String> = buf.copy();
		later['Later.hx'] = 'class Later {\n\tpublic static function run():Void {\n\t\tvar f:String -> Void = new lib.Buf().put;\n'
			+ '\t\tf("x");\n\t}\n}\n';
		assertMatch(truthLibAsk(escaped, 'new Buf().put("y");\n\t\t\tLater.run();', later), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SPLICE-EXTERNAL')
	@:access(anyparse.query.MemberReach)
	public function testAnInlinedLibraryBodyReadOnDemandStaysSplicedInUnderTheTruth(): Void {
		// `lib.Buf` is library code the walk reads only once a call reaches it: the declaration it reads then is the body the
		// call spliced in, which converts the string that call hands it
		final library: Map<String, String> = plainText('new Buf().put("x");');
		library['lib/Buf.hx'] = SPLICED_BUF;
		final files: Map<String, String> = escapingObj('var d:Dynamic = o;');
		final result: ReachResult = withReach(files, null, true, false, null, library, null, true, (reach, dir) -> {
			Assert.isTrue(reach._scope.facts?.truth == true, 'the fixture did not compile');
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(files['Main.hx'] ?? '')), { owner: 'Main', name: 'items' }, Mutate);
		});
		assertMatch(result, r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-REFUSED')
	public function testTargetCodeNamingNoValueLetsNothingEscapeUnderTheTruth(): Void {
		// target code reaches only what it is handed: project code holding some leaves the escapes known
		assertMatch(truthLibAsk('js.Syntax.code("console.log(1)");', 'throw last;'), r -> r.match(Proven));
		assertMatch(truthLibAsk('js.Syntax.code("console.log({0})", 1);', 'throw last;'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-LOCALS') @:killer('M-FACTS-NATIVE-CODE')
	public function testTargetCodeHandedAValueLetsItEscapeUnderTheTruth(): Void {
		// an argument the code's placeholder takes, and a local its text names
		assertMatch(truthLibAsk('js.Syntax.code("console.log({0})", o);', 'throw last;'), r -> !r.match(Proven));
		assertMatch(truthLibAsk('var kept:Obj = o;\n\t\tjs.Syntax.code("console.log(kept)");', 'throw last;'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-THIS') @:killer('M-ESCAPES-FACTS-NATIVE-MEMBERS')
	@:killer('M-ESCAPES-FACTS-NATIVE-THIS-ALWAYS')
	public function testTargetCodeNamingThisLetsItsObjectEscapeUnderTheTruth(): Void {
		// a `Holder` holds `o`: code in its method naming `this`, or a member hxcpp reaches unqualified, hands it; code naming
		// neither does not
		function holder(code: String): Map<String, String> {
			return [
				'Holder.hx' => 'class Holder {\n\tvar held:Main.Obj;\n\n\tpublic function new(o:Main.Obj) this.held = o;\n\n'
					+ '\tpublic function show():Void js.Syntax.code("' + code + '");\n}\n'
			];
		}
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('console.log(this)')), r -> !r.match(Proven));
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('console.log(held)')), r -> !r.match(Proven));
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('console.log(1)')), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-STATICS') @:killer('M-ESCAPES-FACTS-NATIVE-OWN-STATICS')
	@:killer('M-ESCAPES-FACTS-NATIVE-STATIC-CLASS')
	public function testTargetCodeNamingAStaticLetsWhatItHoldsEscapeUnderTheTruth(): Void {
		// a static is named by its name beside its class's, or alone in its own class's code
		final store: Map<String, String> = [
			'Store.hx' => 'class Store {\n\tpublic static var kept:Main.Obj;\n\n'
				+ '\tpublic static function show():Void js.Syntax.code("console.log(kept)");\n}\n'
		];
		final quiet: Map<String, String> = ['Store.hx' => 'class Store {\n\tpublic static var kept:Main.Obj;\n}\n'];
		assertMatch(
			truthLibAsk('Store.kept = o;\n\t\tjs.Syntax.code("console.log(Store.kept)");', 'throw last;', quiet), r -> !r.match(Proven)
		);
		assertMatch(truthLibAsk('Store.kept = o;\n\t\tStore.show();', 'throw last;', store), r -> !r.match(Proven));
		// in `Main`'s code, a `kept` alone is none of `Store`'s
		assertMatch(truthLibAsk('Store.kept = o;\n\t\tjs.Syntax.code("console.log(kept)");', 'throw last;', quiet), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-CODE-META') @:killer('M-FACTS-CODE-META') @:killer('M-ESCAPES-FACTS-NATIVE-COMPUTED')
	public function testTargetCodeAMetadataPastesIsReadLikeACallsUnderTheTruth(): Void {
		// `@:functionCode` pastes its text around the method's body: naming `this` hands it, and a text no literal gives may
		// name anything
		function holder(meta: String): Map<String, String> {
			return [
				'Holder.hx' => 'class Holder {\n\tvar held:Main.Obj;\n\n\tpublic function new(o:Main.Obj) this.held = o;\n\n'
					+ '\t@:functionCode(' + meta + ')\n\tpublic function show():Void {}\n}\n'
			];
		}
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('"this"')), r -> !r.match(Proven));
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('CODE')), r -> !r.match(Proven));
		assertMatch(truthLibAsk('new Holder(o).show();', 'throw last;', holder('"1"')), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-LOCALS')
	@:access(anyparse.query.MemberReach)
	public function testLibraryTargetCodeIsReadLikeTheProjectsUnderTheTruth(): Void {
		// `keep`'s code names its parameter, which the call binds to an `Obj`: one assumption for the libraries and the project
		final library: Map<String, String> = plainText('throw last;');
		library['lib/Text.hx'] = StringTools.replace(
			library['lib/Text.hx'] ?? '', 'keep<A>(x:A):Void {}', 'keep<A>(x:A):Void js.Syntax.code("console.log(x)");'
		);
		final files: Map<String, String> = escapingObj('');
		final result: ReachResult = withReach(files, null, true, false, null, library, null, true, (reach, dir) -> {
			Assert.isTrue(reach._scope.facts?.truth == true, 'the fixture did not compile');
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(files['Main.hx'] ?? '')), { owner: 'Main', name: 'items' }, Mutate);
		});
		assertMatch(result, r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FACTS-NATIVE-REFUSED') @:killer('M-ESCAPES-TRUTH-FACTS')
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

	@:pin('control') @:killer('M-ESCAPES-FACTS-ABSTRACT-REFUSED')
	public function testACoreTypeAsAValueHoldsNothingUnderTheTruth(): Void {
		// the interpreter hands `Int` itself to `Std.isOfType`, typed `Abstract<Int>`: a core type with no implementation class
		// holds no static, so the escapes stay known
		final isInt: String = 'var n:Int = 1;\n\t\tvar isInt:Bool = Std.isOfType(n, Int);';
		assertMatch(truthLibAsk(isInt, 'throw last;', null, INTERP_BUILD), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-STRING-EXACT') @:killer('M-REACH-EXACT-SITE') @:killer('M-FACTS-VIEW-EXACT')
	@:killer('M-FACTS-VIEW-EXACT-CONVERSION') @:killer('M-FACTS-EXACT-WRITTEN')
	@:killer('M-FACTS-CALL-OPERAND-EXACT')
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

	@:pin('control') @:killer('M-TOUCH-EXPANSION-CODE') @:killer('M-FACTS-WITHIN-EXPANSION-NULL')
	public function testAMacroExpansionRunsItsTypedCodeAtItsCallUnderTheTruth(): Void {
		// every build compiled what `Mac.gen()` expanded to: its facts, at `Mac.hx`'s positions, run where the call was — in
		// `Util.f`, which the region calls, and in the region itself; so does the conversion of `Main.obj` `Mac.show()` builds
		final called: String = LOOP_HEAD
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Util.f(); /*>*/ }\n\t}\n}\n'
			+ 'class Util {\n\tpublic static function f():Void Mac.gen();\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => called, 'Mac.hx' => EXPRESSION_MACROS]), r -> r.match(Reached(_)));
		final direct: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Mac.gen(); /*>*/ }\n\t}\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => direct, 'Mac.hx' => EXPRESSION_MACROS]), r -> r.match(Reached(_)));
		final shown: String = StringTools.replace(expandedBefore(''), 'var n:Int = i;', 'Mac.show();');
		assertMatch(compiledTruthAsk(['Main.hx' => shown, 'Mac.hx' => EXPRESSION_MACROS, 'Words.hx' => WORDS]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-EXPANSION-PLACED') @:killer('M-FACTS-EXPANSION-BLIND')
	@:killer('M-GRAPH-FACTS-EXPANSION-CALL')
	public function testAMacroExpansionIsAnsweredFromItsFactsUnderTheTruth(): Void {
		// TM's `t('…')`: the expansion calls `Words.tr`, which changes nothing — and, in the twin, `Loud.tr`, which does
		final quiet: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Util.f(); /*>*/ }\n\t}\n}\n'
			+ 'class Util {\n\tpublic static function f():Void Words.say(Mac.t(\'x\'));\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => quiet, 'Mac.hx' => EXPRESSION_MACROS, 'Words.hx' => WORDS]), r -> r.match(Proven));
		// written in the region itself, beside a `Clear` whose `toString` grows `items`: the expansion converts nothing
		final region: String = StringTools.replace(expandedBefore(''), 'var n:Int = i;', 'Words.say(Mac.t(\'x\'));');
		assertMatch(compiledTruthAsk(['Main.hx' => region, 'Mac.hx' => EXPRESSION_MACROS, 'Words.hx' => WORDS]), r -> r.match(Proven));
		final loud: String = 'class Words {\n\tpublic static function tr(s:String):String {\n\t\tMain.items.push(1);\n\t\treturn s;\n\t}\n\n'
			+ '\tpublic static function say(s:String):Void {}\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => quiet, 'Mac.hx' => EXPRESSION_MACROS, 'Words.hx' => loud]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-FACTS-WITHIN-EXPANSION')
	@:killer('M-GRAPH-FACTS-EXPANSION-SITE') @:killer('M-FACTS-EXPANSION-SPLICE-SITES') @:killer('M-TOUCH-EXPANSION-RUNS')
	@:killer('M-FACTS-WALK-BLOCK-GAP')
	public function testAMacroExpansionRunsWhereItsCallIsUnderTheTruth(): Void {
		// each expansion lies before the loop, in `main`'s own code or in the code of the inlined `Shown.mask`: what it does —
		// grow `items`, call `Words.tr`, convert a `Clear` to a string — it does where its call was, which the region is not
		final loud: String = 'class Words {\n\tpublic static function tr(s:String):String {\n\t\tMain.items.push(1);\n\t\treturn s;\n\t}\n\n'
			+ '\tpublic static function say(s:String):Void {}\n}\n';
		final shown: String = 'class Shown {\n\tpublic static inline function mask():Void Words.say(Mac.t(\'Open\'));\n}\n';
		for (statement in ['Mac.gen();', 'Words.say(Mac.t(\'x\'));', 'Mac.show();', 'Shown.mask();']) {
			final files: Map<String, String> = [
				'Main.hx' => expandedBefore(statement),
				'Mac.hx' => EXPRESSION_MACROS,
				'Words.hx' => loud,
				'Shown.hx' => shown
			];
			assertMatch(compiledTruthAsk(files), r -> r.match(Proven));
		}
	}

	@:pin('control') @:killer('M-GRAPH-FACTS-VALUE-CALLED') @:killer('M-REACH-VALUE-CALLED')
	public function testACallOfAParameterRunsOnlyTheFunctionsItsInvocationsHandItUnderTheTruth(): Void {
		// `Rx.map` calls its parameter `f`, which its one invocation hands `x -> "a"`: the stored `(Rx)->String` that grows
		// `items` is never `f` — although a computed name reads a member off a value of no class, which an `Rx` never is
		final read: String = '\t\tvar o:Dynamic = {};\n\t\tvar n:String = "x";\n\t\tReflect.field(o, n);\n';
		assertMatch(compiledTruthAsk(['Main.hx' => matching(read)]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-VALUE-ARG-WRITTEN') @:killer('M-VALUE-ARG-ESCAPED') @:killer('M-VALUE-ARG-SUPERTYPES')
	@:killer('M-VALUE-ARG-COUNT') @:killer('M-VALUE-ARG-LAMBDA')
	public function testACallOfAParameterOfAMethodInvokedOtherwiseRunsWhatItsTypeAdmits(): Void {
		// the stored `(Rx)->String` may be `f` once an `Rx` leaves the type system, once `map` is read as a value, once an
		// invocation — of `map`, or of the `Base.map` it overrides — hands `f` something else, once `map` assigns `f`, takes an
		// optional argument its invocation leaves out, or is `dynamic`
		final reached: Array<String> = [
			matching('\t\tvar d:Dynamic = new Rx();\n'),
			matching('\t\tvar m:((Rx)->String)->String = new Rx().map;\n'),
			matching('\t\tnew Rx().map(keep);\n'),
			matching(
				'\t\tvar b:Base = new Rx();\n\t\tb.map(keep);\n', null,
				'class Base {\n\tpublic function new() {}\n\n\tpublic function map(f:(Rx)->String):String return "";\n}\n',
				'override public function map(f:(Rx)->String):String return f(this);'
			),
			matching(
				'', null, null, 'public function map(f:(Rx)->String):String {\n\t\tif (f == null) f = Main.keep;\n\t\treturn f(this);\n\t}'
			),
			matching('', null, null, 'public function map(f:(Rx)->String, ?n:Int):String return f(this);'),
			matching('', null, null, 'public dynamic function map(f:(Rx)->String):String return f(this);')
		];
		for (main in reached) assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-VALUE-STORED') @:killer('M-GRAPH-FACTS-VALUE-STORED') @:killer('M-VALUE-CTOR-ARITY')
	@:killer('M-VALUE-STORED-COMPUTED') @:killer('M-VALUE-ESCAPED-ONLY') @:killer('M-VALUE-CTOR-REFLECTIVE-CLASS')
	public function testACallOfADynamicMethodRunsOnlyTheValuesStoredIntoItUnderTheTruth(): Void {
		// `Pool.release` calls its `dynamic` `clean`, which only `Pool`'s constructor stores into, from its parameter: every
		// construction hands it nothing, a function expression, or one of an arity no `(Int)->Void` has (`make`'s), so
		// `Main.grow`, a function read as a value, never runs there — the facts say so only under the truth
		final quiet: Array<String> = [
			poolFixture('', ''),
			poolFixture('null, x -> {}', ''),
			poolFixture('() -> {\n\t\t\titems.push(1);\n\t\t\treturn 1;\n\t\t}', '')
		];
		for (main in quiet) assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> r.match(Proven));
		// `Hook.run` holds the function expressions stored into it, by its type or, once a `Hook` left the type system, by its
		// name — and a name computed at run time names a method only of a class the project declares
		final dynamicStore: String = '\t\tvar d:Dynamic = h;\n\t\td.run = x -> {};\n';
		assertMatch(compiledTruthAsk(['Main.hx' => hookFixture('')]), r -> r.match(Proven));
		assertMatch(compiledTruthAsk(['Main.hx' => hookFixture(dynamicStore)]), r -> r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => hookFixture(COMPUTED_STORE)], null, ['Main']), r -> r.match(Proven));
		// a reflective construction hands `clean` what its argument array holds there
		final reflective: Array<String> = [
			settlessPool('\t\tType.createInstance(Pool, [null, x -> {}]);\n'),
			// out of an array no literal spells, only a function value that escaped: `() -> {}` did, `grow` did not
			settlessPool('\t\tvar a:Array<Dynamic> = [null, () -> {}];\n\t\tType.createInstance(Pool, a);\n')
		];
		for (main in reflective) assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> r.match(Proven));
		// one of another class hands `Pool`'s constructor nothing, whatever its array holds
		final other: String = poolFixture('', '\t\tType.createInstance(Other, [null, keep]);\n')
			+ 'class Other {\n\tpublic function new(a:Dynamic, b:Dynamic) {}\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => other]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => poolFixture('null, x -> {}', '')]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-VALUE-STORED-UNTYPED') @:killer('M-VALUE-STORED-NATIVE') @:killer('M-VALUE-CTOR-REFLECTIVE')
	@:killer('M-VALUE-ESCAPED-SENTINEL') @:killer('M-VALUE-STORED-WRITES') @:killer('M-VALUE-STORED-OWN') @:killer('M-VALUE-CTOR-SUBTYPES')
	@:killer('M-VALUE-CTOR-ARGUMENT') @:killer('M-VALUE-CTOR-SKIPPED') @:killer('M-VALUE-CTOR-REFLECTIVE-ARGS')
	public function testACallOfADynamicMethodRunsAnyValueWhenAStoreIsNotKnown(): Void {
		// `grow` may be `clean` once it is stored into it directly, through a `Dynamic`, by reflection — by a literal name or a
		// computed one —, by a construction, reflective or through a subclass's `super`, or by `set` spliced in at a call that
		// inlines it, or once a construction leaving `make` out hands `clean` a function that grows `items`
		final sub: String = 'class Sub extends Pool {\n\tpublic function new() super(null, Main.keep);\n}\n';
		final reached: Array<String> = [
			poolFixture('', '\t\tp.clean = keep;\n'),
			poolFixture('', '\t\tvar d:Dynamic = p;\n\t\td.clean = keep;\n'),
			poolFixture('', '\t\tReflect.setField(p, "clean", keep);\n'),
			poolFixture('', '\t\tvar n:String = "clean";\n\t\tReflect.setField(p, n, keep);\n'),
			poolFixture('null, grow', ''),
			poolFixture('x -> {\n\t\t\titems.push(x);\n\t\t}', ''),
			settlessPool('\t\tType.createInstance(Pool, [null, keep]);\n'),
			poolFixture('', '\t\tnew Sub();\n') + sub,
			poolFixture('', '\t\tinline p.set(keep);\n')
		];
		for (main in reached) assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> !r.match(Proven));
		// a `Hook` that left the type system may have its field written by its name: off a `Dynamic`, by target code naming
		// it, or by a name computed at run time, which no declaration bounds here
		final escaped: Array<String> = [
			hookFixture('\t\tvar d:Dynamic = h;\n\t\td.run = keep;\n'),
			hookFixture('\t\tvar d:Dynamic = h;\n\t\tjs.Syntax.code("{0}.run = {1}", d, keep);\n')
		];
		for (main in escaped) assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> !r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => hookFixture(COMPUTED_STORE)]), r -> !r.match(Proven));
		// a reflective construction handing `clean` an array no literal spells
		final handed: String = settlessPool('\t\tvar a:Array<Dynamic> = [null, keep];\n\t\tType.createInstance(Pool, a);\n');
		assertMatch(compiledTruthAsk(['Main.hx' => handed]), r -> !r.match(Proven));
		// a store only another build compiles is one of the builds' stores
		final other: String = poolFixture('', '\t\t#if other\n\t\tp.clean = keep;\n\t\t#end\n');
		assertMatch(ask(['Main.hx' => other], [[], ['other']], true, null, false, null, null, null, true), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-VALUE-CTOR-ROUTE')
	public function testACallOfAConstructorParameterRunsWhatItsConstructionsHandIt(): Void {
		// `Runner`'s constructor calls its parameter `f`, which the region's construction hands `keep`, holding `grow`: a
		// constructor is invoked by a `new`, which no call fact records — and once the one construction hands it a function
		// expression that grows nothing, nothing else is `f`
		final main: String = LOOP_HEAD + '\tpublic static var keep:Null<(Int)->Void> = null;\n\n'
			+ '\tstatic function grow(x:Int):Void items.push(x);\n\n\tstatic function main() {\n\t\tkeep = grow;\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ new Runner(keep); /*>*/ }\n\t}\n}\n'
			+ 'class Runner {\n\tpublic function new(f:Null<(Int)->Void>) f(1);\n}\n';
		assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
		final quiet: String = StringTools.replace(main, 'new Runner(keep)', 'new Runner(x -> {})');
		assertMatch(compiledTruthAsk(['Main.hx' => quiet]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPES-FUNCTION-FLOW-TYPED')
	public function testACallOfAFunctionValueRunsOnlyTheFunctionsItsTypeAdmitsUnderTheTruth(): Void {
		// `h`, a local `(Rx)->String`, holds what `map` is handed: the stored callback that grows `items` cannot be it — it
		// returns nothing, takes a `String`, which an `Rx` is not, takes two arguments, or is a `(Base)->Void` stored where a
		// `(Rx)->Void` is wanted
		final proven: Array<String> = [
			valueCallFixture('(Rx)->Void', '(x:Rx) -> { items.push(1); }', '', null, null, BY_TYPE),
			valueCallFixture('(String)->String', '(s:String) -> { items.push(1); return s; }', '', null, null, BY_TYPE),
			valueCallFixture('(Rx, Int)->String', '(x:Rx, n:Int) -> { items.push(1); return "k"; }', '', null, null, BY_TYPE),
			valueCallFixture('(Rx)->Void', '(x:Base) -> { items.push(1); }', '', null, null, BY_TYPE)
		];
		for (main in proven) assertMatch(interpAsk(['Main.hx' => main]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-VALUE-TYPE-FLOWS')
	public function testACallOfAFunctionValueRunsAFunctionOfAMatchingType(): Void {
		// the stored callback is a `(Rx)->String` itself, which any place of that type may hold — `h` among them — or one taking
		// what an `Rx` is, which the region hands `map`
		assertMatch(interpAsk(['Main.hx' => matching('', null, null, BY_TYPE)]), r -> r.match(Reached(_)));
		final wider: String = valueCallFixture(
			'(Base)->String', '(x:Base) -> { items.push(1); return "k"; }', '', 'r.map(keep);', null, BY_TYPE
		);
		assertMatch(interpAsk(['Main.hx' => wider]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-VALUE-TYPE-GENERIC') @:killer('M-VALUE-TYPE-BIND')
	public function testACallOfAFunctionValueRunsWhatAnInitializerABindOrAGenericBodyHandsIt(): Void {
		// a field's initializer stores `Grower.put`, a `(Grower)->Void`, in a `Dynamic`; `Grower.grow.bind(1)` is a `(Rx)->String` that runs
		// `grow`; `apply`'s `f` is a `(A)->String`, which an `(Rx)->String` is once `A` is bound
		final initialized: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n'
			+ '\tstatic var d:Dynamic = Grower.put;\n\n\tstatic function main() {\n\t\tfinal r:Rx = new Rx();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ r.map(x -> "a"); /*>*/ }\n\t}\n}\n' + 'class Rx {\n\tpublic function new() {}\n\n\t'
			+ BY_TYPE + '\n}\n';
		final grower: String = 'class Grower {\n\tpublic function new() {}\n\n'
			+ '\tpublic static function put(g:Grower):Void Main.items.push(1);\n\n'
			+ '\tpublic function grow(n:Int, x:Rx):String {\n\t\tMain.items.push(n);\n\t\treturn "";\n\t}\n}\n';
		assertMatch(interpAsk(['Main.hx' => initialized + grower]), r -> !r.match(Proven));
		final bound: String = valueCallFixture('(Rx)->String', 'new Grower().grow.bind(1)', '', 'r.map(keep);', null, BY_TYPE) + grower;
		assertMatch(interpAsk(['Main.hx' => bound]), r -> !r.match(Proven));
		final generic: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n\n'
			+ '\tstatic function apply<A>(f:(A)->String, a:A):String return f(a);\n\n\tstatic function main() {\n'
			+ '\t\tfinal r:Rx = new Rx();\n\t\tapply((x:Rx) -> { items.push(1); return "k"; }, r);\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ apply((x:Rx) -> "a", r); /*>*/ }\n\t}\n}\n'
			+ 'class Rx {\n\tpublic function new() {}\n}\n';
		assertMatch(interpAsk(['Main.hx' => generic]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-VALUE-TYPE-ESCAPED') @:killer('M-ESCAPES-FUNCTION-RECORDED')
	public function testACallOfAFunctionValueRunsAFunctionValueThatEscaped(): Void {
		// the `(String)->Void` callback is put in a `Dynamic`, or held by a `Holder` that is: from there it may be handed
		// anywhere, `h` included
		final escaped: String = valueCallFixture(
			'(String)->Void', '(s:String) -> { items.push(1); }', '\t\tvar d:Dynamic = keep;\n', null, null, BY_TYPE
		);
		assertMatch(interpAsk(['Main.hx' => escaped]), r -> !r.match(Proven));
		final holder: String = 'class Holder {\n\tpublic var cb:Null<(String)->Void> = null;\n\n\tpublic function new() {}\n}\n';
		final held: String = valueCallFixture(
				'(String)->Void', '(s:String) -> { items.push(1); }',
				'\t\tfinal o:Holder = new Holder();\n\t\to.cb = keep;\n\t\tvar d:Dynamic = o;\n', null, null, BY_TYPE
			) + holder;
		assertMatch(interpAsk(['Main.hx' => held]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-HOLD-CLASSLESS')
	public function testAMethodOfAnObjectThatNeverEscapedIsNoValueAComputedNameReads(): Void {
		// a name computed at run time reads a member off a value of no class: `Quiet.grow` is none of its, a `Quiet` never
		// leaving the type system — and once one does, it may be, and `h` may run it
		final quiet: String = 'class Quiet {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n';
		final read: String = '\t\tvar q:Quiet = new Quiet();\n\t\tvar o:Dynamic = {};\n\t\tvar n:String = "x";\n\t\tReflect.field(o, n);\n';
		final kept: String = valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + quiet;
		assertMatch(interpAsk(['Main.hx' => kept]), r -> r.match(Proven));
		final left: String = valueCallFixture('(Rx)->String', 'null', read + '\t\to = q;\n', 'r.map(keep);', null, BY_TYPE) + quiet;
		assertMatch(interpAsk(['Main.hx' => left]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-VALUE-TYPE-UNTYPED') @:killer('M-ADMIT-OBTAINED') @:killer('M-REACH-READ-BY-NAME')
	public function testACallOfAFunctionValueRunsAMethodReadByAName(): Void {
		// `Grower.grow`, a `(String)->Void`, is read by its name off a value of no type and stored as the `(Rx)->String` the
		// region hands `Rx.map`: `h` is that method
		final read: String = '\t\tvar o:Dynamic = new Grower();\n\t\tkeep = Reflect.field(o, "grow");\n';
		final grower: String =
			'class Grower {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n';
		final main: String = valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + grower;
		assertMatch(interpAsk(['Main.hx' => main]), r -> !r.match(Proven));
		// without the whole list of builds, the syntax says the same: `Reflect.field` names `grow`
		assertMatch(ask(['Main.hx' => main], null, false), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-HOLDERS-DECLARED') @:killer('M-METHODS-HOLDERS-OBTAINED')
	@:killer('M-HOLDERS-GRAPH')
	public function testAMethodAComputedNameReadsIsOneOfAClassTheProjectDeclaresUnderTheTruth(): Void {
		// `Grower.grow` read off a value of no type by a name computed at run time may be any method of any escaped object,
		// unless the project declares whose methods such a name may obtain (`reflectiveMethodHolders`): then of those only
		final read: String = '\t\tvar o:Dynamic = new Grower();\n\t\tvar n:String = "grow";\n\t\tkeep = Reflect.field(o, n);\n';
		final grower: String =
			'class Grower {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n';
		final main: String = valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + grower;
		assertMatch(interpAsk(['Main.hx' => main]), r -> !r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => main], null, ['Rx']), r -> r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => main], null, ['Rx', 'Grower']), r -> !r.match(Proven));
		// a literal still names its one member, whatever the project declares
		final named: String = valueCallFixture(
				'(Rx)->String', 'null', '\t\tvar o:Dynamic = new Grower();\n\t\tkeep = Reflect.field(o, "grow");\n', 'r.map(keep);', null,
				BY_TYPE
			) + grower;
		assertMatch(interpAsk(['Main.hx' => named], null, ['Rx']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-HOLDERS-OWN-NAME')
	public function testADeclaredMethodHolderIsMatchedByTheClassOfTheObjectItselfUnderTheTruth(): Void {
		// the object read is exactly a `Grower`: declaring its subclass `Sub`, which inherits `grow`, declares no `Grower` —
		// each class is declared by its own name
		final read: String = '\t\tvar n:String = "grow";\n\t\tkeep = Reflect.field(new Grower(), n);\n';
		final grower: String = 'class Grower {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n'
			+ 'class Sub extends Grower {}\n';
		final main: String = valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + grower;
		assertMatch(interpAsk(['Main.hx' => main], null, ['Sub']), r -> r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => main], null, ['Grower']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-HOLDERS-VALUE')
	public function testAReflectiveMemberReadAsAValueObtainsOnlyADeclaredClassesMethodsUnderTheTruth(): Void {
		// `f` is `Reflect.field`: whatever calls it hands it a name computed there, so it may obtain any method — or one of a
		// class the project declares
		final read: String = '\t\tvar o:Dynamic = new Grower();\n\t\tvar f:Dynamic = Reflect.field;\n\t\tkeep = f(o, "grow");\n';
		final grower: String =
			'class Grower {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n';
		final main: String = valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + grower;
		assertMatch(interpAsk(['Main.hx' => main]), r -> !r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => main], null, ['Rx']), r -> r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => main], null, ['Grower']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-HOLDERS-SELF') @:killer('M-METHODS-HOLDERS-REBIND')
	public function testAThisNoDeclaredClassLetsAComputedNameObtainIsBoundByItsDispatchUnderTheTruth(): Void {
		// on js `Type.createEnum` rebinds a function's `this`, and `dump` reads its own object by the name it is handed: that
		// may obtain `dump` itself, so `this` may be any object — unless `Other` is no class the project declares; on the
		// interpreter a `Reflect` read as a value may rebind
		final main: String = 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tstatic function sink(x:Dynamic):Void {}\n\tstatic function main() { sink(new Main()); }\n'
			+ '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n'
			+ '\t}\n}\n' + reflectingOther('Reflect.getProperty(this, n)');
		assertMatch(reflectAsk(['Main.hx' => main]), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(['Main.hx' => main], false, ['Main']), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => main], false, ['Other']), r -> r.match(Unknown(DynamicName(_, _))));
		final rebinding: String = StringTools.replace(main, 'sink(new Main()); }', 'sink(new Main()); var t:Dynamic = Reflect; }');
		assertMatch(reflectAsk(['Main.hx' => main], true, ['Other']), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => rebinding], true, ['Other']), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-METHODS-MEMBERLESS-RESULT')
	public function testAReflectiveMemberWhoseResultHoldsNoMemberValueObtainsNoMethodUnderTheTruth(): Void {
		// hxcpp's `Type.enumEq` and `Type.enumIndex` call `nativeEnumEq` and `getEnumValueIndex`, private externs of `Type` the
		// portable API does not declare, in every build's std: each returns a `Bool` or an `Int`, so handing one an escaped
		// `Grower` obtains no `grow` for the value `keep` reads off an object by name to be
		final grower: String =
			'class Grower {\n\tpublic function new() {}\n\n\tpublic function grow(s:String):Void Main.items.push(1);\n}\n';
		final read: String = '\t\tvar o:Dynamic = new Grower();\n\t\tkeep = Reflect.field(o, "look");\n\t\tCmp.same(o);\n'
			+ '\t\tnew Grower().grow("x");\n';
		function compared(body: String): String {
			return valueCallFixture('(Rx)->String', 'null', read, 'r.map(keep);', null, BY_TYPE) + grower
				+ 'class Cmp {\n\tpublic static function same(a:Dynamic):Bool return $body;\n}\n';
		}
		assertMatch(builtAsk(CPP_BUILD, ['Main.hx' => compared('Type.enumEq(a, a)')]), r -> r.match(Proven));
		// a read whose result may be a member's value still obtains one
		assertMatch(builtAsk(CPP_BUILD, ['Main.hx' => compared('Reflect.field(a, Std.string(a)) != null')]), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-SPLICED-REFLECTION-READ') @:killer('M-FACTS-SPLICED-REFLECTION-FROM')
	@:killer('M-FACTS-SPLICED-REFLECTION-MEMBERLESS')
	public function testUnderTheTruthASplicedReflectiveBodyThatReachesNoMemberLeavesItsFunctionReadable(): Void {
		// hxcpp splices `Type.enumIndex` into `main`: the facts name the member, which names none and reads no member's value,
		// so the loop beside it is read through the facts (an index of a constant the compiler folds, so `mk` hands one).
		// `Reflect.copy`, spliced by its call site, returns the object it copied, a value that may hold a member's: no
		// declaration clears it
		function fixture(spliced: String): String {
			return LOOP_HEAD + '\tstatic function mk():E return E.A;\n\tstatic function main() {\n\t\tvar k:Dynamic = $spliced;\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ k = i; /*>*/ }\n\t}\n}\nenum E {\n\tA;\n}\n';
		}
		assertMatch(builtAsk(CPP_BUILD, ['Main.hx' => fixture('Type.enumIndex(mk())')]), r -> r.match(Proven));
		assertMatch(builtAsk(CPP_BUILD, ['Main.hx' => fixture('inline Reflect.copy({ a: 1 })')]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-HOLDERS-FIELDS-UNBOUNDED') @:killer('M-GRAPH-REFLECT-SUPERTYPES')
	public function testAComputedNameStillReadsAVariableOfAnyClassWhateverTheProjectDeclaresUnderTheTruth(): Void {
		// the declaration bounds the methods such a name obtains, not the variables it reads: an `Other` extending `Main`
		// carries `items`, which `dump` may read
		final sub: String = MEMBER_HEAD + '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n'
			+ 'class Other extends Main {\n\tpublic function new() super();\n\n'
			+ '\tpublic function dump(n:String):Dynamic return Reflect.getProperty(this, n);\n}\n';
		assertMatch(reflectAsk(['Main.hx' => sub], false, ['Main']), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(['Main.hx' => sub], false, ['nothing.*']), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-REFLECTED-HOLDERS-METHODS') @:killer('M-REFLECTED-HOLDERS-ACCESSORS')
	@:killer('M-REFLECTED-HOLDERS-INHERITED')
	public function testAComputedNameRunsOnlyAMethodOfAClassTheProjectDeclaresUnderTheTruth(): Void {
		// `dump` reads its own `Other` by the name it is handed: that may run any method of `Other`, `grow` among them — unless
		// the project declares whose methods such a name obtains (`reflectiveMethodHolders`) and `Other` is none of them
		final head: String = 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tstatic function sink(x:Dynamic):Void {}\n\tstatic function main() { sink(new Main()); }\n'
			+ '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n'
			+ '\t}\n}\n';
		final dump: String = '\tpublic function dump(n:String):Dynamic return Reflect.getProperty(this, n);\n';
		final growing: String = head + 'class Other {\n\tpublic function new() {}\n\n' + dump
			+ '\n\tpublic function grow(m:Main):Void m.items.push(1);\n}\n';
		assertMatch(reflectAsk(['Main.hx' => growing]), r -> !r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => growing], false, ['Main']), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => growing], false, ['Other']), r -> !r.match(Proven));
		// a property access by that name runs the accessor of any class, declared or not
		final getting: String = head + 'class Other {\n\tpublic static var shared:Main = null;\n\n\tpublic var size(get, never):Int;\n\n'
			+ '\tpublic function new() {}\n\n\tfunction get_size():Int {\n\t\tshared.items.push(1);\n\t\treturn 0;\n\t}\n\n' + dump + '}\n';
		assertMatch(reflectAsk(['Main.hx' => getting], false, ['Main']), r -> !r.match(Proven));
		// an object of exactly a declared class runs the methods it inherits too
		final inherited: String = StringTools.replace(head, 'o.dump(n);', 'Reflect.getProperty(o, n);')
			+ 'class Base {\n\tpublic function new() {}\n\n\tpublic function grow(m:Main):Void m.items.push(1);\n}\n'
			+ 'class Other extends Base {\n\tpublic function new() super();\n}\n';
		assertMatch(reflectAsk(['Main.hx' => inherited], true, ['Main']), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => inherited], true, ['Other']), r -> !r.match(Proven));
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
	@:access(anyparse.query.MemberReach)
	public function testAMemberAnotherTypeOfItsNameMayDeclareKeepsTheNameShared(): Void {
		// a declaration of `splice` no build typed may still run under another name (`@:genericBuild`): it leaves `Vec.splice`
		// a name two types share. The call of it in `Box.put` is still `lib.Vec`'s, its fact says: the walk reads that one
		final dead: Map<String, String> = sharedNameLibrary();
		dead['dead/Vec.hx'] = 'package dead;\n\nclass Vec {\n\tpublic static function splice(i:Int):Int return i;\n}\n';
		function sole(library: Map<String, String>): Null<String> {
			return withReach(
				['Main.hx' => SHARED_NAME_MAIN],
				null, true, false, null, library, null, true, (reach, dir) -> reach._scope.facts?.soleMember('Vec', 'splice')
			);
		}
		Assert.isNull(sole(dead));
		Assert.equals('lib.Vec', sole(sharedNameLibrary()));
		assertMatch(ask(['Main.hx' => SHARED_NAME_MAIN], null, true, null, false, null, dead, null, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-SOLE-MEMBER-NONE') @:killer('M-REACH-ITERABLE-RETURNS')
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
						values: [],
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

	public function testABodyTheFactsDoNotDescribeWholeKeepsItsSyntacticHazards(): Void {
		// `g` expands a macro that places the code it builds in a file no build read: a fact of `g` has no place
		// (`stale-foreign`), so `g` is read by its syntax, and its untyped expression stays a blind spot however whole the list
		// of builds
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '\tfunction g():Void {\n\t\tvar z = untyped this.zz;\n\t\tMac.nop();\n\t}\n}\n';
		final mac: String = 'class Mac {\n\tpublic static macro function nop()\n'
			+ '\t\treturn macro @:pos(haxe.macro.Context.makePosition({ file: "Gone.hx", min: 0, max: 1 })) Math.abs(1);\n}\n';
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
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("items");')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('Syntax.code("items");')]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => region('Syntax.code("0");')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('@:functionCode("0") g();')]), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-NATIVE-SITE-BLIND') @:killer('M-NATIVE-SITE-NAMES') @:killer('M-NATIVE-SITE-ESCAPED')
	@:killer('M-NATIVE-SITE-COMPUTED') @:killer('M-NATIVE-SITE-VALUES') @:killer('M-FACTS-NATIVE-HANDED')
	@:killer('M-FACTS-NATIVE-CHAIN') @:killer('M-ESCAPES-FACTS-NATIVE-HANDED')
	public function testTargetCodeReachesTheMemberOnlyThroughWhatItIsHandedUnderTheTruth(): Void {
		// target code reaches only what it is handed and what its text names: naming nothing, it reaches no `Main`; naming
		// `items` — even in `peek`, which runs on no object — reaching a `Main` — the static `last`, by its name in a string or
		// in a chain of names untyped code leaves to the target, or `this`, handed to a call through such a chain — or of a
		// text computed at run time, it may; handed what `cb` holds, `g`, which nothing the walk enters reads, it may call it,
		// and `g` changes `items`. Without the truth every native site is a blind spot
		function region(code: String, held: String = 'null'): String {
			return MEMBER_HEAD + '\tstatic var last:Main;\n\n\tstatic var cb:Void->Void = ' + held + ';\n\n'
				+ '\tstatic function g():Void\n\t\tlast.items.push(1);\n\n\tstatic function peek():Void\n\t\tjs.Syntax.code("items");\n\n'
				+ '\tfunction f():Void {\n\t\tvar c:String = "0";\n\t\tfor (i in 0...items.length) { /*<*/ ' + code + ' /*>*/ }\n\t}\n}\n';
		}
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("0");')]), r -> r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('untyped console.log(1);')]), r -> r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("items");')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('peek();')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('untyped document.last;')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("last");')]), r -> r.match(Unknown(NativeCode(_, _))));
		// handed `this`, target code may reach `g`, which a computed name off an escaped `Main`'s class reads as a value
		assertMatch(truthAsk(['Main.hx' => region('untyped console.log(this);')]), r -> !r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code(c);')]), r -> r.match(Unknown(NativeCode(_, _))));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("{0}()", cb);', 'g')]), r -> r.match(Reached(_)));
		assertMatch(ask(['Main.hx' => region('js.Syntax.code("0");')]), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-NATIVE-SITE-INERT') @:killer('M-NATIVE-SITE-CORE-TYPE') @:killer('M-NATIVE-SITE-ALIAS')
	public function testTargetCodeHandedOnlyValuesReachesNoObjectUnderTheTruth(): Void {
		// a `Main` left the type system through `leak`, so a value of any type handed to target code may be one — but an `Int`,
		// a `Tiny` (a type the compiler represents itself and no value of which is null, as `Int` is) and a `Small`, a nullable
		// `Tiny` behind an alias, are no object at all
		function region(code: String): String {
			return MEMBER_HEAD + '\tstatic function leak(m:Main):Dynamic\n\t\treturn m;\n\n'
				+ '\tfunction f(t:Small, o:Other):Void {\n\t\tfor (i in 0...items.length) { /*<*/ ' + code + ' /*>*/ }\n\t}\n}\n'
				+ '@:coreType @:notNull abstract Tiny from Int to Int {}\ntypedef Small = Null<Tiny>;\n'
				+ 'class Other {\n\tpublic function new() {}\n}\n';
		}
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("{0}", 1);')]), r -> r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("{0}", t);')]), r -> r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('js.Syntax.code("{0}", o);')]), r -> r.match(Unknown(NativeCode(_, _))));
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

	@:pin('control') @:killer('M-REACH-REFLECT-BOUND-NONE') @:killer('M-HAZARDS-REFLECT-RECEIVERS')
	@:killer('M-HAZARDS-REFLECT-RECEIVERS-ADDED') @:killer('M-FACTS-REFL-RECEIVER') @:killer('M-REACH-REFLECT-BODY')
	public function testAReflectiveAccessOnAnObjectOfAnUnrelatedClassReachesNoneOfTheMemberUnderTheTruth(): Void {
		// `Other.dump` reads a property of its own object by a name it is handed: under the truth that object is an `Other`,
		// which carries no `items`; without it the name may be any member's
		final main: String = MEMBER_HEAD + '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n';
		final spelled: String = main + reflectingOther('Reflect.getProperty(this, n)');
		assertMatch(reflectAsk(['Main.hx' => spelled]), r -> r.match(Proven));
		assertMatch(ask(['Main.hx' => spelled]), r -> r.match(Unknown(DynamicName(_, _))));
		// `using Reflect` (TM's `drill.Node`): only the facts see the call
		assertMatch(reflectAsk(['Main.hx' => 'using Reflect;\n' + main + reflectingOther('this.getProperty(n)')]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-REFLECT-RELATED') @:killer('M-GRAPH-REFLECT-SUBTYPES')
	public function testAReflectiveAccessOnAnObjectThatMayCarryTheMemberIsADynamicNameUnderTheTruth(): Void {
		// an `Other` extending `Main` carries `items` itself; `this` of `Base` may be a `Main`, which extends it
		final sub: String = MEMBER_HEAD + '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n'
			+ 'class Other extends Main {\n\tpublic function new() super();\n\n'
			+ '\tpublic function dump(n:String):Dynamic return Reflect.getProperty(this, n);\n}\n';
		assertMatch(reflectAsk(['Main.hx' => sub]), r -> r.match(Unknown(DynamicName(_, _))));
		final base: String = 'class Main extends Base {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() super();\n'
			+ '\tstatic function main() {}\n\tfunction f(n:String):Void {\n\t\tfor (i in 0...items.length) { /*<*/ dump(n); /*>*/ }\n\t}\n}\n'
			+ 'class Base {\n\tpublic function new() {}\n\n\tpublic function dump(n:String):Dynamic return Reflect.getProperty(this, n);\n}\n';
		assertMatch(reflectAsk(['Main.hx' => base]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-GRAPH-REFLECT-UNTYPED')
	public function testAReflectiveAccessOnAValueOfNoClassIsADynamicNameUnderTheTruth(): Void {
		// a `Dynamic` value may be any object, a structure's has no class to read its members
		// off (`setProperty`: js inlines `setField`, whose splice is blind of its own)
		function region(code: String): String {
			return MEMBER_HEAD + '\tfunction f(n:String, d:Dynamic, s:{ x:Int }):Void {\n' + '\t\tfor (i in 0...items.length) { /*<*/ '
				+ code + ' /*>*/ }\n\t}\n}\n';
		}
		assertMatch(reflectAsk(['Main.hx' => region('Reflect.getProperty(d, n);')]), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(['Main.hx' => region('Reflect.setProperty(s, n, 1);')]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-GRAPH-REFLECT-ESCAPES') @:killer('M-GRAPH-REFLECT-SELF-ESCAPES') @:killer('M-FACTS-REFL-SELF')
	public function testAReflectedObjectOtherThanThisMayBeAnyEscapedInstanceUnderTheTruth(): Void {
		// a `Main` handed to `Dynamic` may come back typed as anything, an `Other` included; `this` of `Other` is an `Other` where
		// no call rebinds a method (`INTERP_BUILD`) — on js `Type.createEnum` does, and `dump` reads itself by the name it is handed
		function fixture(escape: String, region: String): String {
			return
				'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n\tstatic function sink(x:Dynamic):Void {}\n'
					+ '\tstatic function main() {' + escape + '}\n\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
					+ '\t\tfor (i in 0...items.length) { /*<*/ ' + region + ' /*>*/ }\n\t}\n}\n'
					+ reflectingOther('Reflect.getProperty(this, n)')
					+ 'class Peek {\n\tpublic static function at(o:Other, n:String):Dynamic return Reflect.getProperty(o, n);\n}\n';
		}
		assertMatch(reflectAsk(['Main.hx' => fixture('', 'Peek.at(o, n);')]), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => fixture(' sink(new Main()); ', 'Peek.at(o, n);')]), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(['Main.hx' => fixture(' sink(new Main()); ', 'o.dump(n);')], true), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => fixture(' sink(new Main()); ', 'o.dump(n);')]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-GRAPH-REFLECT-EXACT') @:killer('M-FACTS-REFL-EXACT')
	public function testAReflectedObjectOfExactlyItsClassIsNoSubclassUnderTheTruth(): Void {
		// `Main` extends `Other`: an `Other` handed in may be a `Main`, one built here is an `Other`
		function fixture(code: String): String {
			return 'class Main extends Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() super();\n'
				+ '\tstatic function main() {}\n\tfunction f(n:String, o:Other):Void {\n' + '\t\tfor (i in 0...items.length) { /*<*/ '
				+ code + ' /*>*/ }\n\t}\n}\n' + 'class Other {\n\tpublic function new() {}\n}\n';
		}
		assertMatch(reflectAsk(['Main.hx' => fixture('Reflect.getProperty(new Other(), n);')]), r -> r.match(Proven));
		assertMatch(reflectAsk(['Main.hx' => fixture('Reflect.getProperty(o, n);')]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-REACH-REFLECT-ADMIT')
	public function testAReflectiveAccessRunsTheAccessorsOfTheTypeItReachesUnderTheTruth(): Void {
		// a property read by a name it computes may run `Other.get_v`, which changes `items` of a `Main` it holds; `this` is an
		// `Other` where no call rebinds a method (`INTERP_BUILD`)
		final main: String = MEMBER_HEAD + '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n'
			+ 'class Other {\n\tpublic static var held:Main = new Main();\n\tpublic var v(get, never):Int;\n\n\tpublic function new() {}\n\n'
			+ '\tfunction get_v():Int {\n\t\theld.items.push(1);\n\t\treturn 0;\n\t}\n\n'
			+ '\tpublic function dump(n:String):Dynamic return Reflect.getProperty(this, n);\n}\n';
		assertMatch(reflectAsk(['Main.hx' => main], true), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-METHODS-SELF-BOUND') @:killer('M-METHODS-CLOSURE-READ') @:killer('M-FACTS-REFL-HOLDER') @:killer('M-METHODS-RECEIVER-BOUND')
	public function testThisOfAMethodACallMayRebindIsAnyEscapedInstanceUnderTheTruth(): Void {
		// `Reflect.callMethod` runs the function it is handed with the `Main` it is handed as `this`: once `Other.dump` is read
		// as a value, its `this` may be the escaped `Main`, whose `items` the property write by name replaces. A method no code
		// reads as a value keeps `this` an `Other` — not on js, whose std rebinds in `Type.createEnum` and reads members by a
		// computed name off any object (`haxe.DynamicAccess`). A member read by a computed name off a `Third` just built reads
		// no `Other` method; one off an `Other` may read `dump`
		function fixture(taken: String, read: String = ''): Map<String, String> {
			return [
				'Main.hx' => 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
					+ '\tstatic function sink(x:Dynamic):Void {}\n\tstatic function main() { sink(new Main()); }\n'
					+ '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
					+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n'
					+ 'class Other {\n\tpublic function new() {}\n\n\tpublic function dump(n:String):Void Reflect.setProperty(this, n, null);\n}\n'
					+ 'class Third {\n\tpublic function new() {}\n\n\tpublic function calm():Void {}\n}\n'
					+ 'class Rebind {\n\tpublic static function run(o:Other, n:String):Void {\n\t\t' + read
					+ '\n\t\tReflect.callMethod(new Main(), ' + taken + ', ["items"]);\n\t}\n}\n'
			];
		}
		assertMatch(reflectAsk(fixture('o.dump')), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(fixture('o.dump'), true), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(reflectAsk(fixture('new Third().calm'), true), r -> r.match(Proven));
		final read: String = 'Reflect.field(new Third(), n);';
		assertMatch(reflectAsk(fixture('new Third().calm', read), true), r -> r.match(Proven));
		assertMatch(
			reflectAsk(fixture('new Third().calm', read + '\n\t\tReflect.field(o, n);'), true), r -> r.match(Unknown(DynamicName(_, _)))
		);
		assertMatch(reflectAsk(fixture('new Third().calm')), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-METHODS-NATIVE-REFUSED')
	public function testProjectTargetCodeKeepsThisBoundUnderTheTruth(): Void {
		// target code obtains a method's value only through the reflection the facts record: project code holding some still
		// answers that `Other.dump`, which no code reads as a value, runs on an `Other`
		final main: String = 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
			+ '\tstatic function sink(x:Dynamic):Void {}\n\tstatic function main() { sink(new Main()); }\n'
			+ '\tfunction f(n:String):Void {\n\t\tvar o:Other = new Other();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ o.dump(n); /*>*/ }\n\t}\n}\n'
			+ 'class Other {\n\tpublic function new() {}\n\n\tpublic function dump(n:String):Void Reflect.setProperty(this, n, null);\n}\n'
			+ 'class Third {\n\tpublic function new() {}\n\n\tpublic function calm():Void {}\n}\n'
			+ 'class Rebind {\n\tpublic static function run():Void Reflect.callMethod(new Main(), new Third().calm, ["items"]);\n}\n'
			+ 'class Nat {\n\tpublic static function go():Void untyped __js__("1");\n}\n';
		assertMatch(reflectAsk(['Main.hx' => main], true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-METHODS-REBINDS') @:killer('M-METHODS-METHOD-ONLY')
	public function testThisOfAConstructorIsAnyEscapedInstanceOnceACallMayRebindUnderTheTruth(): Void {
		// a constructor runs with `this` bound by a class value, which a rebinding call may be handed too; with no rebinding
		// call in the program, `this` is what built it
		function fixture(rebind: String): Map<String, String> {
			return [
				'Main.hx' => 'class Main {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n'
					+ '\tstatic function sink(x:Dynamic):Void {}\n\tstatic function main() { sink(new Main()); }\n'
					+ '\tfunction f(n:String):Void {\n\t\tfor (i in 0...items.length) { /*<*/ new Other(n); /*>*/ }\n\t}\n}\n'
					+ 'class Other {\n\tpublic function new(n:String) Reflect.setProperty(this, n, null);\n}\n'
					+ 'class Third {\n\tpublic function new() {}\n\n\tpublic function calm():Void {}\n}\n'
					+ 'class Rebind {\n\tpublic static function run():Void ' + rebind + '\n}\n'
			];
		}
		assertMatch(
			reflectAsk(fixture('Reflect.callMethod(new Main(), new Third().calm, []);'), true), r -> r.match(Unknown(DynamicName(_, _)))
		);
		assertMatch(reflectAsk(fixture('new Third().calm();'), true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-ARRAY-OWN') @:killer('M-REACH-ARRAY-ELEMENTS') @:killer('M-REACH-EXTERN-FACTS-TYPE')
	@:killer('M-REACH-ARRAY-VALUES')
	public function testTheArraysOwnMethodReachesItsElementsOnlyByConvertingThemUnderTheTruth(): Void {
		// `a.join` is the built-in array's own method: it converts each element of `a`, which the compiler types `Array<String>`
		// though the syntax cannot, and reaches no member by name — so neither `Obj.toString`, which changes `items`, nor any
		// other function runs; an array of `Obj` converts one (`INTERP_BUILD`: js's std declares subtypes of `Array` the index
		// does not hold)
		function region(local: String): String {
			return LOOP_HEAD + '\tstatic function main() {\n\t\tnew Obj();\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ Util.go("a,b"); /*>*/ }\n\t}\n}\n'
				+ 'class Util {\n\tpublic static function go(s:String):String {\n\t\t' + local + '\n\t\treturn a.join("");\n\t}\n}\n'
				+ CLEARING_OBJ;
		}
		assertMatch(interpAsk(['Main.hx' => region('var a = s.split(",");')], STD_STRING), r -> r.match(Proven));
		assertMatch(interpAsk(['Main.hx' => region('var a = [new Obj()];')], STD_STRING), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-ARRAY-CTOR')
	public function testAConstructionOfTheBuiltInArrayIsHandedNothingUnderTheTruth(): Void {
		// `new Array()` names a type and hands its target code no argument, no receiver and no function value: neither
		// `Obj.toString` nor `Clear.run`, read as a value, runs — though both change `items`
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tnew Obj();\n\t\tvar f:Void->Void = Clear.run;\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ Util.make(); /*>*/ }\n\t}\n}\n'
			+ 'class Util {\n\tpublic static function make():Array<Int> return new Array<Int>();\n}\n'
			+ 'class Clear {\n\tpublic static function run():Void Main.items = [];\n}\n' + CLEARING_OBJ;
		assertMatch(interpAsk(['Main.hx' => main]), r -> r.match(Proven));
	}

	public function testAnExternConstructionIsHandedItsArgumentsAlone(): Void {
		// a construction's children are its arguments: the target code of `new Ext(o)` holds `o`, an `Obj`, whose `toString`
		// changes `items` — read by the syntax, where nothing else says so
		function main(region: String): String {
			return LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n' + '\t\tfor (i in 0...items.length) { /*<*/ '
				+ region + ' /*>*/ }\n\t}\n}\n' + '@:native("Object") extern class Ext {\n\tpublic function new(?o:Obj);\n}\n'
				+ CLEARING_OBJ;
		}
		assertMatch(ask(['Main.hx' => main('new Ext(o);')], null, false), r -> r.match(Reached(_)));
	}

	public function testAMemberAdmittedByItsNameAloneRunsAsEachTypeSoNamedUnderTheTruth(): Void {
		// a value of any type converted may run the `toString` of either `Color`: each is read as its own, not as a name two
		// types share, and `b.Color`'s changes `items`
		function files(clears: Bool): Map<String, String> {
			return [
				'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tnew a.Color();\n\t\tnew b.Color();\n\t\tvar d:Dynamic = 1;\n'
					+ '\t\tfor (i in 0...items.length) { /*<*/ Std.string(d); /*>*/ }\n\t}\n}\n',
				'a/Color.hx' => 'package a;\n\nclass Color {\n\tpublic function new() {}\n\n\tpublic function toString():String return "a";\n}\n',
				'b/Color.hx' => 'package b;\n\nclass Color {\n\tpublic function new() {}\n\n\tpublic function toString():String {\n\t\t'
					+ (clears ? 'Main.items = [];\n\t\t' : '') + 'return "b";\n\t}\n}\n'
			];
		}
		assertMatch(truthAsk(files(false)), r -> r.match(Proven));
		assertMatch(truthAsk(files(true)), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-INIT-RECORD') @:killer('M-FACTS-VIEW-INIT-FACETED')
	public function testAFieldInitializerIsReadThroughItsFactsUnderTheTruth(): Void {
		// `Holder`'s initializers run when it is built: `0` runs nothing — read by its syntax it would admit every implicitly
		// called member, `Obj.toString` and the `@:from` of `Loud` `main` runs among them — and the `@:from` of `Loud` the
		// compiler calls for `1` changes `items`
		function region(field: String): String {
			return LOOP_HEAD + '\tstatic function main() {\n\t\tnew Obj();\n\t\tvar l:Loud = 2;\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ new Holder(); /*>*/ }\n\t}\n}\n' + 'class Holder {\n\t' + field
				+ '\n\n\tpublic function new() {}\n}\n'
				+ 'abstract Loud(Int) {\n\t@:from static function of(i:Int):Loud {\n\t\tMain.items.push(i);\n\t\treturn cast i;\n\t}\n}\n'
				+ CLEARING_OBJ;
		}
		assertMatch(truthAsk(['Main.hx' => region('var n:Int = 0;')]), r -> r.match(Proven));
		assertMatch(truthAsk(['Main.hx' => region('var l:Loud = 1;')]), r -> r.match(Reached(_)));
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

	@:pin('control') @:killer('M-REACH-PINNED-NONE') @:killer('M-FACTS-PINNED-UNTRUE') @:killer('M-REACH-ENTRY-OWN-NONE')
	@:killer('M-REACH-PINNED-REWRITTEN-SIMPLE')
	public function testTheOwnerTheFactsPinAtTheLoopIsOneOfTwoTypesUnderOneNameUnderTheTruth(): Void {
		// `a.Grid` and `b.Grid` share a simple name; `a.Grid.f` loops over its own `items`, and the compiler resolved that read
		// on `a.Grid`: the member is that type's, and the region its text, though `b.Grid`'s build macro rewrites `calm`. With
		// no whole list of builds nothing tells the two apart
		function question(listed: Bool, ?other: String): ReachResult {
			final files: Map<String, String> = pinnedGrids(null, other);
			return withReach(files, null, true, false, null, null, null, listed, (reach, dir) -> {
				final grid: String = files['a/Grid.hx'] ?? '';
				final at: Int = grid.indexOf('items.length');
				reach.mayMutateNamed(Path.join([dir, 'a/Grid.hx']), 'items', new Span(at, at + 'items'.length), regionOf(grid));
			});
		}
		assertMatch(question(true), r -> r.match(Proven));
		assertMatch(question(false), r -> r.match(Unknown(Ambiguous('Grid'))));
		assertMatch(question(true, 'rewrite'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-PINNED-NONE') @:killer('M-REACH-PINNED-REWRITTEN-SIMPLE') @:killer('M-REACH-PINNED-REWRITTEN-NONE')
	@:killer('M-FACTS-PINNED-OWNER-FILES')
	public function testAPinnedOwnerAsksItsOwnBuildMacroAndNoOtherUnderTheTruth(): Void {
		// `Main` reads `g.items` of an `a.Grid`, whose compiler fact pins `a.Grid` among the two `Grid`s: a build macro of
		// `b.Grid` is none of its code, one of `a.Grid` that rewrites `calm` is. A read the compiler resolved on a type the
		// index declares under another name — `a.Base`, which `a.Grid` extends — pins no `Grid`, and none is the site's: the
		// question has no site at all
		function question(mine: Null<String>, other: Null<String>, ?base: String, site: Bool = true): ReachResult {
			final files: Map<String, String> = pinnedGrids(mine, other, base);
			final main: String = files['Main.hx'] ?? '';
			final at: Int = main.indexOf('g.items');
			final member: MemberRef = site ? { owner: 'Grid', name: 'items', site: new Span(at, at + 'g.items'.length) } : {
				owner: 'Grid',
				name: 'items'
			};
			return ask(files, null, true, member, false, null, null, null, true);
		}
		assertMatch(question(null, null), r -> r.match(Proven));
		assertMatch(question(null, null, null, false), r -> r.match(Unknown(Ambiguous('Grid'))));
		assertMatch(question(null, 'rewrite'), r -> r.match(Proven));
		assertMatch(question('rewrite', null), r -> r.match(Unknown(Reification(_, _))));
		final base: String = 'package a;\n\nclass Base {\n\tpublic var items:Array<Int> = [];\n\n\tpublic function new() {}\n}\n';
		assertMatch(question(null, null, base), r -> r.match(Unknown(Ambiguous('Grid'))));
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

	@:pin('control') @:killer('M-REACH-QUALIFIED-NONE') @:killer('M-FACTS-QUALIFIED-HAZARDS') @:killer('M-GRAPH-FACTS-TYPED-NONE')
	public function testALibraryMemberAFactCallsIsItsOwnTypesUnderTheTruth(): Void {
		// `lib.Vec` and `other.Vec` share a simple name and both declare `get_length` (openfl's `Vector` beside
		// `haxe.ds.Vector`), so the graph folds both into one node; `Label.size` reads `length` of a `lib.Vec`, and the fact of
		// that call names `lib.Vec`'s: the walk reads its declaration alone, whose `untyped` read the compiler typed, never
		// `other.Vec`'s, which changes `Main.items`. With no whole list of builds nothing tells the two apart
		function library(getter: String, other: String): Map<String, String> {
			return [
				'lib/Vec.hx' => 'package lib;\n\nabstract Vec(Array<Int>) {\n\tpublic var length(get, never):Int;\n\n'
					+ '\tpublic function new() this = [];\n\n\t' + getter + '\n}\n',
				'other/Vec.hx' => 'package other;\n\nabstract Vec(Array<Int>) {\n\tpublic var length(get, never):Int;\n\n'
					+ '\tpublic function new() this = [];\n\n\tfunction get_length():Int {\n\t\t' + other
					+ '\n\t\treturn this.length;\n\t}\n}\n',
				'lib/Label.hx' => 'package lib;\n\nclass Label {\n\tpublic static var v:Vec = new Vec();\n\n'
					+ '\tpublic static function size():Int return v.length;\n}\n'
			];
		}
		final main: String = 'import lib.Label;\n\n' + LOOP_HEAD
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Label.size(); /*>*/ }\n'
			+ '\t\ttrace(new other.Vec().length);\n\t}\n}\n';
		final inlined: String = 'inline function get_length():Int return this.length;';
		final untypedRead: String = 'function get_length():Int return untyped this.length;';
		for (getter in [inlined, untypedRead]) for (other in ['', 'Main.items.push(1);']) {
			final files: Map<String, String> = ['Main.hx' => main];
			assertMatch(ask(files, null, true, null, false, null, library(getter, other), null, true), r -> r.match(Proven));
		}
		assertMatch(ask(['Main.hx' => main], null, true, null, false, null, library(inlined, '')), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-QUALIFIED-NONE') @:killer('M-REACH-QUALIFIED-SIMPLE-TOUCH') @:killer('M-TOUCH-SCAN-NODE-UNRECORDED')
	@:killer('M-FACTS-QUALIFIED-ANY-DECLARATION') @:killer('M-REACH-QUALIFIED-ESCAPE')
	public function testOnlyTheProjectTypeAFactCallsTouchesUnderTheTruth(): Void {
		// `a.Grid.run` changes `Main.items`, `b.Grid.run` does not; the graph folds both into `Grid.run`. Under the whole list
		// of builds the call's fact names which one runs, so only that one's touch counts; with no such list either may. A
		// `b.Grid.run` storing `Main.items` under a name no text of it spells lets its value go, which only its facts show
		function files(called: String, other: String, ?bRuns: String): Map<String, String> {
			return [
				'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ ' + called
					+ '.Grid.run(); /*>*/ }\n\t\t' + other + '.Grid.run();\n\t}\n}\n',
				'a/Grid.hx' => 'package a;\n\nclass Grid {\n\tpublic static function run():Void Main.items.push(1);\n}\n',
				'b/Grid.hx' => 'package b;\n\nimport Main.items as stuff;\n\nclass Grid {\n\tpublic static var keep:Array<Int> = null;\n\n'
					+ '\tpublic static function run():Void {' + (bRuns ?? '') + '}\n}\n'
			];
		}
		assertMatch(truthAsk(files('b', 'a')), r -> r.match(Proven));
		assertMatch(truthAsk(files('a', 'b')), r -> r.match(Reached(_)));
		assertMatch(ask(files('b', 'a')), r -> !r.match(Proven));
		assertMatch(truthAsk(files('b', 'a', ' keep = stuff; ')), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-REACH-QUALIFIED-UNNAMED') @:killer('M-REACH-SHARED-OWNERS')
	public function testANameTwoTypesShareReachedByItsSyntaxRunsAsEachOfThemUnderTheTruth(): Void {
		// the region lies in `a.Grid.go`, which `b.Grid` declares too: the node folding both is read by its syntax, whose call
		// of `run` names the folded `Grid.run` and no owner, so either `run` may be the one that runs — each read as its own
		// type's, and `a.Grid`'s changes `items` when it calls `Push.one`. With `go` declared by `a.Grid` alone the node is read through
		// its facts, whose call names `a.Grid`'s; with `run` declared by `a.Grid` alone, its node is its own
		function question(bDeclares: Array<String>, pushes: Bool = false): ReachResult {
			final grid: String = 'package a;\n\nclass Grid {\n\tpublic static function go():Void {\n'
				+ '\t\tfor (i in 0...Main.items.length) { /*<*/ run(); /*>*/ }\n\t}\n\n\tpublic static function run():Void {'
				+ (pushes ? ' Push.one(); ' : '') + '}\n}\n' + 'class Push {\n\tpublic static function one():Void Main.items.push(1);\n}\n';
			final members: String = [for (m in bDeclares) '\tpublic static function $m():Void {}\n'].join('');
			final files: Map<String, String> = [
				'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\ta.Grid.go();\n\t\tb.Grid.n++;\n\t}\n}\n',
				'a/Grid.hx' => grid,
				'b/Grid.hx' => 'package b;\n\nclass Grid {\n\tpublic static var n:Int = 0;\n' + members + '}\n'
			];
			return withReach(files, null, true, false, null, null, null, true, (reach, dir) -> {
				final region: ReachEntry = Region(Path.join([dir, 'a/Grid.hx']), regionOf(grid));
				reach.mayReach(region, { owner: 'Main', name: 'items' }, Mutate);
			});
		}
		assertMatch(question(['go', 'run']), r -> r.match(Proven));
		assertMatch(question(['go', 'run'], true), r -> r.match(Reached(_)));
		assertMatch(question(['go']), r -> r.match(Proven));
		assertMatch(question(['run']), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-CALL-OPERAND-LEAF')
	public function testAConvertedValueOfTheParametersOwnTypeMayBeAnyObjectUnderTheTruth(): Void {
		// `d` is `Dynamic`, `Std.string`'s parameter type, so handing it on records no flow: the flow of the other branch is one
		// leaf of the argument, not the value converted, which may be an `Obj`, whose `toString` replaces `Main.items`
		final main: String = 'import lib.Text;\n\n' + LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ Text.fail(); /*>*/ }\n\t}\n}\n' + CLEARING_OBJ;
		function converting(argument: String): ReachResult {
			final thrown: String = 'var d:Dynamic = null;\n\t\tStd.string(' + argument + ');';
			return ask(['Main.hx' => main], null, true, null, false, null, plainText(thrown), null, true);
		}
		assertMatch(converting('failing ? new Plain() : d'), r -> !r.match(Proven));
		assertMatch(converting('d'), r -> !r.match(Proven));
		assertMatch(converting('new Plain()'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-CALL-OPERAND')
	public function testAConversionAnInlinedBodySplicedFromAnotherFileConvertsItsOwnArgumentUnderTheTruth(): Void {
		// `Buf.add` (cpp's `StringBuf.add`) converts what it is handed; inlined into `main`, the conversion lies in `Buf.hx`,
		// whose text the facts of `main` do not hold, and the region hands it a `String`, whose conversion runs nothing —
		// `Obj.toString` changes `items`, and runs when `show` converts an `Obj`. Each is inlined at its call, so its own body,
		// read through its own facts, converts what its parameter declares
		final buf: String = 'class Buf {\n\tpublic var s:String = "";\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function add(x:String):Void {\n\t\tif (s == null) s = Std.string(x); else s += Std.string(x);\n\t}\n\n'
			+ '\tpublic function show(x:Main.Obj):Void {\n\t\tif (s == null) s = Std.string(x); else s += Std.string(x);\n\t}\n}\n';
		function region(code: String): String {
			return LOOP_HEAD + '\tstatic function main() {\n\t\tvar o:Obj = new Obj();\n\t\tvar b:Buf = new Buf();\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ ' + code + ' /*>*/ }\n\t}\n}\n' + CLEARING_OBJ;
		}

		function question(code: String): ReachResult {
			return ask(['Main.hx' => region(code), 'Buf.hx' => buf], null, true, null, false, null, null, null, true);
		}
		assertMatch(question('inline b.add("x");'), r -> r.match(Proven));
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile');
		assertMatch(question('inline b.show(o);'), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-GRAPH-FACTS-INTERFACE-PLACEHOLDER') @:killer('M-GRAPH-VIRTUAL-OWN-ONLY')
	@:killer('M-GRAPH-ABSTRACT-THIS-STORAGE') @:killer('M-REACH-OVERRIDES-INHERITED-UNLOADED')
	public function testAnInterfacePropertyReadThroughAnInlinedAbstractRunsItsImplementations(): Void {
		// openfl's `Vector` shape: the inlined `Vec.get_length` reads `length` of the interface `IVec`, whose accessor only the
		// property implies — no text declares `IVec.get_length`. The read runs the implementations: `IntVec`'s own, and the one
		// `Sub` inherits from `Base`, a class off `IVec`'s chain, whose file the walk must read though neither it nor
		// `Sub.hx` spells `IVec` and the member both
		function library(intVec: String, base: String, spelled: Bool): Map<String, String> {
			return [
				'lib/Vec.hx' => 'package lib;\n\nabstract Vec(IVec) {\n\tpublic var length(get, never):Int;\n\n'
					+ '\tpublic inline function new(v:IVec) this = v;\n\n\tinline function get_length():Int return this.length;\n}\n\n'
					+ 'interface IVec {\n\tvar length(get, never):Int;\n}\n',
				'lib/IntVec.hx' => 'package lib;\n\nimport lib.Vec.IVec;\n\nclass IntVec implements IVec {\n'
					+ '\tpublic var length(get, never):Int;\n\n\tpublic function new() {}\n\n\tfunction get_length():Int {\n\t\t' + intVec
					+ '\n\t\treturn 0;\n\t}\n}\n',
				'lib/Base.hx' => 'package lib;\n\nclass Base {\n\tpublic function new() {}\n\n\tfunction get_length():Int {\n\t\t' + base
					+ '\n\t\treturn 0;\n\t}\n}\n',
				'lib/Sub.hx' => 'package lib;\n\nimport lib.Vec.IVec;\n\nclass Sub extends Base implements IVec {\n'
					+ '\tpublic var length(get, never):Int;\n' + (spelled ? '\t// the get_length it runs is Base\'s\n' : '') + '}\n',
				'lib/Label.hx' => 'package lib;\n\nclass Label {\n\tpublic static var failing:Bool = false;\n\n'
					+ '\tpublic static var v:Vec = new Vec(failing ? new IntVec() : new Sub());\n\n'
					+ '\tpublic static function size():Int return v.length;\n}\n'
			];
		}
		final main: String = 'import lib.Label;\n\n' + LOOP_HEAD
			+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Label.size(); /*>*/ }\n\t}\n}\n';
		final touch: String = 'Main.items.push(1);';
		function truth(intVec: String, base: String): ReachResult {
			return ask(['Main.hx' => main], null, true, null, false, null, library(intVec, base, false), null, true);
		}
		// library code changing the member is read by its name: never a proof, whichever reading finds it
		assertMatch(truth('', ''), r -> r.match(Proven));
		assertMatch(truth(touch, ''), r -> !r.match(Proven));
		assertMatch(truth('', touch), r -> !r.match(Proven));
		// the syntax's own reading, every type indexed: the accessor's dispatch reaches the inherited implementation too
		function syntax(base: String, spelled: Bool): ReachResult {
			return ask(['Main.hx' => main], null, false, null, true, null, library('', base, spelled));
		}
		assertMatch(syntax('', true), r -> r.match(Proven));
		assertMatch(syntax(touch, true), r -> !r.match(Proven));
		assertMatch(syntax(touch, false), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-INDEX-ALTERNATE-DROPPED') @:killer('M-INDEX-ALTERNATE-MEMBERS')
	public function testAPropertyOnlyAnotherBranchsDeclarationOfATypeGivesRunsItsAccessor(): Void {
		// the first branch declares `Box.size` a plain field, the branch the build compiles a property whose getter changes
		// `Main.items`: the index lists one `Box`, which must hold both readings. A type only the second branch declares,
		// under a name of its own, was always listed
		final box: String = '#if never_defined\nclass Box {\n\tpublic function new() {}\n\n\tpublic var size:Int = 0;\n}\n#else\n'
			+ 'class Box {\n\tpublic function new() {}\n\n\tpublic var size(get, never):Int;\n\n'
			+ '\tfunction get_size():Int {\n\t\tMain.items.push(1);\n\t\treturn 0;\n\t}\n}\n#end\n';
		final crate: String = '#if never_defined\nclass Bag {}\n#else\nclass Crate {\n\tpublic function new() {}\n\n'
			+ '\tpublic var size(get, never):Int;\n\n\tfunction get_size():Int {\n\t\tMain.items.push(1);\n\t\treturn 0;\n\t}\n}\n#end\n';
		function read(type: String, declared: String): ReachResult {
			final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tvar b:' + type + ' = new ' + type + '();\n'
				+ '\t\tfor (i in 0...items.length) { /*<*/ var n:Int = b.size; /*>*/ }\n\t}\n}\n';
			return ask(['Main.hx' => main, type + '.hx' => declared], null, false, null, true);
		}
		assertMatch(read('Box', box), r -> r.match(Reached(_)));
		assertMatch(read('Crate', crate), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-REWRITTEN-SOLE-SIMPLE')
	public function testAMemberOnlyOneTypeOfItsNameDeclaresAsksThatTypesBuildMacroUnderTheTruth(): Void {
		// `lib.Vec` and `other.Vec` share a simple name, and only `lib.Vec` declares `splice`, so the walk reads `Vec.splice`
		// as `lib.Vec`'s without qualifying it (openfl's `Vector.splice` beside `haxe.ds.Vector`); `lib.Vec`'s build macro hands
		// its fields back as they are, which its facts show. Asked by the simple name, the build macro is any `Vec`'s
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ lib.Vec.splice(1); /*>*/ }\n'
				+ '\t\ttrace(new other.Vec());\n\t}\n}\n',
			'lib/Vec.hx' => 'package lib;\n\n@:build(Mac.keep())\nclass Vec {\n\tpublic static function splice(n:Int):Int return n;\n}\n',
			'other/Vec.hx' => 'package other;\n\nclass Vec {\n\tpublic function new() {}\n}\n',
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(truthAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-COPY-UNION') @:killer('M-FACTS-COPY-HOMED-UNION') @:killer('M-FACTS-COPY-TYPE-HOMES') @:killer('M-GRAPH-REFACET-FURTHER')
	@:killer('M-GRAPH-REFACET-RETRACT')
	public function testATypeEachBuildReadsFromItsOwnCopyIsItsTextUnderTheTruth(): Void {
		// each build reads `Gen` from its own directory, the copies differing in a value and so in every position after it —
		// `a`'s `calm` starts inside `b`'s `idle`, as TM's `mas-debug` copy of `ApplicationMain` is shifted: each build's
		// facts are its own copy's text, the macro's expansion and the local function included, so the build macro every
		// class carries changed nothing the text does not say. Without the whole list of builds, a build the list does not
		// name may read a copy otherwise
		final copies: Map<String, String> = ['a' => genCopy('a'), 'b' => genCopy(StringTools.lpad('', 'b', 60))];
		assertMatch(copiesAsk(copies, true), r -> r.match(Proven));
		assertMatch(copiesAsk(copies, false), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-COPY-LINE-HOME') @:killer('M-FACTS-COPY-NESTED-UNION')
	public function testACopyEachBuildReadsFromItsOwnDirectoryIsItsTextUnderTheTruth(): Void {
		// each build runs in its copy's directory, so its facts name `Gen.hx` alike, at alike positions: the same line of
		// two builds names two files, each build's own copy
		final copies: Map<String, String> = ['a' => genCopy('a'), 'b' => genCopy('b')];
		assertMatch(copiesAsk(copies, true, true), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-COPY-UNVOUCHED')
	public function testACopyOfATypeNoBuildReadsIsNoProofUnderTheTruth(): Void {
		// `gen/c` declares `Gen` too, and no build reads it: the graph folds its text into the type's, and no build's facts
		// say what a build macro made of it
		final copies: Map<String, String> = ['a' => genCopy('a'), 'b' => genCopy('bb'), 'c' => genCopy('c')];
		assertMatch(copiesAsk(copies, true), r -> r.match(Unknown(Reification(_, _))));
	}

	public function testACopyABuildMacroRewroteIsNoProofUnderTheTruth(): Void {
		// build `b`'s copy has `Mac.rewrite` make `calm` push onto `items`, which that copy's text never names
		final copies: Map<String, String> = ['a' => genCopy('a'), 'b' => genCopy('bb', '@:build(Mac.rewrite())\n')];
		assertMatch(copiesAsk(copies, true), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-COPY-UNHELD')
	public function testARegionOfATypeABuildReadsFromACopyTheIndexDoesNotHoldIsNoProofUnderTheTruth(): Void {
		// build `b` reads `Main` from `gen/b`, which no index holds and whose loop grows `items`: the region's text is one copy
		// of the type, and what a build macro made of the other no text the analysis reads says
		final region: String -> String = body ->
			LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ ' + body + ' /*>*/ }\n\t}\n}\n';
		final hub: String = '--macro addGlobalMetadata("", "@:build(Mac.hub())")\n';
		final unindexed: Map<String, String> = [
			'gen/b/Main.hx' => region('items.push(1);'),
			'build_a.hxml' => '-cp .\n-main Main\n--js out_a.js\n' + hub,
			'build_b.hxml' => '-cp .\n-cp gen/b\n-main Main\n--js out_b.js\n' + hub
		];
		final files: Map<String, String> = ['Main.hx' => region('var k:Int = i;'), 'Mac.hx' => BUILD_MACROS];
		final result: ReachResult = ask(
			files, null, true, null, false, null, null, unindexed, true, null, null, ['build_a.hxml', 'build_b.hxml']
		);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile');
		assertMatch(result, r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-REACH-COPY-ELSEWHERE')
	public function testACopyTheIndexDoesNotHoldIsNoProofUnderTheTruth(): Void {
		// build `b` reads a copy of `Gen` no index holds, whose `calm` pushes onto `items`: no declaration of the graph holds
		// the code that build runs, whether a build macro ran over it or not
		final copies: Map<String, String> = ['a' => genCopy('a'), 'b' => genCopy('b', null, 'Main.items.push(1);')];
		assertMatch(copiesAsk(copies, true, false, true, ['b']), r -> !r.match(Proven));
		assertMatch(copiesAsk(copies, true, false, false, ['b']), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-DEAD-NODE-ENTERED') @:killer('M-LIVE-FRAGMENTED')
	public function testCodeNoBuildCompilesRunsNothingUnderTheTruth(): Void {
		// `haxe_ver >= 4.2` is no define a build's set decides, so its `#else` stays live, and its call of `Dead.go` is an edge:
		// but `Dead` is declared only where no build compiles, so the node runs nothing — not even a build macro of its own. A
		// call no build compiles is none either when a directive nested in it splits its range (openfl's
		// `untyped #if haxe4 js.Syntax.code #else __js__ #end (…)`)
		final lib: String = 'class Lib {\n\tpublic static function run():Void {\n\t\t#if (haxe_ver >= 4.2)\n\t\tcalm();\n\t\t#else\n'
			+ '\t\tDead.go();\n\t\t#end\n\t\t#if never_defined\n\t\tClearing.go(#if haxe4 1 #else 2 #end);\n\t\t#end\n\t}\n\n'
			+ '\tstatic function calm():Void {}\n}\n\n'
			+ '#if never_defined\n@:build(Nope.build())\nclass Dead {\n\tpublic static function go():Void {}\n}\n#end\n';
		final clearing: String = 'class Clearing {\n\tpublic static function go(n:Int):Void Main.items.push(n);\n}\n';
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Lib.run(); /*>*/ }\n'
			+ '\t\tClearing.go(0);\n\t}\n}\n';
		assertMatch(truthAsk(['Main.hx' => main, 'Lib.hx' => lib, 'Clearing.hx' => clearing]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-SITE-OWNERS-NONE') @:killer('M-FACTS-SITE-CONVERSION-OWNERS-NONE')
	@:killer('M-REACH-OWNED-TYPES-NONE') @:killer('M-REACH-OWNED-UNTYPED')
	@:killer('M-REACH-OWNED-ESCAPES-KEPT')
	public function testAnAdmittedConversionOfANameTwoTypesShareIsTheOperandsTypesUnderTheTruth(): Void {
		// `a.Color` and `b.Color` share a simple name, so the graph folds both `toString`s into one node. The region converts a
		// `b.Color`, concatenated or thrown: the facts name its type, so only `b.Color.toString` may run — never `a.Color`'s.
		// A `Dynamic` operand may be either: its node is read by the name alone, every declaration of it, `a.Color`'s among
		// them; and so may an operand of a type an instance of the other escaped into
		function files(converting: String, aBody: String, bBody: String, ?more: String): Map<String, String> {
			return [
				'Main.hx' => 'import b.Color;\n\n' + LOOP_HEAD + '\tstatic var c:Color = new Color();\n\n'
					+ '\tstatic function main() {\n\t\tvar other:a.Color = new a.Color();\n\t\tvar d:Dynamic = null;\n' + (more ?? '')
					+ '\t\tfor (i in 0...items.length) { /*<*/ ' + converting + ' /*>*/ }\n\t}\n}\n',
				'Helper.hx' => 'class Helper {\n\tpublic static function clear():Void Main.items.push(1);\n}\n',
				'a/Color.hx' => 'package a;\n\nclass Color {\n\tpublic function new() {}\n\n\tpublic function toString():String {\n\t\t'
					+ aBody + '\n\t\treturn "a";\n\t}\n}\n',
				'b/Color.hx' => 'package b;\n\nclass Color {\n\tpublic function new() {}\n\n\tpublic function toString():String {\n\t\t'
					+ bBody + '\n\t\treturn "b";\n\t}\n}\n'
			];
		}
		// `a.Color.toString` changes the member through `Helper.clear`, so its folded node reaches a function that does
		final clearing: String = 'Helper.clear();';
		final concatenated: String = 'var s:String = "" + c;';
		assertMatch(truthAsk(files(concatenated, clearing, '')), r -> r.match(Proven));
		assertMatch(truthAsk(files('try throw c catch (e:haxe.Exception) {}', clearing, '')), r -> r.match(Proven));
		assertMatch(truthAsk(files(concatenated, '', 'Main.items.push(1);')), r -> r.match(Reached(_)));
		assertMatch(truthAsk(files('var s:String = "" + d;', clearing, '')), r -> r.match(Reached(_)));
		assertMatch(truthAsk(files(concatenated, clearing, '', '\t\td = other;\n')), r -> !r.match(Proven));
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

	@:pin('control') @:killer('M-FACTS-ASSIGN-HELD') @:killer('M-FACTS-SUBSTITUTED-RECEIVER') @:killer('M-FACTS-ALIAS-LINK')
	@:killer('M-FACTS-CAPTURE')
	public function testALocalTheMemberIsStoredInIsFollowedThroughItsReadsUnderTheTruth(): Void {
		// `walk` stores `items` — or another array — in `l`, in either branch, and in `copy` after it, and only iterates and
		// reads them: under the truth no value escapes, while the syntax sees a store into a local. A push on either local
		// (`walk` run by the region), handing it on, capturing it, returning it, or a push on the outer `l` past a block
		// declaring a `l` of its own, does change or share the member
		final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ REGION /*>*/ }\n'
			+ '\t\twalk("h");\n\t}\n\tstatic function calm():Void {}\n\tstatic function keep(a:Array<Int>):Void {}\n'
			+ '\tstatic function walk(c:String):Array<Int> {\n'
			+ '\t\tvar other:Array<Int> = [3];\n\t\tvar l:Array<Int> = null;\n\t\tif (c == "h") l = items; else if (c == "v") l = other;\n'
			+ '\t\tfor (i => v in l) trace(i + v);\n\t\tvar copy:Array<Int> = l;\n\t\tfor (x in copy) trace(x + copy.length + copy[0]);\n'
			+ '\t\tUSE\n\t\treturn null;\n\t}\n}\n';
		function files(use: String, region: String = 'calm();'): Map<String, String> {
			return [
				'Main.hx' => StringTools.replace(StringTools.replace(main, 'USE', use), 'REGION', region)
			];
		}
		// the index is the analysis's word for the classpath, which `Array` would otherwise leave open
		for (use in ['', '{ var l:Array<Int> = [5]; l.push(6); }'])
			assertMatch(ask(files(use), null, true, null, true, null, null, null, true), r -> r.match(Proven));
		assertMatch(ask(files('')), r -> r.match(Unknown(Escape(_, _))));
		for (use in [
			'l.push(1);',
			'copy.push(1);',
			'{ var l:Array<Int> = [5]; trace(l.length); } l.push(1);'
		]) assertMatch(compiledTruthAsk(files(use, 'walk("h");')), r -> r.match(Reached(_)));
		for (use in ['keep(l);', 'var f = () -> copy.length; f();', 'if (c == "r") return l;'])
			assertMatch(compiledTruthAsk(files(use)), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-TOUCH-TYPED-HELD-REGION') @:killer('M-FACTS-HELD-FLAG')
	public function testAPushThroughALocalHoldingTheMemberInsideTheRegionReachesItUnderTheTruth(): Void {
		// the store lies before the loop and the push through the local inside it: the touch the facts record at the store is
		// one of a local read anywhere in the function, the region's included
		for (store in ['var l:Array<Int> = items;', 'var l:Array<Int> = null;\n\t\tl = items;']) {
			final main: String = LOOP_HEAD + '\tstatic function main() {\n\t\t' + store
				+ '\n\t\tfor (i in 0...items.length) { /*<*/ if (l.length < 3) l.push(1); /*>*/ }\n\t}\n}\n';
			assertMatch(compiledTruthAsk(['Main.hx' => main]), r -> r.match(Reached(_)));
		}
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

	@:pin('control') @:killer('M-FACTS-TEXT-GENERIC-BUILD') @:killer('M-FACTS-GENERIC-RECORDED')
	public function testAConstructionOfAGenericBuildIsItsTextUnderTheTruth(): Void {
		// lime's and openfl's `Preloader`: `new Event<Void->Void>()` constructs the class `Event`'s `@:genericBuild` defined
		// for `Void->Void`, whose name no text spells — imported and qualified alike
		final files: Map<String, String> = genericFixture(
			'public static function other():Void {\n\t\tfinal a:Ev<Void->Void> = new Ev<Void->Void>();\n'
			+ '\t\tfinal b:gen.Ev<Int->Int->Void> = new gen.Ev<Int->Int->Void>();\n\t}'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
		assertMatch(ask(files, null, true, null, false, HUB_BUILD), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-FACTS-GENERIC-BUILT') @:killer('M-FACTS-ROUNDS')
	public function testAConstructionABuildMacroSwappedForAnotherGenericBuildIsNoTextUnderTheTruth(): Void {
		// `Gen.swap` constructs `Ev<String>` where the text writes `Ev<Int>`: what the text names builds another class
		final files: Map<String, String> = genericFixture(
			'public static function other():Void {\n\t\tfinal a:Dynamic = new Ev<Int>();\n\t}', '@:build(gen.Gen.swap())\n'
		);
		assertMatch(hubAsk(files), r -> r.match(Unknown(Reification(_, _))));
	}

	public function testAMethodAGenericBuildMadeRunsItsFactsUnderTheTruth(): Void {
		// `fire` is a method `Gen.build` wrote into the class it defined for `Int`: no text of `Ev` declares it, and it grows
		// `items` (lime's `Event.dispatch`)
		final files: Map<String, String> = genericFixture('', '', 'new Ev<Int>().fire();');
		files['Main.hx'] = 'import gen.Ev;\n\n' + (files['Main.hx'] ?? '');
		assertMatch(compiledTruthAsk(files), r -> !r.match(Proven));
		assertMatch(hubAsk(files), r -> !r.match(Proven));
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

	@:pin('control') @:killer('M-FACTS-DECLARATION-RUN')
	public function testAnAbstractsInlineConstructorIsItsTextUnderTheTruth(): Void {
		// haxe's `Rest` (TM's `GridScale.hx:61`, S10's blocker): `inline function new(a) this = a;` is lowered into the
		// implementation class's `_new`, which the compiler places at the declaration's first modifier, before the function
		final wrap: String = 'abstract Wrap(Array<Int>) {\n\tinline function new(a:Array<Int>) this = a;\n\n'
			+ '\tpublic static function make(i:Int):Wrap return new Wrap([i]);\n}\n';
		assertMatch(hubAsk(hubFixture('Wrap.make(1);', ['Wrap.hx' => wrap])), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-VIEW-DECLARATION-RUN')
	public function testAnAbstractsInlineConstructorIsReadFromItsFactsUnderTheTruth(): Void {
		// the walk enters `Wrap.new` through the inlined `_new`: read by its syntax, it would admit every conversion of any
		// code — `Loud.of`, which changes `items` — but its facts, placed at the first modifier, are its code
		final wrap: String = 'abstract Wrap(Array<Int>) {\n\tinline function new(a:Array<Int>) this = a;\n\n'
			+ '\tpublic static function make(i:Int):Wrap return new Wrap([i]);\n}\n';
		final loud: String = 'abstract Loud(Int) {\n\t@:from static function of(i:Int):Loud {\n\t\tMain.items.push(i);\n\t\treturn cast i;\n\t}\n'
			+ '\n\tpublic static function use():Loud return 1;\n}\n';
		final files: Map<String, String> = hubFixture('Wrap.make(1);', ['Wrap.hx' => wrap, 'Loud.hx' => loud]);
		files['Main.hx'] = StringTools.replace(
			files['Main.hx'] ?? '', 'static function main() {', 'static function main() {\n\t\tLoud.use();'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-MADE-FORWARDS')
	public function testAConstructorTheCompilerMadeHandingItsParametersOnIsItsTextUnderTheTruth(): Void {
		// a class the text gives no constructor gets its super's, which hands the parameters on (TM's `APIEntity`, `Col`)
		final files: Map<String, String> = hubFixture('new Made(1).poke();', [
			'Made.hx' => 'class Made extends Base {\n\tpublic function poke():Void {}\n}\n',
			'Base.hx' => 'class Base {\n\tpublic function new(k:Int) {}\n}\n'
		]);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-BINDING')
	public function testALocalTheCompilerBindsAValueTheTextWritesToIsItsTextUnderTheTruth(): Void {
		// `n ?? 3` reads `n` once into a `tmp` the compiler declares at `n` (TM's `Typography`, `PlayerBase`)
		assertMatch(hubAsk(utilWith('public static function other(n:Null<Int>):Int return n ?? 3;')), r -> r.match(Proven));
		// `a ?? b ?? 3` binds its `tmp` to `a ?? b`: `??` is left-associative, so that is a node of the text (TM's
		// `AIPanel`, `SharedFileMoveDetector`, `Image`)
		assertMatch(
			hubAsk(utilWith('public static function other(a:Null<Int>, b:Null<Int>):Int return a ?? b ?? 3;')), r -> r.match(Proven)
		);
		// `o.inner.n += 1` holds `o.inner` in an `fh` (TM's `RoundedButton`)
		final outer: String = 'class Outer {\n\tpublic var inner:Holder = new Holder();\n\n\tpublic function new() {}\n}\n';
		final compound: Map<String, String> = utilWith(
			'public static function other(o:Outer):Void o.inner.n += 1;', ['Outer.hx' => outer, 'Holder.hx' => HOLDER]
		);
		assertMatch(hubAsk(compound), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-BINDING-TRIMMED')
	public function testABindingOfAnOperandWrittenBeforeAnotherOperatorIsItsTextUnderTheTruth(): Void {
		// `a + b + c` with `c` an abstract whose commutative `+` takes it first: to keep the order of evaluation the compiler
		// binds `lhs` to `a + b`, whose node runs on to the space before the next `+` (TM's `FileListItemList`:
		// `x + width + SIZE` with a `UInt`)
		final q: String =
			'abstract Q(Int) from Int {\n\t@:commutative @:op(A + B) static function addF(lhs:Q, rhs:Float):Float return rhs;\n}\n';
		final files: Map<String, String> = utilWith(
			'public static function other(a:Float, b:Float, c:Q):Float return a + b + c;', ['Q.hx' => q]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-DECLARES')
	public function testALocalPlacedAtItsDeclarationsKeywordIsItsTextUnderTheTruth(): Void {
		// under `@:privateAccess` the compiler places `final q` at `final` alone (TM's `GlProgressOverlay`)
		final files: Map<String, String> =
			utilWith('public static function other():Int {\n\t\t@:privateAccess final q:Int = 1;\n\t\treturn q;\n\t}');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-READ-AT-VALUE') @:killer('M-FACTS-TEXT-BINDING')
	public function testTheFunctionAPartialApplicationMakesIsItsTextUnderTheTruth(): Void {
		// `add.bind(1)` binds `x` at `1` and makes a function reading it and `y` at `add.bind` (TM's `Editor`, `FileSystemBase`)
		final files: Map<String, String> = utilWith(
			'public static function other():Int->Int return add.bind(1);\n\n\tstatic function add(x:Int, y:Int):Int return x + y;'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-READ-AT-VALUE') @:killer('M-FACTS-TEXT-INTERPOLATED-VALUE') @:killer('M-FACTS-TEXT-LITERAL-END')
	public function testAReadOfAnInlinedArgumentAtTheValueTheTextWritesIsItsTextUnderTheTruth(): Void {
		// a local inline function's parameter, read in an interpolation, is read at the argument the text writes — an
		// interpolated string's value, up to its last part, spaces and all, or an empty string (TM's
		// `APIRequest2.buildMultipartBody`: `writeln('--$boundary')`, `writeln('')`; `ProfileLogoGroup`: `getDMY(' ')`)
		final files: Map<String, String> = utilWith(
			'public static function other(b:String):Void {\n\t\tinline function line(s:String = \'\'):Void Words.say(\'$$s\\r\\n\');\n'
			+ '\t\tline(\'--$$b\');\n\t\tline(\'\');\n\t\tline(\'type: $${b}\');\n\t\tline(\' \');\n\t}',
			['Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-COMPREHENSION')
	public function testThePushesOfAComprehensionAreItsTextUnderTheTruth(): Void {
		// the compiler builds `[for (…) e]` by pushing each `e`, positioned at `e` (TM's `Grid.get_gridData`, `Editor`)
		assertMatch(hubAsk(utilWith('public static function other():Array<Int> return [for (i in 0...3) i * 2];')), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-INTERPOLATION')
	public function testCodeInAnInterpolatedStringPastAnEscapeIsItsTextUnderTheTruth(): Void {
		// the compiler counts `\t` as one character, so `h.n` past it sits one short (TM's `CrashManager`, `FileIO`)
		final files: Map<String, String> = utilWith(
			'public static function other(h:Holder):String return \'a\\tb $${h.q} $${h.n}\';', ['Holder.hx' => HOLDER]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
		// it counts the bytes UTF-8 writes a character in, so past an arrow `h.n` sits two beyond (TM's
		// `CloudDatabaseMigrations.runMigration`: `${a.from()}→${a.to()}`)
		final arrow: Map<String, String> = utilWith(
			'public static function other(h:Holder):String return \'$${h.q}→$${h.n}\';', ['Holder.hx' => HOLDER]
		);
		assertMatch(hubAsk(arrow), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-CONVERTS')
	public function testAnAbstractsConversionAnInterpolationCallsIsItsTextUnderTheTruth(): Void {
		// `${c}` of an abstract calls its `toString` statically, at the value (TM's `VideoExportController`: `${exception.stack}`)
		final cs: String = 'abstract Cs(Int) from Int {\n\tpublic function toString():String return \'c\';\n}\n';
		assertMatch(
			hubAsk(utilWith('public static function other(c:Cs):String return \'c $${c}\';', ['Cs.hx' => cs])), r -> r.match(Proven)
		);
	}

	@:pin('control') @:killer('M-FACTS-TEXT-TYPEDEF-NEW')
	public function testAConstructionThroughAnImportAliasIsItsTextUnderTheTruth(): Void {
		// `import sys.ssl.Socket as SslSocket; new SslSocket()` (TM's `NativeURLLoaderQueue`): the compiler types the alias as a
		// typedef
		final util: String = 'import Holder as H;\n\nclass Util {\n\tpublic static function calm():Void {}\n\n'
			+ '\tpublic static function other():H return new H();\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD + '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Util.calm(); /*>*/ }\n\t}\n}\n',
			'Util.hx' => util,
			'Holder.hx' => HOLDER,
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-TYPEDEF-NEW')
	public function testAConstructionThroughATypedefIsItsTextUnderTheTruth(): Void {
		// `new UniversalImageSelect()`, a typedef each platform points at its own class (TM's `ProfileImageGroup`)
		final files: Map<String, String> = utilWith(
			'public static function other():HH return new HH();', ['Holder.hx' => HOLDER, 'HH.hx' => 'typedef HH = Holder;\n']
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-ABSTRACT-CTOR-CALL')
	public function testACallOfAnAbstractsConstructorIsItsTextUnderTheTruth(): Void {
		// `new URLVariables()` of a constructor that is not inline is a call of its implementation's `_new` (TM's `CreatePDF`)
		final box: String = 'abstract Box(Array<Int>) {\n\tpublic function new() this = [];\n}\n';
		assertMatch(hubAsk(utilWith('public static function other():Box return new Box();', ['Box.hx' => box])), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-INLINED-WHOLE')
	public function testAnInitializerThatIsWhollyAnInlinedCallIsItsTextUnderTheTruth(): Void {
		// the compiler types `twice(3)` as `twice`'s body, at its positions, and records no call (TM's `PopupShadow`, `UInt`)
		final files: Map<String, String> =
			utilWith('static var X:Int = twice(3);\n\n\tstatic inline function twice(q:Int):Int return q + q;');
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-INLINED-CONSTRUCTION')
	public function testAnInitializerThatIsWhollyAnInlinedConstructorIsItsTextUnderTheTruth(): Void {
		// `new ByteArray()` of an abstract whose constructor is inline is its body (TM's `CreatePDF.pdfByteArray`)
		final box: String = 'abstract Box(Array<Int>) {\n\tpublic inline function new() this = [];\n}\n';
		assertMatch(hubAsk(utilWith('static var B:Box = new Box();', ['Box.hx' => box])), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-EXPANSION-SITE')
	public function testAnExpressionMacroInAnInlinedCallsArgumentIsItsTextUnderTheTruth(): Void {
		// `Words.rep(Mac.t('x'), …)`: the expansion stands for `s` in `rep`'s code, the call of the macro at `rep`'s site
		// (TM's `StringUtil.replace(t(…), …)`)
		final files: Map<String, String> = utilWith(
			'public static function other():String return Words.rep(Mac.t(\'x\'), \'a\', \'b\');', ['Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-SITE-HOLDS-OWN-CODE')
	public function testAnExpressionMacroInAnInlinedCallBesideACapturedThisIsItsTextUnderTheTruth(): Void {
		// a method's one statement `Shown.run(() -> self(), Mac.t('x'))`: the closure among the inlined call's arguments
		// captures `this`, which the compiler binds ahead of the splice at the whole block (TM's `Editor.saveAs`)
		final files: Map<String, String> = utilWith(
			'public function new() {}\n\n\tfunction self():Void {}\n\n\tpublic function other():Void {\n'
			+ '\t\tShown.run(() -> self(), Mac.t(\'x\'));\n\t}',
			['Shown.hx' => SHOWN_RUN, 'Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-EXPANSION-SIBLING')
	public function testAnExpressionMacroAnInlinedSetterIsHandedIsItsTextUnderTheTruth(): Void {
		// the inline `apply` assigns `Mac.t(…)` to a property whose inline setter the expansion stands in for: the call of the
		// macro is in `apply`'s code, spliced at the setter's site (TM's `TextToolBase.applyTextLanguage`)
		final files: Map<String, String> = utilWith(
			'public static var text(default, set):String = \'\';\n\n\tstatic inline function set_text(v:String):String return text = v;\n\n'
			+ '\tstatic inline function apply():Void text = Mac.t(\'Type\');\n\n\tpublic static function other():Void apply();',
			['Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-EXPANSION-OUTER')
	public function testAnExpressionMacroInAWhollyInlinedInitializerIsItsTextUnderTheTruth(): Void {
		// `var label = Shown.label(Mac.t('Move'))` is wholly `label`'s body, where the expansion stands for its parameter
		// (TM's `FileDialogOperations._moveButton`)
		final shown: String = 'class Shown {\n\tpublic static inline function label(s:String):String return Words.tr(s);\n}\n';
		final files: Map<String, String> = utilWith(
			'static var L:String = Shown.label(Mac.t(\'Move\'));', ['Shown.hx' => shown, 'Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-JOINED-SITE')
	public function testAWriteOfAFieldOfAnInlinedIndexAccessIsItsTextUnderTheTruth(): Void {
		// `v[0 + j].x += (2.0 * j)`: the compiler joins the written field's range from the text's value to the inlined `get`
		// (openfl's `TextEngine.setTextAlignment`: `layoutGroups[i + j].offsetX += …`)
		final vec: String = 'class G {\n\tpublic var x:Float = 0;\n\n\tpublic function new() {}\n}\n\n'
			+ 'abstract Vec(Array<G>) {\n\tpublic inline function new(a:Array<G>) this = a;\n\n'
			+ '\t@:arrayAccess public inline function get(index:Int):G {\n\t\treturn this[index];\n\t}\n}\n';
		final files: Map<String, String> = utilWith(
			'public static function other(v:Vec, j:Int):Void {\n\t\tv[0 + j].x += (2.0 * j);\n\t\tv[0].x = 3;\n\t}', ['Vec.hx' => vec]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	public function testAReadJoinedAcrossTwoInlinedGettersIsItsTextUnderTheTruth(): Void {
		// `childCount` calls `count(children)`: the compiler joins the read of `children` from `get_children`'s code to the end
		// of what the inline `base` returned (TM's `FileSystemItemData.getChildCount` in `FolderWatcher.updateFileTimestamp`)
		final files: Map<String, String> = utilWith('public static function other(f:Fs):Int return f.childCount();', ['Fs.hx' => FS]);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-WALK-JOINED-START')
	public function testAFieldReadJoinedAcrossTwoGettersInACallbackIsItsTextUnderTheTruth(): Void {
		// in the callback, the inline `isFolderWithChild` reads `folder`, whose getter reads it off what the inline `base`
		// returns: the compiler joins the read from one getter's code to the other's, and no method's range holds it whole
		// (TM's `FileListGrid.createGridItems`: `childItemData.isFolderWithChild()` inside `itemData.forEachChild(…)`)
		final files: Map<String, String> = utilWith(
			'public static function other(f:Fs):Void f.forEachChild(c -> if (c.isFolderWithChild()) Words.say(c));',
			['Fs.hx' => FS, 'Words.hx' => WORDS_REP]
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-JOINED-OTHER-SPLICE')
	public function testAFieldReadJoinedFromAnIndexAccessToTheAccessAnotherInlinedMethodWritesIsItsTextUnderTheTruth(): Void {
		// the inline `Pa.frameOf` reads `a[0].frame` through the inline `get` of an abstract in another file: the compiler
		// joins the read from `get`'s code to `.frame` in `frameOf`'s, keeping `get`'s file for both offsets — whichever
		// comes first (TM's `ReadOnlyArray` read of `.frame` in `PitchArea.getFrameByFieldId`, `Map.get` of `.box`)
		final ro: String = 'class Fr {\n\tpublic var frame:Int = 0;\n\n\tpublic function new() {}\n}\n\n'
			+ 'abstract RoArr(Array<Fr>) from Array<Fr> {\n\t@:arrayAccess public inline function get(i:Int):Fr return this[i];\n}\n';
		function pa(padding: Int): String {
			final doc: String = [
				for (i in 0...padding) '\t * The frame of the first element of what it is handed, read off it.'
			].join('\n');
			return 'class Pa {\n' + (padding == 0 ? '' : '\t/**\n' + doc + '\n\t */\n')
				+ '\tpublic static inline function frameOf(a:Ro.RoArr):Int {\n\t\treturn a[0].frame;\n\t}\n}\n';
		}
		for (padding in [0, 8]) {
			final files: Map<String, String> = utilWith(
				'public static function other(a:Ro.RoArr):Int return Pa.frameOf(a);',
				['Ro.hx' => ro, 'Pa.hx' => pa(padding)]
			);
			assertMatch(hubAsk(files), r -> r.match(Proven));
		}
	}

	@:pin('control') @:killer('M-FACTS-WALK-WRITTEN-CONSTANT')
	public function testAnInlinedMethodWhoseBodyIsAnInlinedCallOfConstantsIsItsTextUnderTheTruth(): Void {
		// `percentLimit(v)` is `limit(v, 0, 1)`: of `percentLimit` the compiler keeps the constants alone, in `limit`'s code
		// (TM's `ScrollContainer.set_percent`)
		final files: Map<String, String> = utilWith(
			'public static function other(v:Float):Float return percentLimit(v);\n\n'
			+ '\tstatic inline function percentLimit(value:Float):Float {\n\t\treturn limit(value, 0, 1);\n\t}\n\n'
			+ '\tstatic inline function limit(value:Float, min:Float, max:Float):Float {\n\t\treturn value < min ? min : value > max ? max : value;\n\t}'
		);
		assertMatch(hubAsk(files), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-FACTS-TEXT-ALIAS-TYPEDEF')
	public function testATypedefAliasingTheTypeElsewhereIsNoneOfItsCodeUnderTheTruth(): Void {
		// tink's `typedef Any = std.Any` in another file: a typed type the name stands for, declaring no code
		final alias: String = 'package other;\n\ntypedef Holder = std.Holder;\n';
		final util: String = 'class Util {\n\tpublic static function calm(h:Holder):Int return h.q;\n\n'
			+ '\tpublic static function other(h:other.Holder):Int return h.n;\n}\n';
		final files: Map<String, String> = [
			'Main.hx' => LOOP_HEAD
				+ '\tstatic function main() {\n\t\tfor (i in 0...items.length) { /*<*/ Util.calm(new Holder()); /*>*/ }\n\t}\n}\n',
			'Util.hx' => util,
			'Holder.hx' => HOLDER,
			'other/Holder.hx' => alias,
			'Mac.hx' => BUILD_MACROS
		];
		assertMatch(hubAsk(files), r -> r.match(Proven));
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
		escape: String, thrown: String, ?more: Map<String, String>, ?build: String, ?reflective: Array<String>, ?pos: haxe.PosInfos
	): ReachResult {
		final files: Map<String, String> = escapingObj(escape);
		for (name => text in more ?? []) files[name] = text;
		return withReach(files, null, true, false, build, plainText(thrown), null, true, (reach, dir) -> {
			Assert.isTrue(reach._scope.facts?.truth == true, 'the fixture did not compile', pos);
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(files['Main.hx'] ?? '')), { owner: 'Main', name: 'items' }, Mutate);
		}, null, reflective);
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
	 * `hxmls` names one build per file among `unindexed`, each compiled as it is from its own directory, in place of `build`
	 * under `configurations`.
	 */
	private static function ask(
		files: Map<String, String>, ?configurations: Array<Array<String>>, withFacts: Bool = true, ?member: MemberRef,
		classpathComplete: Bool = false, ?build: String, ?library: Map<String, String>, ?unindexed: Map<String, String>,
		listed: Bool = false, ?declared: Map<String, String>, ?holders: Array<String>, ?hxmls: Array<String>
	): ReachResult {
		return withReach(files, configurations, withFacts, classpathComplete, build, library, unindexed, listed, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(source)), member ?? { owner: 'Main', name: 'items' }, Mutate);
		}, declared, null, holders, hxmls);
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

	/** `truthAsk` of `files`, which must compile: a build that fails leaves no facts, and the syntax would answer. */
	private static function compiledTruthAsk(files: Map<String, String>, ?pos: haxe.PosInfos): ReachResult {
		final result: ReachResult = truthAsk(files);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile: ${files['Main.hx']}', pos);
		return result;
	}

	/**
	 * `Main.hx` whose region runs `region` — by default `r.map(x -> "a")` — on `r`, an `Rx`, while `Main.keep`, of the type
	 * `type`, holds the callback `stored`, never called; `more` statements run first in `main`. `Rx` extends `base` (a `Base`
	 * declaring nothing, by default), and declares `map` (calling the `(Rx)->String` it is handed, by default).
	 */
	private static function valueCallFixture(
		type: String, stored: String, more: String, ?region: String, ?base: String, ?map: String
	): String {
		return 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n\tpublic static var keep:Null<' + type + '> = null;\n\n'
			+ '\tstatic function main() {\n\t\tkeep = ' + stored + ';\n' + more + '\t\tfinal r:Rx = new Rx();\n'
			+ '\t\tfor (i in 0...items.length) { /*<*/ ' + (region ?? 'r.map(x -> "a");') + ' /*>*/ }\n\t}\n}\n'
			+ (base ?? 'class Base {\n\tpublic function new() {}\n}\n') + 'class Rx extends Base {\n\tpublic function new() super();\n\n\t'
			+ (map ?? 'public function map(f:(Rx)->String):String return f(this);') + '\n}\n';
	}

	/** `truthAsk` of `files` built by `INTERP_BUILD`, which must compile, the library declarations `declared` indexed. */
	private static function interpAsk(
		files: Map<String, String>, ?declared: Map<String, String>, ?holders: Array<String>, ?pos: haxe.PosInfos
	): ReachResult {
		return builtAsk(INTERP_BUILD, files, declared, holders, pos);
	}

	/** `truthAsk` of `files` built by `build`, which must compile, the library declarations `declared` indexed. */
	private static function builtAsk(
		build: String, files: Map<String, String>, ?declared: Map<String, String>, ?holders: Array<String>, ?pos: haxe.PosInfos
	): ReachResult {
		final result: ReachResult = ask(files, null, true, null, false, build, null, null, true, declared, holders);
		Assert.equals('', lastDropped.join('; '), 'the fixture did not compile', pos);
		return result;
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
		question: (MemberReach, String) -> T, ?declared: Map<String, String>, ?reflective: Array<String>, ?holders: Array<String>,
		?hxmls: Array<String>
	): T {
		final entries: Array<{ name: String, source: String }> = [for (name => text in files) { name: name, source: text }];
		for (name => text in library ?? []) entries.push({ name: name, source: text });
		for (name => text in unindexed ?? []) entries.push({ name: name, source: text });
		entries.push({ name: 'build.hxml', source: build ?? BUILD });
		final dir: String = CliFixture.writeTree('reach_facts', entries);
		final oracles: Array<OracleConfig> =
			hxmls == null ? [for (d in configurations ?? [[]]) { hxml: 'build.hxml', dir: dir, defines: d }] : [
				for (h in hxmls)
					{
						hxml: Path.withoutDirectory(h),
						dir: Path.directory(h) == '' ? dir : Path.join([dir, Path.directory(h)]),
						defines: []
					}
			];
		final facts: Null<CompilerFacts> = withFacts ? TypedFactsProbe.probeAll(oracles) : null;
		lastDropped = facts == null ? [] : [for (d in facts.dropped) '${d.name}: ${d.reason}'];
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
			plugin, project, index, true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED, builds, () -> classpathComplete, facts,
			reflective, holders
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
