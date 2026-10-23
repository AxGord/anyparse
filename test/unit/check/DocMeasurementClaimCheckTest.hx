package unit.check;

import anyparse.check.Check;
import anyparse.check.DocMeasurementClaim;
import anyparse.check.Severity;

using StringTools;

/**
 * The `doc-measurement-claim` check: a comment carrying a reading of a tree — a duration, a share
 * written with the percent sign, a commit hash, a slice or backlog id, a before-and-after pair, the
 * recording verb beside a number or opening a claim, or a claim about the state of this repository —
 * is flagged `Info`, and a comment stating a CONTRACT is not.
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
	 * MID-CLAUSE the recording verb needs a NUMBER on its line. A rule describing what it measures
	 * says so in ordinary English, and the verb alone cannot tell that sentence from the record of
	 * a run.
	 * Killed by arm `M-DOC-CLAIM-VERB-UNGATED`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-VERB-UNGATED')
	public function testTheRecordingVerbMidClauseNeedsANumberOnItsLine(): Void {
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
		final found: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(0, CheckFixture.fixOf(check, src, found).length);
		Assert.isTrue(check.noAutofixReason().indexOf('numbers') >= 0, check.noAutofixReason());
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('doc-measurement-claim');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'doc-measurement-claim is opt-in');
		Assert.equals(195, Linter.builtins().length);
	}

	/**
	 * A count written against its total is a census of one tree; a contract counts nothing out of
	 * anything, and a ratio spelled in words has no digits for the shape to read.
	 */
	public function testACountAgainstATotalIsAReading(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// 198 of 231 findings on one such tree\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('a count against a total'), vs[0].message);
		Assert.equals(0, violations('class C {\n\t/** One of the two branches always wins. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Reads the first of three segments. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * A share written with the percent sign is a reading; the same sign with a number on its RIGHT
	 * is the remainder operator, and prose about precedence writes both on one line, so no share
	 * is taken from a line that shows one.
	 * Killed by arm `M-DOC-CLAIM-PERCENT-REMAINDER-BLIND`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-PERCENT-REMAINDER-BLIND')
	public function testAPercentageShareIsAReadingAndTheRemainderOperatorIsNot(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// 71 % of the tree stays invisible\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('a percentage share in a comment'), vs[0].message);
		Assert.equals(0, violations('class C {\n\t/** Binds tighter: `2 * 7 % 4` is 6. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Left-assoc: `20 % (12 % 7)` is 0. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * The recording verb OPENING a clause records something. The same verb mid-clause is this
	 * project's own vocabulary for how a width or a region is obtained — the passive voice, the
	 * participle as an adjective, a prefix glued on with a hyphen — and states a contract.
	 * Killed by arm `M-DOC-CLAIM-CLAUSE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-CLAUSE-BLIND')
	public function testTheRecordingVerbOpeningAClauseIsAReading(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/** Measured on the fork: the walk stayed idempotent. */\n\tvar x = 1;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('a recording verb opening a claim'), vs[0].message);
		Assert.equals(1, violations('class C {\n\t/** The gate holds (measured on the fork). */\n\tvar x = 1;\n}').length);
		Assert.equals(
			0,
			violations('class C {\n\t/** The width is measured by the Doc, and the measured sibling keeps it. */\n\tvar x = 1;\n}').length
		);
		Assert.equals(0, violations('class C {\n\t/** A Doc-measured predicate, re-measured after the fix. */\n\tvar x = 1;\n}').length);
		Assert.equals(
			0, violations('class C {\n\t/** No re-\n\t * measurement of the surrounding context is required. */\n\tvar x = 1;\n}').length
		);
	}

	/**
	 * A chain of arrows is ONE reading: a progression records one observation, and a reading per
	 * arrow would make the block's own count say more than its prose does. The count travels in
	 * the message, so a long block says how much of it is being asked for.
	 */
	public function testAnArrowChainIsOneReadingAndTheCountTravels(): Void {
		final chain: Array<Violation> = violations('class C {\n\t// the indent went 0 -> 2 -> 4 -> 6 columns\n}');
		Assert.equals(1, chain.length);
		Assert.isTrue(chain[0].message.contains('(1 reading)'), chain[0].message);
		final pair: Array<Violation> = violations('class C {\n\t// rebuilt at deadbee1, and the walk took 44 ms\n}');
		Assert.equals(1, pair.length);
		Assert.isTrue(pair[0].message.contains('(2 readings)'), pair[0].message);
	}

	/**
	 * A count before a noun only a run over a tree counts is a census, whether the count is in digits,
	 * in words, or behind one modifier; the same count before a DIMENSION a contract bounds is the
	 * contract itself, and the noun is what tells the two apart.
	 * Killed by arm `M-DOC-CLAIM-CENSUS-NOUN-ANY`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-CENSUS-NOUN-ANY')
	public function testACensusCountIsAReadingAndADimensionIsNot(): Void {
		final vs: Array<Violation> = violations('class C {\n\t// the walk reported 2624 files\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('a census count in a comment'), vs[0].message);
		Assert.equals(1, violations('class C {\n\t// 142 correct blocks remain\n}').length);
		Assert.equals(1, violations('class C {\n\t// the rule left 1041 would-be findings\n}').length);
		Assert.equals(1, violations('class C {\n\t// eleven rules fired, and Seventy-odd rules did not\n}').length);
		Assert.equals(1, violations('class C {\n\t/** Fifty-eight fires across all four members. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Past 40 lines a doc block is too long. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** A type with more than 50 members is reported. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * A count below two digits is the size of a fixture or a contract's own small quantity, and is
	 * never read as a census; a comma before a group of thousands keeps a large one large.
	 * Killed by arm `M-DOC-CLAIM-CENSUS-FLOOR`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-CENSUS-FLOOR')
	public function testASmallCountIsTheSizeOfAFixture(): Void {
		Assert.equals(0, violations('class C {\n\t/** Writes 3 files into a scratch directory. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Since Haxe 4.2 abstract modules are allowed. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** Writes 30 files into a scratch directory. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t// 1,754 sources were read\n}').length);
	}

	/**
	 * A count fenced as inline code is quoted data — a tool's output, a fixture's line — and a count
	 * hyphen-joined to a word is part of a name; neither is prose recording a census.
	 * Killed by arm `M-DOC-CLAIM-CENSUS-CODESPAN`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-CENSUS-CODESPAN')
	public function testACountQuotedAsCodeIsData(): Void {
		Assert.equals(0, violations('class C {\n\t/** The runner prints `999 tests` at exit. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** The runner printed 999 tests at exit. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** The post-Slice-34 sources parse. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** The runner prints 999 Assertions at exit. */\n\tvar x = 1;\n}').length);
	}

	/** A number typeset with grouped thousands is a census on its own: a contract writes its constant as code does. */
	public function testATypesetNumberIsACensus(): Void {
		Assert.equals(1, violations('class C {\n\t// the suite ran 13 251 of its fixtures\n}').length);
		Assert.equals(1, violations('class C {\n\t// a census of 1 754 sources\n}').length);
	}

	/**
	 * A short slice or backlog id is an id in prose; written as code — in backticks, or straight after
	 * the `:`, `<` or `.` a type position opens with — it is a type parameter's name. A single digit is
	 * never read: it names a type parameter far more often than a slice.
	 * Killed by arm `M-DOC-CLAIM-SHORT-ID-TYPE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-SHORT-ID-TYPE-BLIND')
	public function testAShortWorkIdIsFlaggedAndATypeParameterIsNot(): Void {
		Assert.equals(1, violations('class C {\n\t// the shape S56 asked for\n}').length);
		Assert.equals(1, violations('class C {\n\t// retired by T37\n}').length);
		final sub: Array<Violation> = violations('class C {\n\t// the shape S10.4 asked for\n}');
		Assert.equals(1, sub.length);
		Assert.isTrue(sub[0].message.contains('S10.4'), sub[0].message);
		Assert.equals(0, violations('class C {\n\t/** Takes a `T12` and returns it. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Matches `OrState.A(v:T12)` only. */\n\tvar x = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\t/** Returns Array<T12> unchanged. */\n\tvar x = 1;\n}').length);
	}

	/**
	 * Mid-clause, the recording verb needs a number in the PROSE beside it: digits inside backticks are
	 * code the sentence quotes, and quoting a sample is not recording a run.
	 * Killed by arm `M-DOC-CLAIM-VERB-ANY-DIGIT`.
	 */
	@:pin('control')
	@:killer('M-DOC-CLAIM-VERB-ANY-DIGIT')
	public function testTheRecordingVerbBesideQuotedCodeIsNotARecord(): Void {
		Assert.equals(0, violations('class C {\n\t/** As measured, `var x = 1;` is typed `Int`. */\n\tvar x = 1;\n}').length);
		Assert.equals(1, violations('class C {\n\t/** The walk measured 271 runs. */\n\tvar x = 1;\n}').length);
	}

	/** The check's findings on `src`, asked of the check directly so enablement does not apply. */
	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new DocMeasurementClaim(), src);
	}

}
