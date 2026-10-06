package unit.check;

import anyparse.check.FactsTypeTree;
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

	@:pin('control') @:killer('M-FACTS-REFL-MEMBER-NAME') @:killer('M-FACTS-REFL-MEMBER-NAME-ANY')
	@:killer('M-FACTS-REFL-MEMBER-NAME-TABLE')
	public function testAReflectiveCallRecordsTheLiteralItsNameArgumentHolds(): Void {
		// the member a call names is the literal at its name argument: not a value `setField` stores, not an argument of a
		// call that names no member (`Type.resolveClass` names a class, `Type.createEnum` a constructor). The interpreter's
		// `Reflect` inlines none of them, as js's does `hasField` and `setField`
		final scratch: Scratch = compile([
			'Main.hx' => 'enum E { A; }\nclass Main { function new() {} static function main() {\n'
			+ '\tvar m = new Main(); var n = "y" + Std.random(2);\n'
			+ '\tReflect.hasField(m, "x"); Reflect.setField(m, n, "v"); Reflect.field(m, n); Type.resolveClass("Main");\n'
			+ '\tType.createEnum(E, "A");\n} }\n'
		], null, '-cp .\n-main Main\n--interp\n');
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			Assert.isTrue(main.reflection.exists(r -> r.target == 'Reflect.hasField' && r.memberName == 'x'), 'a literal name');
			Assert.isTrue(
				main.reflection.exists(r -> r.target == 'Reflect.setField' && r.memberName == null && r.name == 'v'), 'a literal value'
			);
			Assert.isTrue(main.reflection.exists(r -> r.target == 'Reflect.field' && r.memberName == null), 'a computed name');
			Assert.isTrue(
				main.reflection.exists(r -> r.target == 'Type.resolveClass' && r.memberName == null && r.name == 'Main'), 'no member named'
			);
			Assert.isTrue(
				main.reflection.exists(r -> r.target == 'Type.createEnum' && r.memberName == null && r.name == 'A'), 'a constructor named'
			);
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

	@:pin('control') @:killer('M-FACTS-SPLICE-SITE') @:killer('M-FACTS-SPLICE-SITE-INNERMOST') @:killer('M-FACTS-SPLICE-BODY')
	@:killer('M-FACTS-NESTED-SPLICE')
	public function testAnInlinedCallCarriesWhereItRanAndTheBodyItSplicedIn(): Void {
		// the compiler keeps no range for the call it replaced: the call carries the range of the caller's innermost expression
		// around it, and the callee's declared range, which holds all it spliced in. A body the spliced one spliced in turn is
		// a call of its own, run at the same site, and holds the code of its own callee
		final main: String = 'class Main {\n\tpublic static function hook(i:Int):Int return i;\n'
			+ '\tstatic function main() {\n\t\tvar a = hook(1);\n\t\tvar y = Lib.two(a);\n\t}\n}\n';
		final lib: String = 'class Lib {\n\tpublic static inline function two(x:Int):Int return Lib.one(x) * 2;\n'
			+ '\tpublic static inline function one(x:Int):Int return Main.hook(x) + 1;\n}\n';
		final scratch: Scratch = compile(['Main.hx' => main, 'Lib.hx' => lib]);
		final node: Null<FactNode> = scratch.facts?.node('Main.main');
		final libFile: String = scratch.facts?.keyOf(scratch.path('Lib.hx')) ?? '';
		final two: Null<CallFact> = node?.calls.find(c -> c.access == 'inlined' && c.target == 'Lib.two');
		final one: Null<CallFact> = node?.calls.find(c -> c.access == 'inlined' && c.target == 'Lib.one');
		final call: Int = main.indexOf('Lib.two(a)');
		final statement: Int = main.indexOf('var y');
		final site: Null<Span> = two?.site?.span;
		Assert.isTrue(site != null && site.from >= statement && site.from <= call && site.to >= call + 'Lib.two(a)'.length, 'site: $site');
		Assert.isTrue(site != null && site.to <= main.indexOf(';', call) + 1, 'the site runs past the statement: $site');
		Assert.equals(site?.from, one?.site?.span.from);
		Assert.equals(site?.to, one?.site?.span.to);
		final declared: Null<FactPos> = two?.body;
		Assert.equals(libFile, declared?.file);
		Assert.isTrue(declared != null && declared.span.to >= lib.indexOf('* 2;'), 'body: $declared');
		final hook: Null<CallFact> = node?.calls.find(c -> c.target == 'Main.hook' && c.at.file == libFile);
		final splice: Null<SpliceFact> = node == null || hook == null ? null : CompilerFacts.spliceOf(node, hook.at);
		Assert.equals('Lib.one', splice?.callee);
		Assert.equals(site?.from, splice?.sites[0]?.from);
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

	@:pin('control') @:killer('M-FACTS-ELEMENT-WRITE')
	public function testAnElementWriteIsAWriteThroughTheArrayAtItsOwnRead(): Void {
		// an element write names no field: it is a write through the array, found at the array's own read — a field's, a
		// local's, a call's — as a push is found at its receiver. A compound one is made through a local of the compiler's
		final source: String = 'class Main {\n\tvar items:Array<Int> = [];\n\tfunction new() {}\n'
			+ '\tfunction get():Array<Int> return items;\n' + '\tfunction write() {\n\t\titems[0] = 1; items[1] += 2; items[2]++;\n'
			+ '\t\tvar loc = [1]; loc[0] = 3; get()[0] = 4;\n\t}\n' + '\tstatic function main() new Main().write();\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final node: Null<FactNode> = scratch.facts?.node('Main.write');
		Assert.notNull(node);
		if (node != null) {
			final walked: FactNode = node;
			function readOfItems(at: Null<FactPos>): Bool {
				return at != null
					&& walked.fields.exists(f -> f.field == 'items' && !f.write && f.use == 'elemWrite' && f.at.span.from == at.span.from);
			}
			Assert.equals(5, node.elementWrites.length, 'element writes: ${node.elementWrites}');
			Assert.equals(3, node.elementWrites.filter(w -> readOfItems(w.receiverAt)).length, 'writes through the field');
			final local: Int = source.indexOf('loc[0]');
			Assert.isTrue(
				node.elementWrites.exists(w -> w.receiverAt?.span.from == local && w.receiver == 'Array<Int>'),
				'no write through the local'
			);
			Assert.isTrue(node.reads.exists(r -> r.at.span.from == local), 'the local is not read where the write points');
			final call: Int = source.indexOf('get()[0]');
			Assert.isTrue(node.elementWrites.exists(w -> w.receiverAt?.span.from == call), 'no write through a call result');
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-USE') @:killer('M-FACTS-HELD') @:killer('M-FACTS-CAPTURE')
	public function testAFieldReadSaysHowItsValueIsUsed(): Void {
		// a value handed on as itself — an argument, a capture — is used as a `value`; a lowered loop reads its array
		// through a local of the compiler's, whose reads are the field's uses
		final source: String = 'class Main {\n\tvar items:Array<Int> = [];\n\tvar walker:Iterator<Int> = [1].iterator();\n'
			+ '\tvar next:Null<Main> = null;\n\tvar count:Int = 0;\n\tfunction new() {}\n'
			+ '\tstatic function keep(a:Array<Int>):Void {}\n'
			+ '\tfunction use() {\n\t\titems.push(1); var a = items[0] + items.length; next.count = 2; count++;\n'
			+ '\t\tif (items == null) return; for (x in walker) trace(x); keep(items);\n' + '\t\tfor (y in items) trace(y);\n'
			+ '\t\tvar held = items; var f = () -> held.length;\n\t}\n' + '\tstatic function main() new Main().use();\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final node: Null<FactNode> = scratch.facts?.node('Main.use');
		Assert.notNull(node);
		if (node != null) {
			final walked: FactNode = node;
			function usesOf(field: String, ?at: String): Array<Null<String>> {
				final from: Int = at == null ? -1 : source.indexOf(at) + at.length - field.length;
				final uses: Array<Null<String>> = [
					for (f in walked.fields) if (f.field == field && !f.write && (from < 0 || f.at.span.from == from)) f.use
				];
				uses.sort(Reflect.compare);
				return uses;
			}
			final items: Array<Null<String>> = usesOf('items');
			for (expected in ['call', 'index', 'member', 'compare', 'value'])
				Assert.isTrue(items.contains(expected), '$expected is no use of items: $items');
			Assert.isTrue(node.fields.exists(f -> f.use == 'call' && f.method == 'push'), 'a call receiver names no method');
			Assert.equals('index,member', usesOf('items', 'in items').join(','), 'the lowered loop');
			Assert.equals('value', usesOf('items', 'held = items').join(','), 'a captured local');
			Assert.equals('value', usesOf('items', 'keep(items').join(','), 'an argument');
			Assert.equals('memberWrite', usesOf('next').join(','));
			Assert.equals('iter', usesOf('walker').join(','));
			Assert.equals('update', usesOf('count').join(','));
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-INLINED-RECEIVER') @:killer('M-FACTS-RECEIVER-BLOCK') @:killer('M-FACTS-RECEIVER-PARAM')
	public function testAFieldReadAnInlinedMethodTakesAsItsReceiverIsTheCallsReceiver(): Void {
		// the compiler binds the receiver of an inlined `items.keyValueIterator()` — a key-value loop — to a local of its
		// own at the spliced body's range; a local the method's code names so, or a parameter so named, holds an argument
		final source: String = 'class Main {\n\tvar items:Array<Int> = [];\n\tfunction new() {}\n'
			+ '\tfunction use(k:Keeper) {\n\t\tfor (i => v in items) trace(v);\n\t\tvar it = items.iterator();\n'
			+ '\t\tvar a = k.push(items);\n\t\tk.pop(items);\n\t}\n' + '\tstatic function main() new Main().use(new Keeper());\n}\n'
			+ 'class Keeper {\n\tpublic var kept:Array<Int> = [];\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic inline function push(a:Array<Int>):Array<Int> {\n\t\tvar _this = a;\n\t\treturn _this;\n\t}\n'
			+ '\tpublic inline function pop(_this:Array<Int>):Void {\n\t\tkept = _this;\n\t\tcount = _this.length;\n\t}\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final node: Null<FactNode> = scratch.facts?.node('Main.use');
		Assert.notNull(node);
		if (node != null) {
			final walked: FactNode = node;
			function usesAt(at: String): String {
				final from: Int = source.indexOf(at) + at.indexOf('items');
				final uses: Array<String> = [
					for (f in walked.fields) if (f.field == 'items' && !f.write && f.at.span.from == from)
						f.use + (f.method == null ? '' : ':${f.method}')
				];
				uses.sort(Reflect.compare);
				return uses.join(',');
			}
			Assert.equals('call:keyValueIterator', usesAt('in items)'), 'the key-value loop');
			Assert.equals('call:iterator', usesAt('items.iterator'), 'an inlined reader');
			Assert.equals('value', usesAt('push(items'), 'a local named as a receiver');
			Assert.equals('member,value', usesAt('pop(items'), 'a parameter named as a receiver');
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-FRESH') @:killer('M-FACTS-FRESH-DISCARDED')
	public function testAWriteOfAValueBuiltThereAndHandedNowhereIsFresh(): Void {
		final source: String = 'class Main {\n\tvar items:Null<Array<Int>> = [];\n\tvar copy:Array<Int> = [];\n\tfunction new() {}\n'
			+ '\tfunction reset(c:Bool) {\n\t\titems = [1]; items = new Array<Int>(); items = null; items = c ? [] : null;\n'
			+ '\t\titems = copy; var z = (items = []); items = if (items != null) items else [];\n\t}\n'
			+ '\tstatic function main() new Main().reset(true);\n}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final node: Null<FactNode> = scratch.facts?.node('Main.reset');
		Assert.notNull(node);
		if (node != null) {
			final walked: FactNode = node;
			function freshAt(text: String): Null<Bool> {
				final from: Int = source.indexOf(text);
				return walked.fields.find(f -> f.write && f.field == 'items' && f.at.span.from == from)?.fresh;
			}
			for (fresh in ['items = [1]', 'items = new', 'items = null', 'items = c ?'])
				Assert.equals(true, freshAt(fresh), '`$fresh` is no fresh write');
			// a value held elsewhere, or handed on by the assignment's own value, is not the field's alone
			for (held in ['items = copy', 'items = []);', 'items = if']) Assert.equals(false, freshAt(held), '`$held` is a fresh write');
		}
		scratch.remove();
	}

	/** A compile of `files` (paths under one scratch directory) under each define set of `configurations`, by `build`. */
	@:pin('control') @:killer('M-FACTS-HANDS') @:killer('M-FACTS-GENS')
	public function testWhatExternCodeIsHandedAndWhatAGenericMethodIsInstantiatedAt(): Void {
		// an argument of an extern's field is handed to target code at the type the field declares, its own type parameters
		// unapplied, a same-type one too; a generic method's call and its read as a value name the instantiation chosen
		final scratch: Scratch = compile([
			'Main.hx' => '@:native("Object") extern class Ext<T> {\n\tfunction new(t:T);\n\tstatic function keep(o:Main):Void;\n'
			+ '\tfunction put(t:T, n:Int):Void;\n}\n' + 'class Main { function new() {}\n'
			+ '\tstatic function id<A>(a:A):A return a;\n\tstatic function main() {\n\t\tvar m = new Main(); Ext.keep(m);\n'
			+ '\t\tvar e = new Ext<Main>(m); e.put(m, 1); id(m); var f:Main->Main = id;\n\t}\n}\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			final handed: Array<String> = [for (h in main.handed) '${h.target}:${h.from}:${h.to}'];
			for (expected in [
				'Ext.keep:Main:Main',
				'Ext.new:Main:$$Ext.T',
				'Ext.put:Main:$$Ext.T',
				'Ext.put:Int:Int'
			]) Assert.isTrue(handed.contains(expected), '$expected is not handed: $handed');
			final instantiated: Array<String> = [for (g in main.instantiations) '${g.declared}=>${g.applied}'];
			Assert.isTrue(instantiated.contains('($$id.A)->$$id.A=>(Main)->Main'), 'the call is no instantiation: $instantiated');
			Assert.equals(2, main.instantiations.length);
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-STRING-EXACT') @:killer('M-FACTS-THROW-EXCEPTION') @:killer('M-FACTS-EXACT-WRITTEN')
	@:killer('M-FACTS-FLOW-EXACT')
	public function testAConvertedObjectOfExactlyItsClassAndAThrownException(): Void {
		// a construction, and a local initialized with one of its own type never written again, are objects of exactly their
		// class; a thrown one extending `haxe.Exception` is thrown as it is, and converted by nothing
		final scratch: Scratch = compile([
			'Main.hx' => 'class Err extends haxe.Exception {}\n' + 'class Main { function new() {}\n\tstatic function main() {\n'
			+ '\t\tvar a = new Main(); var b = new Main(); b = a; var c:Dynamic = new Main();\n'
			+ '\t\ttrace("" + a); trace("" + b); trace("" + new Main()); trace("" + c);\n'
			+ '\t\tif (Math.random() < 0) { var e = new Err("x"); throw e; }\n'
			+ '\t\tif (Math.random() < 0) { var e:haxe.Exception = new Err("y"); throw e; }\n'
			+ '\t\tif (Math.random() < 0) throw new Main();\n\t}\n}\n'
		]);
		final main: Null<FactNode> = scratch.facts?.node('Main.main');
		Assert.notNull(main);
		if (main != null) {
			// a concatenated instance is converted by a call of `Std.string`, which it flows into
			final converted: Array<FlowFact> = main.flows.filter(f -> f.via == 'arg' && f.from == 'Main');
			final exact: Array<String> = [for (f in converted) '${f.from}:${f.exact}'];
			Assert.equals(2, converted.filter(f -> f.exact).length, 'exact: $exact');
			Assert.equals(1, converted.filter(f -> !f.exact).length, 'exact: $exact');
			final thrown: Array<String> = [for (s in main.strings) '${s.operand}:${s.exact}'];
			// a local of a supertype holds an object of another class than its type names: converted, and not exactly
			Assert.isTrue(main.strings.exists(s -> s.operand == 'haxe.Exception' && !s.exact), 'thrown: $thrown');
			Assert.isFalse(main.strings.exists(s -> s.operand == 'Err'), 'a thrown exception was converted: $thrown');
			Assert.isTrue(main.strings.exists(s -> s.operand == 'Main' && s.exact), 'thrown: $thrown');
		}
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-ALIAS-TYPEDEF') @:killer('M-FACTS-STATICS-TYPEDEF')
	public function testAnImportAliasIsATypedefAndTheStaticsOfAnEnumReadAsAType(): Void {
		// an import alias is a typedef no module lists: it gets a record of its own; the statics of an enum read as a value
		// print as `Enum<…>` alone, which the type grammar reads
		final scratch: Scratch = compile([
			'Main.hx' => 'import haxe.ds.Option as Opt;\n\nclass Main {\n\tstatic function f(o:Opt<Int>):Void {}\n'
			+ '\tstatic function main() {\n\t\tf(None);\n\t\tvar statics = haxe.ds.Option;\n\t}\n}\n'
		]);
		final facts: Null<CompilerFacts> = scratch.facts;
		Assert.equals('typedef', facts?.type('haxe.ds._Option.Opt')?.kind);
		Assert.equals('haxe.ds.Option<$$haxe.ds.Option.T>', facts?.type('haxe.ds._Option.Opt')?.targets[0]);
		final statics: Null<VarFact> = facts?.node('Main.main')?.vars.find(v -> v.name == 'statics');
		Assert.notNull(statics);
		if (statics != null) Assert.notNull(FactsTypeTree.read(statics.type), 'unreadable: ${statics.type}');
		scratch.remove();
	}

	@:pin('control') @:killer('M-FACTS-ASSIGN-HELD') @:killer('M-FACTS-ASSIGNED-NO-USE') @:killer('M-FACTS-ASSIGNED-TARGET')
	@:killer('M-FACTS-ALIAS-LINK') @:killer('M-FACTS-HELD-LOCAL') @:killer('M-FACTS-SUBSTITUTED-RECEIVER')
	@:killer('M-FACTS-SUBSTITUTED-ARITY') @:killer('M-FACTS-SUBSTITUTED-OWNER') @:killer('M-FACTS-ASSIGN-STATEMENT')
	@:killer('M-FACTS-ASSIGN-OWNER') @:killer('M-FACTS-HELD-FLAG')
	public function testAFieldValueStoredInALocalIsUsedAsTheLocalsReads(): Void {
		// a value an assignment statement stores in a local of the node, in any branch and beside other values, is used as
		// every read of that local and of the locals a read of it is stored in: the receiver of a key-value loop's inlined
		// `keyValueIterator`, an index, a `length`; a write of the local is no use. A store whose own value goes on, one into a
		// local of another node, and a local spliced in as an inline method's argument, or as the receiver of a method of
		// another class than its own, use the value as a value
		final source: String = 'class Main {\n\tvar items:Array<Int> = [1];\n\tvar others:Array<Int> = [2];\n'
			+ '\tvar head:Node = new Node();\n\tvar sub:Sub = new Sub();\n\tfunction new() {}\n'
			+ '\tstatic function keep(a:Array<Int>):Void {}\n' + '\tfunction use(c:String) {\n\t\tvar l:Array<Int> = null;\n'
			+ '\t\tif (c == "h") l = items; else if (c == "v") l = others;\n\t\tfor (i => v in l) trace(i + v);\n'
			+ '\t\tvar copy:Array<Int> = l;\n\t\ttrace(copy[0] + copy.length);\n'
			+ '\t\tvar p:Array<Int> = null;\n\t\tp = items;\n\t\tp.push(1);\n'
			+ '\t\tvar h:Array<Int> = null;\n\t\tkeep(h = items);\n\t\ttrace(h.length);\n'
			+ '\t\tvar q:Array<Int> = null;\n\t\ttrace(q.length);\n\t\tvar f = function() {\n\t\t\tq = items;\n\t\t};\n'
			+ '\t\tvar n:Node = new Node();\n\t\tvar m:Node = null;\n\t\tm = head;\n\t\tn.link(m);\n'
			+ '\t\tvar s:Sub = null;\n\t\ts = sub;\n\t\ts.grab();\n\t}\n' + '\tpublic static function keepAny(b:Base):Void {}\n'
			+ '\tstatic function main() new Main().use("h");\n}\n'
			+ 'class Node {\n\tpublic var next:Null<Node> = null;\n\tpublic function new() {}\n'
			+ '\tpublic inline function link(other:Node):Void next = other;\n}\n'
			+ 'class Base {\n\tpublic function new() {}\n\tpublic inline function grab():Void Main.keepAny(this);\n}\n'
			+ 'class Sub extends Base {}\n';
		final scratch: Scratch = compile(['Main.hx' => source]);
		final node: Null<FactNode> = scratch.facts?.node('Main.use');
		Assert.notNull(node);
		if (node != null) {
			// the store from the nested function is a fact of that function's own node
			final walked: Array<FieldFact> = node.fields.concat([for (id in node.fns) for (f in scratch.facts?.node(id)?.fields ?? []) f]);
			function usesAt(field: String, at: String): String {
				final from: Int = source.indexOf(at) + at.indexOf(field);
				final uses: Array<String> = [];
				for (f in walked) if (f.field == field && !f.write && f.at.span.from == from) {
					final use: String = f.use + (f.method == null ? '' : ':${f.method}') + (f.held ? '' : '!');
					if (!uses.contains(use)) uses.push(use);
				}
				uses.sort(Reflect.compare);
				return uses.join(',');
			}
			Assert.equals('call:keyValueIterator,index,member', usesAt('items', 'l = items'), 'the stored value');
			Assert.equals('call:keyValueIterator,index,member', usesAt('others', 'l = others'), 'the other branch');
			Assert.equals('call:push', usesAt('items', 'p = items'), 'a push on the local');
			Assert.equals('value!', usesAt('items', 'keep(h = items'), 'an assignment used as a value');
			Assert.equals('value!', usesAt('items', 'q = items'), 'a store from a nested function');
			Assert.equals('value', usesAt('head', 'm = head'), 'an inline method\'s argument');
			Assert.equals('value', usesAt('sub', 's = sub'), 'the receiver of another class\'s method');
		}
		scratch.remove();
	}

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
