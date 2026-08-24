package unit;

import anyparse.query.LintDiff;
import anyparse.query.format.json.LintFindingJson;
import utest.Assert;
import utest.Test;

/**
 * Unit cover for `apq lint-diff` — the blast-radius gate `tools/battery.sh`
 * runs once per compared tree.
 *
 * Every case here is a pair of hand-written `apq lint --format json` reports
 * driven straight through `LintDiff.parseReport` / `tally` / `compare`, with
 * no process and no filesystem: the CLI layer only reads two files and prints,
 * so the behaviour worth locking is the multiset arithmetic and the two
 * normalizations, and those are pure.
 *
 * The normalization cases are written as PAIRS — the same inputs with and
 * without the flag — because an assertion that a diff is empty passes just as
 * well when the two reports were never different. Asserting the un-normalized
 * arm is non-empty is what makes the normalized arm mean something. Two cases
 * are deliberately not pairs and say so in place: an over-reach guard, and a
 * pin on a known blind spot of the digit mask.
 */
@:nullSafety(Strict)
class LintDiffTest extends Test {

	/** Example cap passed to `render`, matching the CLI's own default. */
	private static inline final EXAMPLE_LIMIT: Int = 20;

	public function testIdenticalSnapshotsMoveNothing(): Void {
		final report: String = reportOf([
			record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused'),
			record('src/B.hx', 'info', 'member-order', 'member out of order')
		]);
		final result: LintDiffResult = diff(report, report, '');
		Assert.equals(0, result.addedTotal);
		Assert.equals(0, result.removedTotal);
		Assert.equals(2, result.newTotal);
		Assert.equals(2, result.oldTotal);
		Assert.equals(1, LintDiff.render(result, 'anyparse', EXAMPLE_LIMIT).length, 'a clean run renders one headline line');
	}

	public function testSurplusIsCountedPerOccurrenceNotPerKey(): Void {
		final before: String = reportOf([
			record('src/A.hx', 'warning', 'magic-number', 'magic number'),
			record('src/A.hx', 'warning', 'magic-number', 'magic number'),
			record('src/B.hx', 'info', 'member-order', 'member out of order')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'warning', 'magic-number', 'magic number'),
			record('src/C.hx', 'error', 'dead-code', 'unreachable statement')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'the dead-code finding is new');
		Assert.equals(2, result.removedTotal, 'one of two magic-number occurrences plus the member-order one');
		Assert.equals(1, result.added.length);
		Assert.equals(2, result.removed.length);
	}

	public function testRootStripsAnAbsoluteOldAgainstARelativeNew(): Void {
		final before: String = reportOf([record('/repo/src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final after: String = reportOf([record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final bare: LintDiffResult = diff(before, after, '');
		Assert.equals(1, bare.addedTotal, 'without --root the same finding reads as added and removed');
		Assert.equals(1, bare.removedTotal);
		final rooted: LintDiffResult = diff(before, after, '/repo');
		Assert.equals(0, rooted.addedTotal);
		Assert.equals(0, rooted.removedTotal);
	}

	public function testRootStripsAnAbsoluteNewAgainstARelativeOld(): Void {
		final before: String = reportOf([record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final after: String = reportOf([record('/repo/src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final rooted: LintDiffResult = diff(before, after, '/repo');
		Assert.equals(0, rooted.addedTotal, 'the prefix is stripped from whichever side carries it');
		Assert.equals(0, rooted.removedTotal);
		Assert.equals(1, diff(before, after, '').addedTotal, 'and it is --root that does it, not the pair being equal');
	}

	public function testRootToleratesATrailingSlash(): Void {
		final before: String = reportOf([record('/repo/src/A.hx', 'info', 'member-order', 'member out of order')]);
		final after: String = reportOf([record('src/A.hx', 'info', 'member-order', 'member out of order')]);
		final rooted: LintDiffResult = diff(before, after, '/repo/');
		Assert.equals(0, rooted.addedTotal);
		Assert.equals(0, rooted.removedTotal);
	}

	public function testADotSlashScopeSpellingNormalizesWithoutARoot(): Void {
		// `apq lint ./src` and `apq lint src` describe one tree and record two
		// spellings, in the file field AND in the partner path a duplicate-code
		// message quotes. Measured on a real pair before this was handled: 269 of
		// 468 findings read as added-and-removed.
		final before: String = reportOf([
			record('./src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from ./src/B.hx:501 - extract a shared helper')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:501 - extract a shared helper')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'a ./-spelled scope is the same tree');
		Assert.equals(0, result.removedTotal);
	}

	public function testRootDoesNotReachAPathOutsideIt(): Void {
		// An over-reach guard, not a normalization pair: it fails for a basename-
		// only or unanchored strip, and the second arm proves the same --root DOES
		// normalize a path that really is under it.
		final outside: String = reportOf([record('/elsewhere/src/A.hx', 'info', 'member-order', 'member out of order')]);
		final relative: String = reportOf([record('src/A.hx', 'info', 'member-order', 'member out of order')]);
		Assert.equals(1, diff(outside, relative, '/repo').addedTotal, 'a path outside the root is not silently re-keyed');
		Assert.equals(1, diff(outside, relative, '/repo').removedTotal);
		final inside: String = reportOf([record('/repo/src/A.hx', 'info', 'member-order', 'member out of order')]);
		Assert.equals(0, diff(inside, relative, '/repo').addedTotal, 'while a path under it still normalizes');
	}

	public function testDuplicateCodeLineShiftIsMaskedAway(): Void {
		final before: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:501 - extract a shared helper')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:612 - extract a shared helper')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'a partner-block line shift is not a finding');
		Assert.equals(0, result.removedTotal);
	}

	public function testDuplicateCodeIsNotDroppedFromTheReport(): Void {
		// The rule is masked, never excluded — a new duplicate against a NEW
		// partner file is still a finding. This does not exercise the mask itself
		// (the added key differs in `file`, so it survives either way); it pins
		// that nobody "fixes" the line-shift noise by dropping the rule.
		final before: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:501 - extract a shared helper')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:501 - extract a shared helper'),
			record('src/C.hx', 'info', 'duplicate-code', '9 statements duplicated from src/D.hx:12 - extract a shared helper')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'duplicate-code findings still reach the diff');
		Assert.equals(0, result.removedTotal);
	}

	public function testDuplicateCodeSubstitutionWithinOneFileIsMaskedAway(): Void {
		// The documented COST of masking every digit run rather than only the
		// partner line: two duplicate-code findings against the same partner that
		// differ solely in digits share one key, so swapping one for the other
		// reports nothing. Measured over the cached baselines, 57% (anyparse) and
		// 78% (tm) of duplicate-code findings sit in such a merged key. This is a
		// pin on the current behaviour, not an endorsement — narrowing the mask to
		// the line number alone is the fix, and this test is what will flip.
		final before: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '3 statements duplicated from src/B.hx:110 - extract a shared helper')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '7 statements duplicated from src/B.hx:134 - extract a shared helper')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'known blind spot: a different duplicate against the same partner is invisible');
		Assert.equals(0, result.removedTotal);
	}

	/**
	 * `unused-local` names the re-declaration that took a binding over, so its message carries a
	 * POSITION exactly as `duplicate-code`'s does. Without the mask an unrelated edit ABOVE such a
	 * finding reports it as 1 removed + 1 added — and a disappearing finding is the direction the
	 * blast-radius gate exists to catch, so the whole gate would read as a regression on every run
	 * that shifted a line.
	 */
	public function testUnusedLocalRedeclarationPositionIsMaskedAway(): Void {
		final before: String = reportOf([
			record(
				'src/A.hx', 'warning', 'unused-local',
				"unused local 'a' - re-declared at 5:3, and every read past that belongs to the second binding"
			)
		]);
		final after: String = reportOf([
			record(
				'src/A.hx', 'warning', 'unused-local',
				"unused local 'a' - re-declared at 8:3, and every read past that belongs to the second binding"
			)
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'an edit above the finding must not report it as new');
		Assert.equals(0, result.removedTotal, 'nor as removed - a disappearing finding is what the gate is for');
	}

	public function testASeverityFlipIsReported(): Void {
		// severity is part of the key. A rule that keeps its message and changes
		// severity has moved the blast radius, and the render publishes a
		// per-severity breakdown — a silent 0/0 here would let the number the
		// reader watches change under an exit-0 run.
		final before: String = reportOf([record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final after: String = reportOf([record('src/A.hx', 'info', 'unused-import', 'import a.B is unused')]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal);
		Assert.equals(1, result.removedTotal);
		Assert.equals(2, result.severities.length);
		Assert.equals('warning', result.severities[0].severity);
		Assert.equals(1, result.severities[0].removed);
		Assert.equals('info', result.severities[1].severity);
		Assert.equals(1, result.severities[1].added);
	}

	public function testAnUnknownSeveritySortsAfterTheKnownOnes(): Void {
		// SEVERITY_ORDER promises that a severity outside it prints after the
		// known ones rather than being dropped. Real reports only ever carry
		// info/warning, so nothing else would ever run this arm.
		final before: String = reportOf([]);
		final after: String = reportOf([
			record('src/A.hx', 'blocker', 'dead-code', 'unreachable statement'),
			record('src/B.hx', 'warning', 'dead-code', 'unreachable statement')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(2, result.severities.length);
		Assert.equals('warning', result.severities[0].severity, 'a known severity ranks first');
		Assert.equals('blocker', result.severities[1].severity, 'an unknown one follows, it is never dropped');
		Assert.equals(2, result.addedTotal);
	}

	public function testDigitMaskingIsScopedToDuplicateCode(): Void {
		final before: String = reportOf([record('src/A.hx', 'warning', 'complexity', 'cyclomatic complexity 21 (max 20)')]);
		final after: String = reportOf([record('src/A.hx', 'warning', 'complexity', 'cyclomatic complexity 34 (max 20)')]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'digits carry meaning in every other rule');
		Assert.equals(1, result.removedTotal);
	}

	public function testRootAlsoStripsThePartnerPathInsideADuplicateCodeMessage(): Void {
		final before: String = reportOf([
			record('/repo/src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from /repo/src/B.hx:501 - extract a shared helper')
		]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', '4 statements duplicated from src/B.hx:612 - extract a shared helper')
		]);
		Assert.equals(1, diff(before, after, '').addedTotal, 'the absolute partner path re-keys the finding without --root');
		final rooted: LintDiffResult = diff(before, after, '/repo');
		Assert.equals(0, rooted.addedTotal, '--root reaches the path the message quotes, not only the file field');
		Assert.equals(0, rooted.removedTotal);
	}

	public function testSeverityBreakdownCountsBothDirections(): Void {
		final before: String = reportOf([record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		final after: String = reportOf([
			record('src/A.hx', 'error', 'dead-code', 'unreachable statement'),
			record('src/B.hx', 'error', 'dead-code', 'unreachable statement')
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(2, result.severities.length);
		Assert.equals('error', result.severities[0].severity, 'error sorts before warning');
		Assert.equals(2, result.severities[0].added);
		Assert.equals(0, result.severities[0].removed);
		Assert.equals('warning', result.severities[1].severity);
		Assert.equals(1, result.severities[1].removed);
	}

	public function testRenderCapsExamplesAndNamesTheLabel(): Void {
		final before: String = reportOf([]);
		final after: String = reportOf([
			record('src/A.hx', 'warning', 'magic-number', 'magic number'),
			record('src/B.hx', 'warning', 'magic-number', 'magic number'),
			record('src/C.hx', 'warning', 'magic-number', 'magic number')
		]);
		final lines: Array<String> = LintDiff.render(diff(before, after, ''), 'tm', 2);
		Assert.stringContains('lint-diff tm:', lines[0]);
		Assert.stringContains('3 added / 0 removed', lines[0]);
		Assert.equals(5, lines.length, 'headline, severity breakdown, two examples and the elision note');
		Assert.stringContains('1 more added key(s)', lines[lines.length - 1]);
		final uncapped: Array<String> = LintDiff.render(diff(before, after, ''), 'tm', -1);
		Assert.equals(5, uncapped.length, 'a negative limit prints every example and no elision note');
		Assert.stringContains('src/C.hx', uncapped[uncapped.length - 1]);
	}

	public function testEscapedMessageTextSurvivesTheParse(): Void {
		final report: String = '[{"file": "src/A.hx", "line": 1, "col": 1, "severity": "info", "rule": "string-literal-dup",'
			+ ' "message": "string literal \'a\\\\nb\' repeated 3 times", "address": "FnMember:f"}]';
		final findings: Array<LintFindingJson> = LintDiff.parseReport(report);
		Assert.equals(1, findings.length);
		Assert.equals("string literal 'a\\nb' repeated 3 times", findings[0].message);
	}

	public function testParseReportRefusesADocumentThatIsNotAnArray(): Void {
		Assert.raises(LintDiff.parseReport.bind('{"findings": []}'));
	}

	private static function diff(before: String, after: String, root: String): LintDiffResult {
		return LintDiff.compare(LintDiff.tally(LintDiff.parseReport(before), root), LintDiff.tally(LintDiff.parseReport(after), root));
	}

	private static function record(file: String, severity: String, rule: String, message: String): String {
		return '{"file": "$file", "line": 12, "col": 3, "severity": "$severity", "rule": "$rule",'
			+ ' "message": "$message", "address": "FnMember:f"}';
	}

	private static function reportOf(records: Array<String>): String {
		return '[\n' + records.join(',\n') + '\n]';
	}

}
