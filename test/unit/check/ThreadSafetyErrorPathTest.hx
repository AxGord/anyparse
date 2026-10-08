package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.LongLockExplain.LongLockReason;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Error-path demotion (`ErrorPaths`): a finding long only through a call inside a `catch` body is graded info, naming
 * that catch — over the normal paths it is short. A long reason outside every catch keeps the warning.
 */
class ThreadSafetyErrorPathTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	private static inline final REPORT: String = 'class Report { public static function send():Void Sys.sleep(1); }';

	/**
	 * TM's `FolderWatcher.setTimestamp`: the hold spans a call whose only blocking leg is `catch` → `Error.reportError` →
	 * a blocking PUT, so the hold and the main thread's take are long only on an error path.
	 */
	@:pin('control') @:killer('M-TS-ERROR-REACH-OFF') @:killer('M-TS-ERROR-HOLD-OFF') @:killer('M-TS-ERROR-TAKE-OFF')
	public function testABlockOnlyInACalleesCatchIsInfo(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run('function save():Void { try { step(); } catch (e:Dynamic) { Report.send(); } }', 'save();');
		Assert.same(['info A S.ui | Mutex.acquire', 'info B S.work | S._m'], graded(found));
		Assert.isTrue(
			found.filter(v -> v.data != null && v.data.member.indexOf('Report.') < 0)
				.foreach(v -> v.message.indexOf('only on an error path (catch at ') >= 0),
			'each names the catch'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call in the hold's own window inside a `catch` runs only there. */
	@:pin('control') @:killer('M-TS-ERROR-WINDOW-OFF')
	public function testABlockInTheHoldsOwnCatchIsInfo(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A S.ui | Mutex.acquire', 'info B S.work | S._m'],
			graded(run('', 'try { step(); } catch (e:Dynamic) { Report.send(); }'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same block outside the catch too: a long reason not inside a catch keeps both warnings. */
	@:pin('control') @:killer('M-TS-ERROR-ANY') @:killer('M-TS-ERROR-TAKE-ANY')
	public function testABlockAlsoOutsideTheCatchWarns(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A S.ui | Mutex.acquire', 'warning B S.work | S._m'],
			graded(run('function save():Void { try { step(); } catch (e:Dynamic) { Report.send(); } Report.send(); }', 'save();'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A main-thread sink call inside a `catch` runs only on an error path. */
	@:pin('control') @:killer('M-TS-ERROR-CAUGHT-OFF')
	public function testAMainSinkCallInACatchIsInfo(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			'class A { static function step():Void {}'
			+ ' public static function main():Void { try { step(); } catch (e:Dynamic) { Sys.sleep(1); } Sys.sleep(2); } }'
		]);
		Assert.same(['info A A.main | Sys.sleep', 'warning A A.main | Sys.sleep'], graded(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--explain-long` marks a reason that blocks only through a catch with that catch. */
	@:pin('control') @:killer('M-TS-ERROR-EXPLAIN-OFF')
	public function testExplainLongMarksTheErrorPath(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('threadsafetyerrorpath', [{ name: 'apqlint.json', source: CONFIG }]);
		final check: ThreadSafety = new ThreadSafety();
		check.explainLongLocks(true);
		final sources: Array<String> = fixture('function save():Void { try { step(); } catch (e:Dynamic) { Report.send(); } }', 'save();');
		Linter.run([for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }], new HaxeQueryPlugin(), [check]);
		CliFixture.removeDir(dir);
		final reasons: Array<LongLockReason> = check.longLocks?.long.find(l -> l.lock == 'S._m')?.reasons ?? [];
		Assert.same(['$dir/F3.hx:1'], [for (r in reasons) if (r.errorPath != null) r.errorPath]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The sources of a hold of `S._m` on a background thread spanning `held`, beside `members`, and a main-thread take. */
	private static function fixture(members: String, held: String): Array<String> {
		return [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			REPORT,
			'class S { final _m:Mutex = new Mutex(); public function new() {} function step():Void {} $members'
				+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
				+ ' public function ui():Void { _m.acquire(); _m.release(); }'
				+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.ui(); } }'
		];
	}

	private static inline function run(members: String, held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, fixture(members, held));
	}

	/** The findings of `found` with data as `<severity> <family> <member> | <subject>`, sorted, `Report`'s own left out. */
	private static function graded(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.member.indexOf('Report.') < 0)
					'${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
