package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A function value handed to a call that runs it runs where it is handed: under the hold around that call, and as often
 * as that call repeats it (`Lambda.iter` runs it per element). Before, a hold's taint followed only invocations, so a
 * lock held across `Lambda.iter(paths, load)` — `load` blocking — was silent, and so was every lambda handed on under a
 * hold. A value handed to a call that runs it elsewhere — on another thread (`spawns`, `marshals`), once per event
 * (`registers`), never (`neverInvokes`) — taints nothing there.
 */
class ThreadSafetyHandedValueTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Disk.stat","Disk.peek"],'
		+ '"shortSinks":["Disk.peek"],"spawns":["Runner.create"],"marshals":["Ui.post"],"registers":["addEventListener"],'
		+ '"runsOnce":["Once.run"],"neverInvokes":["Never.drop"],"lockPairs":["Mutex.acquire/release"],'
		+ '"nonBlocking":["D.new the dispatcher stands for a library class, no project native",'
		+ '"D.addEventListener keeps the handler and runs nothing"]}}}';

	/**
	 * Review fixture `ep1b-iter-in-caller`: a method value, a lambda and a sink itself, each handed to `Lambda.iter` under the
	 * hold, and a value handed on inside a call the hold makes.
	 */
	@:pin('control') @:killer('M-TS-HANDED-RUNS-HERE') @:killer('M-TS-HANDED-WINDOW-OFF') @:killer('M-TS-HANDED-REACH-OFF')
	@:killer('M-TS-HANDED-SINK-OFF')
	public function testAHoldTaintsAValueHandedToACallThatRunsIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, load);')), 'a method value');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, p -> Disk.stat(p));')), 'a lambda');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, Disk.stat);')), 'a sink handed as a value');
		Assert.same(['S.work | S._m'], holds(run('scan();')), 'handed inside a call the hold makes');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The value repeats with the call it is handed to: a short sink once per element of `Lambda.iter` keeps the lock long,
	 * once under a `runsOnce` call it does not; a sink only a `catch` runs counts on the normal paths when the value repeats.
	 */
	@:pin('control') @:killer('M-TS-REPEAT-NO-ITERATES') @:killer('M-TS-RUNS-ONCE-OFF')
	public function testAHandedValueRepeatsWithTheCallItIsHandedTo(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, p -> Disk.peek(p));')), 'per element');
		Assert.same([], holds(run('Once.run("a", p -> Disk.peek(p));')), 'run once');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, caught);')), 'a catch per element');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A value a call runs on another thread, once per event or never, taints nothing under the hold around the call. */
	@:pin('control') @:killer('M-TS-HANDED-ELSEWHERE') @:killer('M-TS-CYCLE-REGISTERED')
	public function testAValueRunElsewhereTaintsNothing(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('Runner.create(() -> Disk.stat("x"));')), 'spawned');
		Assert.same([], holds(run('Ui.post(() -> Disk.stat("x"));')), 'marshalled');
		Assert.same([], holds(run('new D().addEventListener("x", e -> Disk.stat(e));')), 'registered');
		Assert.same([], holds(run('Never.drop(() -> Disk.stat("x"));')), 'never run');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The main thread reaches a sink handed as a value to a call that runs it, as it reaches one it calls. */
	@:pin('control') @:killer('M-TS-HANDED-SINK-OFF')
	public function testAMainSinkHandedAsAValueIsReported(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A S.main | Disk.stat'], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {} }',
			'class S { static final paths:Array<String> = ["a"]; public static function main():Void Lambda.iter(paths, Disk.stat); }'
		])));
		Assert.same([], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {} }',
			'class Never { public static function drop(f:String->Void):Void {} }',
			'class S { public static function main():Void Never.drop(Disk.stat); }'
		])), 'never run');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A method value of ANOTHER object that takes the held re-entrant lock on its own object waits for that object's
	 * lock: handed to a call that runs it, it re-takes nothing of the holder's.
	 */
	@:pin('control') @:killer('M-TS-HANDED-RETAKE')
	public function testAMethodValueOfAnotherObjectWaitsForItsLock(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.slow | S._m', 'S.work | S._m'],
			holds(ThreadSafetyCheckTest.violations(
				StringTools.replace(CONFIG, '"lockPairs"', '"reentrantLocks":["Mutex.acquire"],"lockPairs"'), [
					ThreadSafetyCheckTest.MUTEX,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class Disk { public static function stat(p:String):Void {} }',
					'class S { final _m:Mutex = new Mutex(); final paths:Array<String> = ["a", "b"]; public function new() {}'
					+ ' function locked(p:String):Void { _m.acquire(); _m.release(); }'
					+ ' function slow():Void { _m.acquire(); Disk.stat("x"); _m.release(); }'
					+ ' public function work():Void { _m.acquire(); final o:S = new S(); Lambda.iter(paths, o.locked); _m.release(); }'
					+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); Runner.create(() -> s.slow());'
					+ ' s._m.acquire(); s._m.release(); } }'
				]
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Lock order through a value handed on: the main thread holds `_a` across `Lambda.iter`, whose lambda or method value
	 * takes `_b` there, while a spawned worker holds `_b` and takes `_a`. Before, the order walk followed calls only, so
	 * the take of `_b` was made under no hold and the pair went unreported. A value run on another thread, or kept to run
	 * per event, takes `_b` under no hold of `_a`.
	 */
	@:pin('control') @:killer('M-TS-ORDER-HANDED') @:killer('M-TS-ORDER-HANDED-ANYWHERE') @:killer('M-TS-ORDER-FOLLOWS-REFS')
	@:killer('M-TS-ORDER-HANDED-RANK') @:killer('M-TS-ORDER-HANDED-CLIMB') @:killer('M-TS-ORDER-HANDED-VIA')
	public function testALockTakenInAHandedValueOrdersUnderTheHold(): Void {
		#if (sys || nodejs)
		final pair: Array<String> = ['S.main | S._a / S._b'];
		Assert.same(pair, orders('Lambda.iter(paths, p -> { _b.acquire(); _b.release(); });'), 'a lambda');
		Assert.same(pair, orders('Lambda.iter(paths, takeB);'), 'a method value');
		Assert.same([], orders('Runner.create(() -> takeB("x"));'), 'spawned');
		Assert.same([], orders('Hub.on(takeB);'), 'registered');
		Assert.same([], orders('Never.drop(() -> takeB("x"));'), 'never run');
		// the same pair made through calls alone too: that way names it, whatever member sorts first
		final direct: Array<String> = ['S.zDirect | S._a / S._b'];
		Assert.same(direct, orders('Lambda.iter(paths, p -> { _b.acquire(); _b.release(); });', true), 'a lambda and a call');
		Assert.same(direct, orders('Lambda.iter(paths, takeB);', true), 'a method value and a call');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Of the sink calls one main-thread way runs, a direct call keeps the way's warning before a sink handed on as a value
	 * (review round 4 `f10`): `new Later(Disk.stat)` only stores the stat for a worker, so the warning stays at the sleep
	 * `C.f` calls itself, though the stat is written first. Of the nearest repeating calls up a short call's ways, a loop
	 * around a direct call comes before a value handed to an iterating call at the same distance.
	 */
	@:pin('control') @:killer('M-TS-WAY-HANDED-RANK') @:killer('M-TS-OWNER-HANDED-RANK')
	public function testADirectCallOutranksAHandedValue(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"sinks":["Disk.stat","Disk.peek","Sys.sleep"],"shortSinks":["Disk.peek"],'
			+ '"spawns":["Runner.create"],"iterates":["Lambda.*"]}}}';
		final disk: String = 'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {} }';
		Assert.same(['info A C.f | Disk.stat', 'warning A C.f | Sys.sleep'], mains(ThreadSafetyCheckTest.violations(config, [
			disk,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Later { var _job:Null<String->Void> = null; public function new(job:String->Void) { _job = job; }'
			+ ' public function run():Void { final j:Null<String->Void> = _job; if (j != null) j("x"); } }',
			'class C { static var later:Null<Later> = null; static function f():Void { later = new Later(Disk.stat); Sys.sleep(1); }'
			+ ' public static function main():Void { f(); Runner.create(() -> { final l:Null<Later> = later; if (l != null) l.run(); }); } }'
		])));
		final owned: Array<Violation> = ThreadSafetyCheckTest.violations(config, [
			disk,
			'class K { static function g(s:String):Void Disk.peek(s); static function viaIter(xs:Array<String>):Void Lambda.iter(xs, g);'
			+ ' static function viaLoop(xs:Array<String>):Void for (x in xs) g(x);'
			+ ' public static function main():Void { viaIter(["a"]); viaLoop(["b"]); } }'
		]);
		final short: Null<Violation> = owned.filter(v -> v.data?.member == 'K.g')[0];
		Assert.isTrue(short?.message.contains('repeated by K.viaLoop, K.viaIter, reported there') == true, short?.message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A value a constructor only stores into a `final` field runs where the field is called, not at the `new` (TM's
	 * `FileList.reload` handing `_source.getThumbnail` to `new FileListGrid(...)` under the tree lock, round 7 L1b): the
	 * hold around the `new` stays silent, and turns long again when the hold itself calls the field — directly, or through
	 * a field another constructor stores it into. Any other shape keeps the value running where it is handed: the
	 * parameter used otherwise or in a nested function, the field read otherwise (in any `#if` branch), a `var` field, a
	 * local shadowing the field, a string literal spelling the field's name, a project not closed, or one that does not
	 * declare which classes a read of a computed name may obtain members of.
	 */
	@:pin('control') @:killer('M-TS-CTOR-STORE-INERT') @:killer('M-TS-CTOR-STORE-DERIVE') @:killer('M-TS-CTOR-STORE-FINAL')
	@:killer('M-TS-CTOR-STORE-READS') @:killer('M-TS-CTOR-STORE-FORWARD') @:killer('M-TS-CTOR-STORE-CLOSED')
	@:killer('M-TS-CTOR-STORE-SPELLED') @:killer('M-TS-CTOR-STORE-STATEMENT') @:killer('M-TS-CTOR-STORE-USE')
	public function testAValueAConstructorOnlyStoresRunsWhereTheFieldIsCalled(): Void {
		#if (sys || nodejs)
		final warns: Array<String> = ['S.work | S._m'];
		Assert.same([], holds(stored('new Grid(load);')), 'only stored');
		Assert.same(warns, holds(stored('final g:Grid = new Grid(load); g.later();')), 'the field called under the hold');
		Assert.same([], holds(stored('final f:Fwd = new Fwd(load); f.make();')), 'forwarded into another store');
		Assert.same(warns, holds(stored('final f:Fwd = new Fwd(load); final i:Item = f.make(); i.go();')), 'the forwarded field called');
		Assert.same(warns, holds(stored('new Eager(load);')), 'the parameter called too');
		Assert.same(warns, holds(stored('new Captured(load);')), 'the parameter in a nested function');
		Assert.same(warns, holds(stored('new Leaky(load);')), 'the field read otherwise');
		Assert.same(warns, holds(stored('new Branched(load);')), 'the field read otherwise in a branch');
		Assert.same(warns, holds(stored('new Mutable(load);')), 'a var field');
		Assert.same(warns, holds(stored('final c:Chained = new Chained(load); c.later();')), 'stored by an assignment whose value is read');
		Assert.same(warns, holds(stored('new Shadowed(load);')), 'a local shadowing the field');
		Assert.same(warns, holds(stored('new Grid(load); Reflect.field(this, "_job");')), 'a literal spells the field');
		Assert.same(warns, holds(stored('new Grid(load);', '"closedWorld":true', '"closedWorld":false')), 'no closed project');
		Assert.same(warns, holds(stored('new Grid(load);', '"reflectiveMethodHolders":["nothing.*"],', '')), 'no holders declared');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Review R5 F1 (`sv/implicit-*`): the language calls some fields by NAME, with no node of that name at the call — a `for`
	 * runs `iterator()` / `keyValueIterator()`, a string conversion runs `toString()` on dynamic targets — and std code reads a
	 * field of a structure it is handed. Such a stored value runs where no occurrence shows it, so a field named so, or a
	 * public one, keeps the value running where it is handed.
	 */
	@:pin('control') @:killer('M-TS-STORED-IMPLICIT-NAME') @:killer('M-TS-STORED-PUBLIC')
	public function testAFieldTheLanguageCallsByNameIsNotOnlyStored(): Void {
		#if (sys || nodejs)
		final warns: Array<String> = ['S.work | S._m'];
		Assert.same(warns, holds(implicit('for (x in new Ib(it)) {}')), 'a stored iterator a loop runs');
		Assert.same(warns, holds(implicit('final ib:Ib = new Ib(it); for (x in ib) {}')), 'through a local');
		Assert.same(warns, holds(implicit('for (k => v in new Kv(kv)) {}')), 'a stored keyValueIterator');
		Assert.same(warns, holds(implicit('trace("" + new Ts(ts));')), 'a stored toString');
		Assert.same(warns, holds(implicit('final p:PIb = new PIb(it); p.each();')), 'a private iterator its own loop runs');
		Assert.same(warns, holds(implicit('new Pub(load);')), 'a public field std code may read');
		Assert.same([], holds(implicit('new Priv(load);')), 'a private field only stored');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `S.work` runs on a spawned thread and holds `_m` across `held`; the main thread takes `_m` too. `load` blocks, `caught` blocks only in its `catch`, `scan` hands `load` to `Lambda.iter`.
	 */
	private static function run(held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Ui { public static function post(fn:()->Void):Void {} }',
			'class Once { public static function run(x:String, fn:String->Void):Void fn(x); }',
			'class Never { public static function drop(fn:()->Void):Void {} }',
			'extern class D { public function new(); public function addEventListener(type:String, fn:String->Void):Void; }',
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {}'
			+ ' public static function parse(p:String):Int { if (p.length > 0) throw "bad"; return 0; } }',
			'class S { final _m:Mutex = new Mutex(); final paths:Array<String> = ["a", "b"]; public function new() {}'
			+ ' function load(p:String):Void Disk.stat(p); function scan():Void Lambda.iter(paths, load);'
			+ ' function caught(p:String):Void { try { Disk.parse(p); } catch (e:Dynamic) { Disk.stat(p); } }'
			+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}
	/**
	 * `S.work` runs on a spawned thread and holds `_m` across `held`; the main thread takes `_m` too. `load` blocks; the
	 * other classes keep the value handed to their constructor in the ways `testAValueAConstructorOnlyStoresRunsWhereTheFieldIsCalled`
	 * names. The project is closed and declares the classes a computed name reads members of; `find` / `put` edit the config.
	 */
	private static function stored(held: String, find: String = '', put: String = ''): Array<Violation> {
		final config: String = '{"reflectiveClasses":["nothing.*"],"reflectiveMethodHolders":["nothing.*"],"rules":{"thread-safety":{'
			+ '"sinks":["Mutex.acquire","Disk.stat"],"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';
		return ThreadSafetyCheckTest.violations(find == '' ? config : StringTools.replace(config, find, put), [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Disk { public static function stat(p:String):Void {} }',
			'class Grid { final _job:String->Void; public function new(job:String->Void) { _job = job; }'
			+ ' public function later():Void _job("x"); }',
			'class Item { final _run:String->Void; public function new(run:String->Void) { this._run = run; }'
			+ ' public function go():Void this._run("y"); }',
			'class Fwd { final _fwd:String->Void; public function new(fwd:String->Void) { _fwd = fwd; }'
			+ ' public function make():Item return new Item(_fwd); }',
			'class Eager { final _eager:String->Void; public function new(job:String->Void) { _eager = job; job("z"); } }',
			'class Captured { final _cap:String->Void; public function new(job:String->Void) { _cap = job;'
			+ ' Runner.create(() -> job("c")); } }',
			'class Leaky { final _leak:String->Void; public function new(job:String->Void) { _leak = job; }'
			+ ' public function share():String->Void return _leak; }',
			'class Branched { final _br:String->Void; public function new(job:String->Void) { _br = job; }'
			+ ' public function share():Null<String->Void> { #if never return _br; #else return null; #end } }',
			'class Mutable { var _mut:String->Void; public function new(job:String->Void) { _mut = job; } }',
			'class Chained { final _ca:String->Void; final _cb:String->Void; public function new(job:String->Void) { _ca = _cb = job; }'
			+ ' public function later():Void _ca("x"); }',
			'class Shadowed { final _sh:String->Void; public function new(job:String->Void) { var _sh:Null<String->Void> = null;'
			+ ' _sh = job; this._sh = Disk.stat; } }',
			'class S { final _m:Mutex = new Mutex(); public function new() {} function load(p:String):Void Disk.stat(p);'
			+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}

	/**
	 * `stored` with classes keeping the value in a field the language calls by name (`Ib`, `Kv`, `Ts`, `PIb` iterating
	 * itself), in a public field (`Pub`) and in a private one (`Priv`); `it`, `kv`, `ts` and `load` block.
	 */
	private static function implicit(held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(
			'{"reflectiveClasses":["nothing.*"],"reflectiveMethodHolders":["nothing.*"],'
			+ '"rules":{"thread-safety":{"sinks":["Mutex.acquire","Disk.stat"],"spawns":["Runner.create"],'
			+ '"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}',
			[
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Disk { public static function stat(p:String):Void {} }',
				'class Ib { public final iterator:() -> Iterator<String>; public function new(i:() -> Iterator<String>) { iterator = i; } }',
				'class Kv { public final keyValueIterator:() -> KeyValueIterator<Int, String>;'
				+ ' public function new(k:() -> KeyValueIterator<Int, String>) { keyValueIterator = k; } }',
				'class Ts { public final toString:() -> String; public function new(t:() -> String) { toString = t; } }',
				'class PIb { final iterator:() -> Iterator<String>; public function new(i:() -> Iterator<String>) { iterator = i; }'
				+ ' public function each():Void for (x in this) {} }',
				'class Pub { public final job:String->Void; public function new(j:String->Void) { job = j; } }',
				'class Priv { final _job:String->Void; public function new(j:String->Void) { _job = j; } }',
				'class S { final _m:Mutex = new Mutex(); public function new() {} function load(p:String):Void Disk.stat(p);'
				+ ' function it():Iterator<String> { Disk.stat("p"); return null; }'
				+ ' function kv():KeyValueIterator<Int, String> { Disk.stat("p"); return null; }'
				+ ' function ts():String { Disk.stat("p"); return ""; }'
				+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
				+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
			]
		);
	}

	/** The hold warnings (b) of `found` as `<member> | <lock>`, sorted: a hold across short calls run once is info. */
	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B' && v.severity.label() == 'warning') '${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	/** The main-thread findings (a) of `found` as `<severity> A <member> | <subject>`, sorted. */
	private static function mains(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'A') '${v.severity.label()} A ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	/**
	 * The lock-order findings (D) as `<member> | <locks>`, sorted, of a run where `S.main` holds the static `_a` across
	 * `held` after spawning `work`, which holds `_b` and takes `_a`; `takeB` takes `_b`, `Hub.on` registers a handler. With
	 * `direct`, `main` then calls `zDirect`, which calls `takeB` holding `_a`.
	 */
	private static function orders(held: String, direct: Bool = false): Array<String> {
		final call: String = direct ? 'zDirect();' : '';
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"spawns":["Runner.create"],"registers":["Hub.on"],'
				+ '"neverInvokes":["Never.drop"],"lockPairs":["Mutex.acquire/release"]}}}',
				[
					ThreadSafetyCheckTest.MUTEX,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class Never { public static function drop(fn:()->Void):Void {} }',
					'class Hub { public static function on(fn:String->Void):Void {} }',
					'class S { static final _a:Mutex = new Mutex(); static final _b:Mutex = new Mutex();'
					+ ' static final paths:Array<String> = ["x", "y"]; static function takeB(p:String):Void { _b.acquire(); _b.release(); }'
					+ ' static function work():Void { _b.acquire(); _a.acquire(); _a.release(); _b.release(); }'
					+ (direct ? ' static function zDirect():Void { _a.acquire(); takeB("x"); _a.release(); }' : '')
					+ ' public static function main():Void { Runner.create(work); _a.acquire(); $held _a.release(); $call } }'
				]
			);
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'D') '${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
