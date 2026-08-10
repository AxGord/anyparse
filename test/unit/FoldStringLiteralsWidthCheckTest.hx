package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The WIDTH side of `fold-adjacent-string-literals`: which segmentation the line
 * width asks for, and how a chain is re-cut to reach it.
 *
 * An over-long literal SPLITS back out at its seams — a `${ … }` interpolation or an
 * embedded `\n` escape — while an escaped backslash is not a seam and a seam past
 * the limit still splits best-effort. A chain whose operand count would not change
 * is re-cut only when a line is over-long; trailing comments count toward the
 * measured width and survive the fold; a construct the writer cannot wrap is
 * repriced at its own column, and an irreducible over-wide segment does not drag
 * the lines that already fit into a re-segmentation.
 */
class FoldStringLiteralsWidthCheckTest extends FoldStringLiteralsCheckTestBase {

	/**
	 * `140` / tab `4` — the values in the repository's OWN `hxformat.json`, which is
	 * what `FormatConfigDiscovery` resolves for the `C.hx` path these fixtures use
	 * (the suite runs from the repository root). Spelled out here so the boundary
	 * fixtures below read as arithmetic rather than as magic.
	 */
	private static inline final LINE_WIDTH: Int = 140;

	/** The tab width in that same config — what a tab counts as when a fixture measures a rendered line. */
	private static inline final TAB_WIDTH: Int = 4;

	/** Columns of indent the width fixtures put their statement at (two tabs). */
	private static inline final FIXTURE_INDENT: Int = 8;

	/** Columns between the fixture indent and the chain: the `g(` call head. */
	private static inline final CALL_HEAD: Int = 2;

	/** The planner's own budget for a `widthSource` fixture: line width less the start column and the `+ ` glue. */
	private static inline final FIXTURE_BUDGET: Int = LINE_WIDTH - FIXTURE_INDENT - CALL_HEAD - 2;

	/** A merge whose rendered line lands EXACTLY on `maxLineLength` is accepted (the fits-probe boundary). */
	public function testWidthBoundaryAtLimitMerges(): Void {
		final vs: Array<Violation> = violations(widthSource(FIXTURE_BUDGET));
		Assert.equals(1, vs.length);
		Assert.equals(FIXTURE_BUDGET, foldOf(widthSource(FIXTURE_BUDGET)).length);
	}

	/** One column inside the limit merges too. */
	public function testWidthBoundaryBelowLimitMerges(): Void {
		Assert.equals(1, violations(widthSource(FIXTURE_BUDGET - 1)).length);
	}

	/**
	 * One column past the limit does NOT merge — the pair stays two operands. The
	 * at-limit case is asserted alongside so the fixture discriminates: a rule that
	 * ignored width would flag both.
	 */
	public function testWidthBoundaryAboveLimitNotMerged(): Void {
		Assert.equals(0, violations(widthSource(FIXTURE_BUDGET + 1)).length);
		Assert.equals(1, violations(widthSource(FIXTURE_BUDGET)).length);
	}

	/**
	 * A literal whose line already fits is never re-cut, however many `${ … }`
	 * seams it has; the same literal on an over-long line is. Both halves are
	 * asserted together so the fixture pins the gate rather than the absence of a
	 * split arm.
	 */
	public function testLiteralSplitOnlyWhenOverLong(): Void {
		final seams: String = "${a.b()}y${c.d()}";
		Assert.equals(0, violations('class C { function f() { g(\'x${seams}z\'); } }').length);
		Assert.equals(1, violations('class C {\n\tfunction f() {\n\t\tg(\'${''.rpad('x', 130)}$seams\');\n\t}\n}').length);
	}

	/** An over-long literal is cut at a `${ … }` seam until the lines fit. */
	public function testOverLongLiteralSplitAtSeam(): Void {
		final head: String = ''.rpad('h', 100);
		final tail: String = ''.rpad('t', 60);
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(\'$head$${a.b()}$tail\');\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('\'$head$${a.b()}\' + \'$tail\'', foldOf(src));
	}

	/**
	 * The numeric-head trap read in the SPLIT direction: two leading expression
	 * segments may never become two bare operands (`1 + 2 + ' items'` is
	 * `"3 items"`), so the planner merges across that seam even though neither
	 * segment fits the budget on its own.
	 */
	public function testSplitNeverEmitsTwoLeadingBareOperands(): Void {
		final one: String = ''.rpad('n', 130);
		final two: String = ''.rpad('m', 130);
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(\'$${$one}$${$two} items\');\n\t}\n}';
		Assert.equals('\'$$$one$$$two\' + \' items\'', foldOf(src));
	}

	/** MERGE fixture, shaped after a real query builder: a literal / ternary / literal / call / literal chain at three tabs. */
	public function testMergeQueryChainFixture(): Void {
		final src: String = [
			'class C {',
			'\tpublic function getEntry(grouped:Bool, keyId:Int, batch:Bool = false):Null<String> {',
			'\t\treturn runPathRequest(',
			"\t\t\t'SELECT rowpath FROM records WHERE grouped = ' + (grouped ? '1 AND group_key_id = $keyId' : '0 AND key_id = $keyId')",
			"\t\t\t+ ' AND status = ' + _linkChannel.quote(statusLabelOfRecord(STATUS_REMOTE_UPDATED_LOCAL_SYNCED_FETCHED)) + ' LIMIT 1',",
			"\t\t\tbatch, 'getEntry'",
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
		Assert.equals(
			"'SELECT rowpath FROM records WHERE grouped = ' + (grouped ? '1 AND group_key_id = $keyId' : '0 AND key_id = $keyId')"
			+ " + ' AND status = ${_linkChannel.quote(statusLabelOfRecord(STATUS_REMOTE_UPDATED_LOCAL_SYNCED_FETCHED))} LIMIT 1'",
			foldOf(src)
		);
	}

	/** SPLIT fixture: ONE over-long interpolated literal, cut at the seam between its two `${ … }` blocks. */
	public function testSplitQueryLiteralFixture(): Void {
		final src: String = [
			'class C {',
			'\tpublic function getMovedEntry(grouped:Bool, rowPath:String, batch:Bool = false):Null<String> {',
			'\t\treturn runPathRequest(',
			"\t\t\t'SELECT rowpath FROM records WHERE grouped = ${(grouped ? '1 AND rowpath_movedfromroot = ' :"
				+ " '0 AND rowpath_movedfromroot = ')}${_linkChannel.quote(rowPath)}',",
			"\t\t\tbatch, 'getMovedEntry'",
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
		Assert.equals(
			"'SELECT rowpath FROM records WHERE grouped = '"
			+ " + '${(grouped ? '1 AND rowpath_movedfromroot = ' : '0 AND rowpath_movedfromroot = ')}${_linkChannel.quote(rowPath)}'",
			foldOf(src)
		);
	}

	/** MERGE fixture 3: the over-wide header literal keeps a segment of its own; the rest packs into as few as fit. */
	public function testMultiLineLiteralChainFixture(): Void {
		final src: String = [
			'class C {',
			'\tfunction f() {',
			'\t\tlink.request(',
			"\t\t\t'INSERT OR IGNORE INTO records (rowpath, grouped, key_id, group_key_id, status, stamp, rowpath_movedfrom,"
				+ " rowpath_movedfromroot) VALUES ('",
			"\t\t\t+ '${link.quote(r.newRowpath)}, ' + '${r.grouped}, ' + '${r.key_id}, ' + '${r.group_key_id}, '",
			"\t\t\t+ '${link.quote(Std.string(r.status))}, ' + '${r.stamp}, ' + '$movedFromSql, ' + '$movedFromRootSql'",
			"\t\t\t+ ')'",
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
		final folded: String = foldOf(src);
		Assert.isTrue(folded.startsWith("'INSERT OR IGNORE INTO records (rowpath, grouped, key_id, group_key_id, status, stamp,"));
		Assert.isTrue(folded.contains("VALUES (' + '${link.quote(r.newRowpath)}, ${r.grouped}, "));
		Assert.isTrue(folded.endsWith("$movedFromRootSql)'"));
	}

	/**
	 * The equal-count RE-CUT direction, which no other fixture reaches: an OVER-LONG
	 * chain whose canonical segmentation keeps the source's operand COUNT and moves
	 * only the boundary between them.
	 */
	public function testEqualCountRecutOverLongFlagged(): Void {
		final vs: Array<Violation> = violations(recutSource(90));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('re-cut'));
	}

	/**
	 * The same chain with its second line INSIDE the limit is left alone: only a
	 * strict MERGE runs unconditionally, and an equal-count re-cut of an
	 * already-fitting construct would trade the author's phrasing for the greedy
	 * fill's. Which of `plan`'s two group-count gates refuses it is NOT pinned here:
	 * they guard the same shape at two stages, and either one alone still refuses
	 * this fixture. What it does pin, paired with `testEqualCountRecutOverLongFlagged`,
	 * is the over-long PRECONDITION both of them share.
	 */
	public function testEqualCountRecutWithinLimitNotFlagged(): Void {
		Assert.equals(0, violations(recutSource(60)).length);
	}

	/**
	 * A trailing comment on the construct's LAST LINE counts toward the width the
	 * planner verifies against. The fixture already fits at 113 columns; a
	 * measurement that reads the member's SPAN instead of the LINES it occupies
	 * cannot see the comment's 40 columns, so the merged single-literal plan
	 * measures 138 — apparently inside the limit — and the file lands at 178.
	 */
	public function testTrailingCommentCountsTowardMeasuredWidth(): Void {
		final src: String = trailingCommentSource();
		Assert.equals(113, widestLine(src));
		Assert.equals(113, widestAfterFix(src));
	}

	/**
	 * A `//` comment on the LAST line of the sub-chain the rule claims must survive the
	 * fold. The veto reads the OPERAND spans, but the fix replaces the chain NODE's span,
	 * which absorbs the trailing comment and the line break as trivia — so a merge that
	 * fits the line width deleted the author's comment silently.
	 */
	public function testTrailingCommentInChainSurvivesFold(): Void {
		Assert.isTrue(fixedText(trailingCommentInChainSource()).indexOf('// one') != -1);
	}

	/**
	 * The shape this rule grew the run model for: every LINE of a wrapped chain ends in a
	 * comment, and each line holds a pair of adjacent literals. The pairs merge, the comments
	 * stay — the merged literal and the comment that follows it are asserted as ONE string, so
	 * neither half can pass on its own (an unchanged input satisfies each separately).
	 */
	public function testPerLinePairsMergeAroundComments(): Void {
		final fixed: String = fixedText(perLineCommentSource());
		Assert.isTrue(fixed.indexOf("'<f i=\"1\"/><f i=\"2\"/>' // second") != -1);
		Assert.isTrue(fixed.indexOf("'<f i=\"3\"/><f i=\"4\"/>' // third") != -1);
		Assert.isTrue(fixed.indexOf('// first') != -1);
	}

	/** The run partition is reproduced from the rule's OWN output, so a second pass changes nothing. */
	public function testPerLineFoldIsIdempotent(): Void {
		assertFixIsIdempotent(perLineCommentSource());
	}


	/**
	 * An over-long literal with NO interpolation at all splits at its embedded `\n`
	 * escape, which stays with the LEFT fragment — the seam that makes a lone string
	 * token layout-fixable at all. Before this, such a literal had one segment and
	 * could only ever plan back to itself.
	 */
	public function testSplitsAtNewlineEscape(): Void {
		Assert.equals(1, violations(newlineSource("'", 100, 60)).length);
		Assert.equals('\'${''.rpad('A', 100)}\\n\' + \'${''.rpad('B', 60)}\'', foldOf(newlineSource("'", 100, 60)));
	}

	/** A DOUBLE-quoted literal interpolates nothing, so every `\n` in it is a seam — and the split stays double-quoted. */
	public function testSplitsDoubleQuotedAtNewlineEscape(): Void {
		Assert.equals('"${''.rpad('A', 100)}\\n" + "${''.rpad('B', 60)}"', foldOf(newlineSource('"', 100, 60)));
	}

	/** The split's own output re-decomposes to the same segment list, so re-linting it finds nothing. */
	public function testNewlineSplitIsIdempotent(): Void {
		assertFixIsIdempotent(newlineSource("'", 100, 60));
	}

	/** A literal whose line already fits is left with the author's own phrasing, `\n` or not. */
	public function testShortLiteralWithNewlineNotSplit(): Void {
		Assert.equals(0, violations(newlineSource("'", 20, 20)).length);
	}

	/** `\\n` is an escaped BACKSLASH followed by an `n`, not a line break — no seam, so the literal is not a candidate. */
	public function testEscapedBackslashIsNotASeam(): Void {
		Assert.equals(0, violations(rawSource('\'${''.rpad('A', 100)}\\\\n${''.rpad('B', 60)}\'')).length);
	}

	/**
	 * A seam PAST the limit still splits — BEST EFFORT, the same answer the rule already
	 * gives for a `${ … }` seam past the limit (`testLiteralSplitOnlyWhenOverLong`,
	 * `testSplitNeverEmitsTwoLeadingBareOperands`, both of which leave their first
	 * fragment over-long). The "does it help" gate is the shipped one — the result must
	 * be strictly NARROWER than the source it replaces — and requiring the first fragment
	 * to come UNDER the limit instead would regress both of those fixtures, since an
	 * unsplittable leading run is the same shape whether it holds no `\n` or no `${ … }`.
	 */
	public function testSeamPastLimitStillSplitsBestEffort(): Void {
		Assert.equals(1, violations(newlineSource("'", 150, 20)).length);
		Assert.equals('\'${''.rpad('A', 150)}\\n\' + \'${''.rpad('B', 20)}\'', foldOf(newlineSource("'", 150, 20)));
	}

	/**
	 * Gate (4): a `\n` inside a `${ … }` block belongs to an EXPRESSION segment, never
	 * to a text one, so it is not a seam — the nested literal comes through the split
	 * intact.
	 */
	public function testNewlineInsideInterpolationBlockIsNotASeam(): Void {
		final src: String = rawSource('\'${''.rpad('A', 100)}$${g("p\\nq")}${''.rpad('B', 60)}\'');
		Assert.isTrue(foldOf(src).indexOf('"p\\nq"') != -1);
	}

	/**
	 * `unwrapped`'s own fixture. An object-literal entry whose value is an over-long
	 * literal: the greedy fill prices it at the CONTINUATION column, which says it fits,
	 * so the plan reproduces the source's boundaries and nothing is ever measured — while
	 * the source line runs past the limit, because the writer never moved the construct.
	 * Without the own-column retry this reports nothing at all.
	 */
	public function testConstructTheWriterCannotWrapIsRepricedAtItsOwnColumn(): Void {
		final src: String = objectFieldSource(60, 40);
		Assert.equals(1, violations(src).length);
		Assert.equals('\'${''.rpad('A', 60)}\\n\' + \'${''.rpad('B', 40)}\'', foldOf(src));
	}

	/**
	 * Fixpoint guard, refusal side. The merged `while` head FITS the line width; only
	 * the untouchable reification segment exceeds it. The old gate compared candidates
	 * against the REGION's max width — vacuously permissive under that segment — so the
	 * planner proposed a split of the already-fitting head, and from the split state the
	 * merge back: `--fix` ping-ponged to the pass cap with a byte-identical file. A
	 * split is licensed by the lines it TOUCHES being over-wide, so this plans NOTHING.
	 *
	 * Measured geometry (tab 4): head 139, reification line 142, limit 140 — the
	 * one-column margin is DELIBERATE (140 vs 141 flips this into the progress
	 * fixture's shape). The reification line alone must stay finding-free too: its
	 * single `\n` is terminal, so there is no seam and nothing to plan — if the seam
	 * model ever changes, this guard keeps the fixture honest.
	 */
	public function testIrreducibleOverwideSegmentNoResegmentOfFittingLines(): Void {
		final head: String =
			"\t\tfinal expected: String = 'class C {\\n\\tfunction test() {\\n\\t\\tfinal resultList = [\\n\\t\\t\\twhile (iteratorValue.hasNextElement())\\n'";
		Assert.equals(0, violations(cycleFixture(head)).length);
		final reificationAlone: String = 'class C {\n\tfunction f() {\n'
			+ "\t\tfinal expected: String = \"\\t\\t\\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\\n\";\n"
			+ '\t}\n}';
		Assert.equals(0, violations(reificationAlone).length);
	}

	/**
	 * Fixpoint guard, progress side — same region, but the merged `for` head genuinely
	 * exceeds the width (141 at tab 4): the split IS licensed, and its result is a
	 * FIXPOINT — re-running the check on the fixed text proposes nothing, where the old
	 * planner reported the merge back and `--fix` cycled.
	 */
	public function testOverwideHeadSplitsOnceAndConverges(): Void {
		final head: String =
			"\t\tfinal expected: String = 'class C {\\n\\tfunction test() {\\n\\t\\tfinal resultList = [\\n\\t\\t\\tfor (fieldEntry in fieldEntryCollection)\\n'";
		final src: String = cycleFixture(head);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				// Pin the EDIT, not just its stability: the head must split into the
				// two seam segments (the `[\n'`-terminated literal + the `for` line) —
				// a future planner proposing a different self-consistent edit fails here.
				Assert.isTrue(text.contains("final resultList = [\\n'"));
				Assert.isTrue(text.contains("+ '\\t\\t\\tfor (fieldEntry in fieldEntryCollection)\\n'"));
				Assert.equals(0, violations(text).length);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/**
	 * A `g('…' + '…')` at three tabs whose FIRST operand is 40 characters of text and
	 * whose second is 40 more, an interpolated `$x` and `tailLen` trailing characters.
	 * The greedy fill packs the first three segments into one group and leaves the
	 * trailing run in a second — the SAME two operands the source has, cut elsewhere.
	 * `tailLen` alone decides whether the source's second line clears `LINE_WIDTH`.
	 */
	private function recutSource(tailLen: Int): String {
		return [
			'class C {',
			'\tfunction f(x:String) {',
			'\t\tg(',
			'\t\t\t\'${''.rpad('a', 40)}\'',
			'\t\t\t+ \'${''.rpad('b', 40)}$${x}${''.rpad('c', tailLen)}\'',
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * A `var` at one indent whose chain the writer already wraps INSIDE the limit and
	 * whose last line ends in a trailing comment — columns that sit PAST the
	 * declaration's own span.
	 */
	private function trailingCommentSource(): String {
		return [
			'class C {',
			'\tvar xxxxx = \'${''.rpad('A', 60)}\' + name',
			'\t\t+ \'${''.rpad('B', 60)}\'; // ${''.rpad('z', 36)}',
			'}'
		].join('\n');
	}

	/**
	 * A chain whose first two literals merge within the limit, the second one followed by
	 * a `//` comment and the chain continuing on the next line — the shape where the
	 * sub-chain the rule claims ENDS at a comment the veto never looks at.
	 */
	private function trailingCommentInChainSource(): String {
		return [
			'class C {',
			'\tfunction f() {',
			'\t\tvar x = \'${''.rpad('A', 30)}\' + \'${''.rpad('B', 30)}\' // one',
			'\t\t\t+ \'${''.rpad('C', 30)}\';',
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * A wrapped chain whose every line holds an adjacent-literal PAIR and ends in a `//`
	 * comment — the shape `Editor.hx`'s test-animation XML has, minified to fit the width.
	 */
	private function perLineCommentSource(): String {
		return [
			'class C {',
			'\tfunction f() {',
			"\t\tvar x = '<animation>' + '<f i=\"0\"/>' // first",
			"\t\t\t+ '<f i=\"1\"/>' + '<f i=\"2\"/>' // second",
			"\t\t\t+ '<f i=\"3\"/>' + '<f i=\"4\"/>' // third",
			"\t\t\t+ '</animation>';",
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * The widest line of `src` once the rule's fix is applied and the result
	 * canonicalised through the writer — with the SAME `hxformat.json` the check
	 * measured against, so the assertion sees the layout the rule was planning for.
	 */
	private function widestAfterFix(src: String): Int {
		return widestLine(fixedText(src));
	}

	/** `src` with the rule's fix applied and canonicalised through the writer, with the SAME `hxformat.json` the check measured against. */
	private function fixedText(src: String): String {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		switch RefactorSupport.canonicalize(src, edits, true, plugin, FormatConfigDiscovery.discover('C.hx')) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
				return '';
		}
	}

	/**
	 * A `g('…' + b);` statement at two tabs whose MERGED literal is exactly
	 * `mergedLen` characters. The chain starts at column `FIXTURE_INDENT +
	 * CALL_HEAD`, so the planner's budget is `FIXTURE_BUDGET` and the merged
	 * rendered line is `mergedLen + FIXTURE_INDENT + CALL_HEAD + 2` columns —
	 * landing exactly on `LINE_WIDTH` at `mergedLen == FIXTURE_BUDGET`. The second
	 * operand is an IDENTIFIER, not a literal, so only the width-aware rule can
	 * merge this pair at all.
	 */
	private function widthSource(mergedLen: Int): String {
		return 'class C {\n\tfunction f() {\n\t\tg(\'${''.rpad('a', mergedLen - 4)}\' + b);\n\t}\n}';
	}

	/**
	 * A `g('<aLen A>\n<bLen B>');` at two tabs in `quote` quoting. The literal starts at
	 * column `FIXTURE_INDENT + CALL_HEAD`, so the planner's budget is `FIXTURE_BUDGET`
	 * and the seam sits after `aLen + 4` characters of rendered fragment — under the
	 * budget for the split fixtures, past it for `testSeamPastLimitStillSplitsBestEffort`.
	 */
	private function newlineSource(quote: String, aLen: Int, bLen: Int): String {
		return rawSource('${quote + ''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}$quote');
	}

	/**
	 * An object-literal entry at three tabs whose value is the over-long literal. The
	 * writer keeps a field's value on the field's own line, so the continuation-column
	 * estimate is refuted by the source itself — `unwrapped`'s shape.
	 */
	private function objectFieldSource(aLen: Int, bLen: Int): String {
		final literal: String = '\'${''.rpad('A', aLen)}\\n${''.rpad('B', bLen)}\'';
		return 'class C {\n\tfunction f() {\n\t\tg({\n\t\t\tsomeVeryLongFieldNameIndeed: $literal\n\t\t});\n\t}\n}';
	}

	/** `src` fixed, canonicalised and re-linted: the canonical form must be a fixed point of the rule. */
	private function assertFixIsIdempotent(src: String): Void {
		Assert.equals(0, violations(fixedText(src)).length);
	}

	/**
	 * The real-world flip-flop geometry: a chain whose region carries an IRREDUCIBLE
	 * over-wide segment — the double-quoted reification line has no seam to split at.
	 * `head` is the chain's first source line (statement indent, two tabs).
	 */
	private function cycleFixture(head: String): String {
		return [
			'class C {',
			'\tfunction f() {',
			head,
			"\t\t\t+ \"\\t\\t\\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\\n\"",
			"\t\t\t+ '\\t\\t];\\n\\t}\\n}';",
			'\t}',
			'}'
		].join('\n');
	}

	/** `text`'s widest line in columns, a tab counting as `TAB_WIDTH`. */
	private static function widestLine(text: String): Int {
		var widest: Int = 0;
		for (line in text.split('\n')) {
			var cols: Int = 0;
			for (i in 0...line.length) cols += line.fastCodeAt(i) == '\t'.code ? TAB_WIDTH : 1;
			if (cols > widest) widest = cols;
		}
		return widest;
	}

}
