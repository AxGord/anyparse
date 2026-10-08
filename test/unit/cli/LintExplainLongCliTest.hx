package unit.cli;

import anyparse.query.Cli;
import anyparse.query.LintDiff;
import anyparse.query.format.json.LintFindingJson;
import haxe.Json;
import unit.check.ThreadSafetyCheckTest;
import unit.check.ThreadSafetyLongLocksTest;
import utest.Assert;
import utest.Test;

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
	private static final CASCADE: String = 'class A { final _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); final _s:Mutex = new Mutex();\n'
		+ ' public function new() {} function give():Void { tick(); _l.release(); } function keep(x:Bool):Void { if (x) _m.acquire(); }\n'
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
		final families: Array<String> = [for (f in findings) f.data?.family ?? '-'];
		families.sort(Reflect.compare);
		Assert.same(['A', 'A', 'B'], families, 'the two main-thread blocking calls and the hold, each with its data');
		final reason: Dynamic = Json.parse(out).longLocks.long[0].reasons[0];
		Assert.same(['spans-blocking', 'A.work', 'Sys.sleep', 3, 2], [
			reason.kind,
			Reflect.field(reason, 'function'),
			reason.call,
			reason.line,
			reason.col
		]);
		Assert.same(['A.work', 'Sys.sleep'], reason.chain);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** The cascade in json: `_l`'s counterfactual names the take of `_m` and `_m` as the lock it waits for; `_s` is short. */
	public function testJsonPinsAsideViaAndMainShort(): Void {
		#if nodejs
		final out: String = lint(CASCADE, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long']).out;
		final longLocks: Dynamic = Json.parse(out).longLocks;
		final l: Dynamic = (longLocks.long: Array<Dynamic>).filter(x -> x.lock == 'A._l')[0];
		final aside: Dynamic = l.aside[0];
		Assert.same(['spans-blocking', 'Mutex.acquire', 'A._m', 3, 39], [aside.kind, aside.call, aside.via, aside.line, aside.col]);
		final short: Array<Dynamic> = longLocks.mainShort;
		Assert.same([['A._s', 4, 25, false]], [for (t in short) [t.lock, t.line, t.col, t.quiet]]);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** A blind hold names its unresolved calls at their line and column; a short lock only a quiet root takes is marked quiet. */
	public function testUnresolvedCallsAndQuietTakes(): Void {
		#if nodejs
		final source: String = 'class A { final _m:Mutex = new Mutex(); final _s:Mutex = new Mutex(); public function new() {}\n'
			+ ' function work(f:() -> Void):Void { _m.acquire();\n' + ' f(); _m.release(); }\n'
			+ ' function shutdown():Void { _s.acquire(); tick(); _s.release(); } function tick():Void {} }';
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"lockPairs":["Mutex.acquire/release"],'
			+ '"quietRoots":["A.shutdown"]}}}';
		final json: Dynamic = Json.parse(lint(source, config, ['--format', 'json', '--explain-long']).out).longLocks;
		final blind: Dynamic = (json.long: Array<Dynamic>).filter(l -> l.lock == 'A._m')[0].reasons[0];
		Assert.same(['blind', 'f', 3, 2], [
			blind.kind,
			blind.unresolved[0].name,
			blind.unresolved[0].line,
			blind.unresolved[0].col
		]);
		final text: String = lint(source, config, ['--explain-long']).out;
		Assert.stringContains('unresolved: f at 3:2', text);
		Assert.stringContains('A.shutdown  (quiet)', text);
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

	/** Nothing to explain still answers an envelope, with a note: the rule not in the run, or a run with no `sinks`. */
	@:pin('control') @:killer('M-LINT-EXPLAIN-NO-ENVELOPE')
	public function testNothingToExplainIsSaid(): Void {
		#if nodejs
		final notInRules: LintOutput = lint(
			SOURCE, ThreadSafetyLongLocksTest.CONFIG, ['--format', 'json', '--explain-long', '--rule', 'unused-import'], false
		);
		Assert.stringContains('"longLocks": null', notInRules.out);
		Assert.stringContains('thread-safety is not among the rules this run reports', notInRules.err);
		final noSinks: LintOutput = lint(
			SOURCE, '{"rules":{"thread-safety":{"lockPairs":["Mutex.acquire/release"]}}}', ['--format', 'json', '--explain-long']
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
			{ name: 'apqlint.json', source: ThreadSafetyLongLocksTest.CONFIG },
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

	#if (sys || nodejs)
	/** What a lint of `source` (plus `Mutex`) under `config` with `flags` prints — `thread-safety` only unless `onlyRule` is off. */
	private static function lint(source: String, config: String, flags: Array<String>, onlyRule: Bool = true): LintOutput {
		final dir: String = CliFixture.writeDir('explainlong', [
			{ name: 'apqlint.json', source: config },
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
