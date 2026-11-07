package unit.cli;

import anyparse.check.common.design.threads.PositiveSinks;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.query.Cli;
import anyparse.query.LintDiff;
import anyparse.query.format.json.LintFindingJson;
import devkit.RawJson;
import unit.check.common.design.ThreadSafetyCheckTest;
import unit.check.common.design.ThreadSafetyLongLocksTest;

using StringTools;

/**
 * `apq lint --explain-long`: the long-lock evidence after the findings — a text section, or the
 * `{"findings": […], "longLocks": {…} | null}` envelope under `--format json`, always an envelope once asked — refused
 * with `--fix` and with checkstyle, and saying so when there is nothing to explain.
 */
class LintExplainLongCliTest extends Test {

	#if (sys || nodejs)
	/** `_m` held across a sleep; `work` and the sleep on lines 2 and 3. */
	private static final SOURCE: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}\n'
		+ ' function work():Void { _m.acquire();\n Sys.sleep(1); _m.release(); } }';

	/**
	 * `_l` long by a crossing release, its hold taking `_m`, long by a leak; `_s` taken on the main thread and short.
	 * The take of `_m` under `_l` sits on line 3, column 39.
	 */
	private static final CASCADE: String = 'class A { final _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); final _s:Mutex = new '
		+ 'Mutex();\n public function new() {} function give():Void { tick(); _l.release(); } '
		+ 'function keep(x:Bool):Void { if (x) _m.acquire(); }\n'
		+ ' function work():Void { _l.acquire(); _m.acquire(); _m.release(); _l.release(); }\n'
		+ ' function boot():Void { _s.acquire(); tick(); _s.release(); } function tick():Void {} }';
	#end

	/** The json envelope carries the findings, `data` included, beside the long locks. */
	@:pin('control') @:killer('M-LINT-EXPLAIN-UNSET')
	public function testJsonEnvelopeCarriesFindingsAndLongLocks(): Void {
		#if nodejs
		final out: String = lint(SOURCE, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long']).out;
		Assert.isTrue(out.trim().startsWith('{'), 'an envelope, not the bare array');
		final findings: Array<LintFindingJson> = LintDiff.parseReport(out);
		final families: Array<String> = [for (f in findings) if (f.file != '') f.data?.family ?? '-'];
		families.sort(Reflect.compare);
		Assert.same(['A', 'A', 'B'], families, 'the two main-thread blocking calls and the hold, each with its data');
		final reason: Null<JValue> = JValueTools.at(JValueParser.parse(out), 'longLocks.long.0.reasons.0');
		Assert.same(
			['"spans-blocking"', '"A.work"', '"Sys.sleep"', '3', '2'], printed(reason, ['kind', 'function', 'call', 'line', 'col'])
		);
		Assert.same(['["A.work","Sys.sleep"]'], printed(reason, ['chain']));
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** The cascade in json: `_l`'s counterfactual names the take of `_m` and `_m` as the lock it waits for; `_s` is short. */
	public function testJsonPinsAsideViaAndMainShort(): Void {
		#if nodejs
		final out: String = lint(CASCADE, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long']).out;
		final longLocks: Null<JValue> = JValueTools.at(JValueParser.parse(out), 'longLocks');
		final aside: Null<JValue> = JValueTools.at(lock(longLocks, 'A._l'), 'aside.0');
		Assert.same(['"spans-blocking"', '"Mutex.acquire"', '"A._m"', '3', '39'], printed(aside, ['kind', 'call', 'via', 'line', 'col']));
		final short: Array<JValue> = RawJson.items(JValueTools.at(longLocks, 'mainShort'));
		Assert.same([['"A._s"', '4', '25', 'false']], short.map(t -> printed(t, ['lock', 'line', 'col', 'quiet'])));
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** A blind hold names its unresolved calls at their line and column; a short lock only a quiet root takes is marked quiet. */
	public function testUnresolvedCallsAndQuietTakes(): Void {
		#if nodejs
		final source: String = 'class A { final _m:Mutex = new Mutex(); final _s:Mutex = new Mutex(); public function new() {}\n'
			+ ' function work(f:() -> Void):Void { _m.acquire();\n f(); _m.release(); }\n'
			+ ' function shutdown():Void { _s.acquire(); tick(); _s.release(); } function tick():Void {} }';
		final config: String =
			'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"lockPairs":["Mutex.acquire/release"],"quietRoots":["A.shutdown"]}}}';
		final json: Null<JValue> = JValueTools.at(
			JValueParser.parse(lint(source, config, ['--format', 'json', '--explain-long']).out), 'longLocks'
		);
		final blind: Null<JValue> = JValueTools.at(lock(json, 'A._m'), 'reasons.0');
		Assert.same(['"blind"', '"f"', '3', '2'], printed(blind, ['kind', 'unresolved.0.name', 'unresolved.0.line', 'unresolved.0.col']));
		final text: String = lint(source, config, ['--explain-long']).out;
		Assert.stringContains('unresolved: f at 3:2', text);
		Assert.stringContains('A.shutdown  (quiet)', text);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** Each lock others dominate, in json (`dominated: [{lock, by}]`) and in text. */
	@:pin('control') @:killer('M-LINT-FORMAT-DOMINATED')
	public function testDominatedLocksAreNamed(): Void {
		#if nodejs
		final source: String = 'class Runner { public static function create(fn:()->Void):Void {} }'
			+ ' class A { final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {}'
			+ ' public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
			+ ' public static function main():Void { final d:A = new A(); Runner.create(() -> d.slow()); } }';
		final json: Null<JValue> = JValueTools.at(
			JValueParser.parse(lint(source, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long']).out), 'longLocks'
		);
		Assert.same(
			[['"A._inner"', '["A._outer"]'], ['"A._outer"', '["A._inner"]']],
			RawJson.items(JValueTools.at(json, 'dominated')).map(d -> printed(d, ['lock', 'by']))
		);
		Assert.stringContains(
			'dominated A._inner by A._outer: a take of it under one of those is brief',
			lint(source, ThreadSafetyLongLocksTest.CONFIG, ['--explain-long']).out
		);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** A reason that blocks only through a `catch` names that catch, as `errorPath` in json and in text. */
	@:pin('control') @:killer('M-LINT-FORMAT-ERRORPATH')
	public function testAnErrorPathReasonNamesItsCatch(): Void {
		#if nodejs
		final source: String = 'class Runner { public static function create(fn:()->Void):Void {} }'
			+ ' class Report { public static function send():Void Sys.sleep(1); }\nclass A { final _m:Mutex = new Mutex(); public '
			+ 'function new() {} static function step():Void {}\n function save():Void { try { step(); } catch (e:Dynamic) {'
			+ ' Report.send(); } }\n public function work():Void { _m.acquire(); save(); _m.release(); } public static function '
			+ 'main():Void { final a:A = new A(); Runner.create(() -> a.work()); a._m.acquire(); a._m.release(); } }';
		final json: Null<JValue> = JValueTools.at(
			JValueParser.parse(lint(source, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long']).out), 'longLocks'
		);
		final reasons: Array<JValue> = RawJson.items(JValueTools.at(lock(json, 'A._m'), 'reasons'));
		final paths: Array<Null<String>> = [
			for (r in reasons)
				if (JValueTools.field(r, 'errorPath') != null)
					(RawJson.string(JValueTools.field(r, 'errorPath')) ?? 'errorPath is not a string').split('/').pop()
		];
		Assert.same(['A.hx:3'], paths);
		Assert.stringContains('only on an error path (catch at ', lint(source, ThreadSafetyLongLocksTest.CONFIG, ['--explain-long']).out);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** A finding naming no file (an option the rule could not read) closes the report, in text and in json. */
	@:pin('control') @:killer('M-LINT-NOFILE-DROPPED')
	public function testAFindingNamingNoFileIsPrinted(): Void {
		#if nodejs
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"lockPairs":["Mutex.acquire/release"],'
			+ '"shortSink":["Sys.sleep"]}}}';
		final unknown: String = 'unknown option "shortSink" — ignored (did you mean "shortSinks"?)';
		final records: Array<LintFindingJson> = LintDiff.parseReport(lint(SOURCE, config, ['--format', 'json']).out);
		// beside the notice every reporting run gives of the builtin sinks it applied
		Assert.same([['', 'info', unknown]], [
			for (r in records) if (r.file == '' && !(r.message: String).startsWith(PositiveSinks.NOTICE)) [r.file, r.severity, r.message]
		]);
		Assert.stringContains('(no file):\n  (no-span): [info] $unknown (thread-safety)', lint(SOURCE, config, ['--all']).out);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/**
	 * Text puts the section after the findings and says when a lock would not be long without its own reasons; without
	 * the flag there is none.
	 */
	public function testTextSectionFollowsTheFindings(): Void {
		#if nodejs
		final out: String = lint(SOURCE, ThreadSafetyLongLocksTest.CONFIG, ['--explain-long']).out;
		Assert.isTrue(out.indexOf('thread-safety --explain-long: 1 long lock(s)') > out.indexOf('holds "A._m"'), out);
		Assert.stringContains('long A._m\n  spans-blocking', out);
		Assert.equals(-1, lint(SOURCE, ThreadSafetyLongLocksTest.CONFIG, []).out.indexOf('--explain-long'));
		final cascade: String = lint(CASCADE, ThreadSafetyLongLocksTest.CONFIG, ['--explain-long']).out;
		Assert.stringContains('long A._m\n  leak', cascade);
		Assert.stringContains('without its own reasons: not long', cascade);
		Assert.stringContains('calls Mutex.acquire via A._m', cascade);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** Nothing to explain still answers an envelope, with a note: the rule not in the run, or a run whose every sink is waived. */
	@:pin('control') @:killer('M-LINT-EXPLAIN-NO-ENVELOPE')
	public function testNothingToExplainIsSaid(): Void {
		#if nodejs
		final notInRules: LintOutput = lint(
			SOURCE, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long', '--rule', 'unused-import'], false
		);
		Assert.stringContains('"longLocks": null', notInRules.out);
		Assert.stringContains('thread-safety is not among the rules this run reports', notInRules.err);
		final noSinks: LintOutput = lint(
			SOURCE,
			'{"rules":{"thread-safety":{"lockPairs":["Mutex.acquire/release"],'
			+ '"nonBlocking":["Sys.sleep a fixture sleep","Mutex.acquire a fixture lock"]}}}',
			['--format', 'json', '--explain-long']
		);
		Assert.stringContains('"longLocks": null', noSinks.out);
		Assert.stringContains('thread-safety explained nothing', noSinks.err);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** Explaining is a report concern: `--fix` and checkstyle refuse it as a usage error. */
	public function testFixAndCheckstyleRefuseIt(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('explainlong', [
			{ name: 'apq.json', source: ThreadSafetyLongLocksTest.CONFIG },
			{ name: 'A.hx', source: SOURCE }
		]);
		var fix: Int = -1;
		var checkstyle: Int = -1;
		CliFixture.captureStderr(() -> fix = Cli.run(['lint', '--rule', 'thread-safety', '--no-oracle', '--explain-long', '--fix', dir]));
		CliFixture.captureStderr(() -> checkstyle = Cli.run(['lint', '--format', 'checkstyle', '--explain-long', dir]));
		CliFixture.removeDir(dir);
		Assert.same([2, 2], [fix, checkstyle]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The value at each of `paths` of `value`, printed as JSON so a number, a string and a flag stay told apart; `null`
	 * where it holds none.
	 */
	private static function printed(value: Null<JValue>, paths: Array<String>): Array<String> {
		return paths.map(path -> RawJson.print(JValueTools.at(value, path) ?? JNull));
	}

	/** The record of `lock` among the long locks of an `--explain-long` section. */
	private static function lock(longLocks: Null<JValue>, lock: String): Null<JValue> {
		return RawJson.items(JValueTools.at(longLocks, 'long')).filter(l -> RawJson.stringAt(l, 'lock') == lock)[0];
	}

	#if (sys || nodejs)
	/** What a lint of `source` (plus `Mutex`) under `config` with `flags` prints — `thread-safety` only unless `onlyRule` is off. */
	private static function lint(source: String, config: String, flags: Array<String>, onlyRule: Bool = true): LintOutput {
		final dir: String = CliFixture.writeDir('explainlong', [
			{ name: 'apq.json', source: config },
			{ name: 'Mutex.hx', source: ThreadSafetyCheckTest.MUTEX },
			{ name: 'A.hx', source: source }
		]);
		final rule: Array<String> = onlyRule ? ['--rule', 'thread-safety'] : [];
		var err: String = '';
		final out: String = CliFixture.captureStdout(
			() -> err = CliFixture.captureStderr(() -> Cli.run(['lint', '--no-oracle'].concat(rule).concat(flags).concat([dir])))
		);
		CliFixture.removeDir(dir);
		return { out: out, err: err };
	}
	#end

}

/** What one lint run printed: stdout and stderr. */
private typedef LintOutput = {
	final out: String;
	final err: String;
}
