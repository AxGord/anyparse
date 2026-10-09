package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * The catch-all of a `switch` over a closed `enum abstract` whose every value an earlier case names is no path
 * (`ExhaustiveSwitches`): TM's `FileList.reload` throws in the `case _` of a switch over `FileListViewType` (LIST, GRID),
 * built only by its constants and a `@:from` mapping every string onto them.
 */
class ThreadSafetyExhaustiveTest extends Test {

	/** A closed project: every write of a member is in the run, which the reading of a member needs (`FieldWrites.complete`). */
	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';

	private static inline final CLOSED: String = 'enum abstract V(Int) { final A; final B;'
		+ ' @:from static function of(s:String):V return s == "a" ? A : B; }';

	@:pin('control') @:killer('M-TS-EXH-OFF') @:killer('M-TS-EXH-OPAQUE')
	public function testACatchAllNoValueReachesIsNoPathInAValue(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run(CLOSED, 'V', 'use(switch mode { case A: 1; case B: 2; case _: throw "x"; });')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-STRUCT')
	public function testACatchAllNoValueReachesIsNoPathInAStatement(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run(CLOSED, 'V', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-ALL-NAMED')
	public function testAValueNoCaseNamesReachesIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', 'switch mode { case A: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-FROM')
	public function testAFromClauseOpensTheAbstract(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'],
			leaks(run(
				'enum abstract V(Int) from Int { final A; final B; }', 'V',
				'switch mode { case A: step(); case B: step(); case _: throw "x"; }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-FROMFN')
	public function testAFunctionBuildingAnyValueOpensTheAbstract(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'],
			leaks(run(
				'enum abstract V(Int) { final A; final B; @:from static function of(i:Int):V return cast i; }', 'V',
				'switch mode { case A: step(); case B: step(); case _: throw "x"; }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testANullableSubjectReachesIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work'], leaks(run(CLOSED, 'Null<V>', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A subject whose name a parameter or a local of the function binds is that binding, not the member (review r4 `e1`, `e2`). */
	@:pin('control') @:killer('M-TS-EXH-SUBJECT-BOUND')
	public function testASubjectTheFunctionBindsIsNoMember(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'], leaks(run(CLOSED, 'V', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }', '?mode:Null<V>'))
		);
		Assert.same(
			['S.work'],
			leaks(run(CLOSED, 'V', 'final mode:Null<V> = pick(); switch mode { case A: step(); case B: step(); case _: throw "x"; }'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A case with a guard matches only where the guard holds: it names no value for sure (review r4 `e5`). */
	@:pin('control') @:killer('M-TS-EXH-GUARD')
	public function testAGuardedCaseNamesNoValue(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', 'switch mode { case A if (flag): step(); case B: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Members that can build a value outside the constants open the abstract: a value only one build declares, a
	 * constructor, a function with no written return type handing back a value, a static field of it (review r4 `e3`,
	 * `e4`, `e8`, `e9`).
	 */
	@:pin('control') @:killer('M-TS-EXH-FROM') @:killer('M-TS-EXH-CTOR') @:killer('M-TS-EXH-NORET')
	public function testMembersBuildingOtherValuesOpenTheAbstract(): Void {
		#if (sys || nodejs)
		final dead: String = 'switch mode { case A: step(); case B: step(); case _: throw "x"; }';
		Assert.same(['S.work'], leaks(run('enum abstract V(Int) { final A; final B; #if mobile final C; #end }', 'V', dead)), 'a region');
		Assert.same(
			['S.work'],
			leaks(run('enum abstract V(Int) { final A = 1; final B = 2; public inline function new(i:Int) this = i; }', 'V', dead)),
			'a constructor'
		);
		Assert.same(
			['S.work'],
			leaks(run(
				'enum abstract V(Int) { final A = 1; final B = 2; @:op(A + B) function add(o:V) return cast (this + (o:Int)); }', 'V', dead
			)),
			'an operator'
		);
		Assert.same(
			['S.work'],
			leaks(run('enum abstract V(Int) { final A = 1; final B = 2; public static final Z:V = cast 9; }', 'V', 'mode = V.Z; $dead')),
			'a static field'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The member must hold only values: an assignment of a `Dynamic` does not, nor does a String abstract's member nothing
	 * initializes (null); a counting abstract's uninitialized member is `0`, a value only when one is `0` (review r4 `e6`,
	 * `e7`; TM's `FileListSelect.viewType`).
	 */
	@:pin('control') @:killer('M-TS-EXH-WRITES') @:killer('M-TS-EXH-UNINIT') @:killer('M-TS-EXH-ZERO') @:killer('M-TS-EXH-OPTIONAL')
	public function testTheMemberHoldsOnlyValues(): Void {
		#if (sys || nodejs)
		final dead: String = 'switch mode { case A: step(); case B: step(); case _: throw "x"; }';
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', 'mode = dyn; $dead', '', ' = A', 'var dyn:Dynamic = 5;')), 'a dynamic write');
		Assert.same(
			['S.work'], leaks(run('enum abstract V(String) { final A = "a"; final B = "b"; }', 'V', dead, '', '')), 'a null string'
		);
		Assert.same(['S.work'], leaks(run('enum abstract V(Int) { final A = 1; final B = 2; }', 'V', dead, '', '')), 'no zero value');
		Assert.same([], leaks(run('enum abstract V(Int) { final A = 1; final B = 0; }', 'V', dead, '', '')), 'a zero value');
		Assert.same([], leaks(run(CLOSED, 'V', dead, '', '')), 'the implicit zero');
		Assert.same([], leaks(run(CLOSED, 'V', 'mode = B; $dead')), 'a value written');
		Assert.same([], leaks(run(CLOSED, 'V', 'mode = m; $dead', 'm:V')), 'a parameter written');
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', 'mode = m; $dead', '?m:V')), 'an optional parameter written');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `FileList.reload` over `FileListSelect.viewType`: a getter reading another object's member, an optional
	 * parameter defaulted through a getter whose call returns a type a `@:from` function takes, a setter's parameter.
	 */
	@:pin('control') @:killer('M-TS-EXH-CONVERT-OFF') @:killer('M-TS-EXH-CONVERT-ANY')
	public function testValuesThroughAccessorsAndConversions(): Void {
		#if (sys || nodejs)
		final abstractDecl: String = 'enum abstract V(UInt) { final A; final B; @:to public inline function toString():String {'
			+ ' return switch abstract { case A: "a"; case B: "b"; }; } @:from public static inline function fromString(v:Null<String>):V {'
			+ ' return switch v { case "a": A; case "b", null, _: B; }; } }';
		final sel: String = 'class Sel { public static var defaultMode(get, set):V; public var mode(default, set):V;'
			+ ' public function new(?mode:V) { @:bypassAccessor this.mode = mode ?? defaultMode; }'
			+ ' private static inline function get_defaultMode():V { return Store.read("k"); }'
			+ ' private static inline function set_defaultMode(value:V):V { return value; }'
			+ ' private function set_mode(mode:V):V { trace(\'$$mode\'); this.mode = mode; return mode; } }';
		final store: String = 'class Store { public static function read(key:String):Null<String> return null; }';
		final dead: String = 'switch view { case A: step(); case B: step(); case _: throw "x"; }';
		final members: String = 'var view(get, set):V; final _sel:Sel = new Sel(); private inline function get_view():V { return _sel.mode; }'
			+ ' private inline function set_view(value:V):V { _sel.mode = value; return value; }';
		Assert.same([], leaks(run(abstractDecl, 'V', dead, '', ' = A', members, [sel, store])));
		Assert.same(
			['S.work'],
			leaks(run(abstractDecl, 'V', dead, '', ' = A', members, [sel, StringTools.replace(store, 'Null<String>', 'Dynamic')])),
			'a call returning another type'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two declarations of the abstract's name leave which one the member's type names to imports: neither is read (review r4 `e10`). */
	@:pin('control') @:killer('M-TS-EXH-COLLISION')
	public function testAnAbstractNameDeclaredTwiceIsNotRead(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'],
			leaks(run(
				CLOSED, 'V', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }', '', ' = A', '',
				['package z9; enum abstract V(Int) from Int { final A; final B; }']
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A getter returning the member's own stored field (`@:isVar`) holds what that field holds: a `Dynamic` written to it
	 * reaches the catch-all (review round 2 `ex1-isvar-getter`).
	 */
	@:pin('control') @:killer('M-TS-EXH-ISVAR-SELF')
	public function testAGetterReturningItsOwnFieldHoldsWhatTheFieldHolds(): Void {
		#if (sys || nodejs)
		final dead: String = 'switch mode { case A: step(); case B: step(); case _: throw "x"; }';
		final isVar: String = 'function get_mode():V return mode;';
		Assert.same(['S.work'], leaks(runIsVar(dead, '$isVar function load(d:Dynamic):Void { mode = d; }')), 'a dynamic write');
		Assert.same([], leaks(runIsVar(dead, '$isVar function load():Void { mode = B; }')), 'a value written');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A run that may miss a write of the project reads no member as holding values: a project file the run leaves out may
	 * write it, and so may any code where nothing declares `closedWorld` (review round 2 `ex3-partial`).
	 */
	@:pin('control') @:killer('M-TS-EXH-PARTIAL')
	public function testARunThatMayMissAWriteReadsNoMemberAsHoldingValues(): Void {
		#if (sys || nodejs)
		final dead: String = 'switch mode { case A: step(); case B: step(); case _: throw "x"; }';
		final outside: { name: String, source: String } = {
			name: 'P.hx',
			source: 'class P { public static function load(s:S, d:Dynamic):Void { s.mode = d; } }'
		};
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', dead, '', ' = A', '', null, [outside])), 'a project file outside the run');
		Assert.same([], leaks(run(CLOSED, 'V', dead)), 'the whole project');
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', dead, '', ' = A', '', null, null, false)), 'no closedWorld');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `run`, with `S.mode` an `@:isVar` property read through a getter `members` declare. */
	private static function runIsVar(held: String, members: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			CLOSED,
			'class S { final _m:Mutex = new Mutex(); @:isVar var mode(get, default):V = A; public function new() {} function step():Void {}'
			+ ' $members public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}

	/**
	 * `S.work(params)` takes `_m`, runs `held`, releases; `S.mode` is of `modeType`, written ` = A` unless `init` says
	 * otherwise; `members` are added to `S`, `more` are further sources, `beside` files of the project the run leaves
	 * out, and `closed` whether the config declares `closedWorld`.
	 */
	private static function run(
		abstractDecl: String, modeType: String, held: String, params: String = '', init: String = ' = A', members: String = '',
		?more: Array<String>, ?beside: Array<{ name: String, source: String }>, closed: Bool = true
	): Array<Violation> {
		return ThreadSafetyCheckTest.violations(closed ? CONFIG : StringTools.replace(CONFIG, ',"closedWorld":true', ''), [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			abstractDecl,
			'class S { final _m:Mutex = new Mutex(); var mode:$modeType$init; public function new() {} function step():Void {}'
			+ ' function use(n:Int):Void {} var flag:Bool = false; function pick():Null<V> return null; $members'
			+ ' public function work($params):Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		].concat(more ?? []), beside);
	}

	/** The members of the findings (c) of `found`. */
	private static function leaks(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'C') data.member;
			}
		];
	}
	#end

}
