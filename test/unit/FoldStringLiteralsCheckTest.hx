package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.Linter;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `fold-adjacent-string-literals` check: a string concatenation whose
 * segmentation does not match the file's line width is flagged (`Info`) and
 * re-segmented — literals and expression operands MERGE into one interpolated
 * literal, an over-long literal SPLITS back out at its seams: a `${ … }`
 * interpolation, or an embedded `\n` escape.
 *
 * Width comes from the file's own `hxformat.json`, and every fixture here names its
 * path `C.hx`: the suite runs from the repository root, so that resolves to the
 * repository's OWN config (`maxLineLength` 140, tab width 4) — the constants the
 * boundary fixtures below are written against.
 *
 * Both the fix's emitted text and the finding count are asserted; the two must
 * agree, since `run` and `fix` share one planner.
 */
class FoldStringLiteralsCheckTest extends Test {

	/**
	 * `140` / tab `4` — the values in the repository's OWN `hxformat.json`, which is
	 * what `FormatConfigDiscovery` resolves for the `C.hx` path these fixtures use
	 * (the suite runs from the repository root). Spelled out here so the boundary
	 * fixtures below read as arithmetic rather than as magic.
	 */
	private static inline final LINE_WIDTH: Int = 140;

	/** The rule id, as the config fixtures spell it. */
	private static inline final RULE: String = 'fold-adjacent-string-literals';

	/** The macro-whitelist option name, which the refusal message names so a reader knows what lifts it. */
	private static inline final WHITELIST_OPTION: String = 'concatFoldingMacros';

	/** The tab width in that same config — what a tab counts as when a fixture measures a rendered line. */
	private static inline final TAB_WIDTH: Int = 4;

	/** Columns of indent the width fixtures put their statement at (two tabs). */
	private static inline final FIXTURE_INDENT: Int = 8;

	/** Columns between the fixture indent and the chain: the `g(` call head. */
	private static inline final CALL_HEAD: Int = 2;

	/** The planner's own budget for a `widthSource` fixture: line width less the start column and the `+ ` glue. */
	private static inline final FIXTURE_BUDGET: Int = LINE_WIDTH - FIXTURE_INDENT - CALL_HEAD - 2;

	public function testDoubleLiteralPairFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f() { final a = "a" + "b"; } }');
		Assert.equals(1, vs.length);
		Assert.equals('fold-adjacent-string-literals', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixMergesDoublePair(): Void {
		Assert.equals('"ab"', foldOf('class C { function f() { final a = "a" + "b"; } }'));
	}

	public function testChainFoldsInOnePass(): Void {
		final src: String = 'class C { function f() { final a = "x" + "y" + "z"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"xyz"', foldOf(src));
	}

	public function testSingleQuotedPlainFolds(): Void {
		final src: String = "class C { function f() { final a = 'p' + 'q'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals("'pq'", foldOf(src));
	}

	/** An interpolated operand is no longer a blocker: its fragments join the segment list. */
	public function testInterpolatedOperandMerges(): Void {
		Assert.equals("'lead ${name}tail'", foldOf("class C { function f(name:String) { final a = 'lead $name' + 'tail'; } }"));
	}

	/** Mixed quotes merge into ONE single-quoted literal, each side re-escaped for that context. */
	public function testMixedQuotesMergeToSingleQuoted(): Void {
		Assert.equals("'mn'", foldOf("class C { function f() { final a = \"m\" + 'n'; } }"));
	}

	public function testNonLiteralOperandMerges(): Void {
		Assert.equals("'a${name}b'", foldOf('class C { function f(name:String) { final a = "a" + name + "b"; } }'));
	}

	public function testNumericOperandMerges(): Void {
		Assert.equals("'z${1}'", foldOf('class C { function f() { final a = "z" + 1; } }'));
	}

	/** The WHOLE chain is one candidate now — the trailing identifier merges in with the literal pair. */
	public function testWholeChainFoldsWithTrailingIdent(): Void {
		final src: String = 'class C { function f(name:String) { final a = "a" + "b" + name; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals("'ab$name'", foldOf(src));
	}

	/**
	 * The whole pipeline over one construct: `run` -> `fix` -> canonicalize -> re-lint.
	 * The canonicalized FILE is asserted verbatim and then fed straight back through
	 * `run`, which must find nothing — the canonical form is a fixed point of the RULE,
	 * not merely of its own rendered fragment.
	 */
	public function testFixAppliedResultIsCanonicalAndIdempotent(): Void {
		final src: String = 'class C {\n\tfunction f(name:String) {\n\t\tfinal a = "a" + name + "b";\n\t}\n}';
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals("class C {\n\tfunction f(name:String) {\n\t\tfinal a = 'a${name}b';\n\t}\n}\n", text);
				Assert.equals(0, violations(text).length);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('fold-adjacent-string-literals'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('fold-adjacent-string-literals'));
	}

	public function testDollarEscapedSingleQuotedFolds(): Void {
		// '$$' is an escaped literal $ (a `Dollar` fragment, not interpolation) — plain, so it folds.
		Assert.equals("'a$$bc'", foldOf("class C { function f() { final a = 'a$$b' + 'c'; } }"));
	}

	/**
	 * A lone `$` literal is ONE segment: nothing to re-cut, so the normalisation to
	 * the escaped `$$` form never fires on its own. It DOES fire when the literal
	 * joins a merge — the plain form would otherwise interpolate whatever follows.
	 */
	public function testLoneDollarLiteralNormalisedOnlyWhenMerged(): Void {
		Assert.equals(0, violations("class C { function f() { final a = '$'; } }").length);
		Assert.equals("'$$a'", foldOf("class C { function f() { final a = '$' + 'a'; } }"));
	}

	/**
	 * The old rule refused a chain laid out ACROSS lines as "deliberate width
	 * layout". Width is now measured, so a cross-line chain that fits when merged
	 * merges.
	 */
	public function testCrossLineChainNowMerges(): Void {
		final src: String = 'class C { function f() { final a = "long message "\n\t\t+ "split for width"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"long message split for width"', foldOf(src));
	}

	/** A cross-line chain is ONE candidate — the whole thing folds, not just its same-line prefix. */
	public function testCrossLinePrefixChainMergesWhole(): Void {
		final src: String = 'class C { function f() { final a = "a" + "b"\n\t\t+ "tail"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"abtail"', foldOf(src));
	}

	public function testConcatHtmlViewRepro(): Void {
		Assert.equals(1, violations(wrap("'<xml>' + xhtml + '</xml>'")).length);
		Assert.equals("'<xml>$xhtml</xml>'", foldOf(wrap("'<xml>' + xhtml + '</xml>'")));
	}

	/** Operands before the first literal are arithmetic — they collapse into ONE `${ … }`, never `$a$b`. */
	public function testConcatEvalOrderPreserved(): Void {
		Assert.equals("'${a + b}x'", foldOf(wrap("a + b + 'x'")));
	}

	public function testConcatIdentBeforeIdentCharBraced(): Void {
		Assert.equals("'a${xhtml}more'", foldOf(wrap("'a' + xhtml + 'more'")));
	}

	public function testConcatNumericOperands(): Void {
		Assert.equals("'s${3}${4}'", foldOf(wrap("'s' + 3 + 4")));
	}

	public function testConcatSingleIdentPrefixBeforeIdentChar(): Void {
		Assert.equals("'${a}x'", foldOf(wrap("a + 'x'")));
	}

	public function testConcatSingleIdentPrefixBeforeNonIdent(): Void {
		Assert.equals("'$a.b'", foldOf(wrap("a + '.b'")));
	}

	/**
	 * The `$name` lookahead reads the DECODED first character of the text that follows,
	 * not its raw one. `"\x41b"` starts with an `A`, which would extend the name, so the
	 * ident needs its braces — emitting the bare `'$x\x41b'` made the compiler read a
	 * local `xAb`, a silent VALUE change (compile-and-run verified: `X!Ab` before,
	 * `XAB-WRONG` after). A raw `\` really starting the text (`'\\x41b'`) is not an
	 * identifier character and keeps the bare form.
	 */
	public function testConcatIdentBeforeDecodedIdentCharBraced(): Void {
		Assert.equals("'${x}\\x41b'", foldOf(wrap('x + "\\x41b"')));
		Assert.equals("'${x}\\u0041b'", foldOf(wrap('x + "\\u0041b"')));
		Assert.equals("'$x\\\\x41b'", foldOf(wrap('x + "\\\\x41b"')));
	}

	public function testConcatDollarInSingleLiteral(): Void {
		Assert.equals("'$$$v'", foldOf(wrap("'$' + v")));
	}

	public function testConcatDoubleQuotedDollar(): Void {
		Assert.equals("'a$$b$x'", foldOf(wrap("\"a$b\" + x")));
	}

	public function testConcatDoubleQuotedEscapedQuote(): Void {
		Assert.equals("'a\"b$x'", foldOf(wrap('\"a\\\"b\" + x')));
	}

	public function testConcatParenSubChain(): Void {
		Assert.equals("'a${(b + 'c')}'", foldOf(wrap("'a' + (b + 'c')")));
	}

	public function testConcatStdStringOperand(): Void {
		Assert.equals("'a${x}b'", foldOf(wrap("'a' + Std.string(x) + 'b'")));
	}

	/** A pure-literal pair is the ORIGINAL fold and still folds — to a plain literal in its own quote. */
	public function testConcatPureLiteralFolds(): Void {
		Assert.equals("'ab'", foldOf(wrap("'a' + 'b'")));
	}

	public function testConcatNumericOnlyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a + b')).length);
	}

	public function testConcatInterpolatedOperandMerges(): Void {
		Assert.equals("'x$y$z'", foldOf(wrap("'x${y}' + z")));
	}

	public function testConcatCommentBetweenOperandsSkipped(): Void {
		Assert.equals(0, violations(wrap("'a' + /* c */ b")).length);
	}

	public function testConcatOperandWithBackslashStringNotFolded(): Void {
		// `'\\'` nested inside a `${}` block mis-lexes in the REAL Haxe compiler
		// ("Unterminated string" - escapes in nested same-quote strings are not
		// processed by the interp-block scanner), even though anyparse's own
		// parser accepts it. An operand whose source carries a backslash cannot
		// enter a `${}` block, so it stays a BARE operand of its own.
		final src: String = "class C { function f(a:String, b:String):String { return a + '/' + b.replace('\\\\', '/'); } }";
		Assert.equals("'$a/' + b.replace('\\\\', '/')", foldOf(src));
	}

	public function testConcatInsideInterpolationBlockNotFolded(): Void {
		// A `+` chain that itself sits INSIDE a `${...}` interpolation block must
		// not fold - the result would nest an interpolated string inside an
		// interpolation block (fragile in the real compiler's interp scanner).
		final src: String = "class C { function f(t:String):String { return 'x${t.split('a').join(q() + \"n\")}y'; } }";
		Assert.equals(0, violations(src).length);
	}

	/** A string literal in an ANNOTATION argument is parsed as an expression — moving a `$` into it changes the annotation. */
	public function testMetadataStringArgumentNotTouched(): Void {
		Assert.equals(0, violations("@:native('a' + 'b') class C { function f() {} }").length);
	}


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
		Assert.equals(0, violations("class C { function f() { g('x" + seams + "z'); } }").length);
		Assert.equals(1, violations("class C {\n\tfunction f() {\n\t\tg('" + ''.rpad('x', 130) + seams + "');\n\t}\n}").length);
	}

	/** An over-long literal is cut at a `${ … }` seam until the lines fit. */
	public function testOverLongLiteralSplitAtSeam(): Void {
		final head: String = ''.rpad('h', 100);
		final tail: String = ''.rpad('t', 60);
		final src: String = "class C {\n\tfunction f() {\n\t\tg('" + head + "${a.b()}" + tail + "');\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals("'" + head + "${a.b()}' + '" + tail + "'", foldOf(src));
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
		final src: String = "class C {\n\tfunction f() {\n\t\tg('${" + one + "}${" + two + "} items');\n\t}\n}";
		Assert.equals("'$" + one + "$" + two + "' + ' items'", foldOf(src));
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
	 * An operand whose OWN span carries a comment is refused outright rather than locked: its
	 * source is copied verbatim into the render, where a `//` would comment out the rest.
	 */
	public function testCommentInsideOperandRefusesConstruct(): Void {
		Assert.equals(0, violations(wrap("'a' + (b /* c */ + d) + 'e'")).length);
	}

	/**
	 * A `\x24` decodes to `$` BEFORE Haxe scans a single-quoted literal for
	 * interpolation, so a DOUBLE-quoted text carrying one may not be re-emitted into
	 * one: merging `"a\x24b" + 'c'` to `'a\x24bc'` would print the value of the local
	 * `bc` instead of the text `a$bc`. Verified against Haxe 4.3.7.
	 */
	public function testHexEscapeNotMergedIntoSingleQuoted(): Void {
		Assert.equals(0, violations(wrap('"a\\x24b" + \'c\'')).length);
		Assert.equals(0, violations(wrap('"\\x24" + name')).length);
	}

	/**
	 * The SINGLE-quoted spelling of the same escape is not a text hazard at all — it is
	 * live interpolation the parser used to hide. `'a\x24b'` reads the local `b`, and
	 * `HxInterpProjection` now says so, which turns the concatenation into the ordinary
	 * text + ident + text fold: `'a${b}c'`, the braces added because a bare `$b` would
	 * swallow the following `c`. Compile-and-run confirms both spellings print `aBBBc`
	 * on `--interp` and `-js`.
	 *
	 * Pinned at 0 findings until this slice: the seam refused the whole group because a
	 * blunt "carries any `\x` / `\u` escape" test could not tell a hidden trigger from
	 * an ordinary `\x41`.
	 */
	public function testHexEscapedInterpolationFoldsAsInterpolation(): Void {
		Assert.equals(1, violations(wrap("'a\\x24b' + 'c'")).length);
		Assert.equals("'a${b}c'", foldOf(wrap("'a\\x24b' + 'c'")));
	}

	/** An escape decoding to something ORDINARY never blocked anything but the blunt test — `\x41` is an `A`. */
	public function testNonTriggerEscapeMergesIntoSingleQuoted(): Void {
		Assert.equals("'a\\x41bc'", foldOf(wrap("'a\\x41b' + 'c'")));
		Assert.equals("'a\\x41bc'", foldOf(wrap('"a\\x41b" + \'c\'')));
	}

	/** `$` is the same trap spelled the other way. */
	public function testUnicodeEscapeNotMergedIntoSingleQuoted(): Void {
		Assert.equals(0, violations(wrap('"a\\u0024b" + \'c\'')).length);
	}

	/**
	 * The real compiler finds a `${ … }` block's closing brace by counting `{` / `}`
	 * NAIVELY, without lexing nested strings, so a brace inside one still counts:
	 * `'a${q("}")}z'` is `Unterminated string` and `'a${q("{")}z'` is `Unclosed brace`
	 * on Haxe 4.3.7 — while anyparse's own re-parse validation accepts both, which is
	 * why the fixer cannot lean on it here. Such an operand stays BARE, so the chain
	 * is already canonical and nothing is flagged.
	 */
	public function testUnbalancedBraceOperandNotMerged(): Void {
		Assert.equals(0, violations(wrap("'a' + q(\"}\") + 'z'")).length);
		Assert.equals(0, violations(wrap("'a' + q(\"{\") + 'z'")).length);
	}

	/**
	 * The same brace count runs over the DECODED text, so an operand may spell its
	 * unbalancing brace as `\x7D` and read as balanced. The audit's answer is that
	 * `interpolationBlockSafe` needs no decoder to see it: it already refuses ANY
	 * backslash — nothing in an expression source can carry an escape past that — and
	 * the operand stays bare, exactly as it does for the raw spelling above. Already
	 * true before this slice, and pinned so a later "the backslash rule is too strict"
	 * relaxation has to answer this case first.
	 */
	public function testEscapeSpelledBraceOperandNotMerged(): Void {
		Assert.equals(0, violations(wrap("'a' + q(\"\\x7D\") + 'z'")).length);
		Assert.equals(0, violations(wrap("'a' + q(\"\\x24x\") + 'z'")).length);
	}

	/** A BALANCED brace closes where that scanner expects it to, so it merges. */
	public function testBalancedBraceOperandMerges(): Void {
		Assert.equals("'v=${{x: 1}.x}'", foldOf("class C { function f() { g('v=' + {x: 1}.x); } }"));
	}

	/**
	 * A single-fragment INTERPOLATED literal head is NOT a bare operand: `'${a + b}'`
	 * is a string, so the plan may not open with a bare `(a + b)`. The segment list
	 * cannot tell the two apart — both are one non-text segment in the first group —
	 * so `Decomposition.startsBare` carries the fact from the decomposition, which
	 * knows whether it emitted a head segment at all.
	 */
	public function testInterpolatedHeadNeverBecomesBareOperand(): Void {
		final tail: String = ''.rpad('B', 5);
		Assert.equals("'${a + b}" + ''.rpad('A', 117) + "' + '" + tail + "'", foldOf(bareHeadSource("'${a + b}'", 117, 5)));
		Assert.equals("'${nnn}" + ''.rpad('A', 119) + "' + '" + tail + "'", foldOf(bareHeadSource("'$nnn'", 119, 5)));
	}

	/**
	 * An over-long literal with NO interpolation at all splits at its embedded `\n`
	 * escape, which stays with the LEFT fragment — the seam that makes a lone string
	 * token layout-fixable at all. Before this, such a literal had one segment and
	 * could only ever plan back to itself.
	 */
	public function testSplitsAtNewlineEscape(): Void {
		Assert.equals(1, violations(newlineSource("'", 100, 60)).length);
		Assert.equals("'" + ''.rpad('A', 100) + "\\n' + '" + ''.rpad('B', 60) + "'", foldOf(newlineSource("'", 100, 60)));
	}

	/** A DOUBLE-quoted literal interpolates nothing, so every `\n` in it is a seam — and the split stays double-quoted. */
	public function testSplitsDoubleQuotedAtNewlineEscape(): Void {
		Assert.equals('"' + ''.rpad('A', 100) + '\\n" + "' + ''.rpad('B', 60) + '"', foldOf(newlineSource('"', 100, 60)));
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
		Assert.equals(0, violations(rawSource("'" + ''.rpad('A', 100) + "\\\\n" + ''.rpad('B', 60) + "'")).length);
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
		Assert.equals("'" + ''.rpad('A', 150) + "\\n' + '" + ''.rpad('B', 20) + "'", foldOf(newlineSource("'", 150, 20)));
	}

	/**
	 * Gate (4): a `\n` inside a `${ … }` block belongs to an EXPRESSION segment, never
	 * to a text one, so it is not a seam — the nested literal comes through the split
	 * intact.
	 */
	public function testNewlineInsideInterpolationBlockIsNotASeam(): Void {
		final src: String = rawSource("'" + ''.rpad('A', 100) + "${g(\"p\\nq\")}" + ''.rpad('B', 60) + "'");
		Assert.isTrue(foldOf(src).indexOf('"p\\nq"') != -1);
	}

	/**
	 * Gate (2): a concatenation is not a legal `case` pattern (`Unrecognized pattern`
	 * on Haxe 4.3.7), so a literal in pattern position is skipped whatever its width.
	 */
	public function testCasePatternIsNotACandidate(): Void {
		Assert.equals(0, violations(casePatternSource(100, 60)).length);
	}

	/**
	 * Gate (3): a default argument value must be constant (`Default argument value
	 * should be constant` on Haxe 4.3.7), so a parameter's default is skipped.
	 */
	public function testDefaultParamValueIsNotACandidate(): Void {
		Assert.equals(0, violations(defaultParamSource(100, 60)).length);
	}

	/**
	 * Gate (3): an enum-abstract VALUE folded to a concatenation still compiles, but
	 * it stops being usable as a `case` pattern (`Unknown identifier` on Haxe 4.3.7) —
	 * the consumer sees the expression SHAPE, so the value is skipped.
	 */
	public function testEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(enumAbstractSource(100, 60)).length);
	}

	/**
	 * The DEPRECATED `@:enum abstract` spelling is the same declaration and breaks the
	 * same way, but it projects as a plain `AbstractDecl` with the annotation as a
	 * SIBLING — so a gate that tested the declaration's KIND folded its values.
	 */
	public function testDeprecatedEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(deprecatedEnumAbstractSource(100, 60)).length);
	}

	/**
	 * A `#if`-guarded value sits one level down, under the conditional region rather than
	 * under the declaration — a gate that asked only about the immediate parent was blind
	 * to it.
	 */
	public function testGuardedEnumAbstractValueIsNotACandidate(): Void {
		Assert.equals(0, violations(guardedEnumAbstractSource(100, 60)).length);
	}

	/**
	 * An `inline` field's value IS a compile-time constant at every use site, so a `case`
	 * pattern reads its expression shape exactly as it reads an enum-abstract value's
	 * (`case S:` becomes an "Unknown identifier" once `S` folds). The modifier is a
	 * preceding SIBLING, invisible from the field node itself.
	 */
	public function testInlineFieldValueIsNotACandidate(): Void {
		Assert.equals(0, violations(inlineFieldSource(100, 60)).length);
		Assert.equals(1, violations(inlineFieldSource(100, 60).replace('static inline final', 'static final')).length);
	}

	/**
	 * A MODULE-LEVEL `inline final` is the same compile-time constant and breaks the same
	 * `case S:` — but it is a top-level declaration, not a member, so a gate that asked
	 * for a member KIND folded it.
	 */
	public function testModuleLevelInlineValueIsNotACandidate(): Void {
		final literal: String = "'" + ''.rpad('A', 100) + '\\n' + ''.rpad('B', 60) + "'";
		Assert.equals(0, violations('inline final S:String = $literal;\n').length);
		Assert.equals(1, violations('final S:String = $literal;\n').length);
	}

	/**
	 * The modifier run ends at EVERY declaration, not only at a member. Ending it at a
	 * member left the `@:enum` of a deprecated enum abstract set for the rest of the
	 * MODULE — a type declaration being no member kind — so every later type's field
	 * values were silently exempt.
	 */
	public function testEnumAbstractRunEndsAtItsOwnDeclaration(): Void {
		final literal: String = "'" + ''.rpad('A', 100) + '\\n' + ''.rpad('B', 60) + "'";
		Assert.equals(1, violations(deprecatedEnumAbstractSource(4, 4) + '\nclass C {\n\tstatic final S:String = $literal;\n}').length);
	}

	/**
	 * Gate (1): a macro argument is reported but NOT fixed — a macro pattern-matching
	 * `EConst(CString)` breaks silently on a concatenation, and no structural check can
	 * see whether it folds.
	 */
	public function testMacroArgumentIsReportedButNotFixed(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final check: FoldStringLiterals = new FoldStringLiterals();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf(WHITELIST_OPTION) != -1);
		Assert.equals(0, check.fix(files[1].source, vs, new HaxeQueryPlugin()).length);
	}

	/** A macro PROVEN to fold `+` chains of constants is whitelisted by qualified path, and its arguments become fixable. */
	public function testWhitelistedMacroArgumentIsFixed(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}'));
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(files[1].source, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals("'" + ''.rpad('A', 100) + "\\n' + '" + ''.rpad('B', 60) + "'", edits[0].text);
	}

	/** A call the file imports nothing for cannot be routed to an unseen macro, so its arguments fold as usual. */
	public function testPlainCallArgumentIsFixed(): Void {
		Assert.equals(
			"'" + ''.rpad('A', 100) + "\\n' + '" + ''.rpad('B', 60) + "'",
			foldOf(rawSource("'" + ''.rpad('A', 100) + "\\n" + ''.rpad('B', 60) + "'"))
		);
	}

	/**
	 * The gate's second refusal. The index covers only what the INVOCATION reaches, so
	 * linting the caller ALONE cannot see `m.Lang.t`'s `macro` modifier — and reading
	 * that as "not a macro" would rewrite the argument, making `--fix` answer differently
	 * depending on how the linter was called. The file's own `import m.Lang.t` binds the
	 * name, which is what makes the unresolved answer refusable rather than merely
	 * unknown.
	 */
	public function testMacroArgumentStaysRefusedWhenTheDeclarationIsOutOfScope(): Void {
		final caller: { file: String, source: String } = macroArgFiles(100, 60)[1];
		final check: FoldStringLiterals = new FoldStringLiterals();
		final vs: Array<Violation> = check.run([caller], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf(WHITELIST_OPTION) != -1);
		Assert.equals(0, check.fix(caller.source, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * Every spelling that can route the call to an out-of-scope declaration refuses, and
	 * the two that CANNOT do not. The gate reads the import's KIND, not just its path: a
	 * wildcard and a `using` bind every name in the file, which is why an unresolved call
	 * under either is refused whatever it is called.
	 */
	public function testEveryOutOfScopeCallSpellingIsRefused(): Void {
		for (spelling in [
			{ imports: 'import m.Lang.t;', call: 't' },
			{ imports: 'import m.Lang;', call: 'Lang.t' },
			{ imports: 'import m.Lang as L;', call: 'L.t' },
			{ imports: 'import m.*;', call: 'Lang.t' },
			{ imports: 'import m.Lang.*;', call: 't' },
			{ imports: 'using m.Ext;', call: 'x.t' },
			{ imports: '', call: 'm.Lang.t' }
		])
			Assert.isTrue(
				refusedIn(outOfScopeCallSource(spelling.imports, spelling.call)),
				'expected a refusal for ${spelling.imports} ${spelling.call}'
			);
	}

	/**
	 * The refusal costs nothing where the source cannot route the call anywhere unseen: a
	 * bare call the file imports nothing for is local, inherited or global, and a
	 * receiver whose TYPE the index carries is resolved. Asked against the same gate as
	 * the refusals above, so the pair discriminates rather than merely agreeing.
	 */
	public function testResolvableCallsAreNotRefused(): Void {
		Assert.isFalse(refusedIn(outOfScopeCallSource('', 'g2')));
		Assert.isFalse(refusedIn(outOfScopeCallSource('class Lang { public static function t(v:String):String return v; }', 'Lang.t')));
	}

	/** A whitelisted target clears the refusal whichever spelling the call site used — the entry and the call meet by dotted suffix. */
	public function testWhitelistClearsAnOutOfScopeCall(): Void {
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}'));
		for (spelling in [
			{ imports: 'import m.Lang.t;', call: 't' },
			{ imports: 'import m.Lang;', call: 'Lang.t' },
			{ imports: '', call: 'm.Lang.t' }
		]) {
			final src: String = outOfScopeCallSource(spelling.imports, spelling.call);
			final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
			Assert.equals(1, vs.length);
			Assert.equals(1, check.fix(src, vs, new HaxeQueryPlugin()).length, 'expected a fix for ${spelling.imports} ${spelling.call}');
		}
	}

	/**
	 * The whitelist is read from the file's OWN discovered config, not from the run's
	 * first file — one `lint` invocation can span projects that disagree about which
	 * macros fold, and applying one project's claim to another's code rewrites an
	 * argument nobody cleared.
	 */
	public function testWhitelistIsResolvedPerFile(): Void {
		final files: Array<{ file: String, source: String }> = macroArgFiles(100, 60);
		final other: { file: String, source: String } = { file: 'other/D.hx', source: files[1].source };
		final check: FoldStringLiterals = new FoldStringLiterals();
		check.setConfigResolver(path -> LintConfig.parse(path == 'C.hx' ? '{"rules":{"$RULE":{"$WHITELIST_OPTION":["m.Lang.t"]}}}' : '{}'));
		final vs: Array<Violation> = check.run([files[0], files[1], other], new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		Assert.equals(1, check.fix(files[1].source, vs.filter(v -> v.file == 'C.hx'), new HaxeQueryPlugin()).length);
		Assert.equals(0, check.fix(other.source, vs.filter(v -> v.file == other.file), new HaxeQueryPlugin()).length);
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
		Assert.equals("'" + ''.rpad('A', 60) + "\\n' + '" + ''.rpad('B', 40) + "'", foldOf(src));
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
			"\t\t\t'" + ''.rpad('a', 40) + "'",
			"\t\t\t+ '" + ''.rpad('b', 40) + "${x}" + ''.rpad('c', tailLen) + "'",
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
	}

	/**
	 * A `g(<head> + '<aLen a>' + '<bLen b>');` at three tabs, sized so the greedy fill
	 * cannot join `head` to the first text but CAN join the two texts — the shape whose
	 * first group is a lone non-text segment, and so the only one where the leading-bare
	 * gate decides anything.
	 */
	private function bareHeadSource(head: String, aLen: Int, bLen: Int): String {
		return [
			'class C {',
			'\tfunction f(a:Int, b:Int, nnn:String) {',
			'\t\tg(',
			'\t\t\t' + head,
			"\t\t\t+ '" + ''.rpad('A', aLen) + "'",
			"\t\t\t+ '" + ''.rpad('B', bLen) + "'",
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
			"\tvar xxxxx = '" + ''.rpad('A', 60) + "' + name",
			"\t\t+ '" + ''.rpad('B', 60) + "'; // " + ''.rpad('z', 36),
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
			"\t\tvar x = '" + ''.rpad('A', 30) + "' + '" + ''.rpad('B', 30) + "' // one",
			"\t\t\t+ '" + ''.rpad('C', 30) + "';",
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
		return "class C {\n\tfunction f() {\n\t\tg('" + ''.rpad('a', mergedLen - 4) + "' + b);\n\t}\n}";
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	/** A `g(<literal>);` statement at two tabs — the plain host every `\n`-seam fixture measures at. */
	private function rawSource(literal: String): String {
		return 'class C {\n\tfunction f() {\n\t\tg($literal);\n\t}\n}';
	}

	/**
	 * A `g('<aLen A>\n<bLen B>');` at two tabs in `quote` quoting. The literal starts at
	 * column `FIXTURE_INDENT + CALL_HEAD`, so the planner's budget is `FIXTURE_BUDGET`
	 * and the seam sits after `aLen + 4` characters of rendered fragment — under the
	 * budget for the split fixtures, past it for `testSeamPastLimitStillSplitsBestEffort`.
	 */
	private function newlineSource(quote: String, aLen: Int, bLen: Int): String {
		return rawSource(quote + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + quote);
	}

	/** The same over-long literal in `case` PATTERN position, where a concatenation is not legal syntax. */
	private function casePatternSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'class C {\n\tfunction f(s:String) {\n\t\tswitch (s) {\n\t\t\tcase $literal: g(1);\n\t\t\tcase _: g(2);\n\t\t}\n\t}\n}';
	}

	/** The same over-long literal as a parameter DEFAULT, where the compiler requires a constant. */
	private function defaultParamSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'class C {\n\tfunction f(s:String = $literal) {\n\t\tg(s);\n\t}\n}';
	}

	/** The same over-long literal as an enum-abstract VALUE, which its `case` consumers read as a shape. */
	private function enumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'enum abstract E(String) {\n\tvar A = $literal;\n\tvar B = \'b\';\n}';
	}

	/** The same declaration in Haxe's deprecated spelling: a PLAIN abstract carrying an `@:enum` annotation sibling. */
	private function deprecatedEnumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return '@:enum abstract E(String) {\n\tvar A = $literal;\n\tvar B = \'b\';\n}';
	}

	/** The same value one level down, inside a `#if` region — the declaration is no longer its immediate parent. */
	private function guardedEnumAbstractSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'enum abstract E(String) {\n\t#if js\n\tvar A = $literal;\n\t#end\n\tvar B = \'b\';\n}';
	}

	/** The same over-long literal as an `inline` field's value — a compile-time constant at every use site. */
	private function inlineFieldSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'class C {\n\tstatic inline final S:String = $literal;\n}';
	}

	/**
	 * An object-literal entry at three tabs whose value is the over-long literal. The
	 * writer keeps a field's value on the field's own line, so the continuation-column
	 * estimate is refuted by the source itself — `unwrapped`'s shape.
	 */
	private function objectFieldSource(aLen: Int, bLen: Int): String {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return 'class C {\n\tfunction f() {\n\t\tg({\n\t\t\tsomeVeryLongFieldNameIndeed: $literal\n\t\t});\n\t}\n}';
	}

	/**
	 * Two files: a `macro` function `m.Lang.t` and a caller passing it the over-long
	 * literal. Resolution is cross-file, so the macro modifier only reaches the check
	 * through the symbol index built over BOTH.
	 */
	private function macroArgFiles(aLen: Int, bLen: Int): Array<{ file: String, source: String }> {
		final literal: String = "'" + ''.rpad('A', aLen) + '\\n' + ''.rpad('B', bLen) + "'";
		return [
			{
				file: 'm/Lang.hx',
				source: 'package m;\nclass Lang {\n\tmacro public static function t(v:Expr):Expr {\n\t\treturn v;\n\t}\n}'
			},
			{ file: 'C.hx', source: 'import m.Lang.t;\nclass C {\n\tfunction f() {\n\t\tg(t($literal));\n\t}\n}' }
		];
	}

	/**
	 * A `<head>` line, then the over-long literal passed to `<call>(…)` — the shape whose
	 * target the index cannot resolve, since neither `m.Lang` nor `m.Ext` is in the run.
	 * `head` doubles as a place to DECLARE a resolvable type, for the negative control.
	 */
	private function outOfScopeCallSource(head: String, call: String): String {
		final literal: String = "'" + ''.rpad('A', 100) + '\\n' + ''.rpad('B', 60) + "'";
		return '$head\nclass C {\n\tfunction f() {\n\t\th($call($literal));\n\t}\n}';
	}

	/** Whether `src`'s single finding is report-only — the macro gate refused it — as opposed to fixable. */
	private function refusedIn(src: String): Bool {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return check.fix(src, vs, new HaxeQueryPlugin()).length == 0;
	}

	/** `src` fixed, canonicalised and re-linted: the canonical form must be a fixed point of the rule. */
	private function assertFixIsIdempotent(src: String): Void {
		Assert.equals(0, violations(fixedText(src)).length);
	}

	private function violations(src: String): Array<Violation> {
		return new FoldStringLiterals().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The canonical text the fix emits for `src`'s first flagged construct (empty if none). */
	private function foldOf(src: String): String {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
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
