package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * How `thread-safety` grades a finding by what it costs (`shortSinks`, `iterates`, `CallRepetition`): a call of a
 * short sink, or a take of a lock held only across short calls, that nothing repeats is reported at `info`; in a loop,
 * handed to an `iterates` call, inside a recursion, or below any main-thread caller that repeats it, it warns. Every
 * finding is still reported — the grade moves, the finding stays.
 */
class ThreadSafetyCostTest extends Test {

	/** `FileSystem.stat` and `FileSystem.readDirectory` are short sinks, `Sys.sleep` a long one; `Runner.create` spawns. */
	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","FileSystem.stat",'
		+ '"FileSystem.readDirectory"],"shortSinks":["FileSystem.stat","FileSystem.readDirectory"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"],"iterates":["Each.all"],"runsOnce":["Once.run"]}}}';

	private static inline final RUNNER: String = 'class Runner { public static function create(fn:()->Void):Void {} }';

	/** TM's `CloudDatabase.getFilePathRequest`: one indexed SQL lookup on the main thread waits well under a frame. */
	@:pin('control') @:killer('M-TS-SHORT-SINKS-IGNORED')
	public function testAShortSinkCalledOnceIsInfo(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(['class A { public static function main():Void FileSystem.stat("a"); }']);
		Assert.same(['info A A.main | FileSystem.stat'], graded(found));
		Assert.stringContains('short', found[0].message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A short sink with a long one beside it: each call site is graded on its own. */
	public function testALongSinkBesideAShortOneStillWarns(): Void {
		#if (sys || nodejs)
		Assert.same(['info A A.main | FileSystem.stat', 'warning A A.main | Sys.sleep'], graded(run([
			'class A { public static function main():Void { FileSystem.stat("a"); Sys.sleep(1); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `moveCloudFolderSubItemsAction2`: a short call once per row is as long as the folder is big. */
	@:pin('control') @:killer('M-TS-REPEAT-NO-LOOPS')
	public function testAShortSinkInALoopWarns(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A A.scan | FileSystem.stat'], graded(run([
			'class A { public static function scan(ps:Array<String>):Void for (p in ps) FileSystem.stat(p); }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `while` repeats its condition too, a `do … while` its body. */
	public function testEveryLoopKindRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A A.a | FileSystem.stat', 'warning A A.b | FileSystem.stat'], graded(run([
			'class A { static function a():Void { while (FileSystem.stat("a") > 0) {} }'
			+ ' static function b():Void { do FileSystem.stat("b") while (true); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The iterable of a `for` is read once, before the first turn: only the body repeats. */
	@:pin('control') @:killer('M-TS-REPEAT-ITERABLE')
	public function testTheIterableOfAForRunsOnce(): Void {
		#if (sys || nodejs)
		Assert.same(['info A A.list | FileSystem.readDirectory'], graded(run([
			'class A { public static function list():Void for (p in FileSystem.readDirectory("d")) trace(p);'
			+ ' public static function main():Void list(); }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's folder icon: `getCloudIcon` asks the database once, but the file list builds an icon per visible item — a
	 * caller anywhere up the main thread's way repeats the short call.
	 */
	@:pin('control') @:killer('M-TS-REPEAT-UPWARD-NONE') @:killer('M-TS-OWNER-OFF')
	public function testAShortSinkBelowARepeatingCallerWarns(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run([
			'class A { public static function main():Void for (i in 0...10) draw(i);'
			+ ' static function draw(i:Int):Void icon(i); static function icon(i:Int):Void FileSystem.stat("a"); }'
		]);
		// the loop owns the warning; the short call below it says where it went
		Assert.same(['info A A.icon | FileSystem.stat', 'warning A A.main | for (i in 0...10)'], graded(found));
		Assert.isTrue(found.exists(v -> v.message.indexOf('repeated by A.main') != -1));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `FSUtil.deleteRecursive`: a function calling itself runs its short call once per level. */
	@:pin('control') @:killer('M-TS-REPEAT-NO-RECURSION') @:killer('M-TS-OWNER-SELF-MOVED')
	public function testRecursionRepeatsAShortSink(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A A.walk | FileSystem.stat'], graded(run([
			'class A { public static function main():Void walk("a");'
			+ ' static function walk(p:String):Void { FileSystem.stat(p); if (p.length > 1) walk(p.substr(1)); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A callback handed to an `iterates` call runs once per element; one handed to any other call runs where that call runs it. */
	@:pin('control') @:killer('M-TS-REPEAT-NO-ITERATES')
	public function testAnIteratesCallbackRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(['info A A.once | FileSystem.stat', 'warning A A.each | FileSystem.stat'], graded(run([
			'class Each { public static function all(xs:Array<String>, fn:String->Void):Void {} }',
			'class Once { public static function run(fn:String->Void):Void {} }',
			'class A { public static function each(ps:Array<String>):Void Each.all(ps, p -> FileSystem.stat(p));'
			+ ' public static function once():Void Once.run(p -> FileSystem.stat(p));'
			+ ' public static function main():Void { each(["a"]); once(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A function written inside a loop runs where it is invoked: a callback stored into a `dynamic` member on every turn
	 * of a loop, and invoked once, calls its short sink once.
	 */
	@:pin('control') @:killer('M-TS-REPEAT-NO-BOUNDARY') @:killer('M-TS-UPWARD-INERT')
	public function testAFunctionAroundTheSiteStartsTheCountAfresh(): Void {
		#if (sys || nodejs)
		Assert.same(['info A A.setup | FileSystem.stat'], graded(run([
			'class A { public function new() {} public dynamic function onDone():Void {}'
			+ ' function setup():Void for (i in 0...3) onDone = () -> FileSystem.stat("a");'
			+ ' public static function main():Void { final a:A = new A(); a.setup(); a.onDone(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `CloudDatabase._mutex` as a single lookup holds it: a background hold over one short call, and the main
	 * thread's take of that lock, both brief.
	 */
	@:pin('control') @:killer('M-TS-LONG-BY-ANY-SPAN')
	public function testAHoldOverAShortSinkOnceIsInfo(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(holdFixture('FileSystem.stat(ps[0]);'));
		Assert.same(['info A S.read | Mutex.acquire', 'info B S.scan | S._m'], graded(found));
		Assert.isTrue(found.foreach(v -> v.message.indexOf('short') != -1), 'each says why it is info');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The hold over a loop of short calls is long, and so is the main thread's wait for its lock. */
	public function testAHoldOverAShortSinkInALoopWarns(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A S.read | Mutex.acquire', 'warning B S.scan | S._m'], graded(run(holdFixture('for (p in ps) FileSystem.stat(p);')))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A loop around the whole hold repeats the hold, not the call inside it: each hold stays brief. */
	@:pin('control') @:killer('M-TS-REPEAT-UNDER-OUTER')
	public function testALoopAroundTheWholeHoldIsShort(): Void {
		#if (sys || nodejs)
		Assert.same(['info A S.read | Mutex.acquire', 'info B S.scan | S._m'], graded(run([
			'class S { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' public function read():Int { _m.acquire(); _m.release(); return 1; }'
			+ ' public function scan(ps:Array<String>):Void { for (p in ps) { _m.acquire(); FileSystem.stat(p); _m.release(); } }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.scan(["a"])); s.read(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A warning names only the calls that block long: the short one beside them is no reason. */
	@:pin('control') @:killer('M-TS-EVIDENCE-PLAIN')
	public function testAWarningNamesOnlyTheLongCalls(): Void {
		#if (sys || nodejs)
		final held: Array<Violation> = run(holdFixture('FileSystem.stat(ps[0]); Sys.sleep(1);')).filter(v -> v.data?.family == 'B');
		Assert.equals(1, held.length);
		Assert.stringContains('Sys.sleep', held[0].message);
		Assert.isFalse(held[0].message.indexOf('FileSystem.stat') != -1, held[0].message);
		#else
		Assert.pass('non-sys target');
		#end
	}


	/**
	 * TM's `FileListMoveFiles.moveItems`: one repeated call reaches four short sinks, which made four warnings at one
	 * line. The site owns ONE warning, keyed by the call it repeats, naming every short sink below it.
	 */
	@:pin('control') @:killer('M-TS-SITE-PER-SINK') @:killer('M-TS-SITE-GROW') @:killer('M-TS-SITE-SUBJECT')
	public function testARepeatingSiteOwnsOneWarning(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run([
			'class A { public static function main():Void for (i in 0...10) draw(i);'
			+ ' static function draw(i:Int):Void { icon(i); list(i); }'
			+ ' static function icon(i:Int):Void FileSystem.stat("a"); static function list(i:Int):Void FileSystem.readDirectory("a"); }'
		]);
		Assert.same([
			'info A A.icon | FileSystem.stat',
			'info A A.list | FileSystem.readDirectory',
			'warning A A.main | for (i in 0...10)'
		], graded(found));
		Assert.isTrue(
			found.exists(v -> v.severity.label() == 'warning' && v.message.indexOf('"FileSystem.readDirectory" / "FileSystem.stat"') != -1)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two repeating sites in one member own a warning each. */
	public function testTwoRepeatingSitesWarnApart(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run([
			'class A { public static function main():Void { for (i in 0...10) icon(i); for (i in 0...10) list(i); }'
			+ ' static function icon(i:Int):Void FileSystem.stat("a"); static function list(i:Int):Void FileSystem.readDirectory("a"); }'
		]);
		Assert.same([
			'info A A.icon | FileSystem.stat',
			'info A A.list | FileSystem.readDirectory',
			'warning A A.main | for (i in 0...10)',
			'warning A A.main | for (i in 0...10) #2'
		], graded(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `S.scan` holds `_m` on a spawned thread across `body`, and the main thread takes `_m` in `S.read`, holding it across
	 * nothing.
	 */
	private static function holdFixture(body: String): Array<String> {
		return [
			'class S { final _m:Mutex = new Mutex(); public function new() {}'
				+ ' public function read():Int { _m.acquire(); _m.release(); return 1; }'
				+ ' public function scan(ps:Array<String>):Void { _m.acquire(); $body _m.release(); }'
				+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.scan(["a"])); s.read(); } }'
		];
	}

	/** Each finding of `found` with structured data as `<severity> <family> <member> | <subject>`, sorted. */
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

	private static function run(sources: Array<String>): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER].concat(sources));
	}
	#end

	/** Of several loops above a short call on different ways to it, the nearest owns the warning: one per call site, never one per loop. */
	@:pin('control') @:killer('M-TS-OWNER-FARTHEST')
	public function testTheNearestRepeatingCallerOwnsTheWarning(): Void {
		#if (sys || nodejs)
		Assert.same(['info A A.icon | FileSystem.stat', 'warning A A.row | for (j in 0...10)'], graded(run([
			'class A { public static function main():Void { row(); page(); }' + ' static function row():Void for (j in 0...10) icon(j);'
			+ ' static function page():Void for (j in 0...10) cell(j); static function cell(i:Int):Void icon(i);'
			+ ' static function icon(i:Int):Void FileSystem.stat("a"); }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

}
