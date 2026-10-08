package unit.query;

import anyparse.query.Cli;
import anyparse.query.LintScore;
import anyparse.query.format.json.LintFindingJson;
import anyparse.query.format.json.LintTruthJson;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `apq lint-score`: a report's findings meet a truth file's entries by `(family, function, subject)`, several findings
 * of one key are one hit plus duplicates, precision leaves `unknown` and unlabelled keys out, recall counts `real-long`
 * and `recall: true` entries, and a lost recall entry is the run's exit status.
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

	/** Precision is real-long keys over the keys with a known verdict: an `unknown` key and an unlabelled one count for nothing. */
	@:pin('control') @:killer('M-SCORE-PRECISION-COUNTS-UNKNOWN')
	public function testPrecisionLeavesUnknownAndUnlabelledOut(): Void {
		final result: LintScoreResult = score(
			[
				entry('A', 'A.b', 'S.f', 'real-long'),
				entry('A', 'A.c', 'S.f', 'real-short'),
				entry('A', 'A.d', 'S.f', 'unknown')
			],
			[
				finding('A', 'A.b', 'S.f'),
				finding('A', 'A.c', 'S.f'),
				finding('A', 'A.d', 'S.f'),
				finding('A', 'A.e', 'S.f')
			]
		);
		Assert.equals(0.5, result.overall.precision);
	}

	/** Recall counts real-long entries and those marked `recall: true`; the ones no finding matches are lost. */
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

	/** Only findings of the truth's rule at the asked severity are scored; null scores every severity. */
	public function testSeverityAndRuleNarrowTheScore(): Void {
		final truth: LintTruthJson = LintScore.parseTruth(truthOf([entry('A', 'A.b', 'S.f', 'real-long')]));
		final findings: Array<LintFindingJson> = LintScore.parseFindings(
			'[${finding('A', 'A.b', 'S.f', 'info')}, ${finding('A', 'A.c', 'S.f')}, ${finding('A', 'A.d', 'S.f', 'warning', 'other-rule')}]'
		);
		Assert.equals(1, LintScore.score(truth, findings, 'warning').overall.findings);
		Assert.equals(2, LintScore.score(truth, findings, null).overall.findings);
	}

	/** Refused though the schema accepts it: an unknown verdict, a bare dup-of, an unknown evidence kind, a key labelled twice. */
	@:pin('control') @:killer('M-SCORE-VERDICT-UNCHECKED')
	public function testValidationRefusesWhatTheSchemaCannot(): Void {
		Assert.raises(LintScore.parseTruth.bind(truthOf([entry('A', 'A.b', 'S.f', 'maybe')])));
		Assert.raises(LintScore.parseTruth.bind(truthOf([entry('A', 'A.b', 'S.f', 'dup-of')])));
		Assert.raises(LintScore.parseTruth.bind(truthOf([entry('A', 'A.b', 'S.f', 'false', ', "evidence": {"kind": "hunch"}')])));
		Assert.raises(LintScore.parseTruth.bind(truthOf([entry('A', 'A.b', 'S.f', 'false'), entry('A', 'A.b', 'S.f', 'rare')])));
		final ok: LintTruthJson = LintScore.parseTruth(truthOf([
			entry('A', 'A.b', 'S.f', 'dup-of', ', "dupOf": "A A.c S.f", "evidence": {"kind": "measured", "ref": "r", "ms": 12}')
		]));
		Assert.equals(12.0, ok.entries[0].evidence?.ms);
	}

	/** The `--explain-long` envelope is a report too: its findings are scored, its other keys skipped. */
	public function testTheExplainEnvelopeIsAReport(): Void {
		final findings: Array<LintFindingJson> =
			LintScore.parseFindings('{"findings": [${finding('A', 'A.b', 'S.f')}], "longLocks": {"long": [], "mainShort": []}}');
		Assert.same(['A.b'], [for (f in findings) f.data?.member]);
	}

	/** The command exits 1 when a recall entry is lost, 0 when none is, 2 when the truth file is refused. */
	@:pin('control') @:killer('M-SCORE-LOST-EXIT')
	public function testExitStatusIsTheLostRecall(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('lintscore', [
			{ name: 'report.json', source: '[${finding('A', 'A.b', 'S.f')}]' },
			{ name: 'kept.json', source: truthOf([entry('A', 'A.b', 'S.f', 'real-long')]) },
			{ name: 'lost.json', source: truthOf([entry('A', 'A.c', 'S.f', 'real-long')]) },
			{ name: 'bad.json', source: truthOf([entry('A', 'A.c', 'S.f', 'maybe')]) }
		]);
		final exits: Array<Int> = [
			for (truth in ['kept', 'lost', 'bad']) {
				var code: Int = -1;
				CliFixture.captureStdout(
					() -> CliFixture.captureStderr(() -> code = Cli.run(['lint-score', '--truth', '$dir/$truth.json', '$dir/report.json']))
				);
				code;
			}
		];
		CliFixture.removeDir(dir);
		Assert.same([0, 1, 2], exits);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function score(entries: Array<String>, findings: Array<String>): LintScoreResult {
		return LintScore.score(LintScore.parseTruth(truthOf(entries)), LintScore.parseFindings('[${findings.join(', ')}]'), 'warning');
	}

	private static function truthOf(entries: Array<String>): String {
		return '{"rule": "thread-safety", "project": "p", "commit": "c", "entries": [${entries.join(', ')}]}';
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

}
