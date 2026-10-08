package unit.cli;

import anyparse.query.Cli;
import anyparse.query.LintScore;
import anyparse.query.format.json.LintFindingJson;
import unit.check.ThreadSafetyCheckTest;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `apq lint --explain-long`: the long-lock evidence after the findings — a text section, or the
 * `{"findings": […], "longLocks": {…}}` envelope under `--format json` — refused with `--fix` and with checkstyle.
 */
class LintExplainLongCliTest extends Test {

	#if (sys || nodejs)
	private static final CONFIG: String =
		'{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}';
	private static final SOURCE: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
		+ ' function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); } }';
	#end

	/** The json envelope carries the findings, `data` included, beside the long locks. */
	@:pin('control') @:killer('M-LINT-EXPLAIN-UNSET')
	public function testJsonEnvelopeCarriesFindingsAndLongLocks(): Void {
		#if nodejs
		final out: String = lint(['--format', 'json', '--explain-long']);
		Assert.isTrue(out.trim().startsWith('{'), 'an envelope, not the bare array');
		final findings: Array<LintFindingJson> = LintScore.parseFindings(out);
		final families: Array<String> = [for (f in findings) f.data?.family ?? '-'];
		families.sort(Reflect.compare);
		Assert.same(['A', 'A', 'B'], families, 'the two main-thread blocking calls and the hold, each with its data');
		Assert.stringContains('"longLocks"', out);
		Assert.stringContains('"kind": "spans-blocking"', out);
		Assert.stringContains('"function": "A.work"', out);
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** Text puts the section after the findings; without the flag there is none. */
	public function testTextSectionFollowsTheFindings(): Void {
		#if nodejs
		final out: String = lint(['--explain-long']);
		final section: Int = out.indexOf('thread-safety --explain-long: 1 long lock(s)');
		Assert.isTrue(section > out.indexOf('holds "A._m"'), out);
		Assert.stringContains('long A._m\n  spans-blocking', out);
		Assert.equals(-1, lint([]).indexOf('--explain-long'));
		#else
		Assert.pass('node only: stdout capture');
		#end
	}

	/** Explaining is a report concern: `--fix` and checkstyle refuse it as a usage error. */
	public function testFixAndCheckstyleRefuseIt(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir(
			'explainlong', [{ name: 'apqlint.json', source: CONFIG }, { name: 'A.hx', source: SOURCE }]
		);
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
	/** The stdout of a `thread-safety` lint of `SOURCE` (plus `Mutex`) with `flags`. */
	private static function lint(flags: Array<String>): String {
		final dir: String = CliFixture.writeDir('explainlong', [
			{ name: 'apqlint.json', source: CONFIG },
			{ name: 'Mutex.hx', source: ThreadSafetyCheckTest.MUTEX },
			{ name: 'A.hx', source: SOURCE }
		]);
		final out: String = CliFixture.captureStdout(
			() -> CliFixture.captureStderr(() -> Cli.run(['lint', '--rule', 'thread-safety', '--no-oracle'].concat(flags).concat([dir])))
		);
		CliFixture.removeDir(dir);
		return out;
	}
	#end

}
