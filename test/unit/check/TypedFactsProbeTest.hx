package unit.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.TypedFactsProbe;
import anyparse.query.CompilerFacts;
import anyparse.runtime.Span;
import haxe.io.Path;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `TypedFactsProbe` over real compiles: what the compiler puts in the typed tree once typing ended, as the facts
 * record it, and the table's union, absence and position semantics.
 */
@:nullSafety(Strict)
class TypedFactsProbeTest extends Test {

	/** The build every fixture compiles: a js target, so `js.Syntax` resolves. */
	private static inline final BUILD: String = '-cp .\n-main Main\n--js out.js\n';

	@:pin('control') @:killer('M-FACTS-CALL-TARGET')
	public function testAbstractOperatorsConversionsAndAccessorsAreCallsOfTheirImplementations(): Void {
		// `@:op`, `@:from`, `@:to` and a property are no syntax of their own in the typed tree: each is a static call on the
		// abstract's implementation class, or a call of the accessor
		final scratch: Scratch = compile([
			'Main.hx' => 'abstract Money(Int) from Int to Int {\n'
			+ '\t@:op(A + B) public function add(o:Money):Money return (this + (o:Int) : Money);\n'
			+ '\t@:from static function ofString(s:String):Money return (s.length : Money);\n'
			+ '\t@:to function show():String return "m" + this;\n' + '\tpublic var cents(get, never):Int;\n'
			+ '\tfunction get_cents():Int return this * 100;\n}\n' + 'class Prop { public function new() {}\n'
			+ '\tpublic var p(get, set):Int; var q:Int = 0;\n'
			+ '\tfunction get_p():Int return q; function set_p(v:Int):Int return q = v; }\n' + 'class Main { static function main() {\n'
			+ '\tvar a:Money = 1; var b:Money = a + a; var m:Money = "xy"; var s:String = a;\n'
			+ '\tvar c = b.cents; var o = new Prop(); o.p = o.p + 1;\n} }\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			final targets: Array<Null<String>> = [for (c in main.calls) c.target];
			for (expected in [
				'_Main.Money_Impl_.add',
				'_Main.Money_Impl_.ofString',
				'_Main.Money_Impl_.show',
				'_Main.Money_Impl_.get_cents',
				'Prop.get_p',
				'Prop.set_p'
			]) Assert.isTrue(targets.contains(expected), '$expected is no call target: $targets');
			Assert.isFalse(main.fields.exists(f -> f.field == 'p'), 'a property access was recorded as a field access');
		}
		Assert.equals('impl', scratch.facts?.type('_Main.Money_Impl_')?.kind);
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-INLINE-POSITIONS') @:killer('M-FACTS-SAME-FILE-INLINE')
	public function testAnInlineCallIsNoCallSiteAndItsBodyKeepsTheCalleesPositions(): Void {
		// the compiler inlines before the hook runs: the call is gone from the caller, whose facts now hold the body — at
		// the callee's own ranges, so none of them reads as the type of the call site; the callee keeps a node of its own
		final source: String = 'class Main {\n\tstatic inline function size(a:Array<Int>):Int return a.length;\n'
			+ '\tstatic function main() { var t = size([1]); }\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final file: String = scratch.path('Main.hx');
		Assert.notNull(facts?.node('Main.size'));
		// no call of the function is left, only the call fact of its spliced body
		Assert.isFalse(
			facts?.node('Main.main')?.calls.exists(c -> c.target == 'Main.size' && c.access != 'inlined') ?? true,
			'the inline call survived'
		);
		Assert.isTrue(
			facts?.node('Main.main')?.calls.exists(c -> c.target == 'Main.size' && c.access == 'inlined') ?? false, 'no inlined call'
		);
		final body: Int = source.indexOf('a.length');
		final inlined: Null<FieldFact> = facts?.node('Main.main')?.fields.find(f -> f.field == 'length');
		Assert.equals(body, inlined?.at.span.from);
		final call: Int = source.indexOf('size([1])');
		Assert.equals(0, facts?.callsAt(file, new Span(call, call + 'size([1])'.length)).length);
		Assert.equals('inline', facts?.type('Main')?.fields.find(f -> f.name == 'size')?.kind);
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-ABSTRACT-THIS')
	public function testARangeMeetingTheBodyIsItsOwnCode(): Void {
		// in the std `CallStack.subtract` an operand shares one range with the inlined `length` getter beside it, a range
		// that starts outside the method's body and ends inside it: the body's own code, not a macro expansion
		final scratch: Scratch = compile([
			'Main.hx' => 'class Main {\n\tstatic function main() { var s:haxe.CallStack = haxe.CallStack.callStack(); s.subtract(s); }\n}\n'
		], null, '-cp .\n-main Main\n--interp\n');
		final subtract: Null<FactNode> = scratch.facts?.node('haxe._CallStack.CallStack_Impl_.subtract');
		Assert.notNull(subtract, 'dropped: ${[for (d in scratch.facts?.dropped ?? []) d.reason]}');
		Assert.isFalse(subtract?.incomplete.contains('macro-expansion') ?? true, 'marks: ${subtract?.incomplete}');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-CALL-SITE-INLINE')
	public function testACallSiteInlineIsASpliceOfItsMethodNotAMacro(): Void {
		// `inline f()` splices a method that is not `inline` itself: it is the method's body, named, not an expansion
		final scratch: Scratch = compile([
			'Main.hx' => 'class Main {\n\tstatic function grow(a:Array<Int>):Void a.push(1);\n'
			+ '\tstatic function main() { var a = [1]; inline grow(a); }\n}\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		Assert.isTrue(main?.incomplete.contains('inline-site-unknown') ?? false, 'no splice: ${main?.incomplete}');
		Assert.isFalse(main?.incomplete.contains('macro-expansion') ?? true, 'a call-site inline read as a macro expansion');
		Assert.isTrue(main?.calls.exists(c -> c.access == 'inlined' && c.target == 'Main.grow') ?? false, 'no inlined call of the method');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-SUPER') @:killer('M-FACTS-INITIALIZER')
	public function testAnImplicitConstructorCallsSuperAndAnInitializerIsANode(): Void {
		// a class that declares no constructor still gets one, calling its super's; a field initializer is typed as the
		// field's own expression, not folded into the constructor
		final scratch: Scratch = compile([
			'Main.hx' => 'class Base { public function new(x:Int) {} }\n' + 'class Kid extends Base { var list:Array<Int> = [1, 2]; }\n'
			+ '@:structInit class Rec { public var a:Int; public var b:String = "x"; }\n'
			+ 'class Main { static function main() { new Kid(3); var r:Rec = { a: 1 }; } }\n'
		]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final ctor: Null<FactNode> = facts?.node('Kid.new');
		Assert.notNull(ctor);
		Assert.isTrue(ctor?.calls.exists(c -> c.access == 'super' && c.target == 'Base.new') ?? false, 'no implicit super call');
		Assert.equals('var', facts?.node('Kid.list')?.kind);
		Assert.isTrue(
			facts?.node('Rec.new')?.fields.exists(f -> f.field == 'a' && f.write) ?? false, 'the structInit constructor writes no field'
		);
		Assert.isTrue(facts?.node('Main.main')?.news.exists(n -> n.type == 'Rec') ?? false, 'a structInit literal is no `new`');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-ITER') @:killer('M-FACTS-STRING-OPERAND') @:killer('M-FACTS-TYPE-TEXT')
	public function testLoopsAndStringConversions(): Void {
		// an Iterable loop stays a `for`; an Array loop is lowered to a `while` and leaves none. A non-String operand of
		// `+` is recorded with its type — a basic one stays an operand, a class instance goes through `Std.string`
		final source: String = 'class Main { static function main() {\n' + '\tvar arr = [1, 2]; for (x in arr) trace(x);\n'
			+ '\tvar it:Iterable<String> = ["a"]; for (y in it) trace(y);\n' + '\tvar s = "n=" + arr.length + " m=" + new Main();\n'
			+ '\tvar t = "q"; t += 1.5;\n} function new() {} }\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		// the lowered loop reads `arr.length` at the whole `for`: that fact is the compiler's, not the loop's type
		final loop: Int = source.indexOf('for (x in arr) trace(x)');
		Assert.isNull(scratch.facts?.typeOfExpressionAt(scratch.path('Main.hx'), new Span(loop, loop + 'for (x in arr) trace(x)'.length)));
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			Assert.equals(1, main.iterations.length);
			Assert.equals('String', main.iterations[0]?.binder);
			Assert.equals('Iterator<String>', main.iterations[0]?.iterated);
			final operands: Array<String> = [for (s in main.strings) s.operand];
			Assert.isTrue(operands.contains('Int') && operands.contains('Float'), 'operands: $operands');
			Assert.isTrue(main.calls.exists(c -> c.target == 'Std.string'), 'an instance operand is not converted by Std.string');
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-LOCAL-CALL') @:killer('M-FACTS-FIELD-WRITE')
	public function testEveryCallAndFieldAccessKind(): Void {
		final scratch: Scratch = compile([
			'Main.hx' => 'enum E { A; B(x:Int); }\n' + 'class P { public function new() {} public var v:Int = 0;\n'
			+ '\tpublic dynamic function dyn(a:Int):Int return a; public function m():Int return 1; }\n'
			+ 'class Main { static function main() {\n' + '\tvar p = new P(); p.dyn(1); var clo = p.m; p.v = 2; p.v++;\n'
			+ '\tfunction local(y:Int) return y + 1; local(2);\n' + '\tvar lam = (z:Int) -> z * 2; var f:Int->Int = lam; f(3);\n'
			+ '\tvar e = B(3); var e2 = A; var d:Dynamic = p; d.foo(1); var an = { q: 1 }; an.q;\n} }\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			final walked: FactNode = main;
			function call(access: String, target: Null<String>): Bool {
				return walked.calls.exists(c -> c.access == access && c.target == target);
			}
			// a dynamic method calls whatever the field holds, not its declared body
			Assert.isTrue(call('fieldValue', 'P.dyn'), 'a dynamic method call');
			Assert.isTrue(call('FDynamic', 'foo'), 'a Dynamic call');
			Assert.isTrue(call('FEnum', 'E.B'), 'an enum constructor call');
			Assert.isTrue(
				main.calls.exists(c -> c.access == 'local' && StringTools.startsWith(c.target ?? '', 'Main.main@')),
				'a local function call'
			);
			Assert.isTrue(main.calls.exists(c -> c.access == 'value' && c.receiver == '(Int)->Int'), 'a call of a function value');
			Assert.isTrue(main.fields.exists(f -> f.access == 'FClosure' && f.field == 'm'), 'a method closure');
			Assert.isTrue(main.fields.exists(f -> f.access == 'FEnum' && f.field == 'A'), 'an enum value');
			Assert.isTrue(main.fields.exists(f -> f.access == 'FAnon' && f.field == 'q'), 'a structure field');
			Assert.equals(2, main.fields.filter(f -> f.field == 'v' && f.write).length);
			Assert.equals(2, main.fns.length);
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-REFLECT-NAME') @:killer('M-FACTS-NATIVE')
	public function testReflectionAndNativeSites(): Void {
		// `untyped` leaves no mark in the typed tree: an untyped field access is a Dynamic one
		final scratch: Scratch = compile([
			'Main.hx' => 'class Main { function new() {} static function main() {\n' + '\tvar m = new Main(); Reflect.field(m, "x");\n'
			+ '\tvar n = "y" + Std.random(2); Reflect.field(m, n); Type.createInstance(Main, []);\n'
			+ '\tjs.Syntax.code("1"); var u = untyped m.zz;\n} }\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			Assert.isTrue(main.reflection.exists(r -> r.target == 'Reflect.field' && r.name == 'x'), 'a literal reflected name');
			Assert.isTrue(main.reflection.exists(r -> r.target == 'Reflect.field' && r.name == null), 'a computed reflected name');
			Assert.isTrue(main.reflection.exists(r -> r.target == 'Type.createInstance' && r.typeArgument == 'Main'), 'a reflected type');
			Assert.isTrue(main.natives.exists(n -> n.kind == 'syntax' && n.name == 'js.Syntax.code'), 'a Syntax.code site');
			Assert.isTrue(main.fields.exists(f -> f.access == 'FDynamic' && f.field == 'zz'), 'an untyped access');
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-FLOW-CAST') @:killer('M-FACTS-TYPE-PARAMETER')
	public function testFlowsIntoOtherTypes(): Void {
		final scratch: Scratch = compile([
			'Main.hx' => 'class Box<T> { public var v:T; public function new(v:T) this.v = v; }\n'
			+ 'class Main { function new() {} static function main() {\n' + '\tvar m = new Main(); var a:Any = m; var d:Dynamic = m;\n'
			+ '\tvar back:Main = cast d; var list:Array<Any> = [m, 1]; var b = new Box(m);\n} }\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			final walked: FactNode = main;
			function flow(from: String, to: String, via: String): Bool {
				return walked.flows.exists(f -> f.from == from && f.to == to && f.via == via);
			}
			Assert.isTrue(flow('Main', 'Any', 'var'), 'a value into Any');
			Assert.isTrue(flow('Dynamic', 'Main', 'cast'), 'an unchecked cast');
			Assert.isTrue(flow('Main', 'Any', 'arr'), 'an array element');
			Assert.isTrue(main.news.exists(n -> n.type == 'Box' && n.instance == 'Box<Main>'), 'a generic instance');
		}
		final whole: Span = new Span(0, File.getContent(scratch.path('Main.hx')).length);
		Assert.isTrue(
			(scratch.facts?.flowsIn(scratch.path('Main.hx'), whole) ?? []).exists(f -> f.via == 'cast'), 'no cast flow in the file'
		);
		Assert.equals("$Box.T", scratch.facts?.type('Box')?.fields.find(f -> f.name == 'v')?.type);
		scratch.remove();
	}

	@:pin('control') @:killer('M-CODEPOINT-NATIVE') @:killer('M-FACTS-READS')
	public function testPositionsAreSpanUnitsPastNonAsciiText(): Void {
		// the compiler counts codepoints, a Span counts the target's string units: an emoji before a site is two units
		final source: String = 'class Main {\n\t// Привет 😀😀 мир\n\tstatic var s = "ёж😀";\n'
			+ '\tstatic function main() { foo(1); }\n\tstatic function foo(x:Int):Int return x;\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final file: String = scratch.path('Main.hx');
		final from: Int = source.indexOf('foo(1)');
		final at: Span = new Span(from, from + 'foo(1)'.length);
		final calls: Array<CallFact> = scratch.facts?.callsAt(file, at) ?? [];
		Assert.equals(1, calls.length);
		Assert.equals('Main.foo', calls[0]?.target);
		Assert.equals('Main.main', scratch.facts?.nodeAt(file, at)?.id);
		Assert.equals('Int', scratch.facts?.typeOfExpressionAt(file, at));
		// a local's read carries its type at the identifier
		final read: Int = source.indexOf('return x') + 'return '.length;
		Assert.equals('Int', scratch.facts?.typeOfExpressionAt(file, new Span(read, read + 1)));
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-UNION')
	public function testTheTableIsTheUnionOfTheConfigurations(): Void {
		// a member and a call only one configuration compiles are in the table; a site both type differently keeps both
		final scratch: Scratch = compile([
			'Main.hx' => 'class Main { static function main() {\n' + '\t#if APQ_A only(); #end\n'
			+ '\tvar v = #if APQ_A 1 #else "s" #end;\n' + '}\n#if APQ_A static function only() {} #end\n}\n'
		], [[], ['APQ_A']]);
		final facts: Null<CompilerFacts> = scratch.facts;
		Assert.equals(2, facts?.configurations.length);
		Assert.notNull(facts?.node('Main.only'));
		Assert.isTrue(facts?.node('Main.main')?.calls.exists(c -> c.target == 'Main.only') ?? false, 'a call one configuration compiles');
		final types: Array<String> = [for (v in facts?.node('Main.main')?.vars ?? []) if (v.name == 'v') v.type];
		Assert.isTrue(types.contains('Int') && types.contains('String'), 'types: $types');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-ABSENT')
	public function testCodeNoConfigurationCompiledIsAbsent(): Void {
		// absence is "no facts": a file the build never reached, and a branch every configuration left out, both answer
		// nothing — while the code is there
		final source: String = 'class Main { static function main() {\n\t#if APQ_NEVER gone(); #end\n\tkept();\n}\n'
			+ 'static function kept() {} static function gone() {} }\n';
		final scratch: Scratch = compile(['Main.hx' => source, 'Unused.hx' => 'class Unused { static function f() {} }\n']);
		final facts: Null<CompilerFacts> = scratch.facts;
		final file: String = scratch.path('Main.hx');
		final gone: Int = source.indexOf('gone()');
		final kept: Int = source.indexOf('kept()');
		Assert.equals(0, facts?.callsAt(file, new Span(gone, gone + 6)).length);
		Assert.equals(1, facts?.callsAt(file, new Span(kept, kept + 6)).length);
		Assert.isFalse(facts?.compiled(scratch.path('Unused.hx')) ?? true, 'a file no configuration reached has facts');
		Assert.isNull(facts?.nodeAt(scratch.path('Unused.hx'), new Span(0, 1)));
		Assert.isNull(facts?.node('Unused.f'));
		Assert.equals(0, facts?.nodesIn(scratch.path('Unused.hx')).length);
		Assert.isTrue(facts?.nodesIn(file).exists(n -> n.id == 'Main.kept') ?? false, 'a compiled member has no node');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-HIERARCHY')
	public function testHierarchyIsPackageQualifiedOverTheWholeTypedSet(): Void {
		final scratch: Scratch = compile([
			'a/Base.hx' => 'package a;\nclass Base { public function new() {} }\n',
			'b/Base.hx' => 'package b;\ninterface Base {}\n',
			'Main.hx' => 'class Mid<T> extends a.Base { }\nclass Leaf extends Mid<Int> implements b.Base { public function new() super(); }\n'
			+ 'class Main { static function main() { new Leaf(); } }\n'
		]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final down: Array<String> = facts?.subtypesOf('a.Base') ?? [];
		down.sort(Reflect.compare);
		Assert.same(['Leaf', 'Mid'], down);
		Assert.same(['Leaf'], facts?.subtypesOf('b.Base'));
		final up: Array<String> = facts?.supertypesOf('Leaf') ?? [];
		up.sort(Reflect.compare);
		Assert.same(['Mid', 'a.Base', 'b.Base'], up);
		Assert.equals('Mid<Int>', facts?.type('Leaf')?.superClass);
		final declared: Null<FactPos> = facts?.typePosition('Leaf');
		final main: String = File.getContent(scratch.path('Main.hx'));
		Assert.equals(main.indexOf('class Leaf'), declared?.span.from);
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-BRANCH-LEAVES') @:killer('M-FACTS-MONO-SINK') @:killer('M-FACTS-CAST-ALWAYS')
	@:killer('M-FACTS-THROW') @:killer('M-FACTS-UNTYPED-ARGS') @:killer('M-FACTS-REST')
	public function testEveryValueChannelIntoAnotherTypeIsAFlow(): Void {
		// a branch's value reaches the place at the branch's own type, not at what the branches unify to; a place of no type
		// is Dynamic; an unchecked cast always names its source; a thrown value, a native call's argument and each rest
		// argument reach a place of their own
		final source: String = 'class Obj { public function new() {} }\nclass Sub extends Obj { public function new() super(); }\n'
			+ 'class Main {\n\tstatic function rest(...xs:Obj):Void {}\n\tstatic function main() {\n'
			+ '\t\tvar o = new Obj(); var r = Std.random(3);\n' + '\t\tvar t:Dynamic = r > 0 ? o : null;\n'
			+ '\t\tvar w:Dynamic = switch r { case 0: o; case _: null; };\n' + '\t\tvar b:Dynamic = { r++; o; };\n'
			+ '\t\tvar same:Obj = cast o; var u = cast o;\n' + '\t\ttrace(o);\n' + '\t\trest(new Sub(), new Sub());\n'
			+ '\t\tif (r > 100) throw o;\n\t}\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		final flows: Array<FlowFact> = main?.flows ?? [];
		function at(text: String, nth: Int = 0): Int {
			var from: Int = -1;
			for (_ in 0...nth + 1) from = source.indexOf(text, from + 1);
			return from;
		}
		function flowAt(from: String, to: String, via: String, offset: Int): Bool {
			return flows.exists(f -> f.from == from && f.to == to && f.via == via && f.at.span.from == offset);
		}
		Assert.isTrue(flowAt('Obj', 'Dynamic', 'var', at('o : null')), 'the ternary branch');
		Assert.isTrue(flowAt('Obj', 'Dynamic', 'var', at('o; case')), 'the switch case');
		Assert.isTrue(flowAt('Obj', 'Dynamic', 'var', at('o; };')), 'the block value');
		Assert.isTrue(flows.exists(f -> f.via == 'cast' && f.from == 'Obj' && f.to == 'Obj'), 'an unchecked cast to its own type');
		Assert.isTrue(flows.exists(f -> f.via == 'var' && f.to == 'Dynamic' && f.at.span.from == at('var u')), 'a place of no type');
		Assert.isTrue(flowAt('Obj', 'Dynamic', 'arg', at('o);')), 'a native call argument');
		Assert.equals(2, flows.filter(f -> f.from == 'Sub' && f.to == 'Obj' && f.via == 'arg').length);
		Assert.isTrue(flows.exists(f -> f.from == 'Obj' && f.via == 'throw'), 'a thrown value');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-GENERIC') @:killer('M-FACTS-INIT') @:killer('M-FACTS-REASSIGNED-LOCAL')
	@:killer('M-FACTS-FIELD-VALUE') @:killer('M-FACTS-REFLECTION-INLINED') @:killer('M-FACTS-REFLECT-VALUE')
	@:killer('M-FACTS-UNTYPED-DECLARED') @:killer('M-FACTS-IDENT-READ') @:killer('M-FACTS-GENERIC-RANGES') @:killer('M-FACTS-BUILDS')
	public function testGenericInstancesInitAndCallsThatNameNoFixedBody(): Void {
		// a `@:generic` instance and `__init__` are code of their own; a local assigned again, a function-typed field and a
		// dynamic method call whatever they hold; an inlined `Reflect` call leaves only a mark, a reflection member or class
		// read as a value is reflection, a value `untyped` retyped keeps its declared type, and a native identifier is a site
		final source: String = '@:generic class Gen<T> { public function new() {} public function g(t:T):T { Main.hook(3); return t; } }\n'
			+ 'class Main {\n\tstatic var stored:Void->Void;\n\tstatic function __init__() { hook(99); }\n'
			+ '\tpublic static function hook(i:Int):Int return i;\n\tstatic function fclos():Void {}\n'
			+ '\tstatic function main() {\n\t\tnew Gen<String>().g("x");\n' + '\t\tvar f = () -> 1; f = () -> 2; f();\n'
			+ '\t\tvar g:Dynamic = () -> 3;\n' + '\t\tstored = fclos; stored();\n' + '\t\tReflect.callMethod(null, fclos, []);\n'
			+ '\t\tfinal rf = Reflect.field; var r = Reflect;\n' + '\t\tvar m:Main = null; var y = untyped m; y.zz();\n'
			+ '\t\tvar w = untyped window;\n\t}\n}\n' + '@:build(Build.build()) class Built {}\n';
		final build: String = 'class Build { public static macro function build():Array<haxe.macro.Expr.Field> '
			+ 'return haxe.macro.Context.getBuildFields(); }\n';
		final scratch: Scratch = compile(['Main.hx' => source, 'Build.hx' => build]);
		final facts: Null<CompilerFacts> = scratch.facts;
		Assert.equals('Gen<String>', facts?.type('Gen_String')?.genericOf);
		Assert.isTrue(facts?.node('Gen_String.g')?.calls.exists(c -> c.target == 'Main.hook') ?? false, 'the generic instance body');
		Assert.isTrue(facts?.node('Main.__init__')?.calls.exists(c -> c.target == 'Main.hook') ?? false, 'the __init__ body');
		final main: Null<FactNode> = facts?.node('Main.main');
		Assert.isFalse(main?.calls.exists(c -> c.access == 'local') ?? true, 'a reassigned local was read as one fixed function');
		Assert.isTrue(
			main?.flows.exists(f -> f.via == 'var' && f.to == 'Dynamic' && f.from == '()->Int') ?? false, 'a function into Dynamic'
		);
		Assert.isTrue(main?.calls.exists(c -> c.access == 'fieldValue' && c.target == 'Main.stored') ?? false, 'a call of a field value');
		Assert.isTrue(main?.incomplete.contains('reflection-inlined') ?? false, 'an inlined Reflect call left no mark');
		final values: Array<String> = [for (r in main?.reflection ?? []) if (r.isValue) r.target];
		Assert.isTrue(values.contains('Reflect.field') && values.contains('Reflect'), 'values: $values');
		Assert.isTrue(main?.flows.exists(f -> f.via == 'var' && f.from == 'Main') ?? false, 'an untyped value lost its declared type');
		Assert.isTrue(main?.natives.exists(n -> n.kind == 'ident' && n.name == 'window') ?? false, 'a native identifier read');
		Assert.isFalse(
			facts?.nodesIn(scratch.path('Main.hx')).exists(n -> n.id == 'Gen_String.g') ?? true, 'a generic copy claims a range'
		);
		Assert.same(['Build.build()'], facts?.type('Built')?.builds);
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-OVERLOADS')
	public function testEveryOverloadIsANodeAndACallNamesTheOneItChose(): Void {
		// an overload body compiles on a target that has them: each is a node, and a call names the signature it chose
		final source: String = 'class Main {\n\toverload static function ov(i:Int):Void {}\n\toverload static function ov(s:String):Void {}\n'
			+ '\tstatic function main() { ov(1); ov("x"); }\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source], null, '-cp .\n-main Main\n--jvm out.jar\n');
		final facts: Null<CompilerFacts> = scratch.facts;
		Assert.equals(1, facts?.node('Main.ov~1')?.overloadIndex, 'dropped: ${[for (d in facts?.dropped ?? []) d.reason]}');
		final chosen: Array<Null<String>> = [
			for (c in facts?.node('Main.main')?.calls ?? []) if (c.target == 'Main.ov') c.signature
		];
		Assert.isTrue(chosen.contains('(Int)->Void') && chosen.contains('(String)->Void'), 'chosen: $chosen');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-INLINED-CALL') @:killer('M-FACTS-INLINED-CHILD') @:killer('M-FACTS-GENERATED')
	@:killer('M-FACTS-SITE-UNKNOWN') @:killer('M-FACTS-MACRO-EXPANSION') @:killer('M-FACTS-SPLICE-OWN-ARGUMENTS')
	public function testSplicedCodeIsTheCallersAndItsSiteIsUnknown(): Void {
		// an inlined body — from another file or this one — is a call of its inline function and the caller's facts, but the
		// compiler keeps no range for the site it replaced: a range query short of the whole caller is Unknown. A function
		// in it runs in the caller and is found by id; a macro-built field's body is found by id too, as is a macro
		// expansion's, which leaves a mark of its own
		final main: String = 'class Main {\n\tpublic static function hook(i:Int):Int return i;\n'
			+ '\tstatic inline function same():Void { var g = function() { hook(10); }; g(); }\n'
			+ '\tstatic function main() {\n\t\tLib.wrap(1);\n\t\tvar d = Lib.deferred();\n\t\tsame();\n\t\tTarget.generated();\n'
			+ '\t\tBuild.mac(3);\n\t}\n}\n@:build(Build.build()) class Target {}\n';
		final lib: String = 'class Lib {\n\tpublic static inline function wrap(i:Int):Int return Main.hook(i);\n'
			+ '\tpublic static inline function deferred():Void->Int return () -> Main.hook(2);\n}\n';
		final build: String = 'import haxe.macro.Context;\nimport haxe.macro.Expr;\nclass Build {\n'
			+ '\tpublic static macro function build():Array<Field> {\n'
			+ '\t\tfinal fields = Context.getBuildFields();\n\t\tfields.push({ name: "generated", access: [APublic, AStatic], '
			+ 'pos: Context.currentPos(), kind: FFun({ args: [], ret: macro :Void, expr: macro { Main.hook(7); } }) });\n'
			+ '\t\treturn fields;\n\t}\n\tpublic static macro function mac(e:Expr):Expr return macro Main.hook($$e);\n}\n';
		final scratch: Scratch = compile(['Main.hx' => main, 'Lib.hx' => lib, 'Build.hx' => build]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final file: String = scratch.path('Main.hx');
		final node: Null<FactNode> = facts?.node('Main.main');
		final inlined: Array<Null<String>> = [for (c in node?.calls ?? []) if (c.access == 'inlined') c.target];
		Assert.isTrue(inlined.contains('Lib.wrap') && inlined.contains('Main.same'), 'inlined: $inlined');
		Assert.isTrue(node?.incomplete.contains('inline-site-unknown') ?? false, 'the splice left no mark');
		Assert.isTrue(node?.incomplete.contains('macro-expansion') ?? false, 'the macro expansion left no mark');
		final call: Int = main.indexOf('Lib.wrap(1)');
		Assert.isNull(facts?.callsIn(file, new Span(call, call + 'Lib.wrap(1)'.length)), 'a range short of the caller answered');
		final whole: Null<FactPos> = node?.at;
		final all: Array<CallFact> = whole == null ? [] : facts?.callsIn(file, whole.span) ?? [];
		Assert.isTrue(all.exists(c -> c.target == 'Main.hook'), 'the whole caller does not hold the spliced call');
		final spliced: Array<String> = [for (id in node?.fns ?? []) if (facts?.node(id)?.inlinedFrom == 'Main.main') id];
		Assert.equals(2, spliced.length);
		for (name in ['Main.hx', 'Lib.hx'])
			Assert.isFalse(
				facts?.nodesIn(scratch.path(name)).exists(n -> n.inlinedFrom != null) ?? true, 'a spliced function claims $name'
			);
		Assert.isTrue(facts?.node('Target.generated')?.generated ?? false, 'the generated body is not marked');
		Assert.isFalse(
			facts?.nodesIn(scratch.path('Build.hx')).exists(n -> n.id == 'Target.generated') ?? true,
			'a generated body claims the macro file'
		);
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-STALE-SOURCE') @:killer('M-FACTS-INVALIDATE') @:killer('M-FACTS-VARIANT-RANGES')
	public function testFactsOfAnotherTextAreAbsent(): Void {
		// facts describe the text the compile read: a file changed since, or one the run rewrote, has none; and two `#if`
		// variants of one member are each found at their own range
		final source: String = 'class Main {\n\tstatic function main() { hook(); Other.f(); Stale.f(); }\n'
			+ '\tpublic static function hook():Void {}\n'
			+ '#if APQ_A\n\tstatic function v():Void { hook(); }\n#else\n\tstatic function v():Void { hook(); hook(); }\n#end\n}\n';
		final stale: String = 'class Stale { public static function f() Main.hook(); }\n';
		final scratch: Scratch = compile([
			'Main.hx' => source,
			'Other.hx' => 'class Other { public static function f() Main.hook(); }\n',
			'Stale.hx' => stale
		], [[], ['APQ_A']]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final file: String = scratch.path('Main.hx');
		final first: Int = source.indexOf('hook(); }\n#else');
		final second: Int = source.indexOf('hook(); hook();');
		Assert.equals('Main.v', facts?.nodeAt(file, new Span(first, first + 6))?.id);
		Assert.equals('Main.v', facts?.nodeAt(file, new Span(second, second + 6))?.id);
		Assert.notNull(facts?.node('Other.f'));
		facts?.invalidate(scratch.path('Other.hx'));
		Assert.isNull(facts?.node('Other.f'), 'a rewritten file still has facts');
		// the table reads Stale.hx only now, after the edit: its text is not the compiled one
		File.saveContent(scratch.path('Stale.hx'), stale + '// edited\n');
		Assert.isNull(facts?.node('Stale.f'), 'facts answered for a text the compile never read');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-STALE-FOREIGN') @:killer('M-FACTS-REFLECTION-PATH')
	public function testALostSplicedFactMarksItsNodeAndOnlyTheStdIsReflection(): Void {
		// the caller's file is unchanged, but facts spliced in from a file the table dropped are lost to it: the node says so,
		// and its range queries are Unknown. A project's own `Type.hx` inlined into it is no reflection
		final main: String = 'class Main {\n\tpublic static function hook(i:Int):Int return i;\n'
			+ '\tstatic function main() { Lib.wrap(1); my.Type.twice(2); }\n}\n';
		final scratch: Scratch = compile([
			'Main.hx' => main,
			'Lib.hx' => 'class Lib { public static inline function wrap(i:Int):Int return Main.hook(i); }\n',
			'my/Type.hx' => 'package my;\nclass Type { public static inline function twice(i:Int):Int return Main.hook(i) * 2; }\n'
		]);
		final facts: Null<CompilerFacts> = scratch.facts;
		Assert.isFalse(facts?.node('Main.main')?.incomplete.contains('reflection-inlined') ?? true, 'a project Type.hx read as reflection');
		facts?.invalidate(scratch.path('Lib.hx'));
		final node: Null<FactNode> = facts?.node('Main.main');
		Assert.isTrue(node?.incomplete.contains('stale-foreign') ?? false, 'a lost spliced fact left no mark');
		final whole: Null<FactPos> = node?.at;
		Assert.isNull(whole == null ? [] : facts?.callsIn(scratch.path('Main.hx'), whole.span), 'a node with lost facts answered');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-WRITTEN-DURING') @:killer('M-FACTS-CHANGED-STALE')
	public function testAFileWrittenWhileTheCompileRanIsStale(): Void {
		// a build macro rewrites its own file, same bytes, while the facts compile types it: the hash then names a text
		// the positions need not come from, so the file has no facts
		final touch: String = 'class Touch {\n\tpublic static macro function build():Array<haxe.macro.Expr.Field> {\n'
			+ '\t\tif (Sys.args().join(" ").indexOf("TypedFactsMacro") >= 0) {\n'
			+ '\t\t\tfinal p = haxe.macro.Context.getPosInfos(haxe.macro.Context.currentPos()).file;\n'
			+ '\t\t\tsys.io.File.saveContent(p, sys.io.File.getContent(p));\n\t\t}\n\t\treturn null;\n\t}\n}\n';
		final scratch: Scratch = compile([
			'Main.hx' => '@:build(Touch.build())\nclass Main { static function main() { var x = 1; trace(x); } }\n',
			'Touch.hx' => touch
		]);
		final facts: Null<CompilerFacts> = scratch.facts;
		final main: String = scratch.path('Main.hx');
		Assert.isTrue(facts?.compiled(main) ?? false, 'the compile typed the file');
		Assert.isNull(facts == null ? null : facts.sourceOf(facts.keyOf(main)), 'facts of a file written during the compile answered');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-DROPPED')
	public function testAConfigurationThatFailsContributesNothing(): Void {
		final dir: String = CliFixture.writeTree('typed_facts', [
			{ name: 'Main.hx', source: 'class Main { static function main() { #if APQ_BROKEN nope(); #end } }\n' },
			{ name: 'build.hxml', source: BUILD }
		]);
		final oracles: Array<OracleConfig> = [
			{ hxml: 'build.hxml', dir: dir, defines: [] },
			{ hxml: 'build.hxml', dir: dir, defines: ['APQ_BROKEN'] },
			{
				hxml: 'build.hxml',
				dir: dir,
				defines: [],
				unavailable: 'generation failed'
			}
		];
		final facts: Null<CompilerFacts> = TypedFactsProbe.probeAll(oracles);
		Assert.equals(1, facts?.configurations.length);
		// each configuration that contributed nothing is named, with why: the run reports it rather than going quiet
		final reasons: Array<String> = [for (d in facts?.dropped ?? []) d.reason];
		Assert.equals(2, reasons.length);
		Assert.isTrue(reasons.contains('generation failed'), 'reasons: $reasons');
		Assert.isTrue(reasons.exists(r -> StringTools.startsWith(r, 'the compile failed')), 'reasons: $reasons');
		Assert.equals(0, TypedFactsProbe.probeAll([oracles[1]])?.configurations.length);
		CliFixture.removeDir(dir);
	}

	/** A compile of `files` (paths under one scratch directory) under each define set of `configurations`, by `build`. */
	private static function compile(files: Map<String, String>, ?configurations: Array<Array<String>>, ?build: String): Scratch {
		final entries: Array<{ name: String, source: String }> = [for (name => text in files) { name: name, source: text }];
		entries.push({ name: 'build.hxml', source: build ?? BUILD });
		final dir: String = CliFixture.writeTree('typed_facts', entries);
		final oracles: Array<OracleConfig> = [for (d in configurations ?? [[]]) { hxml: 'build.hxml', dir: dir, defines: d }];
		return new Scratch(dir, TypedFactsProbe.probeAll(oracles));
	}

}

/** A scratch directory and the facts of its compile. */
@:nullSafety(Strict)
private final class Scratch {

	public final dir: String;
	public final facts: Null<CompilerFacts>;

	public function new(dir: String, facts: Null<CompilerFacts>) {
		this.dir = dir;
		this.facts = facts;
	}

	/** The absolute path of `name` in the directory. */
	public function path(name: String): String {
		return Path.join([dir, name]);
	}

	public function remove(): Void {
		CliFixture.removeDir(dir);
	}

}
