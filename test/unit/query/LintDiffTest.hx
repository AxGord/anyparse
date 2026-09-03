package unit.query;

import anyparse.check.Linter;
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
 * arm is non-empty is what makes the normalized arm mean something. One case is
 * deliberately not a pair and says so in place: an over-reach guard for --root.
 *
 * The message normalization is NOT configured here — it is asked of the check registry
 * (`Linter.messageIdentities`), so these cases exercise the REAL declarations the builtins
 * make about their own messages. A fixture must therefore spell a message the way its check
 * writes it; the helpers at the bottom do that, and the pin that they still MATCH lives in
 * each check test, which feeds `messageIdentity` a message the check itself produced.
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
		final before: String = reportOf([record('./src/A.hx', 'info', 'duplicate-code', crossDup(4, './src/B.hx', 501))]);
		final after: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 501))]);
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
		final before: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 501))]);
		final after: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 612))]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'a partner-block line shift is not a finding');
		Assert.equals(0, result.removedTotal);
	}

	public function testDuplicateCodeSameFileLineShiftIsMaskedAway(): Void {
		// The same-file message spells the original as `from line N` rather than
		// `<path>:N`, so it needs its own anchor — and its own case, since a mask
		// written for one shape is a silent no-op on the other.
		final before: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', sameDup(4, 226))]);
		final after: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', sameDup(4, 241))]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'an original-block line shift is not a finding');
		Assert.equals(0, result.removedTotal);
		final grown: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', sameDup(7, 226))]);
		Assert.equals(1, diff(before, grown, '').addedTotal, 'while the statement COUNT still moves the key');
	}

	public function testDuplicateCodeIsNotDroppedFromTheReport(): Void {
		// The rule is masked, never excluded — a new duplicate against a NEW
		// partner file is still a finding. This does not exercise the mask itself
		// (the added key differs in `file`, so it survives either way); it pins
		// that nobody "fixes" the line-shift noise by dropping the rule.
		final before: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 501))]);
		final after: String = reportOf([
			record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 501)),
			record('src/C.hx', 'info', 'duplicate-code', crossDup(9, 'src/D.hx', 12))
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'duplicate-code findings still reach the diff');
		Assert.equals(0, result.removedTotal);
	}

	public function testDuplicateCodeSubstitutionWithinOneFileIsReported(): Void {
		// This case READ 0/0 until the mask became anchored. `lint-diff` used to blank every
		// digit run in a duplicate-code message, which ate the statement count and any digit in
		// the partner filename as well as the line — 57% (anyparse) and 78% (tm) of that rule's
		// findings sat in a key shared with a sibling, and swapping one for the other was
		// invisible to the gate. Anchoring the mask on the message's own tail leaves the count
		// and the path in the key, which is what makes this pair move.
		final before: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(3, 'src/B.hx', 110))]);
		final after: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(7, 'src/B.hx', 134))]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'a different duplicate against the same partner is a different finding');
		Assert.equals(1, result.removedTotal);
		final sameCount: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(3, 'src/B.hx', 134))]);
		Assert.equals(0, diff(before, sameCount, '').addedTotal, 'and the line alone still moves nothing');
	}

	/**
	 * `unused-local` names the re-declaration that took a binding over, so its message carries a
	 * POSITION exactly as `duplicate-code`'s does. Without the mask an unrelated edit ABOVE such a
	 * finding reports it as 1 removed + 1 added — and a disappearing finding is the direction the
	 * blast-radius gate exists to catch, so the whole gate would read as a regression on every run
	 * that shifted a line.
	 */
	public function testUnusedLocalRedeclarationPositionIsMaskedAway(): Void {
		final before: String = reportOf([record('src/A.hx', 'warning', 'unused-local', redeclared('a', 5, 3))]);
		final after: String = reportOf([record('src/A.hx', 'warning', 'unused-local', redeclared('a', 8, 3))]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'an edit above the finding must not report it as new');
		Assert.equals(0, result.removedTotal, 'nor as removed - a disappearing finding is what the gate is for');
		final renamed: String = reportOf([record('src/A.hx', 'warning', 'unused-local', redeclared('a2', 5, 3))]);
		Assert.equals(1, diff(before, renamed, '').addedTotal, 'while the local NAME is not a coordinate - v1 and v2 are two findings');
	}

	/**
	 * The case this seam was built for: a type's LINE EXTENT drifts under any edit to the
	 * file, so the gate reported movement on a writer slice whose findings had not moved
	 * (`WrapList` 4184 -> 4194, and three more, against a total of 2256 versus a base of
	 *  2256). Since S15 the MEMBER count is masked as well, so both arms here read 0/0; the
	 *  arm pinning the difference between a masked measurement and a kept one lives on
	 *  `duplicate-code`, whose count is the last discriminator its key has.
	 */
	public function testOversizedTypeLineExtentAndMemberCountAreBothMasked(): Void {
		final before: String = reportOf([
			record('src/W.hx', 'warning', 'oversized-type', oversized('WrapList', '108 members (max 50) and 4184 lines (max 2000)'))
		]);
		final reflowed: String = reportOf([
			record('src/W.hx', 'warning', 'oversized-type', oversized('WrapList', '108 members (max 50) and 4194 lines (max 2000)'))
		]);
		final reflow: LintDiffResult = diff(before, reflowed, '');
		Assert.equals(0, reflow.addedTotal, 'a line-extent drift is not a finding');
		Assert.equals(0, reflow.removedTotal);
		final grown: String = reportOf([
			record('src/W.hx', 'warning', 'oversized-type', oversized('WrapList', '109 members (max 50) and 4184 lines (max 2000)'))
		]);
		final growth: LintDiffResult = diff(before, grown, '');
		// The member count LEAVES the key too, since S15. It used to stay, on the argument that
		// crossing the limit is the finding — but crossing it is what makes the finding APPEAR,
		// which the key shows on its own, while the count then drifts on every unrelated member
		// added anywhere in the type. Measured across the campaign's last three blast-radius
		// verdicts, that drift produced two of the six lines reported and none was real
		// movement. The type NAME stays in the message, so nothing else here discriminates by
		// the number — unlike `duplicate-code`, whose count is kept for exactly that reason.
		Assert.equals(0, growth.addedTotal, 'a member count drift is not a finding either');
		Assert.equals(0, growth.removedTotal);
	}

	public function testOversizedTypeCrossingTheLineThresholdIsReported(): Void {
		// The half a mask could silently swallow: a type already over on members that grows
		// past the LINE limit gains a whole clause, and no amount of digit masking turns the
		// longer message back into the shorter one. Same for a type that had no finding at
		// all — it simply appears.
		final overMembers: String = reportOf([
			record('src/W.hx', 'warning', 'oversized-type', oversized('WrapList', '108 members (max 50)'))
		]);
		final overBoth: String = reportOf([
			record('src/W.hx', 'warning', 'oversized-type', oversized('WrapList', '108 members (max 50) and 2001 lines (max 2000)'))
		]);
		final crossed: LintDiffResult = diff(overMembers, overBoth, '');
		Assert.equals(1, crossed.addedTotal, 'crossing the line threshold is still reported');
		Assert.equals(1, crossed.removedTotal);
		Assert.equals(1, diff(reportOf([]), overBoth, '').addedTotal, 'and a type that was quiet before simply appears');
	}

	public function testTheIdentityMapIsAskedOfTheRegistryNotOfAList(): Void {
		// The seam, not the masking: `lint-diff` holds no rule ids at all, so a rule joins by
		// declaring `VolatileMessage` on itself. Assert both directions — the three declaring
		// rules are in the map, and a rule that quotes digits which ARE the finding is not.
		final identities: LintMessageIdentities = Linter.messageIdentities();
		final declaring: Array<String> = [
			'duplicate-code',
			'unused-local',
			'oversized-type',
			'complexity',
			'string-literal-dup',
			'anon-type-dup',
			'extract-repeated-expression'
		];
		for (rule in declaring) Assert.notNull(identities[rule], 'a declaring check must reach lint-diff through the registry');
		// Two rules stay OUT of the map, for the two different reasons the contract names.
		// `magic-number` quotes the literal VALUE it found, which is the finding itself and not
		// a measurement of it — nothing to mask. `fragmented-doc-comment` DOES quote a
		// measurement, but its message carries no name and no position, so that tally is the
		// only thing telling two fragmented declarations in one file apart.
		for (rule in ['magic-number', 'fragmented-doc-comment'])
			Assert.isNull(identities[rule], 'a rule whose number must survive the key is not in the map');
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

	public function testMaskingIsScopedToDeclaringRules(): Void {
		final before: String = reportOf([record('src/A.hx', 'warning', 'complexity', 'cyclomatic complexity 21 (max 20)')]);
		final after: String = reportOf([record('src/A.hx', 'warning', 'complexity', 'cyclomatic complexity 34 (max 20)')]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(1, result.addedTotal, 'digits carry meaning in every other rule');
		Assert.equals(1, result.removedTotal);
	}

	public function testRootAlsoStripsThePartnerPathInsideADuplicateCodeMessage(): Void {
		final before: String = reportOf([
			record('/repo/src/A.hx', 'info', 'duplicate-code', crossDup(4, '/repo/src/B.hx', 501))
		]);
		final after: String = reportOf([record('src/A.hx', 'info', 'duplicate-code', crossDup(4, 'src/B.hx', 612))]);
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

	public function testOversizedTypeMemberBumpIsMaskedAway(): Void {
		// The movement the S15 mask absorbs, in the shape that actually reached the campaign's
		// verdicts: `type 'Cli' has 518 -> 519 members`, printed as one added plus one removed
		// on two consecutive slices that had not touched the rule at all.
		final before: String = reportOf([
			record('src/C.hx', 'warning', 'oversized-type', oversized('Cli', '518 members (max 50)'))
		]);
		final after: String = reportOf([
			record('src/C.hx', 'warning', 'oversized-type', oversized('Cli', '519 members (max 50)'))
		]);
		final result: LintDiffResult = diff(before, after, '');
		Assert.equals(0, result.addedTotal, 'a member the type gained is not a NEW finding');
		Assert.equals(0, result.removedTotal);
	}

	private static function diff(before: String, after: String, root: String): LintDiffResult {
		final identities: LintMessageIdentities = Linter.messageIdentities();
		return LintDiff.compare(
			LintDiff.tally(LintDiff.parseReport(before), root, identities), LintDiff.tally(LintDiff.parseReport(after), root, identities)
		);
	}

	private static function record(file: String, severity: String, rule: String, message: String): String {
		return '{"file": "$file", "line": 12, "col": 3, "severity": "$severity", "rule": "$rule",'
			+ ' "message": "$message", "address": "FnMember:f"}';
	}

	private static function reportOf(records: Array<String>): String {
		return '[\n' + records.join(',\n') + '\n]';
	}

	/**
	 * The CROSS-FILE `duplicate-code` message, spelled exactly as `DuplicateCode` writes it —
	 * em dash and full tail included, because the mask is anchored on that tail and a
	 * paraphrased fixture would silently exercise nothing.
	 *
	 * The pin that the wording here still MATCHES the check lives in
	 * `DuplicateCodeCrossFileCheckTest`, which feeds a message the check itself produced
	 * through `messageIdentity`; this helper only keeps the plumbing cases realistic.
	 */
	private static function crossDup(count: Int, partner: String, line: Int): String {
		return '$count statements duplicated from $partner:$line — extract a shared helper (report-only, cross-file)';
	}

	/** The SAME-FILE `duplicate-code` message, spelled as `DuplicateCode` writes it. */
	private static function sameDup(count: Int, line: Int): String {
		return '$count statements duplicated from line $line — extract a helper (hxq extract-method)';
	}

	/** The `unused-local` message with its re-declaration note, spelled as `UnusedLocal` writes it. */
	private static function redeclared(name: String, line: Int, col: Int): String {
		return 'unused local \'$name\' — re-declared at $line:$col, and every read past that belongs to the second binding';
	}

	/** The `oversized-type` message, spelled as `OversizedType` writes it. */
	private static function oversized(name: String, over: String): String {
		return 'type \'$name\' has $over — a decomposition candidate (see hxq clusters)';
	}

}
