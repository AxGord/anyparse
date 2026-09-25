package unit.query;

import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.MemberReach;
import anyparse.query.QueryNode;
import anyparse.query.ReachLiveness.ReachConfiguration;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import unit.QueryTestHelpers;
import utest.Assert;
import utest.Test;

/**
 * `MemberReach`: may the code an entry runs change member M? Each case writes the entry as a REGION
 * between `/*<*\/` and `/*>*\/` in the first project file and asks about `C.items` unless it says
 * otherwise. The three answers are asserted by their constructor; a `Reached` case also names the
 * function the path ends in, an `Unknown` case the blind spot.
 */
class MemberReachTest extends Test {

	/**
	 * The library declaration of the built-in array type every case resolves against, as the real std
	 * declares it: what a call does with its arguments is read off these parameter types.
	 */
	private static inline final STD_ARRAY: String = 'extern class Array<T> { public var length(default, null):Int; '
		+ 'public function push(x:T):Int; public function pop():Null<T>; public function contains(x:T):Bool; '
		+ 'public function indexOf(x:T, ?fromIndex:Int):Int; public function copy():Array<T>; public function concat(a:Array<T>):Array<T>; '
		+ 'public function slice(pos:Int, ?end:Int):Array<T>; public function map<S>(f:T->S):Array<S>; '
		+ 'public function filter(f:T->Bool):Array<T>; public function sort(f:T->T->Int):Void; public function join(sep:String):String; }';

	private static inline final REGION_OPEN: String = '/*<*/';
	private static inline final REGION_CLOSE: String = '/*>*/';

	@:pin('control') @:killer('M-REACH-OUT-OF-SCOPE')
	public function testFieldWithoutTheWholeProjectIsUnknown(): Void {
		// A toucher, or an implicitly-called function, may live in a file the run did not read — even a
		// region of plain reads can run one.
		final reads: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ var x:Int = items[0]; /*>*/ } }';
		assertMatch(ask([reads], null, false), r -> r.match(Unknown(OutOfScope(_))));
		final calls: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([calls], null, false), r -> r.match(Unknown(OutOfScope(_))));
	}

	@:pin('control') @:killer('M-REACH-WALK-UNKNOWN')
	public function testPureCalleeIsProven(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function new() items.push(1); '
			+ 'function f():Void { /*<*/ helper(items[0]); /*>*/ } function helper(v:Int):Void { trace(v); } }';
		assertMatch(ask([src]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-TOUCHER-FOUND')
	public function testTwoHopMutatorIsReached(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ outer(); /*>*/ } '
			+ 'function outer():Void inner(); function inner():Void items.push(1); }';
		assertReachedAt(ask([src]), 'C.inner');
	}

	@:pin('control') @:killer('M-REACH-METHOD-TOUCH')
	public function testMutatingMethodIsATouchAndAReaderIsNot(): Void {
		final pushes: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void items.pop(); }';
		assertReachedAt(ask([pushes]), 'C.g');
		final reads: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void trace(items.indexOf(1)); }';
		assertMatch(ask([reads]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SLOT-WRITE')
	public function testSlotWriteIsATouch(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void items[0] = 2; }';
		assertReachedAt(ask([src]), 'C.g');
	}

	@:pin('control') @:killer('M-REACH-ESCAPE-ARGUMENT')
	public function testValueHandedOutIsAnEscape(): Void {
		// `keep` may store the array and a later callee change it through that alias without naming `items`.
		final src: String = 'class C { var items:Array<Int> = []; function new() Keeper.keep(items); '
			+ 'function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([src, 'class Keeper { public static function keep(a:Array<Int>):Void {} }']), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-REACH-FRESH-ASSIGN')
	public function testStoringASharedValueIsAnEscape(): Void {
		final shared: String = 'class C { var items:Array<Int> = []; public function set(a:Array<Int>):Void items = a; '
			+ 'function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([shared]), r -> r.match(Unknown(Escape(_, _))));
		final fresh: String = 'class C { var items:Array<Int> = []; public function reset():Void items = []; '
			+ 'function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([fresh]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SHARED-INITIALIZER')
	public function testSharedInitializerIsAnEscape(): Void {
		final src: String = 'class C { static final SHARED:Array<Int> = []; var items:Array<Int> = SHARED; '
			+ 'function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([src]), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-GRAPH-SETTER-EDGE')
	public function testSetterWriteInTheRegionIsAnEntry(): Void {
		// `objs[0].x = 1` runs `set_x`, which grows `items`: the property write IS a call.
		final src: String =
			'class C { public var items:Array<Int> = []; var objs:Array<P>; function f():Void { /*<*/ objs[0].x = 1; /*>*/ } }';
		final p: String =
			'class P { public var x(default, set):Int; var owner:C; function set_x(v:Int):Int { owner.items.push(v); return x = v; } }';
		assertReachedAt(ask([src, p]), 'P.set_x');
	}

	@:pin('control') @:killer('M-GRAPH-GETTER-EDGE')
	public function testGetterReadInTheRegionIsAnEntry(): Void {
		final src: String = 'class C { public var items:Array<Int> = []; var p:P; function f():Void { /*<*/ trace(p.x); /*>*/ } }';
		final p: String = 'class P { public var x(get, never):Int; var owner:C; function get_x():Int { owner.items.push(1); return 1; } }';
		assertReachedAt(ask([src, p]), 'P.get_x');
	}

	@:pin('control') @:killer('M-REACH-VALUE-CHANNEL')
	public function testFunctionValueCallAdmitsAValueUsedMutator(): Void {
		// `cb()` runs whatever was stored; `grow` was stored, and it can reach `items`.
		final src: String = 'class C { var items:Array<Int> = []; var cb:() -> Void; public function register():Void cb = grow; '
			+ 'function f():Void { /*<*/ cb(); /*>*/ } function grow():Void items.push(1); }';
		assertReachedAt(ask([src]), 'C.grow');
	}

	@:pin('control') @:killer('M-REACH-WALK-UNKNOWN')
	public function testFunctionValueCallWithNoValueUsedMutatorIsProven(): Void {
		// A function used as a value that can NOT reach the member is not admitted as a path to it.
		final src: String = 'class C { var items:Array<Int> = []; var cb:() -> Void; public function register():Void cb = quiet; '
			+ 'function new() items.push(1); function f():Void { /*<*/ cb(); /*>*/ } function quiet():Void {} }';
		assertMatch(ask([src]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-NAME-CHANNEL')
	public function testDynamicReceiverAdmitsBySameName(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f(d:Dynamic):Void { /*<*/ d.grow(); /*>*/ } '
			+ 'public function grow():Void items.push(1); }';
		assertReachedAt(ask([src]), 'C.grow');
	}

	@:pin('control') @:killer('M-REACH-REFLECT-LITERAL')
	public function testReflectionByLiteralNameIsATouch(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } '
			+ "function g():Void Reflect.setField(this, 'items', []); }";
		assertReachedAt(ask([src]), 'C.g');
	}

	@:pin('control') @:killer('M-REACH-REFLECT-COMPUTED')
	public function testReflectionByComputedNameIsUnknown(): Void {
		final src: String = 'class C { var items:Array<Int> = []; var key:String; function f():Void { /*<*/ g(); /*>*/ } '
			+ 'function g():Void Reflect.setField(this, key, []); }';
		assertMatch(ask([src]), r -> r.match(Unknown(DynamicName(_, _))));
	}

	@:pin('control') @:killer('M-REACH-NATIVE')
	public function testNativeCodeIsUnknown(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } '
			+ "function g():Void js.Syntax.code('run()'); }";
		assertMatch(ask([src]), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-REACH-UNTYPED')
	public function testUntypedCodeIsUnknown(): Void {
		final src: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void untyped run(); }';
		assertMatch(ask([src]), r -> r.match(Unknown(Untyped(_, _))));
	}

	@:pin('control') @:killer('M-REACH-SKIP-PARSE')
	public function testUnparsedProjectFileNamingTheMemberIsUnknown(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([src, 'class Broken { function b() { c.items.push(1); ']), r -> r.match(Unknown(SkipParse('F1.hx'))));
	}

	@:pin('control') @:killer('M-REACH-SKIP-PARSE-ANY') @:killer('M-REACH-SKIP-PARSE-LOCAL')
	public function testUnparsedProjectFileSpellingNothingIsStillUnknown(): Void {
		// `Sub` does not parse and never spells `items`, yet it overrides `go` with a call to the grower: the dispatch the
		// region makes may land there. A shared parameter's region is refused for the same reason — the file may hold a
		// function the language calls implicitly.
		final src: String = 'class C { public static var items:Array<Int> = []; var b:Base; function f():Void { /*<*/ b.go(); /*>*/ } }';
		final base: String = 'class Base { public function new() {} public function go():Void {} }';
		final helper: String = 'class Helper { public static function grow():Void C.items.push(9); }';
		final sub: String = 'class Sub extends Base {\n#if js\noverride function go():Void {\n#else\noverride function go():Void {\n#end\n'
			+ 'Helper.grow(); } }';
		assertMatch(ask([src, base, helper, sub]), r -> r.match(Unknown(SkipParse('F3.hx'))));
		final param: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = xs[0] + 1; /*>*/ } }';
		final at: Int = param.lastIndexOf('xs', param.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([param, sub], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(param)),
			r -> r.match(Unknown(SkipParse('F1.hx')))
		);
	}

	@:pin('control') @:killer('M-REACH-LIB-SKIP-OVERRIDE')
	public function testUnparsedLibraryFileSpellingTheDispatchIsUnknown(): Void {
		// The library's `LibSub` does not parse, so the index lists no override of `Base.go` there — yet it spells both.
		final src: String = 'class C { public static var items:Array<Int> = []; var b:Base; function f():Void { /*<*/ b.go(); /*>*/ } }';
		final base: String = 'class Base { public function new() {} public function go():Void {} }';
		final sub: String = 'class LibSub extends Base {\n#if js\noverride function go():Void {\n#else\noverride function go():Void {\n#end\n'
			+ 'C.items.push(9); } }';
		assertMatch(ask([src], [base, sub]), r -> r.match(Unknown(SkipParse('L1.hx'))));
		assertMatch(ask([src], [base]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-LIB-REFLECT-TOUCH') @:killer('M-REACH-LIB-REFLECT-UNSURE')
	@:killer('M-REACH-LIB-REFLECT-UNRELATED')
	public function testReflectiveReadOfTheMemberInLibraryCodeIsATouch(): Void {
		// A library override reads `items` by name: through a receiver of the owner's type it is the member itself, through
		// an untyped one it may be, and through a type unrelated to the owner it is that type's own field.
		final base: String = 'class Base { public function new() {} public function go():Void {} }';
		final other: String = 'class Other { public static var one:Other; public var items:Array<Int> = []; public function new() {} }';
		function ask2(receiver: String): ReachResult {
			final src: String = 'class C { public var items:Array<Int> = []; public static var inst:C; var b:Base; '
				+ 'function f():Void { /*<*/ b.go(); /*>*/ } }';
			final sub: String = 'class LibSub extends Base { override public function go():Void { '
				+ 'var a:Array<Int> = Reflect.field($receiver, "items"); a.push(9); } }';
			final reflect: String = 'extern class Reflect { public static function field(o:Dynamic, name:String):Dynamic; }';
			return ask([src], [base, other, sub, reflect]);
		}
		assertMatch(ask2('C.inst'), r -> r.match(Reached(_)));
		assertMatch(ask2('(null : Dynamic)'), r -> r.match(Unknown(DynamicName(_, _))));
		assertMatch(ask2('Other.one'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-CARRY-SUBTYPE-MEET')
	public function testAValueOfAnInterfaceOnlyASubtypeSharesCarriesTheMember(): Void {
		// `J` and `C` are unrelated, but `Sub extends C implements J`: a `J` may be a `Sub`, which carries `C.items`.
		final src: String =
			'class C { public var items:Array<Int> = []; public var me:J; function f():Void { /*<*/ Poker.poke(me); /*>*/ } }';
		final sub: String = 'class Sub extends C implements J { public function new() {} }';
		final lib: Array<String> = [
			'interface J {}',
			'class Poker { public static function poke(j:J):Void { var a:Array<Int> = Reflect.field(j, "items"); a.push(9); } }',
			'extern class Reflect { public static function field(o:Dynamic, name:String):Dynamic; }'
		];
		assertMatch(ask([src, sub], lib), r -> r.match(Reached(_)));
		assertMatch(ask([src], lib), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-RECEIVER-OWNER') @:killer('M-CARRY-SUBTYPE-MEET')
	public function testAnAccessThroughAnInterfaceTheOwnerImplementsIsATouch(): Void {
		// `j.items` names `J`'s declaration, yet a `J` may be the `C` whose `items` the loop walks — as may a structure
		// or a typedef of one, so the read lets `items` escape; a receiver typed by a class unrelated to `C` reaches another field.
		function poke(param: String, decls: String): String {
			return 'class C implements J { public var items:Array<Int> = []; public var me:J; '
				+ 'function f():Void { /*<*/ poke(this); /*>*/ } static function poke(s:$param):Void { var a:Array<Int> = s.items; '
				+ 'a.push(9); } } $decls';
		}
		assertMatch(ask([poke('J', 'interface J { var items:Array<Int>; }')]), r -> !r.match(Proven));
		assertMatch(ask([poke('{items:Array<Int>}', 'interface J {}')]), r -> !r.match(Proven));
		assertMatch(ask([poke('Has', 'interface J {} typedef Has = {var items:Array<Int>;}')]), r -> !r.match(Proven));
		assertMatch(ask([
			poke('Other', 'interface J {} class Other { public var items:Array<Int> = []; public function new() {} }')
		]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-LIB-ACCESS')
	public function testALibraryReadOfTheMemberByItsNameIsATouch(): Void {
		// Library code reads `items` off a `J` a subtype of `C` implements — typed, through `Dynamic`, through a cast.
		final src: String = 'class C implements J { public var items:Array<Int> = []; public var me:J; '
			+ 'function f():Void { /*<*/ Poker.poke(me); /*>*/ } }';
		function lib(body: String, iface: String): Array<String> {
			return [iface, 'class Poker { public static function poke(j:J):Void { $body } }'];
		}
		assertMatch(
			ask([src], lib('var a:Array<Int> = j.items; a.push(9);', 'interface J { var items:Array<Int>; }')), r -> r.match(Reached(_))
		);
		assertMatch(
			ask([src], lib('var a:Array<Int> = (j : Dynamic).items; a.push(9);', 'interface J {}')),
			r -> r.match(Unknown(DynamicName(_, _)))
		);
		assertMatch(
			ask([src], lib('var d:Dynamic = j; var a:Array<Int> = d.items; a.push(9);', 'interface J {}')),
			r -> r.match(Unknown(DynamicName(_, _)))
		);
	}

	@:pin('control') @:killer('M-CARRY-ESCAPES') @:killer('M-ESCAPE-STORE') @:killer('M-ESCAPE-CAST') @:killer('M-ESCAPE-DECL')
	@:killer('M-ESCAPE-PARAM') @:killer('M-ESCAPE-RETURN') @:killer('M-ESCAPE-LAMBDA') @:killer('M-ESCAPE-THROW')
	@:killer('M-ESCAPE-METHOD-VALUE') @:killer('M-ESCAPE-HELD') @:killer('M-ESCAPE-LIBRARY-SUPER') @:killer('M-ESCAPE-NATIVE') @:killer('M-ESCAPE-ANY')
	public function testAnInstanceThatLeftTheTypeSystemMayBeAnyType(): Void {
		// `Poker.poke` changes `o.items` of an `Other`. A `C` never IS an `Other` by its static type, but once one leaves the
		// type system — stored in a `Dynamic`, cast unchecked, handed to code that types it as nothing, inherited by library
		// code — a `Dynamic` handed to `poke` may be it, and a member resolves by name on js and interp. With no such exit
		// the `Other` parameter cannot hold a `C`.
		final other: String = 'class Other { public var items:Array<Int> = []; public function new() {} }';
		final poker: String = 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }';
		final keep: String = 'class Keep { public static function put(o:Dynamic):Void {} public static function run(f:() -> Dynamic):Void {} '
			+ 'public static function later(f:() -> Void):Void {} }';
		final holder: String = 'class Holder { public var c:C; public function new(c:C) this.c = c; }';
		function source(field: String, escape: String, ?header: String, ?extra: String): String {
			return 'class C ${header ?? ''} { public var items:Array<Int> = []; var me:$field; public function new() { $escape } '
				+ '${extra ?? ''} function f():Void {} function loop():Void { /*<*/ Poker.poke(me); /*>*/ } }';
		}
		function run(src: String, ?library: Array<String>): ReachResult {
			return ask([src, other, poker, keep, holder], library);
		}
		assertMatch(run(source('Dynamic', '')), r -> r.match(Proven));
		// a static method read as a value binds no object
		assertMatch(run(source('Dynamic', 'Keep.later(g);', null, 'static function g():Void {}')), r -> r.match(Proven));
		for (escape in [
			'me = this;',
			'var d:Any = this; me = d;',
			'Keep.put(this);',
			'Keep.run(() -> this);',
			'if (items.length > 9) throw this;',
			'Keep.later(f);',
			'var h:Holder = new Holder(this); Keep.put(h);',
			'untyped 0;'
		]) refused(run(source('Dynamic', escape)), 'escape `$escape`');
		refused(run(source('Other', 'me = cast this;')), 'an unchecked cast');
		refused(run(source('Dynamic', 'me = self();', null, 'function self():Dynamic return this;')), 'a return');
		final base: String = 'class LibBase { public function new() {} }';
		refused(run(source('Dynamic', 'super();', 'extends LibBase'), [base]), 'a library superclass');
	}

	@:pin('control') @:killer('M-ESCAPE-P-STORE') @:killer('M-ESCAPE-P-CAST') @:killer('M-ESCAPE-P-THROW') @:killer('M-ESCAPE-P-DECL')
	@:killer('M-ESCAPE-P-PARAM') @:killer('M-ESCAPE-P-RETURN') @:killer('M-ESCAPE-P-LAMBDA') @:killer('M-ESCAPE-P-METHOD-VALUE')
	@:killer('M-ESCAPE-P-HELD') @:killer('M-ESCAPE-P-LIBRARY-SUPER') @:killer('M-ESCAPE-P-NATIVE') @:killer('M-ESCAPE-P-TYPED-ARGS') @:killer('M-ESCAPE-DECLARED-SOURCE')
	@:killer('M-ESCAPE-LOCAL-INIT') @:killer('M-ESCAPE-PRIMITIVE-PARAM') @:killer('M-ESCAPE-ASSIGN-VALUE')
	@:killer('M-ESCAPE-IF-VALUE') @:killer('M-ESCAPE-BLOCK-VALUE') @:killer('M-ESCAPE-MACRO-MEMBER') @:killer('M-ESCAPE-MACRO-HAZARD') @:killer('M-ESCAPE-REIFICATION')
	@:killer('M-ESCAPE-THROW') @:killer('M-ESCAPE-DECL') @:killer('M-ESCAPE-PARAM') @:killer('M-ESCAPE-LAMBDA')
	@:killer('M-ESCAPE-STORE') @:killer('M-ESCAPE-CAST') @:killer('M-ESCAPE-METHOD-VALUE') @:killer('M-ESCAPE-HELD')
	@:killer('M-ESCAPE-LIBRARY-SUPER') @:killer('M-ESCAPE-NATIVE')
	public function testEveryEscapeRuleLetsItsSoundTwinThrough(): Void {
		// Each exit a `C` may take out of the type system beside a twin that keeps it typed: the escaped one lets a `Dynamic`
		// handed to `poke` be the `C`, the sound one does not, so `poke`'s `o.items` of an `Other` cannot touch `C.items`.
		final other: String = 'class Other { public var items:Array<Int> = []; public function new() {} }';
		final poker: String = 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }';
		final keep: String = 'class Keep { public static function put(o:Dynamic):Void {} public static function typed(o:C):Void {} '
			+ 'public static function run(f:() -> Dynamic):Void {} public static function later(f:() -> Void):Void {} }';
		final holders: String = 'class Holder { public var c:C; public function new(c:C) this.c = c; } '
			+ 'class Holder2 { public var o:Other; public function new() {} }';
		final lib: String = 'class LibBase { public function new() {} } class LibMath { public static function abs(v:Int):Int return v; '
			+ 'public static function keep(o:Dynamic):Void {} } class LibRaw { static function r():Void untyped 0; }';
		function source(escape: String, ?header: String, ?extra: String): String {
			return 'class C ${header ?? ''} { public var items:Array<Int> = []; var me:Dynamic; public function new() { $escape } '
				+ '${extra ?? ''} function f():Void {} static function g():Void {} '
				+ 'function loop():Void { /*<*/ Poker.poke(me); /*>*/ } }';
		}
		function run(src: String, ?more: Array<String>): ReachResult {
			return ask([src, other, poker, keep, holders].concat(more ?? []), [lib]);
		}
		final pairs: Array<{
			rule: String,
			sound: String,
			escaped: String,
			?header: String,
			?extra: String,
			?more: Array<String>
		}> = [
			{ rule: 'store', sound: 'var c:C = null; c = this;', escaped: 'me = this;' },
			{ rule: 'cast', sound: 'var c:C = cast(this, C);', escaped: 'var o:Other = cast this;' },
			{ rule: 'throw', sound: 'if (items.length > 9) throw "x";', escaped: 'if (items.length > 9) throw this;' },
			{ rule: 'declaration', sound: 'var c:C = this;', escaped: 'var d:Any = this;' },
			{ rule: 'parameter', sound: 'Keep.typed(this);', escaped: 'Keep.put(this);' },
			{
				rule: 'return',
				sound: 'var c:C = mine();',
				escaped: 'function self():Dynamic return this; me = self();',
				extra: 'function mine():C return this;'
			},
			{ rule: 'lambda', sound: 'Keep.run(() -> new Other());', escaped: 'Keep.run(() -> this);' },
			{ rule: 'method value', sound: 'Keep.later(g);', escaped: 'Keep.later(f);' },
			{
				rule: 'held',
				sound: 'var h:Holder2 = new Holder2(); Keep.put(h);',
				escaped: 'var h:Holder = new Holder(this); Keep.put(h);'
			},
			{ rule: 'type argument', sound: 'var cs:Array<C> = [this];', escaped: 'var ds:Array<Dynamic> = [this];' },
			{ rule: 'local', sound: 'var o = new Other(); Keep.put(o);', escaped: 'var o = this; Keep.put(o);' },
			{
				rule: 'declared source',
				sound: 'cs = [this];',
				escaped: 'ds = [this];',
				extra: 'var cs:Array<C>; var ds:Array<Dynamic>;'
			},
			{ rule: 'primitive parameter', sound: '[1].map(q -> LibMath.abs(q));', escaped: 'LibMath.keep(this);' },
			{ rule: 'assignment value', sound: 'var z:Int = 0; Keep.put(z = 1);', escaped: 'var c:C = null; Keep.put(c = this);' },
			{
				rule: 'if value',
				sound: 'Keep.put(if (items.length > 0) 1 else 2);',
				escaped: 'Keep.put(if (items.length > 0) null else this);'
			},
			{ rule: 'block value', sound: 'Keep.put({ trace(1); 2; });', escaped: 'Keep.put({ trace(1); this; });' },
			{
				rule: 'macro member',
				sound: '',
				escaped: '',
				extra: 'macro static function m() { var x = foo; Keep.put(x); return null; }',
				more: []
			},
			{
				rule: 'reification',
				sound: '',
				escaped: 'untyped 0;',
				extra: 'static function r():Dynamic return macro trace(1);'
			}
		];
		for (p in pairs) {
			proven(run(source(p.sound, p.header, p.extra), p.more), '${p.rule}: the sound twin');
			if (p.escaped != '') refused(run(source(p.escaped, p.header, p.extra), p.more), '${p.rule}: the escaped twin');
		}
		// code that runs outside a macro is not excused
		refused(run(source('', null, 'static function m() { var x = foo; Keep.put(x); }')), 'the same body outside a macro');
		// a library superclass, and target code, count in the project only
		proven(run(source(''), ['class D extends LibBase {}']), 'a library superclass of another type');
		refused(run(source('', 'extends LibBase', null)), 'a library superclass of the owner');
		refused(run(source('untyped 0;')), 'target code in the project');
	}

	@:pin('control') @:killer('M-CARRY-TYPED-ARGS') @:killer('M-CARRY-TYPED-ARITY')
	@:killer('M-ESCAPE-UNWRITTEN-ARGS')
	public function testAPositionTypedOnlyOnTheOutsideHoldsAnything(): Void {
		// `Array<Dynamic>` keeps nothing typed: a `C` put in one — literally, by variance from an `Array<C>`, through a
		// parameter, a return, or an alias that hides the argument — reaches `poke` as an `Other` on js and interp.
		final other: String = 'class Other { public var items:Array<Int> = []; public function new() {} }';
		final poker: String = 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }';
		final keep: String = 'class Keep { public static function put(o:Dynamic):Void {} } typedef Dyns = Array<Dynamic>;';
		function source(escape: String, ?extra: String): String {
			return
				'class C { public var items:Array<Int> = []; var arr:Array<Dynamic> = []; var al:Dyns; public function new() { $escape } '
					+ '${extra ?? ''} function loop():Void { /*<*/ Poker.poke(arr[0]); /*>*/ } }';
		}
		function run(src: String): ReachResult {
			return ask([src, other, poker, keep]);
		}
		assertMatch(run(source('var cs:Array<C> = [this];')), r -> r.match(Proven));
		for (escape in [
			'arr = [this];',
			'var cs:Array<C> = [this]; arr = cs;',
			'al = [this];'
		]) refused(run(source(escape)), 'escape `$escape`');
		refused(run(source('keep([this]);', 'function keep(a:Array<Dynamic>):Void arr = a;')), 'a parameter');
		refused(run(source('arr = held();', 'function held():Array<Dynamic> return [this];')), 'a return');
		refused(run(source('Keep.put(mine());', 'function mine():Array<C> return [this];')), 'a container whose arguments nothing says');
	}

	@:pin('control') @:killer('M-ESCAPE-NEW-TYPE') @:killer('M-ESCAPE-RECEIVER-CALL')
	public function testAConstructedReceiverIsItsOwnType(): Void {
		// `new C().loop()` is the commonest entry: the value is a `C`, whose `loop` takes nothing untyped. Handing the new object
		// itself to untyped code is an exit.
		final other: String = 'class Other { public var items:Array<Int> = []; public function new() {} }';
		final poker: String = 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }';
		final keep: String = 'class Keep { public static function put(o:Dynamic):Void {} }';
		function source(main: String): String {
			return 'class C { public var items:Array<Int> = []; var me:Dynamic; public function new() {} '
				+ 'static function main() { $main } function loop():Void { /*<*/ Poker.poke(me); /*>*/ } }';
		}
		assertMatch(ask([source('new C().loop();'), other, poker, keep]), r -> r.match(Proven));
		assertMatch(ask([source('(new C()).loop();'), other, poker, keep]), r -> r.match(Proven));
		refused(ask([source('Keep.put(new C());'), other, poker, keep]), 'a new object handed to untyped code');
	}

	@:pin('control') @:killer('M-REACH-BASE-CLASSPATH') @:killer('M-REACH-TYPES-HELD')
	public function testOnlyTheBuildsVouchForTheClasspath(): Void {
		// `poke` changes an `Other`'s `items`, and a field typed `Other` never holds a `C` — provided no subtype of `C`
		// that is also an `Other` exists outside the index. Only builds whose oracle list is declared complete can say so,
		// and only when the index declares every type they typed: a type a macro made may be exactly that subtype.
		final src: String = 'class C { public var items:Array<Int> = []; var o:Other; public function new() {} '
			+ 'function loop():Void { /*<*/ Poker.poke(o); /*>*/ } }';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'F0.hx', source: src },
			{ file: 'F1.hx', source: 'class Other { public var items:Array<Int> = []; public function new() {} }' },
			{ file: 'F2.hx', source: 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }' },
			{ file: 'std/Array.hx', source: STD_ARRAY }
		];
		final member: MemberRef = { owner: 'C', name: 'items' };
		function run(plugin: CachingGrammarPlugin): ReachResult {
			return MemberReach.forRun(plugin, 'F0.hx', src).mayReach(Region('F0.hx', regionOf(src)), member, Mutate);
		}
		assertMatch(run(QueryTestHelpers.projectPlugin(files)), r -> r.match(Proven));
		assertMatch(run(QueryTestHelpers.projectPlugin(files, null, true, false)), r -> !r.match(Proven));
		final made: CachingGrammarPlugin = QueryTestHelpers.projectPlugin(files);
		final cwd: String = Sys.getCwd();
		made.setResolutionScope({
			declared: true,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new anyparse.query.LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: true
			},
			builds: () -> {
				configurations: [
					{
						name: 'made',
						defined: [],
						everDefined: [],
						compiled: [for (f in files) OracleCoverage.canonical(cwd, f.file)],
						types: [
							for (t in [['C', 'F0.hx'], ['Other', 'F1.hx'], ['Poker', 'F2.hx'], ['Made', 'F0.hx']])
								{ name: t[0], file: OracleCoverage.canonical(cwd, t[1]) }
						]
					}
				],
				library: []
			}
		});
		assertMatch(run(made), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-ESCAPE-NAMED-CLASS')
	public function testAClassNamedToTheClassValueProducerMayBeInstantiatedUntyped(): Void {
		// `Type.resolveClass` hands back a class by the name it is given: a literal naming `C`, or a computed name, lets a `C`
		// be built untyped and reach `poke`; a literal naming another class does not.
		final other: String = 'class Other { public var items:Array<Int> = []; public function new() {} }';
		final poker: String = 'class Poker { public static function poke(o:Other):Void { o.items.push(9); } }';
		final type: String = 'class Type { public static function resolveClass(name:String):Class<Dynamic> return null; }';
		function run(named: String): ReachResult {
			final src: String = 'class C { public var items:Array<Int> = []; var me:Dynamic; public function new() {} '
				+ 'function loop():Void { /*<*/ Poker.poke(me); /*>*/ } }';
			final lib: String = 'class Reg { public static function get(n:String):Class<Dynamic> return Type.resolveClass($named); }';
			return ask([src, other, poker], [type, lib]);
		}
		assertMatch(run('"Other"'), r -> r.match(Proven));
		assertMatch(run('"C"'), r -> !r.match(Proven));
		assertMatch(run('n'), r -> !r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CLASSPATH-DISPATCH') @:killer('M-CARRY-CLASSPATH')
	public function testAClasspathTheIndexDoesNotHoldMayDeclareAnOverrideOrASubtype(): Void {
		// With the builds' classpath not known to be inside the index, a dispatch on a library type may land in an
		// override the index never read, and a receiver of an unrelated class may be a subtype of the owner declared there.
		final src: String = 'class C { public static var items:Array<Int> = []; var b:Base; function f():Void { /*<*/ b.go(); /*>*/ } }';
		final base: String = 'class Base { public function new() {} public function go():Void {} }';
		function run(complete: Bool, project: Array<String>, library: Array<String>): ReachResult {
			final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final files: Array<{ file: String, source: String }> = [for (i in 0...project.length) { file: 'F$i.hx', source: project[i] }];
			final libs: Array<{ file: String, source: String }> = [for (i in 0...library.length) { file: 'L$i.hx', source: library[i] }];
			libs.push({ file: 'std/Array.hx', source: STD_ARRAY });
			return new MemberReach(
				plugin, files, SymbolIndex.build(files.concat(libs), plugin), true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED,
				null, () -> complete
			).mayReach(Region('F0.hx', regionOf(project[0])), { owner: 'C', name: 'items' }, Mutate);
		}
		assertMatch(run(false, [src], [base]), r -> r.match(Unknown(OutOfScope(_))));
		assertMatch(run(true, [src], [base]), r -> r.match(Proven));
		final other: String = 'class C { public var items:Array<Int> = []; var o:Other; function f():Void { /*<*/ grow(); /*>*/ } '
			+ 'function grow():Void o.items.push(9); } class Other { public var items:Array<Int> = []; public function new() {} }';
		assertMatch(run(false, [other], []), r -> r.match(Reached(_)));
		assertMatch(run(true, [other], []), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-BUILD-MACRO')
	public function testBuildMacroOnTheOwnerIsUnknown(): Void {
		final src: String = '@:build(Gen.make()) class C { var items:Array<Int> = []; function f():Void { /*<*/ helper(); /*>*/ } '
			+ 'function helper():Void {} }';
		assertMatch(ask([src]), r -> r.match(Unknown(Reification(_, _))));
	}

	@:pin('control') @:killer('M-REACH-PROPERTY')
	public function testPropertyMemberIsUnknown(): Void {
		final src: String = 'class C { var items(get, never):Array<Int>; function get_items():Array<Int> return []; '
			+ 'function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		assertMatch(ask([src]), r -> r.match(Unknown(UnresolvedDispatch(_, _, _))));
	}

	@:pin('control') @:killer('M-REACH-RECEIVER-OWNER')
	public function testSameNamedMemberOfAnotherTypeIsNotATouch(): Void {
		final src: String = 'class C { var items:Array<Int> = []; var other:Other; function f():Void { /*<*/ g(); /*>*/ } '
			+ 'function g():Void other.items.push(1); }';
		assertMatch(ask([src, 'class Other { public var items:Array<Int> = []; }']), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-SHADOW')
	public function testSameNamedLocalIsNotATouch(): Void {
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } '
			+ 'function g():Void { final items:Array<Int> = []; items.push(1); } }';
		assertMatch(ask([src]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-GRAPH-INIT-WIRING')
	public function testConstructorRunsTheFieldInitializers(): Void {
		// `new Maker()` runs `Maker`'s field initializers, and one of them grows the static collection.
		final src: String = 'class C { static var items:Array<Int> = []; public static function fill():Int { items.push(1); return 1; } '
			+ 'function f():Void { /*<*/ new Maker(); /*>*/ } }';
		assertReachedAt(ask([src, 'class Maker { var x:Int = C.fill(); }']), 'C.fill');
	}

	@:pin('control') @:killer('M-REACH-LIBRARY-GROWTH')
	public function testLibraryBodyIsReadOnDemand(): Void {
		// `Lib.run`'s body is clean, so the project's value-used mutator is never admitted — but only a
		// walk that READS that body can tell: an unread library member is an extern leaf that admits it.
		final src: String = 'class C { var items:Array<Int> = []; var lib:Lib; public function register():Void lib.cb = grow; '
			+ 'function f():Void { /*<*/ lib.run(); /*>*/ } function grow():Void items.push(1); }';
		final lib: String = 'class Lib { public var cb:() -> Void; public function run():Void { var z:Int = 1; } }';
		assertMatch(ask([src], [lib]), r -> r.match(Proven));
		final calling: String = 'class Lib { public var cb:() -> Void; public function run():Void cb(); }';
		assertReachedAt(ask([src], [calling]), 'C.grow');
	}

	@:pin('control') @:killer('M-REACH-CTOR-NOT-DISPATCHED')
	public function testConstructorOfALibrarySubclassIsNotADispatchTarget(): Void {
		// Library code reaches a subclass through its overrides, never through its constructor.
		final src: String = 'class C extends Lib { var items:Array<Int> = []; var lib:Lib; public function new() { super(); items.push(1); } '
			+ 'function f():Void { /*<*/ lib.run(); /*>*/ } }';
		final lib: String = 'class Lib { public var cb:() -> Void; public function new() {} public function run():Void cb(); }';
		assertMatch(ask([src], [lib]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-FRESH-OBJECT')
	public function testConstructingAnotherInstanceIsNotATouch(): Void {
		// A constructor that grows `items` on its own `this` builds a different object than the one `f` runs on;
		// one that grows ANOTHER object's `items` may be handed this one.
		final own: String =
			'class C { var items:Array<Int> = []; public function new() items.push(1); function f():Void { /*<*/ new C(); /*>*/ } }';
		assertMatch(ask([own]), r -> r.match(Proven));
		final other: String = 'class C { var items:Array<Int> = []; public function new(o:C) o.items.push(1); '
			+ 'function f():Void { /*<*/ new C(this); /*>*/ } }';
		assertReachedAt(ask([other]), 'C.new');
	}

	@:pin('control') @:killer('M-GRAPH-OPERATOR-KIND') @:killer('M-REACH-IMPLICIT-ADMIT')
	public function testImplicitOperatorIsRunFromArithmetic(): Void {
		// `a + b` names no call, yet it runs `Deg.add`, which grows `items`.
		final src: String = 'class C { public var items:Array<Int> = []; public static var inst:C; '
			+ 'function f(a:Deg, b:Deg):Void { /*<*/ var z:Deg = a + b; /*>*/ } }';
		final deg: String = 'abstract Deg(Int) { @:op(A + B) function add(o:Deg):Deg { C.inst.items.push(1); return o; } }';
		assertReachedAt(ask([src, deg]), 'Deg.add');
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-ARRAY-CHANGE') @:killer('M-REACH-ARRAY-CHANGE-SITE')
	public function testParameterRegionOfArithmeticDependsOnWhatImplicitFunctionsChange(): Void {
		// No visible call, but an implicitly-called function may run from `+` on a `Deg`: one that writes an array element
		// could change the caller's; one that changes none cannot.
		final src: String = 'class C { function f(xs:Array<Int>, d:Deg):Void { /*<*/ var y:Int = xs[0]; var z:Deg = d + d; /*>*/ } }';
		final changing: String = 'abstract Deg(Int) { @:op(A + B) function add(o:Deg):Deg { Store.all[0] = 1; return o; } }';
		final store: String = 'class Store { public static var all:Array<Int> = []; }';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		final region: Span = regionOf(src);
		assertMatch(
			reachOf([src, changing, store], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), region),
			r -> r.match(Unknown(Aliased(_, _, 'F1.hx', _)))
		);
		final pure: String = 'abstract Deg(Int) { @:op(A + B) function add(o:Deg):Deg return o; }';
		assertMatch(reachOf([src, pure], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), region), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-FRESH')
	public function testFreshUnsharedLocalIsProvenWhateverTheBodyCalls(): Void {
		final src: String = 'class C { function f():Void { final xs:Array<Int> = [1, 2]; xs.push(3); /*<*/ anything(xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-ESCAPE')
	public function testLocalHandedOutIsAnEscape(): Void {
		final src: String = 'class C { function f():Void { final xs:Array<Int> = []; keep(xs); /*<*/ anything(xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-CAPTURE')
	public function testLocalCapturedByAClosureIsAnEscape(): Void {
		final src: String =
			'class C { function f():Void { final xs:Array<Int> = []; final g = () -> xs.length; /*<*/ anything(g, xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-PARAM')
	public function testParameterIsProvenOnlyWhenTheRegionRunsNothing(): Void {
		// The caller may hold the same array, so any code the region runs could change it.
		final calls: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ anything(); var y:Int = xs[0]; /*>*/ } }';
		assertMatch(askLocal(calls, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		final quiet: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = xs[0]; /*>*/ } }';
		assertMatch(askLocal(quiet, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-EXPLAIN-PATH')
	public function testExplainNamesThePath(): Void {
		final src: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void items.push(1); }';
		final reach: MemberReach = reachOf([src], null, true);
		final text: String = reach.explain(reach.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate));
		Assert.isTrue(text.indexOf('C.g') >= 0, text);
		Assert.isTrue(text.indexOf('F0.hx:1') >= 0, text);
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-RUNS-CODE')
	public function testImplicitlyCalledMethodsAreRunFromStringsAndIteration(): Void {
		// `'' + this` runs `toString`, and a `for` over an object runs its `iterator` — neither is a call node.
		final concat: String = 'class C { var items:Array<Int> = []; public function toString():String { items.push(0); return ""; } '
			+ 'function f():Void { /*<*/ var s:String = "" + this; /*>*/ } }';
		assertReachedAt(ask([concat]), 'C.toString');
		final iterate: String =
			'class C { public var items:Array<Int> = []; var bag:Bag; function f():Void { /*<*/ for (z in bag) trace(z); /*>*/ } }';
		final bag: String = 'class Bag { var owner:C; public function iterator():Iterator<Int> { owner.items.push(0); return null; } }';
		assertReachedAt(ask([iterate, bag]), 'Bag.iterator');
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-CONSTRUCTION')
	public function testLiteralTypedAsAConstructedClassRunsItsConstructor(): Void {
		// A literal typed as a `@:structInit` class runs its constructor, wherever the type annotation sits.
		final src: String = 'class C { public static var items:Array<Int> = []; function f():Void { /*<*/ use({x: 1}); /*>*/ } '
			+ 'function use(p:Pt):Void {} }';
		final pt: String = '@:structInit class Pt { public final x:Int; public function new(x:Int) { this.x = x; C.items.push(0); } }';
		assertReachedAt(ask([src, pt]), 'Pt.new');
		// Through a function value the graph names no parameter to type the literal by; the compiler still does.
		final viaValue: String = 'class C { public static var items:Array<Int> = []; var cb:Pt->Void; '
			+ 'function f():Void { /*<*/ cb({x: 1}); /*>*/ } }';
		assertReachedAt(ask([viaValue, pt]), 'Pt.new');
	}

	@:pin('control') @:killer('M-REACH-EXTERN-HANDS')
	public function testBodylessLibraryCallAdmitsImplicitlyCalledMethods(): Void {
		// `Std.string(this)` has no body the graph holds, and it calls `toString` on its argument — an implicitly-called method
		// the walk admits from any code.
		final src: String = 'class C { var items:Array<Int> = []; function toString():String { items.push(0); return ""; } '
			+ 'function f():Void { /*<*/ Std.string(this); /*>*/ } }';
		final std: String = 'extern class Std { public static function string(v:Dynamic):String; }';
		assertReachedAt(ask([src], [std]), 'C.toString');
	}

	@:pin('control') @:killer('M-REACH-UNMODELLED')
	public function testConstructNobodyClassifiedIsUnknown(): Void {
		// An untyped BLOCK is a kind the whitelist does not carry: the walk refuses rather than guess.
		final src: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } function g():Void untyped { run(); } }';
		assertMatch(ask([src]), r -> r.match(Unknown(Unmodelled(_, _, _))));
	}

	@:pin('control') @:killer('M-REACH-ESCAPE-GATE')
	public function testAliasWrittenInTheRegionItselfIsRefused(): Void {
		// The region runs no call, but `alias` IS `items`: the element write grows the field behind the loop.
		final src: String = 'class C { static var alias:Array<Int>; var items:Array<Int> = []; public function new() alias = items; '
			+ 'function f():Void { /*<*/ alias[alias.length] = 0; /*>*/ } }';
		assertMatch(ask([src]), r -> r.match(Unknown(Escape(_, _))));
	}

	@:pin('control') @:killer('M-REACH-REGION-ARRAY-CHANGE')
	public function testParameterRegionWritingAnyOtherArrayIsRefused(): Void {
		// `alias` may be the caller's array; only a fresh local of the function is provably another one.
		final src: String = 'class C { static var alias:Array<Int>; function f(xs:Array<Int>):Void { final mine:Array<Int> = []; '
			+ '/*<*/ mine[0] = xs[0]; alias[alias.length] = 7; /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		final fresh: String =
			'class C { function f(xs:Array<Int>):Void { final mine:Array<Int> = []; /*<*/ mine[0] = xs[0]; mine.push(1); /*>*/ } }';
		assertMatch(askLocal(fresh, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CALLEE-WALK') @:killer('M-REACH-CALLEE-REFUSED')
	public function testParameterRegionCallingProjectCodeDependsOnWhatItChanges(): Void {
		// The caller may hold the same array, so a callee that changes ANY array other than a fresh local of its own may
		// change it; a callee that changes none cannot.
		final growing: String = 'class C { static var all:Array<Int> = []; function f(xs:Array<Int>):Void {'
			+ ' /*<*/ var y:Int = xs[0]; bump(); /*>*/ } static function bump():Void { if (all.length < 5) all.push(1); } }';
		assertMatch(askLocal(growing, 'xs'), r -> r.match(Unknown(Aliased(_, _, 'F0.hx', _))));
		final pure: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = sq(xs[0]); /*>*/ } '
			+ 'static function sq(v:Int):Int return v * v; }';
		assertMatch(askLocal(pure, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CALLEE-BENIGN-EDGE')
	public function testCalleeChangingOnlyAFreshLocalOfItsOwnIsProven(): Void {
		final src: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = dup(xs[0]); /*>*/ } '
			+ 'static function dup(v:Int):Int { final out:Array<Int> = []; out.push(v); return out.length; } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Proven));
		// the same push onto an array the callee did not build may be onto the caller's
		final shared: String = 'class C { static var all:Array<Int> = []; function f(xs:Array<Int>):Void { /*<*/ var y:Int = dup(xs[0]); '
			+ '/*>*/ } static function dup(v:Int):Int { final out:Array<Int> = all; out.push(v); return out.length; } }';
		assertMatch(askLocal(shared, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-COMPOUND-WRITE-ALIAS')
	public function testLocalGivenASharedValueByAnyWriteIsNotFresh(): Void {
		// `x ??= all` stores the shared array in a local that started fresh: its push changes `all`, which may be the
		// caller's, whether the region or a callee does it
		final region: String = 'class C { static var all:Array<Int> = []; function f(xs:Array<Int>):Void { /*<*/ '
			+ 'var x:Null<Array<Int>> = null; x ??= all; x.push(9); var y:Int = xs[0]; /*>*/ } }';
		assertMatch(askLocal(region, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		final callee: String = 'class C { static var all:Array<Int> = []; function f(xs:Array<Int>):Void { /*<*/ var y:Int = xs[0]; '
			+ 'step(); /*>*/ } static function step():Void { var x:Null<Array<Int>> = null; x ??= all; x.push(9); } }';
		assertMatch(askLocal(callee, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		// a fresh value stored the same way leaves the local unshared
		final fresh: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = xs[0]; step(); /*>*/ } '
			+ 'static function step():Void { var x:Null<Array<Int>> = null; x ??= []; x.push(9); } }';
		assertMatch(askLocal(fresh, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-ASSIGNMENT-VALUE-ALIAS')
	public function testAssignmentUsedAsAValueSharesWhatItStores(): Void {
		// `all = xs = [1]` stores the fresh array in `xs` AND hands it to `all`, which `grow` pushes onto
		final src: String = 'class C { static var all:Array<Int> = []; static function grow():Void all.push(9); '
			+ 'function f():Void { var xs:Array<Int> = []; all = xs = [1]; /*<*/ grow(); var y:Int = xs[0]; /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		final statement: String = 'class C { static var all:Array<Int> = []; static function grow():Void all.push(9); '
			+ 'function f():Void { var xs:Array<Int> = []; xs = [1]; /*<*/ grow(); var y:Int = xs[0]; /*>*/ } }';
		assertMatch(askLocal(statement, 'xs'), r -> r.match(Proven));
	}

	@:pin('guard')
	public function testDynamicFunctionACalleeRunsIsRefused(): Void {
		// `hook` does nothing as declared, but any function value may be assigned over it: the syntax reads the call as one
		// through a value.
		final src: String = 'class C { dynamic static function hook():Void {} function f(xs:Array<Int>):Void {'
			+ ' /*<*/ var y:Int = xs[0]; step(); /*>*/ } static function step():Void hook(); }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-CALLEE-REWRITTEN') @:killer('M-REACH-CALLEE-AMBIGUOUS')
	public function testCalleeWhoseBodyIsNotItsSourceIsRefused(): Void {
		// A build macro may rewrite the callee's body; a second type of its name leaves which body runs unknown.
		final region: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = H.id(xs[0]); /*>*/ } }';
		final built: String = '@:build(M.build()) class H { public static function id(v:Int):Int return v; }';
		assertMatch(askLocalIn([region, built], 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		final plain: String = 'class H { public static function id(v:Int):Int return v; }';
		assertMatch(askLocalIn([region, plain, plain], 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
		assertMatch(askLocalIn([region, plain], 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CALLEE-OVERRIDES')
	public function testCalleeDispatchOnALibraryTypeReachesItsLibraryOverrides(): Void {
		// `b.go()` runs `LBase.go` as declared, and `LSub.go` — declared in library code the graph has not read — for an `LSub`.
		final region: String = 'class C { function f(xs:Array<Int>, b:LBase):Void { /*<*/ var y:Int = xs[0]; b.go(); /*>*/ } }';
		final base: String = 'class LBase { public function new() {} public function go():Void {} }';
		final sub: String =
			'class LSub extends LBase { public static var all:Array<Int> = []; override public function go():Void all.push(1); }';
		final reach: MemberReach = reachOf([region], [base, sub], true);
		assertMatch(mutatesNamed(reach, region, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-ENTRY-HAZARDS')
	public function testHazardInTheRegionItselfIsUnknown(): Void {
		final computed: String =
			'class C { var items:Array<Int> = []; var key:String; function f():Void { /*<*/ Reflect.setField(this, key, []); /*>*/ } }';
		assertMatch(ask([computed]), r -> r.match(Unknown(DynamicName(_, _))));
		final native: String =
			"class C { var items:Array<Int> = []; function f():Void { /*<*/ js.Syntax.code('this.items.push(0)'); /*>*/ } }";
		assertMatch(ask([native]), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-REACH-REFLECT-ACCESSOR')
	public function testReflectivePropertyWriteRunsTheSetter(): Void {
		// `Reflect.setProperty(p, 'x', …)` runs `set_x`, which grows `items`.
		final src: String =
			'class C { public var items:Array<Int> = []; var p:P; function f():Void { /*<*/ Reflect.setProperty(p, \'x\', 1); /*>*/ } }';
		final prop: String =
			'class P { public var x(default, set):Int; var owner:C; function set_x(v:Int):Int { owner.items.push(v); return x = v; } }';
		assertReachedAt(ask([src, prop]), 'P.set_x');
	}

	@:pin('control') @:killer('M-REACH-DYNAMIC-VALUE')
	public function testMethodReadOffAnUntypedReceiverIsAdmitted(): Void {
		// `d.grow` is read as a value off a Dynamic and run by `Reflect.callMethod`.
		final src: String = 'class C { var items:Array<Int> = []; function grow():Void items.push(0); '
			+ 'function f():Void { /*<*/ final d:Dynamic = this; Reflect.callMethod(d, d.grow, []); /*>*/ } }';
		assertReachedAt(ask([src]), 'C.grow');
	}

	@:pin('control') @:killer('M-REACH-LIBRARY-BUDGET')
	public function testLibraryGrowthPastTheCapIsUnknown(): Void {
		// A dispatch on a library type must load every library override; past the cap that is a blind spot.
		final src: String = 'class C { var items:Array<Int> = []; var b:Base; function f():Void { /*<*/ b.run(); /*>*/ } }';
		final base: String = 'class Base { public function run():Void {} }';
		final sub: String = 'class Sub extends Base { override public function run():Void {} }';
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }];
		final libs: Array<{ file: String, source: String }> = [{ file: 'L0.hx', source: base }, { file: 'L1.hx', source: sub }];
		final reach: MemberReach = new MemberReach(
			plugin, files, SymbolIndex.build(files.concat(libs), plugin), true, 1, MemberReach.MAX_VISITED, null, () -> true
		);
		assertMatch(
			reach.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Unknown(Budget(_)))
		);
	}

	@:pin('control') @:killer('M-REACH-VISITED-BUDGET')
	public function testWalkPastTheVisitCapIsUnknown(): Void {
		final src: String =
			'class C { var items:Array<Int> = []; function f():Void { /*<*/ a(); /*>*/ } function a():Void b(); function b():Void {} }';
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }];
		final reach: MemberReach = new MemberReach(
			plugin, files, SymbolIndex.build(files, plugin), true, MemberReach.MAX_LIBRARY_FILES, 1, null, () -> true
		);
		assertMatch(
			reach.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Unknown(Budget(_)))
		);
	}

	@:pin('control') @:killer('M-REACH-RERUN-END')
	public function testEscapeLaterInAnEnclosingLoopPrecedesTheNextRun(): Void {
		// `sink = xs` runs after the inner loop, but the outer loop runs the inner one again with `xs` shared.
		final src: String = 'class C { static var sink:Array<Int>; static function grow():Void sink.push(9); '
			+ 'static function f():Void { final xs:Array<Int> = [1]; for (r in 0...2) { /*<*/ grow(); var y:Int = xs[0]; /*>*/ sink = xs; } } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-HAZARDS')
	public function testTargetCodeCanNameAFreshLocal(): Void {
		final src: String =
			"class C { function f():Void { final xs:Array<Int> = [1]; /*<*/ js.Syntax.code('xs.push(0)'); var y:Int = xs[0]; /*>*/ } }";
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(NativeCode(_, _))));
	}

	@:pin('control') @:killer('M-REACH-AMBIGUOUS')
	public function testTypeSharingItsSimpleNameIsUnknown(): Void {
		// Two `Helper`s in two packages merge into one graph node; which one `h.tick` reaches is not provable.
		final src: String =
			'import a.Helper; class C { public var items:Array<Int> = []; var h:Helper; function f():Void { /*<*/ h.tick(this); /*>*/ } }';
		final a: String = 'package a; class Helper { public function tick(c:C):Void {} }';
		final b: String = 'package b; class Helper { public function tick(c:C):Void c.items.push(0); }';
		assertMatch(ask([src, a, b]), r -> r.match(Unknown(Ambiguous('Helper'))));
	}

	@:pin('control') @:killer('M-REACH-LOCAL-SCOPE')
	public function testSharedParameterWithoutTheWholeProjectIsUnknown(): Void {
		final src: String = 'class C { function f(xs:Array<Int>):Void { /*<*/ var y:Int = xs[0] + 1; /*>*/ } }';
		final reach: MemberReach = reachOf([src], null, false);
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(reach.mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)), r -> r.match(Unknown(OutOfScope(_))));
	}

	@:pin('control') @:killer('M-REACH-NOT-A-MEMBER')
	public function testNameTheEnclosingTypeDoesNotDeclareIsUnknown(): Void {
		// `import Store.items;` makes the bare name another type's static: not a member of `C` this can follow.
		final src: String = 'import Store.items; class C { function f():Void { /*<*/ Store.add(); var y:Int = items[0]; /*>*/ } }';
		final store: String = 'class Store { public static var items:Array<Int> = []; public static function add():Void items.push(0); }';
		final reach: MemberReach = reachOf([src, store], null, true);
		final at: Int = src.lastIndexOf('items', src.indexOf(REGION_CLOSE));
		assertMatch(reach.mayMutateNamed('F0.hx', 'items', new Span(at, at + 5), regionOf(src)), r -> r.match(Unknown(OutOfScope(_))));
	}

	@:pin('control') @:killer('M-REACH-FRESH-METHOD')
	public function testCopyOfAnArrayIsFresh(): Void {
		final src: String = 'class C { function f(ys:Array<Int>):Void { final xs:Array<Int> = ys.copy(); /*<*/ anything(xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-BENIGN-CALL')
	public function testParameterRegionCallingOnlyArrayReadersIsProven(): Void {
		// `kinds.contains` reads an array; `out.push` changes only a fresh local — neither can reach the caller's.
		final src: String = 'class C { function f(xs:Array<Int>, kinds:Array<Int>):Void { final out:Array<Int> = []; '
			+ '/*<*/ if (kinds.contains(xs[0])) out.push(xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Proven));
		final copyInto: String = 'class C { function f(xs:Array<Int>, out:Array<Int>):Void { /*<*/ out.push(xs[0]); /*>*/ } }';
		assertMatch(askLocal(copyInto, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-UNTYPED-FRESH-LOCAL')
	public function testUnannotatedFreshLocalArrayIsNotACulprit(): Void {
		// `final out = [];` carries no annotation, so `out.push` is an unresolved call — on a new array nobody else holds.
		final src: String = 'class C { function f(xs:Array<Int>):Void { final out = []; /*<*/ out.push(xs[0]); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CALLS-ENTRY')
	public function testCallsEntryStartsAtTheSitesOnly(): Void {
		// Only the named call runs: `grow()` beside it is not part of the entry.
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { quiet(); grow(); } function quiet():Void {} '
			+ 'function grow():Void items.push(0); }';
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }];
		final reach: MemberReach = new MemberReach(
			plugin, files, SymbolIndex.build(files, plugin), true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED, null, () -> true
		);
		final tree: QueryNode = plugin.parseFile(src);
		final quiet: Array<QueryNode> = callsNamed(tree, 'quiet');
		final grow: Array<QueryNode> = callsNamed(tree, 'grow');
		assertMatch(reach.mayReach(Calls('F0.hx', quiet), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Proven));
		assertReachedAt(reach.mayReach(Calls('F0.hx', grow), { owner: 'C', name: 'items' }, Mutate), 'C.grow');
	}

	@:pin('control') @:killer('M-HOST-ROOTS-ALL')
	public function testRunWithAnUnmatchedRootDoesNotKnowTheProject(): Void {
		// A root that matched nothing may be where the toucher lives, so the run's files are not the project.
		final src: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ helper(); /*>*/ } function helper():Void {} }';
		final complete: MemberReach = MemberReach.forRun(QueryTestHelpers.projectPlugin([{ file: 'F0.hx', source: src }]), 'F0.hx', src);
		assertMatch(complete.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Proven));
		final partial: MemberReach = MemberReach.forRun(
			QueryTestHelpers.projectPlugin([{ file: 'F0.hx', source: src }], null, false), 'F0.hx', src
		);
		assertMatch(
			partial.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Unknown(OutOfScope(_)))
		);
	}

	@:pin('control') @:killer('M-REACH-EXTERN-BODYLESS') @:killer('M-REACH-CALLS-ARGUMENT')
	public function testCallbackArrayMethodRunsTheFunctionItIsHanded(): Void {
		// The lambda is made before the region, so nothing in the region names it — `map` and `sort` run it.
		final mapped: String = 'class C { var items:Array<Int> = []; function f(o:Array<Int>):Void { '
			+ 'final g:Int->Int = v -> { items.push(0); return v; }; /*<*/ o.map(g); /*>*/ } }';
		assertMatch(ask([mapped]), r -> r.match(Reached(_)));
		final sorted: String = 'class C { var items:Array<Int> = []; function f():Void { '
			+ 'final cmp:(Int, Int) -> Int = (a, b) -> { items.push(0); return a - b; }; final t:Array<Int> = [2, 1]; /*<*/ t.sort(cmp); /*>*/ } }';
		assertMatch(ask([sorted]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-EXTERN-BODYLESS') @:killer('M-REACH-EXTERN-CLOSED')
	public function testExternMethodRunsTheFunctionItIsHanded(): Void {
		// A body-less extern member runs target code, which may call the function value it is handed.
		final src: String = 'class C { var items:Array<Int> = []; var lib:Lib; function f():Void { '
			+ 'final g:Int->Void = v -> items.push(v); /*<*/ lib.each(g); /*>*/ } }';
		final lib: String = 'extern class Lib { public function each(f:Int->Void):Void; }';
		assertMatch(ask([src], [lib]), r -> r.match(Reached(_)));
		assertMatch(ask([src, lib]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-BENIGN-CALLBACK') @:killer('M-REACH-CALLS-ARGUMENT')
	public function testParameterRegionCallingACallbackMethodIsRefused(): Void {
		// `filter` runs `g`, and `g` grows the array the caller may have passed in as `xs`.
		final src: String = 'class C { static var alias:Array<Int> = []; function f(xs:Array<Int>, o:Array<Int>):Void { '
			+ 'final g:Int->Bool = v -> { alias.push(0); return true; }; /*<*/ var y:Int = xs[0] + o.filter(g).length; /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-REGION-REF')
	public function testParameterRegionHandingOnAFunctionValueIsRefused(): Void {
		// The region hands `grow` on; whatever receives a function value may run it.
		final src: String = 'class C { static var alias:Array<Int> = []; static function grow(v:Int):Int { alias.push(0); return v; } '
			+ 'function f(xs:Array<Int>):Void { final fs:Array<Int->Int> = []; /*<*/ var y:Int = xs[0]; fs.push(grow); /*>*/ } }';
		assertMatch(askLocal(src, 'xs'), r -> r.match(Unknown(Aliased(_, _, _, _))));
	}

	@:pin('control') @:killer('M-REACH-CALLBACK-PURE')
	public function testImplicitFunctionCallingACallbackMethodMayChangeArrays(): Void {
		// `d + d` may run `Deg.add`, whose `map` runs whatever function `Store.cb` holds.
		final src: String = 'class C { function f(xs:Array<Int>, d:Deg):Void { /*<*/ var y:Int = xs[0]; var z:Deg = d + d; /*>*/ } }';
		final deg: String = 'abstract Deg(Int) { @:op(A + B) function add(o:Deg):Deg { Store.arr.map(Store.cb); return o; } }';
		final store: String = 'class Store { public static var arr:Array<Int> = []; public static var cb:Int->Int; }';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([src, deg, store], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-BODYLESS') @:killer('M-REACH-FORWARDING-OP')
	public function testImplicitFunctionCallingAnExternMayChangeArrays(): Void {
		// An abstract's body-less operator forwards to its underlying value; an extern member runs target code.
		final forwarding: String = 'enum abstract K(Int) { var A = 1; @:op(A < B) static function lt(a:K, b:K):Bool; }';
		final plain: String = 'class C { function f(xs:Array<Int>, k:K):Void { /*<*/ var y:Int = xs[0] + 1; var b:Bool = k < k; /*>*/ } }';
		final from: Int = plain.lastIndexOf('xs', plain.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([plain, forwarding], null, true).mayMutateNamed('F0.hx', 'xs', new Span(from, from + 2), regionOf(plain)),
			r -> r.match(Proven)
		);
		final src: String = 'class C { function f(xs:Array<Int>, d:Deg):Void { /*<*/ var y:Int = xs[0]; var z:Deg = d + d; /*>*/ } }';
		final deg: String = 'abstract Deg(Int) { @:op(A + B) function add(o:Deg):Deg { Store.lib.each(1); return o; } }';
		final store: String = 'class Store { public static var lib:Lib; }';
		final lib: String = 'extern class Lib { public function each(v:Int):Void; public var held:Array<Int>; }';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([src, deg, store, lib], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
	}

	@:pin('control') @:killer('M-REACH-INTERFACE-DISPATCH')
	public function testInterfaceCallDispatchesToTheImplementationOnly(): Void {
		// The interface declaration runs nothing; its implementation, reached by dispatch, grows `items`.
		// The lambda is used as a value: an extern could run it, a dispatch through the interface cannot.
		final src: String = 'class C { public var items:Array<Int> = []; public static var inst:C; var ip:IP; '
			+ 'var cb:Void->Void = () -> inst.items.push(0); function f():Void { /*<*/ ip.m(); /*>*/ } }';
		final ip: String = 'interface IP { function m():Void; }';
		assertMatch(ask([src, ip]), r -> r.match(Proven));
		final impl: String = 'class Impl implements IP { public function new() {} public function m():Void C.inst.items.push(0); }';
		assertReachedAt(ask([src, ip, impl]), 'Impl.m');
	}

	@:pin('control') @:killer('M-REACH-QUESTION-BUDGET')
	public function testLibraryBudgetIsPerQuestion(): Void {
		// The same question asked after another one that loaded library files gets the same answer as when asked first.
		final src: String = 'class C { var items:Array<Int> = []; var a:LA; var b:LB; function f():Void { /*<*/ a.run(); /*>*/ } '
			+ 'function g():Void { /*<*/ b.run(); /*>*/ } }';
		final la: String = 'class LA { public function run():Void {} }';
		final lb: String = 'class LB { public function run():Void {} }';
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }];
		final libs: Array<{ file: String, source: String }> = [{ file: 'L0.hx', source: la }, { file: 'L1.hx', source: lb }];
		final reach: MemberReach = new MemberReach(
			plugin, files, SymbolIndex.build(files.concat(libs), plugin), true, 1, MemberReach.MAX_VISITED, null, () -> true
		);
		final second: Int = src.lastIndexOf(REGION_OPEN) + REGION_OPEN.length;
		final g: Span = new Span(second, src.lastIndexOf(REGION_CLOSE));
		assertMatch(reach.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Proven));
		assertMatch(reach.mayReach(Region('F0.hx', g), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-MEMO-EVERY-SOURCE') @:killer('M-REACH-INCREMENTAL-PURGE')
	public function testMemoIsDroppedWhenAnyProjectFileChanged(): Void {
		// An edit earlier in the pass to ANOTHER project file leaves the memoised graph describing code that is gone.
		final src: String = 'class C { var items:Array<Int> = []; var h:H; public function grow():Void items.push(0); '
			+ 'function f():Void { /*<*/ h.run(); /*>*/ } }';
		final quiet: String = 'class H { public var c:C; public function run():Void {} }';
		final files: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }, { file: 'F1.hx', source: quiet }];
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin(files);
		assertMatch(
			MemberReach.forRun(plugin, 'F0.hx', src).mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate),
			r -> r.match(Proven)
		);
		files[1].source = 'class H { public var c:C; public function run():Void c.grow(); }';
		assertMatch(
			MemberReach.forRun(plugin, 'F0.hx', src).mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate),
			r -> r.match(Reached(_))
		);
		// an edit that changes no declaration is taken in place — and what the old text did is gone with it
		final memo: MemberReach = MemberReach.forRun(plugin, 'F0.hx', src);
		files[1].source = quiet;
		final refreshed: MemberReach = MemberReach.forRun(plugin, 'F0.hx', src);
		Assert.equals(memo, refreshed);
		assertMatch(refreshed.mayReach(Region('F0.hx', regionOf(src)), { owner: 'C', name: 'items' }, Mutate), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-SPLIT-FRESH') @:killer('M-REACH-FRESH-CHAIN')
	public function testSplitOfAStringAndAChainedResultAreFresh(): Void {
		final split: String =
			'class C { function f(text:String):Void { final xs:Array<String> = text.split(","); /*<*/ anything(xs[0]); /*>*/ } }';
		assertMatch(askLocal(split, 'xs'), r -> r.match(Proven));
		final chained: String =
			'class C { function f(text:Array<Int>):Void { final xs:Array<Int> = text.copy().map(v -> v); /*<*/ anything(xs[0]); /*>*/ } }';
		assertMatch(askLocal(chained, 'xs'), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-STRINGBUF-PURE')
	public function testParameterRegionWritingAStringBufferIsProven(): Void {
		// `add(x:T)` may run the `toString` of what it is handed — but a string literal runs nothing.
		final src: String = 'class C { function f(xs:Array<Int>):Void { final b:StringBuf = new StringBuf(); '
			+ '/*<*/ var y:Int = xs[0]; b.add("v"); /*>*/ } }';
		final std: String = 'class StringBuf { public function new() {} public function add<T>(x:T):Void {} }';
		final reach: MemberReach = reachOf([src], [std], true);
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(reach.mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-GRAPH-STORED-FIELD')
	public function testFieldOfAnAnonymousStructureIsNotAMethodRead(): Void {
		// `parts[i].cond` reads a stored `Null<Sp>`, never a method, whatever function elsewhere is called `cond`.
		final src: String = 'class Sp { public function new() {} } class C { static function cond():Void {} '
			+ 'function f(parts:Array<{ cond: Null<Sp>, atom: Int }>):Void { /*<*/ final c:Null<Sp> = parts[0].cond; /*>*/ } }';
		final at: Int = src.lastIndexOf('parts', src.indexOf(REGION_CLOSE));
		assertMatch(reachOf([src], null, true).mayMutateNamed('F0.hx', 'parts', new Span(at, at + 5), regionOf(src)), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-PLACEHOLDER') @:killer('M-REACH-CLOSURE-CHANNELS') @:killer('M-REACH-CLOSURE-LIBRARY')
	public function testImplicitMethodAnywhereMayRunAFunctionValue(): Void {
		// `'' + o` runs `o.toString`, which calls whatever `cb` holds — a lambda growing `items`. The toString is found
		// through the index even when its library file was never read, and it reaches the lambda through a call it cannot
		// resolve, not through an edge.
		final src: String = 'class C { var items:Array<Int> = []; var o:Lib; public function new() Lib.cb = () -> items.push(0); '
			+ 'function f():Void { /*<*/ var s:String = "" + o; /*>*/ } }';
		final lib: String = 'class Lib { public static var cb:() -> Void; public function new() {} '
			+ 'public function toString():String { cb(); return ""; } }';
		assertMatch(ask([src], [lib]), r -> r.match(Reached(_)));
		assertMatch(ask([src, lib]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-PURE-PARAMS')
	public function testLibraryCallHandedAnObjectIsNotPure(): Void {
		// `add(x:T)` converts what it is handed: a literal runs nothing, an object may run its `toString`, whose code the
		// region then runs.
		final std: String = 'class StringBuf { var s:String = ""; public function new() {} public function add<T>(x:T):Void s += x; }';
		final obj: String = 'class Obj { public static var all:Array<Int> = []; public function new() {} '
			+ 'public function toString():String { all.push(1); return ""; } }';
		final src: String = 'class C { function f(xs:Array<Int>, o:Obj):Void { final b:StringBuf = new StringBuf(); '
			+ '/*<*/ var y:Int = xs[0]; b.add(o); /*>*/ } }';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([src, obj], [std], true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
	}

	@:pin('control') @:killer('M-REACH-FRESH-TYPED')
	public function testFreshMethodMustBeTheReceiverTypesOwn(): Void {
		// `'k'.copy()` and `seed.split(",")` on an array are `using` extensions — String has no `copy`, Array no `split` —
		// which may return a shared array.
		final ext: String = 'class Ext { public static var list:Array<Int> = []; public static function copy(s:String):Array<Int> return list; '
			+ 'public static function split(a:Array<Int>, sep:String):Array<Int> return list; public static function poke():Void list.push(0); }';
		final copy: String =
			'using Ext; class C { function f():Void { final xs:Array<Int> = "k".copy(); /*<*/ Ext.poke(); var y:Int = xs[0]; /*>*/ } }';
		final at: Int = copy.lastIndexOf('xs', copy.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([copy, ext], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(copy)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
		final split: String = 'using Ext; class C { function f():Void { final seed:Array<Int> = [5]; final xs:Array<Int> = seed.split(","); '
			+ '/*<*/ Ext.poke(); var y:Int = xs[0]; /*>*/ } }';
		final from: Int = split.lastIndexOf('xs', split.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([split, ext], null, true).mayMutateNamed('F0.hx', 'xs', new Span(from, from + 2), regionOf(split)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-INSTANCE')
	public function testExternHandedOnlyInertValuesRunsNoProgramCode(): Void {
		// An extern whose every member takes and returns numbers, strings or itself — the std `Date` shape — can hold no
		// array or function value of the program, so its `toString` changes nothing the region shares.
		final src: String = 'class C { function f(xs:Array<Int>, s:Stamp, d:Dump):Void { /*<*/ var y:Int = xs[0] + 1; /*>*/ } }';
		final stamp: String = 'extern class Stamp { public function new(t:Float):Void; public function getTime():Float; '
			+ 'public function toString():String; public static function now():Stamp; }';
		// a STATIC `toString` is an ordinary call, never an implicit one
		final dump: String = 'class Dump { public static var all:Array<Int> = []; public static function toString(x:Int):String { all.push(x); '
			+ 'return ""; } }';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([src], [stamp, dump], true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)), r -> r.match(Proven)
		);
	}

	@:pin('control') @:killer('M-REACH-IMPLICIT-WRITTEN') @:killer('M-REACH-EXTERN-IMPLICIT-QUIET') @:killer('M-REACH-SITE-SELF-ALIAS')
	public function testImplicitMembersOnlyOfTypesInPlayCount(): Void {
		// A library toString that grows an array runs only on an instance of its class — no code the run reads names
		// `Loud`, so none is in play. An extern's own conversion runs target code that calls back only through a value
		// it is handed. A typedef re-exporting `Quiet` under its own name is not a second declaration of it.
		final src: String = 'class C { function f(xs:Array<Int>, q:Quiet, n:Native):Void { /*<*/ var y:Int = xs[0] + 1; /*>*/ } }';
		final loud: String =
			'class Loud { public static var all:Array<Int> = []; public function toString():String { all.push(0); return ""; } }';
		final native: String = 'extern class Native { public var data:Array<Int>; public function toString():String; }';
		final quiet: String = 'package q; class Quiet { public function toString():String return "q"; }';
		final alias: String = 'typedef Quiet = q.Quiet;';
		final at: Int = src.lastIndexOf('xs', src.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([src], [loud, native, quiet, alias], true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(src)),
			r -> r.match(Proven)
		);
	}

	@:pin('control') @:killer('M-REACH-EXTERN-INERT')
	public function testExternClosedOverInertValuesAdmitsNoFunctionValue(): Void {
		// Target code behind an extern that takes and returns only numbers, strings and itself was handed no function
		// value — so calling it cannot run the lambda that grows `items`.
		final src: String = 'class C { var items:Array<Int> = []; var s:Stamp; var cb:Void->Void; '
			+ 'public function new() cb = () -> items.push(0); function f():Void { /*<*/ var t:Float = s.getTime(); /*>*/ } }';
		final stamp: String = 'extern class Stamp { public function new(t:Float):Void; public function getTime():Float; }';
		assertMatch(ask([src], [stamp]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-CONSTRUCTIBLE') @:killer('M-REACH-INDEX-IMPLICIT')
	public function testLibraryInstanceMadeOutOfSightRunsItsMembers(): Void {
		// A library factory hands out a `Hidden` no project code names — as `Dynamic`, as its superclass, as an
		// `Iterable` — and the string conversion or loop runs `Hidden.toString` / `HiddenBag.iterator`, which call the
		// lambda growing `items`. The instance exists because library code constructs it, however it is held.
		final lib: Array<String> = [
			'class Base { public function new() {} }',
			'class Hidden extends Base { public function new() super(); public function toString():String { Factory.cb(); return "H"; } }',
			'class HiddenBag { public function new() {} public function iterator():Iterator<Int> { Factory.cb(); return null; } }',
			'class Factory { public static var cb:() -> Void; public static function make():Dynamic return new Hidden(); '
				+ 'public static function makeIterable():Iterable<Int> return new HiddenBag(); }'
		];
		final head: String = 'class C { var items:Array<Int> = []; var x:Dynamic; var b:Base; var it:Iterable<Int>; '
			+ 'public function new() Factory.cb = () -> items.push(0); ';
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = "" + x; /*>*/ } }'], lib), r -> r.match(Reached(_)));
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = "" + b; /*>*/ } }'], lib), r -> r.match(Reached(_)));
		assertMatch(ask([head + 'function f():Void { /*<*/ for (e in it) trace(e); /*>*/ } }'], lib), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-QUESTION-ENTERED')
	public function testAnAnswerDoesNotDependOnTheQuestionsBeforeIt(): Void {
		// Asked fresh, and asked after a question whose walk loaded the factory's file and entered code spelling the
		// abstract `Loud`: the same answer. Nothing an earlier question read may widen what a later one admits.
		final lib: Array<String> = [
			'class Hidden { public function new() {} public function toString():String { Factory.cb(); return "H"; } }',
			'class Factory { public static var cb:() -> Void; public static function make():Dynamic return new Hidden(); }',
			'abstract Loud(Int) from Int { @:to public function toText():String { Factory.cb(); return ""; } }'
		];
		final src: String = 'class C { public static var items:Array<Int> = []; var x:Dynamic; '
			+ 'public function new() Factory.cb = () -> items.push(0); '
			+ 'function f():Void { /*<*/ var s:String = "" + x; /*>*/ } function g():Void { /*<*/ var y:Int = 1; /*>*/ } '
			+ 'function h():Void { /*<*/ var l:Loud = 1; Factory.make(); /*>*/ } }';
		final regions: Array<Span> = regionsOf(src);
		final member: MemberRef = { owner: 'C', name: 'items' };
		for (i in 0...2) {
			final fresh: ReachResult = reachOf([src], lib, true).mayReach(Region('F0.hx', regions[i]), member, Mutate);
			final reach: MemberReach = reachOf([src], lib, true);
			reach.mayReach(Region('F0.hx', regions[2]), member, Mutate);
			final after: ReachResult = reach.mayReach(Region('F0.hx', regions[i]), member, Mutate);
			Assert.equals(fresh.getIndex(), after.getIndex(), 'region $i: fresh $fresh, after another question $after');
		}
		assertMatch(reachOf([src], lib, true).mayReach(Region('F0.hx', regions[1]), member, Mutate), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-EXTERN-OBJECT')
	public function testExternHandedAnObjectRunsItsMembersByName(): Void {
		// `JSON.stringify(this)` calls `toJSON` BY NAME in target code: every member of what the extern is handed is a
		// reflective access. An object whose type declares no toucher admits nothing.
		final nj: String = "@:native('JSON') extern class NJ { public static function stringify(v:Dynamic):String; }";
		final src: String = 'class C { var items:Array<Int> = []; public function toJSON(k:Dynamic):Dynamic { items.push(0); return 1; } '
			+ 'function f():Void { /*<*/ var s:String = NJ.stringify(this); /*>*/ } }';
		assertReachedAt(ask([src], [nj]), 'C.toJSON');
		final other: String = 'class C { var items:Array<Int> = []; var o:Other; public function toJSON(k:Dynamic):Dynamic { items.push(0); '
			+ 'return 1; } function f():Void { /*<*/ var s:String = NJ.stringify(o); /*>*/ } }';
		final otherType: String = 'class Other { public function new() {} public function toJSON(k:Dynamic):Dynamic return 2; }';
		assertMatch(ask([other, otherType], [nj]), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-EXTERN-NESTED')
	public function testExternHandedAnObjectRunsWhatItsFieldsHoldByName(): Void {
		// `JSON.stringify(h)` walks `h`'s fields as it walks `h`: the `toJSON` of the `Child` a field holds runs too.
		final nj: String = "@:native('JSON') extern class NJ { public static function stringify(v:Dynamic):String; }";
		final src: String = 'class C { public static var items:Array<Int> = []; var h:Holder; '
			+ 'function f():Void { /*<*/ var s:String = NJ.stringify(h); /*>*/ } }';
		final holder: String = 'class Holder { public var child:Child; public var n:Int = 0; public function new() {} }';
		final child: String =
			'class Child { public function new() {} public function toJSON(k:Dynamic):Dynamic { C.items.push(0); return 1; } }';
		assertReachedAt(ask([src, holder, child], [nj]), 'Child.toJSON');
		// the same walk when library code builds and hands the holder: no project value leaves the type system
		final lib: String = 'class Lib { public static function dump():String { var h:LHolder = new LHolder(); return NJ.stringify(h); } } '
			+ 'class LHolder { public var child:LChild = new LChild(); public function new() {} } '
			+ 'class LChild { public function new() {} public function toJSON(k:Dynamic):Dynamic { C.grow(); return 1; } }';
		final call: String = 'class C { public static var items:Array<Int> = []; public static function grow():Void items.push(0); '
			+ 'function f():Void { /*<*/ Lib.dump(); /*>*/ } }';
		assertMatch(ask([call], [nj, lib]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-EXTERN-ENUM-ARGS') @:killer('M-REACH-EXTERN-ENUM-CTOR')
	public function testExternHandedAnEnumValueRunsWhatItsArgumentsHoldByName(): Void {
		// `h.e` holds `Box(new Child())`: `JSON.stringify(h)` walks the constructor's argument and runs `Child.toJSON`. An
		// enum whose constructors hold only numbers hands nothing that runs code.
		final nj: String = "@:native('JSON') extern class NJ { public static function stringify(v:Dynamic):String; }";
		final child: String =
			'class Child { public function new() {} public function toJSON(k:Dynamic):Dynamic { C.items.push(0); return 1; } }';
		function region(holder: String): ReachResult {
			final src: String = 'class C { public static var items:Array<Int> = []; var h:Holder; '
				+ 'function f():Void { /*<*/ var s:String = NJ.stringify(h); /*>*/ } }';
			return ask([src, holder, child], [nj, '@:coreType abstract Int {}']);
		}
		assertReachedAt(
			region('enum E { Box(o:Child); Nothing; } class Holder { public var e:E; public function new() {} }'), 'Child.toJSON'
		);
		assertMatch(
			region('enum E { Num(n:Int); Nothing; } class Holder { public var e:E; public function new() {} }'), r -> r.match(Proven)
		);
		// the same walk when library code builds and hands the value: no project value leaves the type system
		final lib: String = 'class Lib { public static function dump():String { var h:LHolder = LHolder.make(); return NJ.stringify(h); } } '
			+ 'enum LE { Box(o:LChild); Nothing; } '
			+ 'class LHolder { public var e:LE; function new(e:LE) this.e = e; public static function make():LHolder return null; } '
			+ 'class LChild { public function new() {} public function toJSON(k:Dynamic):Dynamic { C.grow(); return 1; } }';
		final call: String = 'class C { public static var items:Array<Int> = []; public static function grow():Void items.push(0); '
			+ 'function f():Void { /*<*/ Lib.dump(); /*>*/ } }';
		assertMatch(ask([call], [nj, lib, '@:coreType abstract Int {}']), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-EXTERN-RECEIVER')
	public function testExternMethodRunsItsReceiversMembersByName(): Void {
		// The native `Date.prototype.toJSON` calls `this.toISOString()` by name: a program subclass's override-free
		// method runs from a bare call of the extern member.
		final jdate: String = "@:native('Date') extern class JDate { public function new(); public function toJSON(k:String):Dynamic; }";
		final src: String = 'class C extends JDate { var items:Array<Int> = []; public function new() super(); '
			+ 'public function toISOString():String { items.push(0); return ""; } function f():Void { /*<*/ toJSON(""); /*>*/ } }';
		assertReachedAt(ask([src], [jdate]), 'C.toISOString');
	}

	@:pin('control') @:killer('M-REACH-JOIN-CONVERTS') @:killer('M-REACH-JOIN-CULPRIT')
	public function testJoinConvertsTheElementsToStrings(): Void {
		// `os.join(",")` runs each element's `toString` in target code — no `+` anywhere in the region.
		final obj: String = 'class Obj { public function new() {} public function toString():String { C.items.push(0); return ""; } }';
		final src: String = 'class C { public static var items:Array<Int> = []; var os:Array<Obj>; '
			+ 'function f():Void { /*<*/ var s:String = os.join(","); /*>*/ } }';
		assertMatch(ask([src, obj]), r -> !r.match(Proven));
		final local: String = 'class C { public static var items:Array<Int> = []; '
			+ 'function f(xs:Array<Int>, os:Array<Obj>):Void { /*<*/ var y:Int = xs[0]; var s:String = os.join(","); /*>*/ } }';
		final at: Int = local.lastIndexOf('xs', local.indexOf(REGION_CLOSE));
		assertMatch(
			reachOf([local, obj], null, true).mayMutateNamed('F0.hx', 'xs', new Span(at, at + 2), regionOf(local)),
			r -> r.match(Unknown(Aliased(_, _, _, _)))
		);
	}

	@:pin('control') @:killer('M-REACH-MEMO-DYNAMIC')
	public function testMemoIsRebuiltWhenAMethodBecomesDynamic(): Void {
		// Another file's call to `b.m()` was resolved as a plain call; once `m` is `dynamic` it runs whatever function
		// value the member holds — the lambda growing `items` — and only a rebuild re-reads that call.
		final src: String = 'class C { public var items:Array<Int> = []; var b:B; function f():Void { /*<*/ b.m(); /*>*/ } }';
		final assigner: String = 'class Z { public function g(c:C, b:B):Void b.m = () -> c.items.push(0); }';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'F0.hx', source: src },
			{ file: 'F1.hx', source: 'class B { public function m():Void {} }' },
			{ file: 'F2.hx', source: assigner }
		];
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin(files);
		final member: MemberRef = { owner: 'C', name: 'items' };
		assertMatch(
			MemberReach.forRun(plugin, 'F0.hx', src).mayReach(Region('F0.hx', regionOf(src)), member, Mutate), r -> r.match(Proven)
		);
		files[1].source = 'class B { public dynamic function m():Void {} }';
		assertMatch(
			MemberReach.forRun(plugin, 'F0.hx', src).mayReach(Region('F0.hx', regionOf(src)), member, Mutate), r -> r.match(Reached(_))
		);
	}

	@:pin('control') @:killer('M-REACH-FAMILY-MATCH')
	public function testIterationRunsOnlyFromALoopOverAValue(): Void {
		// `Bag.iterator` runs only where a `for … in` iterates a value: an index access is another family's site.
		final lib: Array<String> = [
			'class Bag { public function new() {} public function iterator():Iterator<Int> { Lib.cb(); return null; } }',
			'class Lib { public static var cb:() -> Void; public static function make():Dynamic return new Bag(); }'
		];
		final head: String = 'class C { var items:Array<Int> = []; var d:Dynamic; public function new() Lib.cb = () -> items.push(0); ';
		assertMatch(ask([head + 'function f():Void { /*<*/ var y:Int = d[0]; /*>*/ } }'], lib), r -> r.match(Proven));
		assertMatch(ask([head + 'function f():Void { /*<*/ for (e in d) trace(e); /*>*/ } }'], lib), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-TYPED-SITE')
	public function testAConversionOfATypedOperandRunsOnlyItsTypesMethod(): Void {
		// `"" + q` with `q:Quiet` runs `Quiet.toString` or an override — never `Loud.toString`, which only a value whose
		// type is not known may reach.
		final lib: Array<String> = [
			'class Loud { public function new() {} public function toString():String { Lib.cb(); return "L"; } }',
			'class Quiet { public function new() {} public function toString():String return "Q"; }',
			'class Lib { public static var cb:() -> Void; public static function make():Dynamic return new Loud(); }'
		];
		final head: String = 'class C { var items:Array<Int> = []; var q:Quiet; var d:Dynamic; '
			+ 'public function new() Lib.cb = () -> items.push(0); ';
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = "" + q; /*>*/ } }'], lib), r -> r.match(Proven));
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = "" + d; /*>*/ } }'], lib), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-ABSTRACT-VISIBLE') @:killer('M-REACH-MEMBER-READ') @:killer('M-REACH-INFERRED-MEMBER')
	@:killer('M-GRAPH-IMPLICIT-META')
	public function testAnAbstractsMemberRunsOnlyWhereItsTypeIsInReach(): Void {
		// `Loud`'s conversion is a static call the compiler puts where a value's STATIC type is `Loud`: the region must be
		// able to hold one — by spelling it, or by reading a member declared with it, or one whose type is inferred from it.
		final lib: Array<String> = [
			'abstract Loud(Int) from Int { @:to public function toText():String { Keeper.cb(); return ""; } }',
			'class Keeper { public static var cb:() -> Void; public static var loud:Loud = 1; public static var guess = (1 : Loud); '
				+ 'public static var plain:Int = 1; }'
		];
		final head: String = 'class C { public static var items:Array<Int> = []; public function new() Keeper.cb = () -> items.push(0); ';
		assertMatch(ask([head + 'function f():Void { /*<*/ var y:Int = Keeper.plain; /*>*/ } }'], lib), r -> r.match(Proven));
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = Keeper.loud; /*>*/ } }'], lib), r -> r.match(Reached(_)));
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = Keeper.guess; /*>*/ } }'], lib), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-INDEX-OPERATOR')
	public function testIndexOperatorOverloadRunsFromAnIndexAccess(): Void {
		// `@:op([])` overloads the index access, though its annotation projects as an array literal: `l[0]` runs it.
		final lst: String =
			'abstract Lst(Array<Int>) { public static var cb:() -> Void; @:op([]) function get(i:Int):Int { cb(); return 0; } }';
		final src: String = 'class C { var items:Array<Int> = []; var l:Lst; public function new() Lst.cb = () -> items.push(0); '
			+ 'function f():Void { /*<*/ var y:Int = l[0]; /*>*/ } }';
		assertMatch(ask([src], [lst]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-EXTENSION-READ') @:killer('M-REACH-GENERATED-READ') @:killer('M-REACH-FILE-IMPORTS')
	@:killer('M-GRAPH-READ-DECLARED')
	public function testAReadNoReceiverTypeDeclaresReachesWhatItMayBe(): Void {
		// `b.loudOf()` is a static extension, declared on `Ext`, not on the receiver's type `Box`, and only the file's
		// `using` brings `Ext` in; `g.made` reads a member a build macro generated, which nothing indexed describes — the
		// `made` another type declares is not it. Either may hand back a `Loud`, whose conversion changes `items`. The
		// extension is body-less, so no body the walk enters spells `Loud` for it, and no function value reaches `items`.
		final loud: String = 'abstract Loud(Int) from Int { @:to public function toText():String { C.items.push(0); return ""; } }';
		final lib: Array<String> = [
			'@:coreType abstract Int {}',
			'class Box { public function new() {} }',
			'class Other { public var made:Int = 0; public function new() {} }',
			'extern class Ext { public static function loudOf(b:Box):Loud; }',
			'class Built { public static function build():Array<Dynamic> return null; }',
			'@:build(Built.build()) class Gen { public function new() {} }'
		];
		final head: String = 'using Ext; class C { public static var items:Array<Int> = []; var n:Int; var b:Box; var g:Gen; '
			+ 'public function new() {} ';
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = b.loudOf(); /*>*/ } }', loud], lib), r -> r.match(Reached(_)));
		assertMatch(ask([head + 'function f():Void { /*<*/ var s:String = g.made; /*>*/ } }', loud], lib), r -> r.match(Reached(_)));
		assertMatch(ask([head + 'function f():Void { /*<*/ var y:Int = n; /*>*/ } }', loud], lib), r -> r.match(Proven));
	}

	@:pin('control') @:killer('M-REACH-COMPOUND-OPERATOR')
	public function testCompoundAssignmentRunsTheBinaryOperatorOverload(): Void {
		// `acc += 1` runs an `@:op(A + B)` overload: no `+` node is written.
		final acc: String = 'abstract Acc(Int) from Int { public static var cb:() -> Void; '
			+ '@:op(A + B) function add(o:Acc):Acc { cb(); return this; } }';
		final src: String = 'class C { public static var items:Array<Int> = []; var acc:Acc; public function new() Acc.cb = () -> items.push(0); '
			+ 'function f():Void { /*<*/ acc += 1; /*>*/ } }';
		assertMatch(ask([src], [acc]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-LIVE-HAZARDS') @:killer('M-REACH-LIVE-EDGES')
	public function testBranchNoConfiguredBuildCompilesIsNotWalked(): Void {
		// `#if js` target code and a `#if js` call to a function that changes `items`: under builds that provably leave
		// `js` undefined neither runs; one build that defines it — or none known at all — keeps both.
		final lib: String = 'class Lib { public static function go():Void { #if js untyped __js__("x"); #else trace(1); #end } }';
		final native: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ Lib.go(); /*>*/ } }';
		final call: String = 'class C { var items:Array<Int> = []; function f():Void { /*<*/ g(); /*>*/ } '
			+ 'function g():Void { #if js h(); #else trace(1); #end } function h():Void items.push(0); }';
		final cpp: ReachConfiguration = {
			name: 'cpp',
			defined: ['cpp', 'sys'],
			everDefined: ['cpp', 'sys'],
			compiled: [],
			types: []
		};
		final js: ReachConfiguration = {
			name: 'js',
			defined: ['js'],
			everDefined: ['js'],
			compiled: [],
			types: []
		};
		assertMatch(configuredAsk([native], [lib], [cpp]), r -> r.match(Proven));
		assertMatch(configuredAsk([native], [lib], [cpp, js]), r -> r.match(Unknown(_)));
		assertMatch(configuredAsk([native], [lib], []), r -> r.match(Unknown(_)));
		assertMatch(configuredAsk([call], null, [cpp]), r -> r.match(Proven));
		assertMatch(configuredAsk([call], null, [cpp, js]), r -> r.match(Reached(_)));
	}

	@:pin('control') @:killer('M-REACH-COMPILED-ONLY') @:killer('M-REACH-ESCALATE-NEVER') @:killer('M-REACH-ESCALATE-ALWAYS')
	@:killer('M-REACH-ESCALATE-INCOMPLETE')
	public function testLibraryFileNoConfiguredBuildParsesIsNotInPlay(): Void {
		// `Loud` lives in a library file none of the configured builds parses: its `toString` runs in none of them. The
		// region's raw `#if js` splice makes the question consult the builds, and so does the same conversion in `g`, whose
		// answer rests on which library code may run; a touch in the region itself (`h`) needs neither and probes nothing.
		final src: String = 'class C { var items:Array<Int> = []; var d:Dynamic; public function new() Loud.cb = () -> items.push(0); '
			+ 'function f():Void { /*<*/ var s:String = "" + d; var t:Dynamic = d #if js .x #end; /*>*/ } '
			+ 'function g():Void { var z:String = "" + d; } function h():Void { items.push(1); } }';
		final loud: String = 'class Loud { public static var cb:() -> Void; public static var one:Loud = new Loud(); public function new() {} '
			+ 'public function toString():String { cb(); return ""; } }';
		var probes: Int = 0;
		function reach(parsesLoud: Bool): MemberReach {
			final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final project: Array<{ file: String, source: String }> = [{ file: 'F0.hx', source: src }];
			final library: Array<{ file: String, source: String }> = [{ file: 'L0.hx', source: loud }];
			final build: ReachConfiguration = {
				name: 'b',
				defined: [],
				everDefined: [],
				compiled: parsesLoud ? ['F0.hx', 'L0.hx'] : ['F0.hx'],
				types: [
					{
						name: 'C',
						file: OracleCoverage.canonical(Sys.getCwd(), 'F0.hx')
					}
				].concat(parsesLoud ? [{ name: 'Loud', file: OracleCoverage.canonical(Sys.getCwd(), 'L0.hx') }] : [])
			};
			plugin.setResolutionScope({
				declared: true,
				sources: () -> {
					report: project,
					projectRoots: [],
					library: new anyparse.query.LibrarySources(library),
					rootsMatched: true,
					rootsAllMatched: true
				},
				builds: () -> {
					probes++;
					{ configurations: [build], library: parsesLoud ? library : [] };
				}
			});
			return MemberReach.forRun(plugin, 'F0.hx', src);
		}
		final member: MemberRef = { owner: 'C', name: 'items' };
		final gBody: Int = src.indexOf('var z');
		final hBody: Int = src.indexOf('items.push(1)');
		final plain: MemberReach = reach(false);
		assertMatch(plain.mayReach(Region('F0.hx', new Span(hBody, hBody + 14)), member, Mutate), r -> r.match(Reached(_)));
		Assert.equals(0, probes, 'a question that needed neither the branches nor the classpath of the builds consulted them');
		assertMatch(plain.mayReach(Region('F0.hx', regionOf(src)), member, Mutate), r -> r.match(Proven));
		Assert.equals(1, probes, 'a question that met a raw conditional region did not consult the builds exactly once');
		assertMatch(plain.mayReach(Region('F0.hx', new Span(gBody, src.indexOf(';', gBody) + 1)), member, Mutate), r -> r.match(Proven));
		assertMatch(reach(true).mayReach(Region('F0.hx', regionOf(src)), member, Mutate), r -> r.match(Reached(_)));
	}

	/** `ask` under the builds `configurations`. */
	private function configuredAsk(
		project: Array<String>, library: Null<Array<String>>, configurations: Array<ReachConfiguration>
	): ReachResult {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [for (i in 0...project.length) { file: 'F$i.hx', source: project[i] }];
		final libs: Array<{ file: String, source: String }> = [
			for (i in 0...(library ?? []).length) { file: 'L$i.hx', source: (library ?? [])[i] }
		];
		libs.push({ file: 'std/Array.hx', source: STD_ARRAY });
		final reach: MemberReach = new MemberReach(
			plugin, files, SymbolIndex.build(files.concat(libs), plugin), true, MemberReach.MAX_LIBRARY_FILES, MemberReach.MAX_VISITED,
			configurations, () -> true
		);
		return reach.mayReach(Region('F0.hx', regionOf(project[0])), { owner: 'C', name: 'items' }, Mutate);
	}

	/** Every call node of `tree` whose callee is the bare name `name`. */
	private static function callsNamed(tree: QueryNode, name: String): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function walk(n: QueryNode): Void {
			if (n.kind == 'Call' && n.children.length > 0 && n.children[0].name == name) out.push(n);
			for (c in n.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Ask whether the region of `project[0]` may mutate `C.items`. */
	private function ask(project: Array<String>, ?library: Array<String>, scopeKnown: Bool = true): ReachResult {
		return reachOf(project, library, scopeKnown).mayReach(Region('F0.hx', regionOf(project[0])), { owner: 'C', name: 'items' }, Mutate);
	}

	/** Ask whether the region of `src` may mutate what the local or parameter `name` holds. */
	private function askLocal(src: String, name: String): ReachResult {
		return askLocalIn([src], name);
	}

	/** `askLocal` over the whole `project`, whose first file holds the region. */
	private function askLocalIn(project: Array<String>, name: String): ReachResult {
		return mutatesNamed(reachOf(project, null, true), project[0], name);
	}

	/** Ask `reach` whether the region of `src` (the file `F0.hx`) may mutate what `name`, read last in it, holds. */
	private static function mutatesNamed(reach: MemberReach, src: String, name: String): ReachResult {
		final at: Int = src.lastIndexOf(name, src.indexOf(REGION_CLOSE));
		return reach.mayMutateNamed('F0.hx', name, new Span(at, at + name.length), regionOf(src));
	}

	private function reachOf(project: Array<String>, library: Null<Array<String>>, scopeKnown: Bool): MemberReach {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [for (i in 0...project.length) { file: 'F$i.hx', source: project[i] }];
		final libs: Array<{ file: String, source: String }> = [
			for (i in 0...(library ?? []).length) { file: 'L$i.hx', source: (library ?? [])[i] }
		];
		libs.push({ file: 'std/Array.hx', source: STD_ARRAY });
		return new MemberReach(
			plugin, files, SymbolIndex.build(files.concat(libs), plugin), scopeKnown, MemberReach.MAX_LIBRARY_FILES,
			MemberReach.MAX_VISITED, null, () -> true
		);
	}

	/** Every region of `src`, in order. */
	private static function regionsOf(src: String): Array<Span> {
		final out: Array<Span> = [];
		var at: Int = src.indexOf(REGION_OPEN);
		while (at >= 0) {
			final from: Int = at + REGION_OPEN.length;
			out.push(new Span(from, src.indexOf(REGION_CLOSE, from)));
			at = src.indexOf(REGION_OPEN, from);
		}
		return out;
	}

	private static function regionOf(src: String): Span {
		final from: Int = src.indexOf(REGION_OPEN) + REGION_OPEN.length;
		return new Span(from, src.indexOf(REGION_CLOSE));
	}

	/** Assert that `result` is `Proven`, naming `why`. */
	private static function proven(result: ReachResult, why: String): Void {
		Assert.isTrue(result.match(Proven), '$why: got $result');
	}

	/** Assert that `result` is not `Proven`, naming `why`. */
	private static function refused(result: ReachResult, why: String): Void {
		Assert.isFalse(result.match(Proven), '$why: got Proven');
	}

	private static function assertMatch(result: ReachResult, expected: ReachResult -> Bool, ?pos: haxe.PosInfos): Void {
		Assert.isTrue(expected(result), 'got $result', pos);
	}

	private static function assertReachedAt(result: ReachResult, last: String): Void {
		switch result {
			case Reached(path):
				Assert.isTrue(path.length > 0 && path[path.length - 1].to == last, [for (s in path) '${s.from}->${s.to}:${s.kind}'].join(
					' '
				));
			case _:
				Assert.fail('expected a path ending in $last, got $result');
		}
	}

}
