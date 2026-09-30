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

	/** The library declaration of the built-in array type the index resolves against. */
	private static inline final STD_ARRAY: String = 'extern class Array<T> { public var length(default, null):Int; '
		+ 'public function push(x:T):Int; public function pop():Null<T>; public function indexOf(x:T, ?fromIndex:Int):Int; }';

	private static inline final REGION_OPEN: String = '/*<*/';
	private static inline final REGION_CLOSE: String = '/*>*/';

	/** A loop in `Main.main` whose body is the region, over the static `Main.items`. */
	private static inline final LOOP_HEAD: String = 'class Main {\n\tpublic static var items:Array<Int> = [1, 2];\n';

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

	@:pin('control') @:killer('M-FACTS-TRUTH-CONTEXT')
	public function testATypeInAFileImportingUnderAConditionIsReadFromTheListedBuilds(): Void {
		// `b.T` has no conversion to run, until a listed build defines `other` and the call converts to `a.T`
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
		// `g` is declared twice, one declaration per branch: the graph folds the two into one node, which no single body's
		// facts describe, so `g` is read by its syntax and its untyped expression stays a blind spot however whole the list
		final main: String = MEMBER_HEAD + '\tfunction f():Void {\n\t\tfor (i in 0...items.length) { /*<*/ g(); /*>*/ }\n\t}\n'
			+ '#if !other\n\tfunction g():Void {\n\t\tvar z = untyped this.zz;\n\t}\n#else\n\tfunction g():Void {}\n#end\n}\n';
		assertMatch(truthAsk(['Main.hx' => main]), r -> r.match(Unknown(Untyped(_, _))));
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
		// the escapes over the project answer — a file no build compiles, which the graph does not hold, is none of it
		final main: String = MEMBER_HEAD + '\tfunction f(o:Other):Void {\n\t\tfor (i in 0...items.length) { /*<*/ Poker.poke(o); /*>*/ }\n'
			+ '\t}\n}\nclass Other {\n\tpublic var items:Array<Int> = [];\n\tpublic function new() {}\n}\n'
			+ 'class Poker {\n\tpublic static function poke(o:Other):Void o.items.push(9);\n}\n';
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

	/**
	 * The answer for `member` (by default `Main.items`) over the region of `Main.hx` among `files`, compiled by `build` under
	 * each define set of `configurations` and read through the facts unless `withFacts` is false; `classpathComplete` is
	 * the analysis's word that the index holds every type the builds compile. `library` files compile beside
	 * them and are indexed, but are no part of the project: the walk reads one only when it follows code into it.
	 * `unindexed` files are written and compiled but indexed by nothing — code only the compiler sees. `listed` hands the
	 * analysis the builds as the whole list of them — one per define set, as a run probes them (`ReachDefinesProbe`).
	 */
	private static function ask(
		files: Map<String, String>, ?configurations: Array<Array<String>>, withFacts: Bool = true, ?member: MemberRef,
		classpathComplete: Bool = false, ?build: String, ?library: Map<String, String>, ?unindexed: Map<String, String>,
		listed: Bool = false
	): ReachResult {
		return withReach(files, configurations, withFacts, classpathComplete, build, library, unindexed, listed, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			reach.mayReach(Region(Path.join([dir, 'Main.hx']), regionOf(source)), member ?? { owner: 'Main', name: 'items' }, Mutate);
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
		files: Map<String, String>, name: String, withFacts: Bool = true, classpathComplete: Bool = false, ?unindexed: Map<String, String>
	): ReachResult {
		return withReach(files, null, withFacts, classpathComplete, null, null, unindexed, !classpathComplete, (reach, dir) -> {
			final source: String = files['Main.hx'] ?? '';
			final at: Int = source.lastIndexOf(name, source.indexOf(REGION_CLOSE));
			reach.mayMutateNamed(Path.join([dir, 'Main.hx']), name, new Span(at, at + name.length), regionOf(source));
		});
	}

	/** The fixture of `ask` written, compiled and indexed, `question` asked of its analysis, and the fixture removed. */
	private static function withReach<T>(
		files: Map<String, String>, configurations: Null<Array<Array<String>>>, withFacts: Bool, classpathComplete: Bool,
		build: Null<String>, library: Null<Map<String, String>>, unindexed: Null<Map<String, String>>, listed: Bool,
		question: (MemberReach, String) -> T
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
		final index: SymbolIndex = SymbolIndex.build(
			project.concat(libraries).concat([{ file: 'std/Array.hx', source: STD_ARRAY }]), plugin
		);
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
