package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Repetition is POSITIVE (`CallRepetition`, `MainRepeats.climb`): a short sink call runs once per main-thread run only
 * when every way up to it is a resolved call from the entry point that nothing repeats. A value handed to a call not
 * listed `runsOnce` repeats; a registration into project code, a value marshalled onto the main thread and a function
 * no resolved call runs repeat as often as nothing says; the info note never claims "once" for any of them. Owners of
 * one distance each warn, ordered by number, and a repeating call's finding is keyed by a name, never by a position.
 */
class ThreadSafetyRepetitionTest extends Test {

	/** TM's shape of a user helper looping over a callback (`each(xs, f)`): no `iterates` entry, so it repeats. */
	@:pin('control') @:killer('M-TS-REPEAT-NO-ITERATES')
	public function testAValueHandedToAnUnlistedCallRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A M.main | Db.request'],
			graded(run(
				'static function each(xs:Array<String>, f:String->Void):Void { for (x in xs) f(x); }'
				+ ' public static function main():Void { final xs:Array<String> = ["a"]; each(xs, x -> Db.request(x)); }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An `iterates` call reached through a local alias is a call the graph cannot resolve: the value repeats. */
	public function testAValueHandedToAnAliasedCallRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A M.main | Db.request'],
			graded(run(
				'public static function main():Void { final xs:Array<String> = ["a"]; final it = Lambda.iter; it(xs, x -> Db.request(x)); }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A recursion through an unlisted higher-order call (`n.forEachKid(walk)`) repeats the walk's own call. */
	public function testARecursionThroughAnUnlistedCallRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A M.walk | Disk.stat'],
			graded(run(
				'static function walk(n:Kid):Void { Disk.stat(n.p); n.forEachKid(walk); }'
				+ ' public static function main():Void walk(new Kid());',
				'class Kid { public final kids:Array<Kid> = []; public final p:String = ""; public function new() {}'
				+ ' public function forEachKid(f:Kid->Void):Void { for (k in kids) f(k); } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call `runsOnce` lists runs the value it is handed at most once: the short call below it stays info. */
	@:pin('control') @:killer('M-TS-RUNS-ONCE-OFF')
	public function testARunsOnceCallRepeatsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A M.main | Db.request'],
			graded(run(
				'static function later(f:String->Void):Void f("x");' + ' public static function main():Void later(x -> Db.request(x));',
				'', '"runsOnce":["M.later"],'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A bare `runsOnce` name speaks for the runtime's calls only: a project function of that name may run the value once
	 * per item, and does here (review round 2 `cr1-runsonce-project`). A `Type.member` entry is the project's word on
	 * that member.
	 */
	@:pin('control') @:killer('M-TS-RUNS-ONCE-PROJECT') @:killer('M-TS-RUNS-ONCE-UNRESOLVED')
	public function testABareRunsOnceNameSaysNothingOfProjectCode(): Void {
		#if (sys || nodejs)
		final batch: String = 'class Batch { final items:Array<String>; public function new(items:Array<String>) this.items = items;'
			+ ' public function success(f:String->Void):Batch { for (i in items) f(i); return this; } }';
		final typed: String =
			'public static function main():Void { final b:Batch = new Batch(["a", "b"]); b.success(s -> Db.request(s)); }';
		final chained: String = 'public static function main():Void new Batch(["a", "b"]).success(s -> Db.request(s));';
		final repeated: Array<String> = ['warning A M.main | Db.request'];
		Assert.same(repeated, graded(run(typed, batch, '"runsOnce":["success"],')), 'a bare name, the call resolved');
		Assert.same(repeated, graded(run(chained, batch, '"runsOnce":["success"],')), 'a bare name, the call unresolved');
		Assert.same(['info A M.main | Db.request'], graded(run(typed, batch, '"runsOnce":["Batch.success"],')), 'a member');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A registration into project code is kept by that code and run from a call the graph cannot follow — here per item
	 * of a dispatch loop: the registration owns the warning.
	 */
	@:pin('control') @:killer('M-TS-REGISTER-PROJECT')
	public function testARegistrationIntoProjectCodeRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A M.onItem | Db.request', 'warning A M.main | Hub.addEventListener'],
			graded(run(
				'static function onItem(e:String):Void Db.request(e);'
				+ ' public static function main():Void { final d:Hub = new Hub(); d.addEventListener("item", onItem);'
				+ ' final xs:Array<String> = ["a"]; for (x in xs) d.dispatchEvent(x); }',
				'class Hub { final _ls:Array<String->Void> = []; public function new() {}'
				+ ' public function addEventListener(t:String, l:String->Void):Void _ls.push(l);'
				+ ' public function dispatchEvent(e:String):Void { for (l in _ls) l(e); } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A registration with the runtime runs once per event, and the info note says so instead of claiming the entry point. */
	@:pin('control') @:killer('M-TS-SHORT-REGISTERED-NOTE')
	public function testARuntimeRegistrationIsOncePerEvent(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(
			'static function onItem(e:String):Void Db.request(e);'
			+ ' public static function main():Void { final d:Hub = new Hub(); d.addEventListener("item", onItem); }',
			'extern class Hub { public function new(); public function addEventListener(t:String, l:String->Void):Void; }'
		);
		Assert.same(['info A M.onItem | Db.request'], graded(found));
		Assert.isTrue(found.exists(v -> v.message.indexOf('once per event of a registration (`registers`)') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Once means every caller up from the entry point is resolved and none repeats it — and the note says just that. */
	public function testTheShortNoteNamesWhatItProved(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run('static function a():Void Db.request("a"); public static function main():Void a();');
		Assert.same(['info A M.a | Db.request'], graded(found));
		Assert.isTrue(found.exists(v -> v.message.indexOf('every caller up from the entry point resolved') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `ThreadsUtil`: a background loop posts a task per item, and the main thread runs every pending task in one frame. */
	@:pin('control') @:killer('M-TS-MARSHAL-OWNER-OFF')
	public function testAMarshalledValueRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A M.main | Db.request'],
			graded(run(
				'static final _q:Array<()->Void> = []; public static function runInMainThread(f:()->Void):Void _q.push(f);'
				+ ' public static function pump():Void { for (f in _q) f(); }'
				+ ' public static function main():Void { Runner.create(() -> { for (i in 0...1000) runInMainThread(() -> Db.request("x")); }); pump(); }',
				'', '"marshals":["M.runInMainThread"],'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A loop over `Dynamic` handlers runs `run` through no call the graph resolves: its repetition is unknown, a warning. */
	@:pin('control') @:killer('M-TS-ASSUMED-OFF')
	public function testAFunctionNoResolvedCallRunsWarns(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(
			'public static function main():Void { final hs:Array<Dynamic> = [new Saver()]; for (h in hs) h.run("x"); }',
			'class Saver { public function new() {} public function run(x:String):Void Db.request(x); }'
		);
		Assert.same(['warning A Saver.run | Db.request'], graded(found));
		Assert.isTrue(found.exists(v -> v.message.indexOf('repetition unknown') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A custom iterator's `next`, run by a `for` the graph does not resolve, repeats as often as the loop turns. */
	public function testAnIteratorNextWarns(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A Walker.next | Disk.stat'],
			graded(run(
				'public static function main():Void { for (p in new Walker(["a", "b"])) trace(p); }',
				'class Walker { var _i:Int = 0; final _ps:Array<String>; public function new(ps:Array<String>) _ps = ps;'
				+ ' public function hasNext():Bool return _i < _ps.length;'
				+ ' public function next():String { Disk.stat(_ps[_i]); return _ps[_i++]; } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A static initializer runs once per program, like the entry point: its short call stays info. */
	@:pin('control') @:killer('M-TS-ASSUMED-STATIC')
	public function testAStaticInitializerRunsOnce(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A Conf.load | Db.request'],
			graded(run(
				'public static function main():Void trace(Conf.value);',
				'class Conf { public static final value:String = load(); static function load():String { Db.request("c"); return "c"; } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two loops one call away from a short call each repeat it: each warns, whatever comment sits between them. */
	@:pin('control') @:killer('M-TS-OWNER-FIRST-ONLY')
	public function testEquallyNearOwnersEachWarn(): Void {
		#if (sys || nodejs)
		Assert.same([
			'info A M.a | Db.request',
			'warning A M.p | for (x in xs)',
			'warning A M.q | for (x in xs)'
		], graded(run(owners(''))));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Owners of one distance are ordered by file, then offset as a number: `p` at a two-digit
	 * offset stays ahead of `q` past a thousand-character comment, which text order would put first.
	 */
	@:pin('control') @:killer('M-TS-OWNER-OFFSET-TEXT')
	public function testOwnersAreOrderedByOffsetAsANumber(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(owners(' // ' + StringTools.lpad('', 'x', 1000) + '\n'));
		Assert.isTrue(found.exists(v -> v.message.indexOf('long only as repeated by M.p, M.q') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A loop's warning is keyed by the loop's header: a short call added earlier in the loop renames nothing. */
	@:pin('control') @:killer('M-TS-LOOP-SUBJECT')
	public function testALoopWarningIsKeyedByItsHeader(): Void {
		#if (sys || nodejs)
		final before: Array<String> = graded(run(loop('')));
		final after: Array<String> = graded(run(loop('c();')));
		Assert.isTrue(before.contains('warning A M.main | for (x in xs)'));
		Assert.isTrue(after.contains('warning A M.main | for (x in xs)'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `StandardFileSystem.deleteItemInternal#6`: a warning owned by a value handed to an iterating call is keyed by
	 * that call, never by the lambda's number in its file, which an unrelated lambda shifts.
	 */
	@:pin('control') @:killer('M-TS-HAND-SUBJECT')
	public function testAHandedValueIsKeyedByTheCall(): Void {
		#if (sys || nodejs)
		for (extra in ['', 'static final unrelated:()->Int = () -> 1; '])
			Assert.same(
				['info A M.leaf | Disk.stat', 'warning A M.main | Kid.forEachKid'],
				graded(run(
					'${extra}static function leaf(n:Kid):Void Disk.stat(n.p);'
					+ ' public static function main():Void { final n:Kid = new Kid(); n.forEachKid(k -> leaf(k)); }',
					'class Kid { public final kids:Array<Kid> = []; public final p:String = ""; public function new() {}'
					+ ' public function forEachKid(f:Kid->Void):Void { for (k in kids) f(k); } }',
					'"iterates":["Kid.forEachKid"],'
				))
			);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline final LIB: String = 'class Db { public static function request(s:String):Void {} }'
		+ ' class Disk { public static function stat(p:String):Void {} }'
		+ ' class Runner { public static function create(fn:()->Void):Void {} }';

	/** A class `M` of `members`, beside the sinks, `other` types and the `extra` options. */
	private static function run(members: String, other: String = '', extra: String = ''): Array<Violation> {
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Db.request","Disk.stat"],'
			+ '"shortSinks":["Db.request","Disk.stat","trace"],"iterates":["Lambda.*","iter","map"],"registers":["addEventListener"],'
			+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],$extra"repeatBudgetMs":50}}}';
		return ThreadSafetyCheckTest.violations(config, [ThreadSafetyCheckTest.MUTEX, LIB, other, 'class M { $members }']);
	}

	/** `p` and `q` each loop over a call of `a`, a short call, `p` first in the file and `gap` between them. */
	private static function owners(gap: String): String {
		return 'static function p(xs:Array<String>):Void for (x in xs) a();\n$gap'
			+ ' static function q(xs:Array<String>):Void for (x in xs) a(); static function a():Void Db.request("a");'
			+ ' public static function main():Void { p(["x"]); q(["y"]); }';
	}

	/** `main` loops over `b`, a short call, with `first` before it in the loop. */
	private static function loop(first: String): String {
		return 'static function b():Void Db.request("b"); static function c():Void Db.request("c");'
			+ ' public static function main():Void { final xs:Array<String> = ["a"]; for (x in xs) { $first b(); } }';
	}

	/** The findings of `found` with data as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
