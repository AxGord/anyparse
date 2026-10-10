package unit.check;

import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * The `thread-safety` options are read and checked in ONE place (`ThreadSafetyOptions`): a key no option has, a value
 * of the wrong shape, a list item or a `boundedRepeats` entry dropped, a `site` matching no function — each is said, as
 * an `info` finding naming no file, instead of reading as a quiet config (the reviewer's `tm-bad` config was
 * byte-identical to no config at all).
 */
class ThreadSafetyOptionsTest extends Test {

	private static inline final SOURCES: String = 'class Mutex { public function new() {} public function acquire():Void {}'
		+ ' public function release():Void {} } class L { public static function main():Void { for (i in 0...3) Sys.sleep(1); } }';

	@:pin('control') @:killer('M-TS-OPT-UNKNOWN') @:killer('M-TS-OPT-LIST-SHAPE') @:killer('M-TS-OPT-LIST-ITEM')
	@:killer('M-TS-OPT-FLAG') @:killer('M-TS-OPT-BUDGET') @:killer('M-TS-OPT-BOUNDED-ENTRY') @:killer('M-TS-OPT-BOUNDED-SITE')
	public function testEveryMalformedOptionIsSaid(): Void {
		#if (sys || nodejs)
		Assert.same([
			'boundedRepeats site "Nope.nothing" matches no function of the run — it bounds nothing',
			'boundedRepeats[0] dropped: "max" is not a number',
			'boundedRepeats[1] is not an object — dropped',
			'option "compilerFacts" is not true or false — ignored',
			'option "iterates" ignored 2 value(s) that are not strings',
			'option "nonThrowing" ignored 1 value(s) that are not strings',
			'option "registers" is not an array of strings — ignored',
			'option "repeatBudgetMs" is not a positive number — ignored',
			'option "runsOnce" is not an array of strings — ignored',
			'option "sharedLocks" is not an array of strings — ignored',
			'option "shortSinks" is not an array of strings — ignored',
			'unknown option "shortSink" — ignored (did you mean "shortSinks"?)'
		], said(
			'"shortSinks":"Sys.sleep","shortSink":["Sys.sleep"],"iterates":[1,2],"registers":{"x":1},"sharedLocks":"Mutex.acquire",'
			+ '"nonThrowing":[null],"repeatBudgetMs":"50","compilerFacts":"true","runsOnce":"L.main","boundedRepeats":['
			+ '{"site":"L.main","max":"414","costMs":0.08},"junk",{"site":"Nope.nothing","max":5,"costMs":0.1}]'
		));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A well-formed config says nothing: an entry's `evidence` is for people, and `runsOnce` a list like the others. */
	public function testAWellFormedConfigSaysNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			[],
			said(
				'"shortSinks":["Sys.sleep"],"iterates":["Lambda.*"],"registers":["addEventListener"],'
				+ '"sharedLocks":["Mutex.acquire"],"nonThrowing":["Sys.sleep"],"repeatBudgetMs":50,"compilerFacts":false,'
				+ '"closedWorld":false,"runsOnce":["L.main"],"exclude":["gen"],'
				+ '"boundedRepeats":[{"site":"L.main","call":"Sys.sleep","max":3,"costMs":0.1,"evidence":"three turns, measured"}]'
			)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `sinks` the config loses — a typo of the key, a value of the wrong shape, items that are no strings — or one
	 * naming no call of the run leaves the rule nothing to find: it is said, not answered "no issues"; and a mistyped
	 * `enabled` is a value of the wrong shape, not an unknown option (review round 2 `cfgA`–`cfgE`).
	 */
	@:pin('control') @:killer('M-TS-MALFORMED-UNGATED') @:killer('M-TS-OPT-SINKS-UNMATCHED') @:killer('M-TS-OPT-SKIP-DECLARED')
	@:killer('M-TS-OPT-NO-SINK-NOTICES') @:killer('M-TS-OPT-LIFTED')
	public function testALostSinksListIsSaid(): Void {
		#if (sys || nodejs)
		final none: String = 'option "sinks" lists no call — thread-safety finds nothing under this config';
		Assert.same(['unknown option "sink" — ignored (did you mean "sinks"?)'], saidAlone('"sink":["Sys.sleep"]'), 'a typo');
		Assert.same(['option "sinks" is not an array of strings — ignored', none], saidAlone('"sinks":"Sys.sleep"'), 'a string');
		Assert.same(
			['option "sinks" ignored 1 value(s) that are not strings', none], saidAlone('"sinks":[{"call":"Sys.sleep"}]'), 'objects'
		);
		Assert.same([
			'option "sinks" names no call of the run (Sys.slep) — thread-safety finds nothing here'
		], saidAlone('"sinks":["Sys.slep"]'), 'matching nothing');
		Assert.same(['option "enabled" is not true or false — ignored'], saidAlone('"enabled":"true","sinks":["Sys.sleep"]'), 'enabled');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The config lines a run under the `thread-safety` options `options` alone says, sorted. */
	private static function saidAlone(options: String): Array<String> {
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{$options}}}', [SOURCES]);
		final out: Array<String> = [for (v in found) if (v.file == '') v.message];
		out.sort(Reflect.compare);
		return out;
	}

	/** The config lines a run under `options` (beside its `sinks` and `lockPairs`) says, sorted. */
	private static function said(options: String): Array<String> {
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep","Mutex.acquire"],"lockPairs":["Mutex.acquire/release"],$options}}}', [SOURCES]
		);
		final out: Array<String> = [for (v in found) if (v.file == '') v.message];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
