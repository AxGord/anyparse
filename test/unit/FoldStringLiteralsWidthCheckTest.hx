package unit;

import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxStringEscape;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;

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

	/**
	 * The double-quoted macro-reification line the fixpoint fixtures wrap around: 142
	 * columns at three tabs, and no seam to split at — the irreducible over-wide line whose
	 * presence must never stand in for a verdict on the lines around it.
	 *
	 * Its spaces read `_`, its commas and opening brackets `.`, which is what keeps it
	 * irreducible now that a text can also be cut at a SEPARATOR: the shape and the 128
	 * characters are the real reification's, only spelled with no legal cut point in them.
	 * Its own `\n` is terminal, so that seam yields nothing either.
	 */
	private static inline final IRREDUCIBLE: String =
		"\"\\t\\t\\tmacro_if_.$p..'sourceObject'._fieldEntry.slot]}_!=_null)_$p..fieldEntry.slot]}_=_$p..'sourceObject'._fieldEntry.slot]}\\n\"";

	/** A real column list, 128 characters of solid text whose ONLY cut points are its commas — no space, bracket or `\n`. */
	private static inline final COLUMN_LIST: String =
		'filepath,folder,cloud_id,folder_cloud_id,action,filepath_movedfrom,filepath_movedfromorigin,timestamp,synced_at,deleted_at,stamp';

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

	/**
	 * The MERGE arm reads no layout at all, which is what makes `hxq fmt` unable to CREATE one of
	 * its findings. The report was that the writer joins `'literal'\n+ intExpr` onto one line when
	 * it fits and the rule then fires on the joined form; the same chain wrapped and joined is
	 * asserted here to yield the same finding COUNT and the same fold text, so a future arm that
	 * starts consulting the source's own line breaks fails this instead of shipping.
	 *
	 * Only the merge direction is layout-free. The SPLIT arm is gated on `overLong`, which reads
	 * SOURCE lines on purpose — a writer-canonical file already IS the writer's layout for that
	 * construct — so on a file the writer would re-indent, formatting legitimately changes what is
	 * reported. That is the arm's contract, not a defect, and it is pinned by
	 * `testLiteralSplitOnlyWhenOverLong`.
	 */
	public function testMergeIsIndependentOfSourceWrapping(): Void {
		final joined: String = 'class C {\n\tfunction f(count:Int) {\n\t\tvar s = \'total: \' + count;\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f(count:Int) {\n\t\tvar s = \'total: \'\n\t\t\t+ count;\n\t}\n}';
		Assert.equals(1, violations(joined).length);
		Assert.equals(1, violations(wrapped).length);
		Assert.equals("'total: $count'", foldOf(joined));
		Assert.equals(foldOf(joined), foldOf(wrapped));
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

	/**
	 * MERGE fixture, shaped after a real query builder: a literal / ternary / literal / call / literal
	 * chain at three tabs — the ternary's nested `$keyId` strings merge into the block (no `$` refusal).
	 */
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
			+ " + (grouped ? '1 AND rowpath_movedfromroot = ' : '0 AND rowpath_movedfromroot = ') + _linkChannel.quote(rowPath)",
			foldOf(src)
		);
	}

	/**
	 * MERGE fixture 3, and the real trigger for separator cutting: the header literal is
	 * 150 columns on its own, and before a text could be cut at a separator it could only
	 * ever be a group of ITS OWN — the fix left that line over the limit. It is now cut
	 * after a `, ` inside the column list, and everything after it packs into as few groups
	 * as fit, so every line of the result lands inside the limit.
	 */
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
		Assert.isTrue(
			folded.contains("stamp, rowpath_movedfrom, ' + 'rowpath_movedfromroot) VALUES (${link.quote(r.newRowpath)}, ${r.grouped}, ")
		);
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
			"\t\tfinal expected: String = 'class C {\\n\\tfunction test() {\\n\\t\\tfinal resultList = [\\n\\t\\t\\twhile (iteratorValue.hasNextElement())\\n'"; // noqa
		Assert.equals(0, violations(cycleFixture(head)).length);
		final reificationAlone: String = 'class C {\n\tfunction f() {\n\t\tfinal expected: String = $IRREDUCIBLE;\n\t}\n}';
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
			"\t\tfinal expected: String = 'class C {\\n\\tfunction test() {\\n\\t\\tfinal resultList = [\\n\\t\\t\\tfor (fieldEntry in fieldEntryCollection)\\n'"; // noqa
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
	 * MIDDLE-SANDWICH precision, accept side. The chain merges a literal pair on EITHER
	 * side of the irreducible line, so the plan changes a line above it and a line below
	 * it and leaves the 142-column line between them alone. Measured as one contiguous
	 * window, that untouched line entered both maxima and pinned them EQUAL — the gate
	 * read "no improvement" and refused a plan that narrowed every line it touched, so
	 * `--fix` recovered one pair per pass through the inner-chain descent (2 edits over
	 * 3 passes). Differenced by CONTENT it is on neither side, and the whole chain folds
	 * in ONE pass. The assertion spans the construct — both merges AND the untouched
	 * line between them — so no half of it can pass on the unchanged source.
	 */
	public function testMiddleSandwichFoldsBothSidesInOnePass(): Void {
		final src: String = sandwichSource(30, 30);
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.contains(
			'String = \'${''.rpad('A', 30)}${''.rpad('B', 30)}\'\n\t\t\t+ $IRREDUCIBLE'
			+ '\n\t\t\t+ \'${''.rpad('C', 30)}${''.rpad('D', 30)}\';'
		));
		Assert.equals(0, violations(fixed).length);
	}

	/**
	 * MIDDLE-SANDWICH geometry read by the OTHER consumer of the same measurement, and a
	 * no-regression guard rather than a discriminator: it flips on disabling `settle`'s
	 * back-off loop, not on reverting the content difference. The head pair is sized so
	 * its merge renders 155 columns, the back-off sees that CHANGED line past the limit,
	 * re-fills against a narrower budget and settles on the tail merge alone — so
	 * dropping untouched lines from the measurement narrows what the back-off and the
	 * gate see without blinding either: the 142-column line neither triggers a back-off
	 * of its own nor masks the 155-column one. The preserved head split and the changed
	 * tail are asserted as ONE string, so the unchanged source cannot satisfy it, and the
	 * result is re-linted: this side of the geometry converges too.
	 */
	public function testMiddleSandwichRefusesHeadMergeThatOverflows(): Void {
		final src: String = sandwichSource(60, 30);
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.contains(
			'String = \'${''.rpad('A', 60)}\'\n\t\t\t+ \'${''.rpad('B', 60)}\'\n\t\t\t+ $IRREDUCIBLE'
			+ '\n\t\t\t+ \'${''.rpad('C', 30)}${''.rpad('D', 30)}\';'
		));
		Assert.equals(0, violations(fixed).length);
	}

	/**
	 * The lowest cut tier: a solid over-long text with no interpolation and no `\n` is
	 * cut at a plain COMMA. The fixture carries no space at all, deliberately — a space
	 * outranks a comma, so a spaced list would cut elsewhere and stop pinning this tier.
	 * The changed half and the preserved half are asserted as ONE string, so the unsplit
	 * input satisfies neither.
	 */
	public function testOverLongSolidLiteralSplitsAtComma(): Void {
		final src: String = separatorSource(COLUMN_LIST);
		Assert.equals(1, violations(src).length);
		Assert.equals(
			"'filepath,folder,cloud_id,folder_cloud_id,action,filepath_movedfrom,filepath_movedfromorigin,timestamp,synced_at,deleted_at,'"
			+ " + 'stamp$v'",
			foldOf(src)
		);
	}

	/**
	 * The RANK ladder, not the widest fit: inside the window that keeps the group count
	 * minimal, the boundary right after an open bracket preceded by a space outranks
	 * every plain space further right. A greedy last-fit would cut after the space
	 * following the `a` run instead, so the fixture discriminates the tie-break.
	 */
	public function testSplitPrefersBracketAdjacentBoundary(): Void {
		final src: String = separatorSource('MATCH [' + ''.rpad('a', 60) + ' ' + ''.rpad('b', 60)); // noqa: fold-adjacent-string-literals
		Assert.equals(1, violations(src).length);
		Assert.equals("'MATCH [' + '" + ''.rpad('a', 60) + ' ' + ''.rpad('b', 60) + "$v'", foldOf(src)); // noqa
	}

	/**
	 * The same ladder read one step further: the bracket has to open a LIST for the tier to
	 * apply. Here it closes immediately — an empty `[]`, the shape a serialized structure is
	 * full of — so the boundary after it splits one token and the fill falls back to the plain
	 * space run further right. Sibling fixture of the one above with the ONE character that
	 * changes the verdict, so a ladder that ignores what follows the bracket fails exactly here.
	 */
	public function testSplitSkipsBracketThatOpensAToken(): Void {
		final src: String = separatorSource('MATCH []' + ''.rpad('a', 60) + ' ' + ''.rpad('b', 60)); // noqa: fold-adjacent-string-literals
		Assert.equals(1, violations(src).length);
		Assert.equals("'MATCH []" + ''.rpad('a', 60) + " ' + '" + ''.rpad('b', 60) + "$v'", foldOf(src)); // noqa
	}

	/**
	 * A blank line is not two cut points. The greedy end lands BETWEEN the two `\n` escapes of
	 * a `\n\n` run — the widest boundary that still fits — and emits a group opening with the
	 * newline that terminates the line the group before it just ended: `'…\t}\n' + '\n}\n'`,
	 * the split that reads as noise rather than as a seam. The run is one boundary, so the fill
	 * takes the seam before it and the trailing lines stay together.
	 *
	 * Geometry (budget `FIXTURE_BUDGET`): the A and B lines together render at exactly the
	 * budget, so the greedy end is past the blank line's first escape and the alternative is
	 * the seam between them — the fixture has no verdict to give if either changes.
	 */
	public function testSplitDoesNotCutInsideABlankLineRun(): Void {
		final text: String = ''.rpad('A', 62) + '\\n' + ''.rpad('B', 60) + '\\n\\n}\\n'; // noqa: fold-adjacent-string-literals
		final src: String = rawSource('\'$text\'');
		Assert.equals(1, violations(src).length);
		Assert.equals("'" + ''.rpad('A', 62) + "\\n' + '" + ''.rpad('B', 60) + "\\n\\n}\\n'", foldOf(src)); // noqa
	}

	/**
	 * The preserved fallback: an over-long token carrying NO separator keeps its own
	 * over-wide group and is accepted as is. Paired with the fixtures above, this is what
	 * says the new tier cuts at separators rather than at any character that fits.
	 */
	public function testSolidLiteralWithoutSeparatorsAcceptedAsIs(): Void {
		Assert.equals(0, violations(separatorSource('https://cdn.example.com/assets/' + ''.rpad('u', 110))).length); // noqa
	}

	/** The separator split's own output re-decomposes to the same segment list, so re-linting it finds nothing. */
	public function testSplitOutputIsFixedPoint(): Void {
		assertFixIsIdempotent(separatorSource(COLUMN_LIST));
	}

	/**
	 * A separator spelled as an ESCAPE is not one: the cut scan walks escapes the way the
	 * lexer does and never decodes them, so a `\x20` between two solid runs leaves the
	 * literal seamless — while the same text with a RAW space is cut right after it. The
	 * `$$` rides along to pin the other half of that walk: a cut may never land between
	 * an escaped dollar's two characters, and the split half re-parses as one again.
	 */
	public function testEscapeSpelledSeparatorIsNotACut(): Void {
		Assert.equals(0, violations(separatorSource(''.rpad('a', 62) + "\\x20$$" + ''.rpad('b', 62))).length); // noqa
		final spaced: String = ''.rpad('a', 62) + " $$" + ''.rpad('b', 62); // noqa: fold-adjacent-string-literals
		Assert.equals("'" + ''.rpad('a', 62) + " ' + '$$" + ''.rpad('b', 62) + "$v'", foldOf(separatorSource(spaced))); // noqa
	}

	/**
	 * A BRACED unicode escape carries an opening brace, so a cut scan that skipped a fixed
	 * two characters past the backslash landed on it and bisected the escape — emitting a
	 * literal ending in a truncated `\u{`, which does not compile. The scan asks
	 * `HxStringEscape` for the span of each character instead, so the escape is one unit:
	 * with nothing else to cut at the literal is left alone, and with a space in front of it
	 * the cut lands on that space and the escape comes through whole. Both halves are
	 * asserted, so the fix cannot pass on the absence of a split.
	 */
	public function testBracedUnicodeEscapeIsNeverBisected(): Void {
		Assert.equals(0, violations(separatorSource(''.rpad('a', 60) + '\\u{1F600}' + ''.rpad('b', 60))).length); // noqa
		final spaced: String = ''.rpad('a', 60) + ' \\u{1F600}' + ''.rpad('b', 60); // noqa: fold-adjacent-string-literals
		Assert.equals("'" + ''.rpad('a', 60) + " ' + '\\u{1F600}" + ''.rpad('b', 60) + "$v'", foldOf(separatorSource(spaced))); // noqa
	}

	/**
	 * The value-changing half of the same bisection, and the reason the escape span has to
	 * come from the decoder rather than from a character count. `escapeLiteral` refuses a
	 * DOUBLE-quoted text whose escapes decode to a `$`, because Haxe decodes before it scans
	 * a single-quoted literal for interpolation. That refusal is per SEGMENT, so a cut inside
	 * `\u{24}` split the trigger into two halves that each pass it, and the fold emitted
	 * `'a\u{24}b$v'` — the value of `b` where the source said the text `a$b`. With the escape
	 * intact the whole raw carries it, the group is refused, and nothing is reported.
	 */
	public function testEscapedDollarEscapeIsNotFoldedIntoInterpolation(): Void {
		final src: String = [
			'class C {',
			'\tfunction f() {',
			'\t\tg(',
			'\t\t\t"a\\u{24}b"',
			'\t\t\t+ v',
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
		Assert.isTrue(HxStringEscape.carriesEscapedDollar('a\\u{24}b'));
		Assert.equals(0, violations(src).length);
		Assert.equals('', foldOf(src));
	}

	/**
	 * An opening bracket is a cut point ONLY where a space or a comma introduced it. A regex
	 * spells brackets with neither, and cutting there once broke a 501-column character class
	 * into five unreadable pieces — value-preserving and useless. Such a literal carries no
	 * legal cut at all now, so it keeps its own over-wide group and nothing is reported.
	 */
	public function testBareBracketIsNotACut(): Void {
		final regex: String = '(' + ''.rpad('a', 42) + ')[' + ''.rpad('b', 42) + '](' + ''.rpad('c', 42) + ')'; // noqa
		Assert.equals(0, violations(separatorSource(regex)).length);
	}

	/**
	 * A BARE first group — a `$name` or `${ … }` head the source did not write as its own
	 * operand — is the one end `fill` may not steer to, because `mergeLeadingBares` folds it
	 * into the next group WITHOUT pricing the result. That boundary reads as a seam and wins
	 * the ladder outright, so the merged first line landed 145 columns wide and stayed there:
	 * the partition re-lints to itself, so nothing ever recovers it.
	 *
	 * The `$name` shorthand runs to the first non-identifier character, so the head here is
	 * the whole `abcde` + `x` run and the space after it is the literal's first text piece —
	 * which is exactly the shape that makes the head bare AND wide. The control is the SAME
	 * geometry with those 67 columns spelled as TEXT; the two are asserted together, so the
	 * bare head must reach the same three groups the plain one does.
	 */
	public function testBareHeadDoesNotSteerIntoAnUnpricedMerge(): Void {
		final tail: String = ''.rpad('x', 60) + ' ' + ''.rpad('y', 62) + ' ' + ''.rpad('z', 63); // noqa: fold-adjacent-string-literals
		Assert.equals(
			"'$abcde" + ''.rpad('x', 60) + " ' + '" + ''.rpad('y', 62) + " ' + '" + ''.rpad('z', 63) + "$v'", // noqa
			foldOf(separatorSource("$abcde" + tail)) // noqa: fold-adjacent-string-literals
		);
		Assert.equals(
			"'wvutsr" + ''.rpad('x', 60) + " ' + '" + ''.rpad('y', 62) + " ' + '" + ''.rpad('z', 63) + "$v'", // noqa
			foldOf(separatorSource('wvutsr' + tail)) // noqa: fold-adjacent-string-literals
		);
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
			'\t\t\t+ $IRREDUCIBLE',
			"\t\t\t+ '\\t\\t];\\n\\t}\\n}';",
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * The MIDDLE-SANDWICH geometry: an adjacent literal pair on EITHER side of the
	 * irreducible over-wide line, so a whole-chain plan changes a line above it and a line
	 * below it while leaving that line itself alone. `headLen` sizes the pair above — and
	 * with it the width the writer renders its merge at — and `tailLen` the pair below.
	 */
	private function sandwichSource(headLen: Int, tailLen: Int): String {
		return [
			'class C {',
			'\tfunction f() {',
			'\t\tfinal expected: String = \'${''.rpad('A', headLen)}\'',
			'\t\t\t+ \'${''.rpad('B', headLen)}\'',
			'\t\t\t+ $IRREDUCIBLE',
			'\t\t\t+ \'${''.rpad('C', tailLen)}\' + \'${''.rpad('D', tailLen)}\';',
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * A `g(<literal> + v);` chain at three tabs — the host every separator fixture
	 * measures at. The literal starts at column 12, so the planner's budget is 126: a
	 * 127-character text already overflows the source line and no single group can hold it.
	 */
	private function separatorSource(text: String): String {
		return [
			'class C {',
			'\tfunction f() {',
			'\t\tg(',
			'\t\t\t\'$text\'',
			'\t\t\t+ v',
			'\t\t);',
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
