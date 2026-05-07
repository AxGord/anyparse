package unit;

import utest.Assert;
import utest.Test;
import anyparse.core.Doc;
import anyparse.core.D;
import anyparse.core.Renderer;
import anyparse.format.IndentChar;

/**
	Tests for the core Doc IR and its renderer. These are the most
	foundational tests in the project: everything above them (writers,
	formatters, grammars) builds on top of the assumption that the Doc
	layer lays out correctly.
**/
class DocRendererTest extends Test {
	function testEmpty() {
		Assert.equals("", Renderer.render(D.empty(), 80));
	}

	function testText() {
		Assert.equals("hello", Renderer.render(D.text("hello"), 80));
	}

	function testConcat() {
		var doc = D.concat([D.text("hello"), D.text(" "), D.text("world")]);
		Assert.equals("hello world", Renderer.render(doc, 80));
	}

	function testSoftlineFlat() {
		// A group that fits: softlines collapse to nothing, lines become spaces.
		var doc = D.group(D.concat([
			D.text("["),
			D.softline(),
			D.text("1"), D.text(","), D.line(),
			D.text("2"),
			D.softline(),
			D.text("]"),
		]));
		Assert.equals("[1, 2]", Renderer.render(doc, 80));
	}

	function testGroupBreaksWhenTooLong() {
		// Same shape, but width too small → breaks all lines.
		var doc = D.group(D.concat([
			D.text("["),
			D.nest(2, D.concat([
				D.softline(),
				D.text("a"), D.text(","), D.line(),
				D.text("b"), D.text(","), D.line(),
				D.text("c"),
			])),
			D.softline(),
			D.text("]"),
		]));

		// At width 80 everything fits flat.
		Assert.equals("[a, b, c]", Renderer.render(doc, 80));

		// At width 5 we expect a break with indent = 2.
		var expected = "[\n  a,\n  b,\n  c\n]";
		Assert.equals(expected, Renderer.render(doc, 5));
	}

	function testNestedGroups() {
		// Outer array of two inner arrays. Outer doesn't fit, inners do.
		var inner1 = D.group(D.concat([
			D.text("["),
			D.text("1"), D.text(","), D.line(),
			D.text("2"),
			D.text("]"),
		]));
		var inner2 = D.group(D.concat([
			D.text("["),
			D.text("3"), D.text(","), D.line(),
			D.text("4"),
			D.text("]"),
		]));
		var outer = D.group(D.concat([
			D.text("["),
			D.nest(2, D.concat([
				D.softline(),
				inner1, D.text(","), D.line(),
				inner2,
			])),
			D.softline(),
			D.text("]"),
		]));

		// Width 80: everything flat.
		Assert.equals("[[1, 2], [3, 4]]", Renderer.render(outer, 80));

		// Width 10: outer breaks, inners stay flat on their own lines.
		var expected = "[\n  [1, 2],\n  [3, 4]\n]";
		Assert.equals(expected, Renderer.render(outer, 10));
	}

	function testInterspersePreservesElements() {
		var items = [D.text("a"), D.text("b"), D.text("c")];
		var result = D.intersperse(items, D.text(","));
		var doc = D.concat(result);
		Assert.equals("a,b,c", Renderer.render(doc, 80));
	}

	function testInterspersePreservesSingleItem() {
		var items = [D.text("only")];
		var result = D.intersperse(items, D.text(","));
		var doc = D.concat(result);
		Assert.equals("only", Renderer.render(doc, 80));
	}

	function testInterspersePreservesEmpty() {
		var items = [];
		var result = D.intersperse(items, D.text(","));
		var doc = D.concat(result);
		Assert.equals("", Renderer.render(doc, 80));
	}

	function testRenderWithTabIndent() {
		// Nest columns align to tabWidth → pure tabs, no trailing spaces.
		final doc:Doc = D.group(D.concat([
			D.text("{"),
			D.nest(4, D.concat([
				D.softline(),
				D.text("a"), D.text(","), D.line(),
				D.text("b"),
			])),
			D.softline(),
			D.text("}"),
		]));
		// Force break by narrowing the width.
		final expected:String = "{\n\ta,\n\tb\n}";
		Assert.equals(expected, Renderer.render(doc, 5, Tab, 4));
	}

	function testRenderWithTabIndentNested() {
		// Two-level Nest(4) + Nest(4) → 8 columns → 2 tabs at the deep level.
		final inner:Doc = D.nest(4, D.concat([
			D.softline(),
			D.text("x"),
		]));
		final doc:Doc = D.group(D.concat([
			D.text("{"),
			D.nest(4, D.concat([
				D.softline(),
				D.text("{"),
				inner,
				D.softline(),
				D.text("}"),
			])),
			D.softline(),
			D.text("}"),
		]));
		final expected:String = "{\n\t{\n\t\tx\n\t}\n}";
		Assert.equals(expected, Renderer.render(doc, 1, Tab, 4));
	}

	function testRenderWithTabIndentRemainderSpaces() {
		// Nest column not aligned to tabWidth → floor(n/tw) tabs + remainder spaces.
		final doc:Doc = D.group(D.concat([
			D.text("["),
			D.nest(3, D.concat([
				D.softline(),
				D.text("a"),
			])),
			D.softline(),
			D.text("]"),
		]));
		// tabWidth=2 → 3 cols → 1 tab + 1 space.
		final expected:String = "[\n\t a\n]";
		Assert.equals(expected, Renderer.render(doc, 2, Tab, 2));
	}

	function testRenderWithCustomLineEnd() {
		final doc:Doc = D.group(D.concat([
			D.text("["),
			D.nest(2, D.concat([
				D.softline(),
				D.text("a"),
			])),
			D.softline(),
			D.text("]"),
		]));
		final expected:String = "[\r\n  a\r\n]";
		Assert.equals(expected, Renderer.render(doc, 1, Space, 1, '\r\n'));
	}

	function testRenderFinalNewlineAppendedWhenMissing() {
		final doc:Doc = D.text("hello");
		Assert.equals("hello\n", Renderer.render(doc, 80, Space, 1, '\n', true));
	}

	function testRenderFinalNewlineNotDuplicated() {
		// Output already ends in lineEnd from a forced break → no double newline.
		final doc:Doc = D.group(D.concat([
			D.text("a"),
			D.line(),
			D.text(""),
		]));
		final out:String = Renderer.render(doc, 1, Space, 1, '\n', true);
		Assert.equals("a\n", out);
	}

	function testRenderFinalNewlineDisabledByDefault() {
		// Default render(doc, width) must not append a trailing newline.
		final doc:Doc = D.text("hello");
		Assert.equals("hello", Renderer.render(doc, 80));
	}

	function testRenderTrailingWhitespaceDisabledByDefault() {
		// Consecutive break-mode Lines at non-zero indent produce a bare
		// blank line: the first hardline's pending indent is silently
		// overwritten by the second, and flushed only when the next text
		// arrives. This is the pre-ω-trailing-whitespace default.
		final doc:Doc = D.nest(2, D.concat([
			D.hardline(),
			D.text("a"),
			D.hardline(),
			D.hardline(),
			D.text("b"),
		]));
		Assert.equals("\n  a\n\n  b", Renderer.render(doc, 80));
	}

	function testRenderTrailingWhitespaceFlushesIndentOnBlankLines() {
		// With trailingWhitespace=true the first hardline's pending indent
		// is flushed before the second hardline's lineEnd, so the blank
		// row carries the enclosing block's indent.
		final doc:Doc = D.nest(2, D.concat([
			D.hardline(),
			D.text("a"),
			D.hardline(),
			D.hardline(),
			D.text("b"),
		]));
		final out:String = Renderer.render(doc, 80, Space, 1, '\n', false, true);
		Assert.equals("\n  a\n  \n  b", out);
	}

	// ω-break-group: hardline-force-not-fit. A Group whose own inner
	// contains a hardline (NOT shielded behind a BodyGroup) must always
	// break, even if the total flat width fits in the budget. Without
	// the force, short hardline-bearing content (a 2-line block body)
	// would fit by length alone and the renderer would emit raw `\n`
	// without indent.
	function testGroupForcesBreakOnDirectHardlineEvenWhenContentFits() {
		final inner:Doc = D.nest(1, D.concat([
			D.text("a"),
			D.hardline(),
			D.text("b"),
		]));
		final actual:String = Renderer.render(D.group(inner), 80, Tab, 1);
		Assert.equals("a\n\tb", actual);
	}

	// ω-break-group: a `Group` wrapping `Nest( BodyGroup{ block-body Doc
	// containing hardlines } )`. The outer Group defers the BodyGroup in
	// `fitsFlat` measurement, so the call-arg-shaped outer stays inline
	// (no break around `(...)`). The inner BodyGroup measures its own
	// hardlines (force-not-fit), commits to MBreak, and lays the body
	// out at the surrounding `Nest`'s indent — which the BG inherits as
	// MBreak from its own decision, so the inner Nest bumps correctly.
	// This is the synthetic shape behind issue_552
	// (`trace(switch foo { case … })`) and the arrow-body-in-call family
	// after `triviaBlockStarExpr` BG-wraps its block-body emission.
	// Fill (Wadler fillSep): items join with `sep` on the same line as long
	// as each fits in the remaining budget; on overflow the renderer breaks
	// the offending separator at the Fill's indent and resumes packing.
	function testFillAllFlat() {
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [D.text("a"), D.text("b"), D.text("c")];
		Assert.equals("a, b, c", Renderer.render(D.fill(items, sep), 80));
	}

	function testFillAllBreakAtNarrowWidth() {
		// Width 1: every successive item overflows so every sep breaks.
		// Indent comes from the surrounding Nest — Fill itself does not
		// add depth.
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [D.text("aa"), D.text("bb"), D.text("cc")];
		final doc:Doc = D.nest(2, D.fill(items, sep));
		Assert.equals("aa,\n  bb,\n  cc", Renderer.render(doc, 1));
	}

	function testFillPacksMultiplePerLine() {
		// Width 8 fits "aa, bb" (6 cols) but ", cc" overflows (need 4, have
		// 2). After breaking to col 2, "cc, dd" fits exactly (8 cols), then
		// ", ee" overflows again so the last item starts a new line.
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [
			D.text("aa"), D.text("bb"), D.text("cc"), D.text("dd"), D.text("ee"),
		];
		final doc:Doc = D.nest(2, D.fill(items, sep));
		Assert.equals("aa, bb,\n  cc, dd,\n  ee", Renderer.render(doc, 8));
	}

	function testFillFirstItemAlwaysInline() {
		// items[0] is always emitted at entry column, even when it alone
		// already overflows. The fill decision starts at items[1].
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [D.text("longlonglong"), D.text("x")];
		Assert.equals("longlonglong,\n  x", Renderer.render(D.nest(2, D.fill(items, sep)), 5));
	}

	function testFillWithBodyGroupItemPacksByHeader() {
		// Item shape `name -> { body }` where the body is a BodyGroup with
		// hardlines. Per-item flat measurement defers BodyGroups, so the
		// item's "header" width drives packing — three lambdas with short
		// headers pack on the same line, body breaks aside.
		function lambda(name:String):Doc {
			return D.concat([
				D.text(name + " -> "),
				BodyGroup(D.concat([
					D.text("{"),
					D.nest(1, D.concat([D.hardline(), D.text("body;")])),
					D.hardline(),
					D.text("}"),
				])),
			]);
		}
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [lambda("x"), lambda("y")];
		// Outer width 80: both lambda headers (`x -> {` and `y -> {`)
		// fit on the same line; bodies break inside their BG. The lambdas'
		// internal `Nest(1)` drives body indent without a Fill-level Nest.
		Assert.equals(
			"x -> {\n\tbody;\n}, y -> {\n\tbody;\n}",
			Renderer.render(D.fill(items, sep), 80, Tab, 1)
		);
	}

	function testFillWrappedInGroupFlatWhenAllFits() {
		// Outer Group's flat measurement of Fill = items joined by sep flat.
		// If everything fits, Group commits to flat → Fill in MFlat → all
		// items packed with sep flat.
		final sep:Doc = D.concat([D.text(","), D.line()]);
		final items:Array<Doc> = [D.text("a"), D.text("b"), D.text("c")];
		final doc:Doc = D.group(D.fill(items, sep));
		Assert.equals("a, b, c", Renderer.render(doc, 80));
	}

	function testCallArgOuterStaysFlatWhileBodyGroupBreaksCorrectly() {
		final blockBody:Doc = BodyGroup(D.concat([
			D.text("{"),
			D.nest(1, D.concat([D.hardline(), D.text("case A: x;")])),
			D.hardline(),
			D.text("}"),
		]));
		final doc:Doc = D.group(D.concat([
			D.text("trace("),
			D.nest(1, blockBody),
			D.text(")"),
		]));
		// Outer `(`...`)` stays inline; case body indents under the Nest
		// (depth 1) that the inner BG inherits via its own MBreak choice.
		Assert.equals("trace({\n\tcase A: x;\n})", Renderer.render(doc, 80, Tab, 1));
	}

	// `IfWidthExceeds(n, brk, flat)` is the column-aware sibling of
	// `IfBreak`. The renderer probes `column + flatWidth(flatDoc)`
	// against `n` at layout time: when the threshold is reached the
	// brk shape fires, otherwise flat. Independent of the enclosing
	// Group's flat/break mode (slice ω-ifwidthexceeds-infra).

	function testIfWidthExceedsAtColumnZeroBelowThreshold() {
		// At col 0 with 5-char content and threshold 10, col + flat = 5
		// — under threshold → flat side fires.
		final doc:Doc = IfWidthExceeds(10, D.text("BREAK"), D.text("FLATX"));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsAtColumnZeroReachesThreshold() {
		// At col 0 with 10-char content and threshold 10, col + flat = 10
		// — reaches threshold (`>= n`) → brk fires. Renderer probe is
		// `col + flatTokenWidth(flatDoc) >= n` (boundary inclusive).
		final doc:Doc = IfWidthExceeds(10, D.text("BREAKBREAK"), D.text("FLATXFLATX"));
		Assert.equals("BREAKBREAK", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsShiftedByPrefix() {
		// Prefix "abcdefgh" (8 cols) puts pen at col 8; with threshold
		// 10, even short 3-char content (col + flat = 11) crosses — brk
		// fires. Both shapes have same width so the test is purely
		// about the column-aware probe.
		final doc:Doc = D.concat([
			D.text("abcdefgh"),
			IfWidthExceeds(10, D.text("BRK"), D.text("FLT")),
		]);
		Assert.equals("abcdefghBRK", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsShiftedShortPrefix() {
		// Same shape, prefix only 2 cols → col + flat = 5, under
		// threshold 10 → flat fires.
		final doc:Doc = D.concat([
			D.text("ab"),
			IfWidthExceeds(10, D.text("BRK"), D.text("FLT")),
		]);
		Assert.equals("abFLT", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsForwardsToFlatInFitsFlat() {
		// Outer Group's fitsFlat measurement walks the IfWidthExceeds
		// flat side; the Group's own break/flat decision is unaffected
		// by the column-aware probe. Here flat side is 5 cols, brk
		// side is 50 cols. Outer Group with budget 80 fits the flat
		// shape — Group commits to MFlat, IfWidthExceeds probes col 0
		// vs threshold 10 → 5 < 10 → flat fires.
		final brk:Doc = D.text("BREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAK");
		final flat:Doc = D.text("FLATX");
		final doc:Doc = D.group(IfWidthExceeds(10, brk, flat));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsThresholdLessThanColumnFiresBreak() {
		// Sentinel: when `col >= n` already, the rule fires regardless
		// of flat content width — the column has already crossed the
		// threshold. Threshold 5 with 10-col prefix puts col past the
		// threshold before any flat content is measured.
		final doc:Doc = D.concat([
			D.text("0123456789"),
			IfWidthExceeds(5, D.text("BRK"), D.text("FLT")),
		]);
		Assert.equals("0123456789BRK", Renderer.render(doc, 80));
	}

	function testIfWidthExceedsFlatHardlinesIgnoredInProbe() {
		// `BinaryChainEmit`-style flat side: a multi-line shape with
		// forced hardlines (each operand on its own continuation line).
		// The cascade rule `lineLength >= n` semantic asks "does the
		// natural inline width reach n?" — hardlines count as zero width
		// in that probe (otherwise `fitsFlat`-style budget walk would
		// always refuse-to-flatten and pick brk regardless of column).
		// At col 0, flat side's token width is 6 ("aabbcc"), threshold
		// 10 — 0 + 6 < 10, so flat fires.
		final flatShape:Doc = D.concat([
			D.text("aa"), D.hardline(), D.text("bb"), D.hardline(), D.text("cc"),
		]);
		final brkShape:Doc = D.text("BRK");
		final doc:Doc = IfWidthExceeds(10, brkShape, flatShape);
		Assert.equals("aa\nbb\ncc", Renderer.render(doc, 80));
	}

	// `IfFirstLineExceeds(n, brk, flat)` is the first-line-aware sibling
	// of `IfWidthExceeds`. The probe formula is `col +
	// flatTokenWidthFirstLine(flatDoc) >= n` — the first-line walk caps
	// at the first forced hardline inside `flatDoc`, so a multi-line
	// subtree whose first line fits stays inline (this branch picks
	// `flat`) even though its total flat width would exceed `n`. Used by
	// `bodyPolicyWrap`'s width-aware path to keep `return <multi-line
	// if-expr>` glued to the kw when the head fits (slice
	// ω-issue-257-firstline).

	function testIfFirstLineExceedsAtColumnZeroBelowThreshold() {
		// At col 0 with 5-char single-line flat and threshold 10, col +
		// firstLine = 5 — under threshold → flat fires. Same arithmetic
		// as the `IfWidthExceeds` sibling for hardline-free shapes.
		final doc:Doc = IfFirstLineExceeds(10, D.text("BREAK"), D.text("FLATX"));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}

	function testIfFirstLineExceedsAtColumnZeroReachesThreshold() {
		// At col 0 with 10-char single-line flat and threshold 10, col +
		// firstLine = 10 — reaches threshold (`>= n`) → brk fires.
		final doc:Doc = IfFirstLineExceeds(10, D.text("BREAKBREAK"), D.text("FLATXFLATX"));
		Assert.equals("BREAKBREAK", Renderer.render(doc, 80));
	}

	function testIfFirstLineExceedsCapsAtFirstHardline() {
		// CRITICAL: this is the difference from `IfWidthExceeds`. flat
		// side is multi-line via forced hardlines; total token width
		// would be 12 ("aabbbbbbbbbbcc" minus hardlines), but the
		// first-line walk aborts at the first hardline and returns just
		// "aa" (2 cols). At col 0 with threshold 10, 0 + 2 < 10 → flat
		// fires (the multi-line shape renders verbatim). The
		// `IfWidthExceeds` sibling on the same input would also pick
		// flat at col 0, but for different reasons; the diverging
		// behaviour shows up under prefix shift (next test).
		final flatShape:Doc = D.concat([
			D.text("aa"), D.hardline(), D.text("bbbbbbbbbb"), D.hardline(), D.text("cc"),
		]);
		final brkShape:Doc = D.text("BRK");
		final doc:Doc = IfFirstLineExceeds(10, brkShape, flatShape);
		Assert.equals("aa\nbbbbbbbbbb\ncc", Renderer.render(doc, 80));
	}

	function testIfFirstLineExceedsPrefixedFirstLineFits() {
		// 6-col prefix puts pen at col 6; flat side first line is "aaa"
		// (3 cols) before the hardline, total firstLine probe = 6 + 3 =
		// 9 < threshold 10 → flat fires. Even though the full flat shape
		// has 50+ cols of content beyond the hardline, only the first
		// line is measured. This is the sameLine.returnBody=same shape
		// in microcosm: `return ` head + multi-line if-expr body whose
		// first line fits.
		final flatShape:Doc = D.concat([
			D.text("aaa"), D.hardline(), D.text("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
		]);
		final brkShape:Doc = D.text("BRK");
		final doc:Doc = D.concat([
			D.text("prefix"),
			IfFirstLineExceeds(10, brkShape, flatShape),
		]);
		Assert.equals("prefixaaa\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", Renderer.render(doc, 80));
	}

	function testIfFirstLineExceedsPrefixedFirstLineOverflows() {
		// 8-col prefix + flat first line "aaaa" (4 cols) = 12 >= threshold
		// 10 → brk fires. Even though the flat side's first line by
		// itself is short, combined with the prefix it crosses the
		// threshold. Demonstrates the column-aware nature of the probe
		// is preserved (same as `IfWidthExceeds`).
		final flatShape:Doc = D.concat([
			D.text("aaaa"), D.hardline(), D.text("bb"),
		]);
		final brkShape:Doc = D.text("BRK");
		final doc:Doc = D.concat([
			D.text("12345678"),
			IfFirstLineExceeds(10, brkShape, flatShape),
		]);
		Assert.equals("12345678BRK", Renderer.render(doc, 80));
	}

	function testIfFirstLineExceedsForwardsToFlatInFitsFlat() {
		// Outer Group's fitsFlat measurement walks the IfFirstLineExceeds
		// flat side (mirrors `IfWidthExceeds` semantic). The probe is
		// renderer-side, transparent to wrap-engine width measurement.
		// Here flat side is 5 cols (no hardline), brk side is 50 cols.
		// Outer Group with budget 80 fits the flat shape — Group commits
		// to MFlat, the probe at col 0 vs threshold 10 evaluates 5 < 10
		// → flat fires.
		final brk:Doc = D.text("BREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAK");
		final flat:Doc = D.text("FLATX");
		final doc:Doc = D.group(IfFirstLineExceeds(10, brk, flat));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}

	// `IfLineExceeds(n, brk, flat)` is the line-length-aware sibling of
	// `IfWidthExceeds`. The probe formula is `col +
	// flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n`
	// — extends the column-aware probe with a lookahead over the rest
	// of the rendering stack up to the next forced hardline. Closes the
	// Wadler-style local-Group blindspot where an inner `Group(IfBreak)`
	// decides flat even though enclosing expression pushes the line past
	// `lineWidth` (slice ω-iflineexceeds-infra).

	function testIfLineExceedsAtColumnZeroBelowThreshold() {
		// At col 0 with 5-char flat content and no rest-of-stack,
		// 0 + 5 + 0 = 5 < 10 → flat fires. Same arithmetic as the
		// `IfWidthExceeds` sibling when stack is empty after the probe.
		final doc:Doc = IfLineExceeds(10, D.text("BREAK"), D.text("FLATX"));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}

	function testIfLineExceedsSelfAloneCrossesThreshold() {
		// At col 0 with 10-char flat content and no rest-of-stack,
		// 0 + 10 + 0 = 10 >= 10 → brk fires. Self-only width is enough.
		final doc:Doc = IfLineExceeds(10, D.text("BREAKBREAK"), D.text("FLATXFLATX"));
		Assert.equals("BREAKBREAK", Renderer.render(doc, 80));
	}

	function testIfLineExceedsCombinedCrossesThreshold() {
		// CRITICAL: this is the difference from `IfWidthExceeds`. Self
		// width is 5 cols (would fire flat under sibling probe); but the
		// rest-of-stack contains another 8 cols of content. At col 0,
		// 0 + 5 + 8 = 13 >= 10 → brk fires. The lookahead captures the
		// trailing content that will land on the same line.
		final doc:Doc = D.concat([
			IfLineExceeds(10, D.text("BRKBR"), D.text("FLATX")),
			D.text("trailing"),
		]);
		Assert.equals("BRKBRtrailing", Renderer.render(doc, 80));
	}

	function testIfLineExceedsHardlineInRestStopsLookahead() {
		// Hardline in rest-of-stack caps the lookahead: content after
		// the hardline doesn't count toward the line-length probe.
		// Self width 5 + rest "ab" before hardline = 7 < threshold 10
		// → flat fires. The 102-col text after the hardline is on a
		// different line, irrelevant to the probe.
		final doc:Doc = D.concat([
			IfLineExceeds(10, D.text("BRKBR"), D.text("FLATX")),
			D.text("ab"),
			D.hardline(),
			D.text("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
		]);
		Assert.equals("FLATXab\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", Renderer.render(doc, 200));
	}

	function testIfLineExceedsBodyGroupInRestDeferred() {
		// `BodyGroup` content in rest-of-stack is deferred (zero-width
		// contribution) — mirrors `fitsFlat` Departure 2. Without BG
		// defer, a multi-line block body inflated the lookahead and
		// triggered brk regardless of the body's actual layout.
		// Here self width 5 + BG (zero) + 2 trailing chars = 7 < 10 →
		// flat fires. The BG renders as its own subtree separately.
		final body:Doc = BodyGroup(D.concat([
			D.text("{"),
			D.nest(1, D.concat([D.hardline(), D.text("verylongbody")])),
			D.hardline(),
			D.text("}"),
		]));
		final doc:Doc = D.concat([
			IfLineExceeds(10, D.text("BRKBR"), D.text("FLATX")),
			body,
			D.text("ab"),
		]);
		// BG's inner has hardlines so it commits to MBreak — body indents
		// at one tab via the inner Nest. The probe sees zero width for BG
		// (deferred per `flatTokenWidthOfRestStack`'s BodyGroup arm).
		Assert.equals("FLATX{\n\tverylongbody\n}ab", Renderer.render(doc, 80, Tab, 1));
	}

	function testIfLineExceedsForwardsToFlatInFitsFlat() {
		// Outer Group's fitsFlat measurement walks the `IfLineExceeds`
		// flat side (mirrors sister primitives). Here flat side is 5
		// cols, brk side is 50 cols. Outer Group with budget 80 fits
		// the flat shape — commits to MFlat. The line-length probe at
		// col 0 with rest-empty evaluates 5 < 10 → flat fires
		// independently of the Group's decision.
		final brk:Doc = D.text("BREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAKBREAK");
		final flat:Doc = D.text("FLATX");
		final doc:Doc = D.group(IfLineExceeds(10, brk, flat));
		Assert.equals("FLATX", Renderer.render(doc, 80));
	}
}
