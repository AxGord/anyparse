package unit.check;

import anyparse.check.Check;
import anyparse.check.DocMeasurementClaim;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `doc-measurement-claim` check: a comment carrying a reading of a tree — a duration, a
 * commit hash, a slice or backlog id, a before-and-after pair, the recording verb beside a
 * number, or a claim about the state of this repository — is flagged `Info`, and a comment
 * stating a CONTRACT is not.
 *
 * Every fixture keeps its markers inside a Haxe source STRING, which is also what one of the
 * fixtures asserts about the seam, so this file stands clean under the rule it exercises.
 */
class DocMeasurementClaimCheckTest extends Test {

	public function testADurationIsFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// the walk took 3,21 s\n}');
		Assert.equals(1, vs.length);
		Assert.equals('doc-measurement-claim', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.startsWith('a duration in a comment'), vs[0].message);
	}

	public function testACommitHashIsFlaggedAndAPlainTokenIsNot(): Void {
		Assert.equals(1, violations('class C {\n\t// rebuilt at a3588740\n}').length);
		Assert.equals(0, violations('class C {\n\t// the offset 14556000 is stable\n}').length);
		Assert.equals(0, violations('class C {\n\t// the deadbeef sentinel\n}').length);
	}

	public function testAWorkIdIsFlaggedAndAShortOneIsNot(): Void {
		Assert.equals(1, violations('class C {\n\t// the shape S208 asked for\n}').length);
		Assert.equals(1, violations('class C {\n\t// the shape T1008 asked for\n}').length);
		Assert.equals(0, violations('class C {\n\t// the S3 bucket name\n}').length);
	}

	public function testAScopeClaimIsFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// the only such shape on this tree\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('a claim about the state of this repository'), vs[0].message);
	}

	public function testADocBlockIsReadLikeALineComment(): Void {
		Assert.equals(1, violations('class C {\n\t/** Rebuilt at a3588740. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/* Rebuilt at a3588740. */\n\tvar x = 1;\n}').length);
	}

	public function testOneCommentYieldsOneFinding(): Void {
		final src: String =
			'class C {\n\t/**\n\t * Rebuilt at a3588740, and again at b4711aa9.\n\t * The walk took 44 ms.\n\t */\n\tvar x = 1;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testTheMessageCarriesTheOffendingWords(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// rebuilt at a3588740\n}');
		Assert.isTrue(vs[0].message.contains('a3588740'), vs[0].message);
		Assert.isTrue(vs[0].message.contains('commit message'), vs[0].message);
	}

	/**
	 * A NUMBER is not a reading. A doc naming the code's own constant — a minimum, a maximum, a
	 * floor — states a contract, and the shape set is built so that nothing there matches: the
	 * UNIT beside the number is what makes a duration one. A fixture's own claim about its base
	 * commit is the same case one step over, and needs no exception in the code because it
	 * carries no unit, no id and no hash. Asserted beside the duration that IS a finding, so a
	 * rule that had stopped reading numbers at all would fail the pair.
	 * Killed by arm `M-DOC-CLAIM-BARE-NUMBER`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-BARE-NUMBER')
	public function testANumericContractIsNotAReading(): Void {
		Assert.equals(0, violations('class C {\n\t/** At least 3 statements, and never past 20. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** RED at base, green after the fix. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** The walk took 44 ms. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * An arrow needs DIGITS on both sides. Prose about code is full of arrows that are not a
	 * before and an after — a function type, a lambda, a map entry — and a rule reading those as
	 * readings would report a doc for describing the language it documents.
	 * Killed by arm `M-DOC-CLAIM-ARROW-ANY`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-ARROW-ANY')
	public function testAnArrowNeedsNumbersOnBothSides(): Void {
		Assert.equals(0, violations('class C {\n\t/** The callback is v -> field = v. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** It takes a (String) -> Int. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** The count went 9 -> 19. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * The recording verb needs a NUMBER on its line. A rule describing what it measures says so
	 * in ordinary English, and the verb alone cannot tell that sentence from the record of a run.
	 * Killed by arm `M-DOC-CLAIM-VERB-UNGATED`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-VERB-UNGATED')
	public function testTheRecordingVerbNeedsANumberOnItsLine(): Void {
		Assert.equals(0, violations('class C {\n\t/** The line is measured whole, tabs included. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** Measured on the fork: 8 files lost their nodes. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * A POINTER at the record is not the record. A path, a URL and a doc-tag line all name where
	 * the numbers live, which is exactly what this rule asks prose to leave behind — flagging one
	 * would contradict the advice in its own message. Asserted beside the same id standing in
	 * prose, which IS a finding.
	 * Killed by arm `M-DOC-CLAIM-REFERENCE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-REFERENCE-BLIND')
	public function testAPointerAtTheRecordIsNotTheRecord(): Void {
		Assert.equals(0, violations('class C {\n\t/** The recipe is in docs/backlog/T928.md. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/**\n\t * @see T928\n\t */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** The shape T928 asked about is gone. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * The seam is the comment scan, so a hash or a duration inside a STRING literal is data — a
	 * fixture, a message, a sample value — and never prose. A `guard` rather than a discriminating
	 * fixture: no member of this check decides it, the lexical scan hands over comments only.
	 */
	@:pin('guard')
	public function testAReadingInsideAStringLiteralIsData(): Void {
		Assert.equals(0, violations('class C {\n\tvar sha = "a3588740";\n\tvar took = "3,21 s";\n}').length);
	}

	public function testFixReturnsEmptyAndTheReasonSaysWhy(): Void {
		final check: DocMeasurementClaim = new DocMeasurementClaim();
		final src: String = 'class C {\n\t// rebuilt at a3588740\n}';
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, found, new HaxeQueryPlugin()).length);
		Assert.isTrue(check.noAutofixReason().indexOf('numbers') >= 0, check.noAutofixReason());
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('doc-measurement-claim');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'doc-measurement-claim is opt-in');
		Assert.equals(182, Linter.builtins().length);
	}

	/** The check's findings on `src`, asked of the check directly so enablement does not apply. */
	private function violations(src: String): Array<Violation> {
		return new DocMeasurementClaim().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
