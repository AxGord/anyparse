package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * Repetition on the main thread read over its STATES (`MainRepeats`): a call a condition rules out under the value a
 * caller hands down carries no repetition from that caller — TM's `DrillVOModel.loadDrillData` loops over drills calling
 * `loadXML(path, false, …)`, whose `if (checkLimits)` SQL count never runs on that way.
 */
class ThreadSafetyMainStatesTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Db.count"],"shortSinks":["Db.count"]}}}';

	/** The loop's callee rules the short call out under the constant it is handed: nothing repeats it there. */
	@:pin('control') @:killer('M-TS-STATES-IGNORED')
	public function testAConstantArgumentRulesTheRepeatedCallOut(): Void {
		#if (sys || nodejs)
		Assert.same(['info A L.load | Db.count'], graded(run('load(p, false);')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The owner is found on the ways that run the call: another loop handing an unknown flag owns it, never the loop
	 * whose constant rules it out, however near its site.
	 */
	@:pin('control') @:killer('M-TS-STATES-OWNER-IGNORED')
	public function testTheOwnerIsOnAWayThatRunsTheCall(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A L.load | Db.count', 'warning A L.other | L.load'],
			graded(run(
				'load(p, false); static function other(qs:Array<String>):Void for (q in qs) load(q, Math.random() > 0.5);', 'other(["c"]);'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `Token.blockedPost` → `blockedRequestInternal`: an object literal handed down is never null, and a `final`
	 * local bound to `data == null` is that test — the cache read under it never runs from the loop.
	 */
	@:pin('control') @:killer('M-TS-COND-FINAL-LOCAL') @:killer('M-TS-ARG-LITERAL-NONNULL') @:killer('M-TS-ARG-FINAL-LOCAL-READ')
	public function testALiteralArgumentDecidesAFinalLocalCondition(): Void {
		#if (sys || nodejs)
		final found: Array<String> = graded(run(
			'req({ a: 1 }); static function req(data:Dynamic):Void { final simple:Bool = data == null; if (simple) Db.count(); }',
			'req(null);'
		)).filter(g -> g.indexOf('L.load') < 0);
		Assert.equals('info A L.req | Db.count', found.join(';'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `L.all` loops calling `body`; `load` counts under `check`; `main` also calls `load` once with an unknown flag. */
	private static function run(body: String, ?more: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			'class Db { public static function count():Int return 0; }',
			'class L { static function load(p:String, check:Bool):Void { if (check) Db.count(); }'
			+ ' static function all(ps:Array<String>):Void for (p in ps) $body'
			+ ' public static function main():Void { all(["a"]); load("b", Math.random() > 0.5); ${more ?? ''} } }'
		]);
	}

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
