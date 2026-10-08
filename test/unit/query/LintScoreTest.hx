package unit.query;

import anyparse.query.Cli;
import anyparse.query.LintDiff;
import anyparse.query.LintScore;
import anyparse.query.format.json.LintTruthJson;
import haxe.Exception;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `apq lint-score`: a report's findings meet a truth file's entries by `(family, function, subject)`, several findings
 * of one key are one hit plus duplicates, precision leaves `unknown` and unlabelled keys out, recall counts `real-long`
 * and `recall: true` entries, a lost recall entry is the run's exit status, and a score of nothing is no score.
 */
@:nullSafety(Strict)
class LintScoreTest extends Test {

	/** Three findings of one key are one key and two duplicates; each verdict counts its keys, a key no entry labels is unlabelled. */
	@:pin('control') @:killer('M-SCORE-DUPLICATES-AS-KEYS')
	public function testFindingsMeetEntriesByKey(): Void {
		final result: LintScoreResult = score(
			[
				entry('A', 'A.b', 'S.f', 'real-long'),
				entry('B', 'C.d', 'C._m', 'false')
			],
			[
				finding('A', 'A.b', 'S.f'),
				finding('A', 'A.b', 'S.f'),
				finding('A', 'A.b', 'S.f'),
				finding('B', 'C.d', 'C._m'),
				finding('B', 'X.y', 'X._n')
			]
		);
		final all: LintScoreBucket = result.overall;
		Assert.same([5, 3, 1, 1, 1], [
			all.findings,
			all.keys,
			all.matched['real-long'],
			all.matched['false'],
			all.unlabelled
		]);
		Assert.same(['A', 'B'], [for (b in result.families) b.family]);
		Assert.same(['X.y'], [for (k in result.unlabelled) k.member]);
	}

	/**
	 * Precision is real-long keys over the keys with a known verdict: an `unknown` key and an unlabelled one count for
	 * nothing, a `dup-of` key counts against it.
	 */
	@:pin('control') @:killer('M-SCORE-PRECISION-COUNTS-UNKNOWN')
	public function testPrecisionLeavesUnknownAndUnlabelledOut(): Void {
		final result: LintScoreResult = score(
			[
				entry('A', 'A.b', 'S.f', 'real-long'),
				entry('A', 'A.c', 'S.f', 'real-short'),
				entry('A', 'A.d', 'S.f', 'unknown'),
				entry('A', 'A.g', 'S.f', 'dup-of', ', "dupOf": "A|A.b|S.f"')
			],
			[
				finding('A', 'A.b', 'S.f'),
				finding('A', 'A.c', 'S.f'),
				finding('A', 'A.d', 'S.f'),
				finding('A', 'A.e', 'S.f'),
				finding('A', 'A.g', 'S.f')
			]
		);
		Assert.floatEquals(1 / 3, result.overall.precision ?? -1);
	}

	/** Recall counts every real-long entry and any other marked `recall: true`; the ones no finding matches are lost. */
	@:pin('control') @:killer('M-SCORE-RECALL-REAL-LONG-ONLY')
	public function testRecallCountsMarkedEntries(): Void {
		final marked: String = entry('A', 'A.c', 'S.f', 'rare', ', "recall": true');
		final result: LintScoreResult = score(
			[entry('A', 'A.b', 'S.f', 'real-long'), marked, entry('A', 'A.d', 'S.f', 'false')],
			[finding('A', 'A.b', 'S.f')]
		);
		Assert.same([1, 2], [result.overall.recallHit, result.overall.recallEntries]);
		Assert.same(['A.c'], [for (e in result.lost) e.member]);
	}

	/** A zero denominator is no ratio, and a family with entries but no finding still has its row, its recall lost. */
	public function testZeroDenominatorsAndAFamilyWithoutFindings(): Void {
		final result: LintScoreResult = score([entry('B', 'C.d', 'C._m', 'real-long')], [finding('A', 'A.b', 'S.f')]);
		Assert.same(['A', 'B'], [for (b in result.families) b.family]);
		final a: LintScoreBucket = result.families[0];
		final b: LintScoreBucket = result.families[1];
		Assert.same([null, 0, 0], [a.precision, a.recallEntries, a.recallHit]);
		Assert.same([0, 0, 1, 0], [b.findings, b.keys, b.recallEntries, b.recallHit]);
		Assert.isNull(result.overall.precision, 'one unlabelled key gives precision no denominator');
	}

	/** A finding without `data` matches no entry: it keys by itself, never merging with another, and counts unlabelled. */
	public function testAFindingWithoutDataIsUnlabelled(): Void {
		final plain: String = '{"file": "src/A.hx", "severity": "warning", "rule": "thread-safety", "message": "m"}';
		final result: LintScoreResult = LintScore.score(
			LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'false')])), LintDiff.parseReport('[$plain, $plain]'), 'warning'
		);
		Assert.same([2, 2, 2], [result.overall.findings, result.overall.keys, result.overall.unlabelled]);
	}

	/** The default minimum scores warnings and errors; a lower one scores more, and a higher one leaves the rest out, counted. */
	@:pin('control') @:killer('M-SCORE-SEVERITY-EXACT')
	public function testSeverityIsAMinimum(): Void {
		final truth: LintTruthJson = LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long')]));
		final report: String = '[${finding('A', 'A.b', 'S.f', 'error')}, ${finding('A', 'A.c', 'S.f')}, ${finding('A', 'A.d', 'S.f', 'info')},'
			+ ' ${finding('A', 'A.e', 'S.f', 'warning', 'other-rule')}]';
		Assert.same([2, 1], counts(LintScore.score(truth, LintDiff.parseReport(report), 'warning')));
		Assert.same([3, 0], counts(LintScore.score(truth, LintDiff.parseReport(report), null)));
		Assert.same([1, 2], counts(LintScore.score(truth, LintDiff.parseReport(report), 'error')));
	}

	/** Nothing left to score is no score: a misspelt rule, an empty report, a minimum above every finding — each one says which. */
	@:pin('control') @:killer('M-SCORE-NOTHING-SCORED')
	public function testNothingToScoreIsRefused(): Void {
		final truth: LintTruthJson = LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long')]));
		Assert.stringContains(
			'no finding of rule "thread-safety"', refusal(() -> LintScore.score(truth, LintDiff.parseReport('[]'), 'warning'))
		);
		Assert.stringContains(
			'no finding of rule',
			refusal(() -> LintScore.score(truth, LintDiff.parseReport('[${finding('A', 'A.b', 'S.f', 'warning', 'other')}]'), 'warning'))
		);
		Assert.stringContains(
			'1 finding(s) of rule "thread-safety", none at error or above',
			refusal(() -> LintScore.score(truth, LintDiff.parseReport('[${finding('A', 'A.b', 'S.f')}]'), 'error'))
		);
	}

	/**
	 * A truth file the schema accepts is still refused for: empty provenance, an unknown verdict, a dup-of naming nothing,
	 * itself or no entry, a `recall: false` real-long entry, an unknown evidence kind, a negative `ms`, a key labelled twice.
	 */
	@:pin('control') @:killer('M-SCORE-VERDICT-UNCHECKED', 'M-SCORE-DUPOF-DANGLING', 'M-SCORE-RECALL-FALSE-REAL-LONG')
	public function testValidationRefusesWhatTheSchemaCannot(): Void {
		Assert.stringContains('"commit" must be non-empty', refusal(() -> LintScore.parseTruth(truthOf([], '""'))));
		Assert.stringContains('unknown verdict "maybe"', refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'maybe')]))));
		Assert.stringContains('needs "dupOf"', refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'dup-of')]))));
		Assert.stringContains(
			'names the entry itself',
			refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'dup-of', ', "dupOf": "A|A.b|S.f"')])))
		);
		Assert.stringContains(
			'names no entry', refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'dup-of', ', "dupOf": "A|A.c|S.f"')])))
		);
		Assert.stringContains(
			'"recall": false contradicts it',
			refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long', ', "recall": false')])))
		);
		Assert.stringContains(
			'unknown evidence kind "hunch"',
			refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'false', ', "evidence": {"kind": "hunch"}')])))
		);
		Assert.stringContains('negative "ms"', refusal(() ->
			LintScore.parseTruth(truthOf([
				entry('A', 'A.b', 'S.f', 'false', ', "evidence": {"kind": "measured", "ms": -1}')
			]))
		));
		Assert.stringContains(
			'labelled twice',
			refusal(() -> LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'false'), entry('A', 'A.b', 'S.f', 'rare')])))
		);
		final ok: LintTruthJson = LintScore.parseTruth(truthOf([
			entry('A', 'A.c', 'S.f', 'false'),
			entry('A', 'A.b', 'S.f', 'dup-of', ', "dupOf": "A|A.c|S.f", "evidence": {"kind": "measured", "ref": "r", "ms": 12}')
		]));
		Assert.equals(12.0, ok.entries[1].evidence?.ms);
	}

	/**
	 * A `|` inside a key part is no collision — `{A, "x|y", "z"}` and `{A, "x", "y|z"}` are two keys — but a `dupOf` that
	 * spells both is ambiguous, and refused.
	 */
	@:pin('control') @:killer('M-SCORE-UNIQUE-JOINED', 'M-SCORE-DUPOF-AMBIGUOUS')
	public function testAPipeInsideAPartIsNoCollision(): Void {
		final twoKeys: Array<String> = [entry('A', 'x|y', 'z', 'real-long'), entry('A', 'x', 'y|z', 'false')];
		Assert.equals(2, LintScore.parseTruth(truthOf(twoKeys)).entries.length);
		Assert.stringContains(
			'names 2 entries',
			refusal(() -> LintScore.parseTruth(truthOf(twoKeys.concat([entry('A', 'w', 'v', 'dup-of', ', "dupOf": "A|x|y|z"')]))))
		);
	}

	/** A finding of a severity outside the order is refused, never scored as below the minimum. */
	@:pin('control') @:killer('M-SCORE-SEVERITY-UNKNOWN')
	public function testAnUnknownSeverityIsRefused(): Void {
		final truth: LintTruthJson = LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long')]));
		Assert.stringContains(
			'severity "fatal"',
			refusal(() ->
				LintScore.score(
					truth, LintDiff.parseReport('[${finding('A', 'A.b', 'S.f')}, ${finding('A', 'A.c', 'S.f', 'fatal')}]'), 'warning'
				)
			)
		);
	}

	/** The `--explain-long` envelope is a report too: its findings are scored, its other keys skipped. */
	public function testTheExplainEnvelopeIsAReport(): Void {
		final result: LintScoreResult = LintScore.score(
			LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long')])),
			LintDiff.parseReport('{"findings": [${finding('A', 'A.b', 'S.f')}], "longLocks": {"long": [], "mainShort": []}}'), 'warning'
		);
		Assert.equals(1, result.overall.recallHit);
	}

	/** The text table and the json document carry the same numbers, ratios to two decimals and `-` for none. */
	@:pin('control') @:killer('M-SCORE-JSON-EXCLUDED')
	public function testRenderAndJson(): Void {
		final result: LintScoreResult = score(
			[
				entry('A', 'A.b', 'S.f', 'real-long'),
				entry('A', 'A.c', 'S.f', 'false'),
				entry('A', 'A.d', 'S.f', 'false')
			],
			[
				finding('A', 'A.b', 'S.f'),
				finding('A', 'A.c', 'S.f'),
				finding('A', 'A.d', 'S.f'),
				finding('A', 'A.e', 'S.f')
			]
		);
		final lines: Array<String> = LintScore.render(result, 0);
		Assert.equals(
			'lint-score thread-safety @ p c (warning and above): 4 finding(s), 4 key(s), 0 duplicate(s), 0 below the severity', lines[0]
		);
		Assert.isTrue(lines.exists(l -> l.startsWith('all ') && l.indexOf('0.33') >= 0 && l.indexOf('1/1') >= 0), lines.join('\n'));
		Assert.stringContains('unlabelled: 1', lines.join('\n'));
		Assert.stringContains('… 1 more not shown — raise --limit', lines.join('\n'));
		final json: String = LintScore.json(result);
		Assert.stringContains('"precision": 0.3333', json);
		Assert.stringContains('"function": "A.e"', json);
		Assert.stringContains('"severity": "warning"', json);
		Assert.stringContains('"excluded": 0', json);
	}

	/** The command exits 1 when a recall entry is lost, 0 when none is, 2 when the truth is refused or nothing is scored. */
	@:pin('control') @:killer('M-SCORE-LOST-EXIT')
	public function testExitStatusIsTheLostRecall(): Void {
		#if (sys || nodejs)
		Assert.same([0, 1, 2, 2], [
			for (truth in [
				truthOf([entry('A', 'A.b', 'S.f', 'real-long')]),
				truthOf([entry('A', 'A.c', 'S.f', 'real-long')]),
				truthOf([entry('A', 'A.c', 'S.f', 'maybe')]),
				truthOf([entry('A', 'A.b', 'S.f', 'real-long')], '"c"', 'other-rule')
			]) runScore(truth, '[${finding('A', 'A.b', 'S.f')}]', [])
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A malformed flag is a usage error: an unknown severity, a non-numeric or too-small `--limit`, a stray dash argument. */
	public function testFlagsAreChecked(): Void {
		#if (sys || nodejs)
		final truth: String = truthOf([entry('A', 'A.b', 'S.f', 'real-long')]);
		final report: String = '[${finding('A', 'A.b', 'S.f')}]';
		Assert.same([2, 2, 2, 2, 0, 0], [
			for (flags in [
				['--severity', 'loud'],
				['--limit', 'abc'],
				['--limit', '-2'],
				['-x'],
				['--limit', '-1'],
				['--severity', 'all']
			])
				runScore(truth, report, flags)
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function score(entries: Array<String>, findings: Array<String>): LintScoreResult {
		return LintScore.score(LintScore.parseTruth(truthOf(entries)), LintDiff.parseReport('[${findings.join(', ')}]'), 'warning');
	}

	private static function counts(result: LintScoreResult): Array<Int> {
		return [result.overall.findings, result.excluded];
	}

	/** The message of what `fn` throws, '' when it returns. */
	private static function refusal(fn: () -> Void): String {
		return try {
			fn();
			'';
		} catch (exception: Exception) exception.message;
	}

	private static function truthOf(entries: Array<String>, commit: String = '"c"', rule: String = 'thread-safety'): String {
		return '{"rule": "$rule", "project": "p", "commit": $commit, "entries": [${entries.join(', ')}]}';
	}

	private static function entry(family: String, member: String, subject: String, verdict: String, extra: String = ''): String {
		return '{"family": "$family", "function": "$member", "subject": "$subject", "verdict": "$verdict"$extra}';
	}

	private static function finding(
		family: String, member: String, subject: String, severity: String = 'warning', rule: String = 'thread-safety'
	): String {
		return '{"file": "src/A.hx", "line": 1, "col": 1, "severity": "$severity", "rule": "$rule", "message": "m",'
			+ ' "data": {"family": "$family", "function": "$member", "subject": "$subject", "chain": []}}';
	}

	#if (sys || nodejs)
	/** The exit status of `lint-score` over `truth` and `report` with `flags`, its output captured. */
	private static function runScore(truth: String, report: String, flags: Array<String>): Int {
		final dir: String = CliFixture.writeDir(
			'lintscore', [{ name: 'truth.json', source: truth }, { name: 'report.json', source: report }]
		);
		var code: Int = -1;
		CliFixture.captureStdout(() ->
			CliFixture.captureStderr(() -> code = Cli.run(['lint-score', '--truth', '$dir/truth.json', '$dir/report.json'].concat(flags)))
		);
		CliFixture.removeDir(dir);
		return code;
	}
	#end

}
