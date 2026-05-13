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

	function testGroupRestProbeEmptyStackBehavesLikeGroup() {
		// ω-group-rest-probe: with nothing trailing, the rest-probe variant
		// must behave identically to plain Group — restW returns 0 from
		// an empty stack, so the fit decision sees the same budget.
		final inner:Doc = Concat([Text('['), Text('a'), Text(','), Line(' '), Text('b'), Text(']')]);
		final groupDoc:Doc = Group(inner);
		final probeDoc:Doc = GroupWithRestProbe(inner);

		// Width 80: both fit flat.
		Assert.equals('[a, b]', Renderer.render(groupDoc, 80));
		Assert.equals('[a, b]', Renderer.render(probeDoc, 80));

		// Width 4: both break (`[a, b]` is 6 chars > 4).
		Assert.equals('[a,\nb]', Renderer.render(groupDoc, 4));
		Assert.equals('[a,\nb]', Renderer.render(probeDoc, 4));
	}

	function testGroupRestProbeBreaksWhenTrailingContent() {
		// ω-group-rest-probe: when significant content trails on the same
		// line, the probe variant prefers MBreak over MFlat — even though
		// the Group's own content fits flat in the remaining budget.
		final groupContent:Doc = Concat([Text('['), Text('a'), Text(','), Line(' '), Text('b'), Text(']')]);
		final trailing:Doc = Text(' = LongTrailingContentThatPushesPastWidth');

		final plainGroup:Doc = Concat([Group(groupContent), trailing]);
		final probeGroup:Doc = Concat([GroupWithRestProbe(groupContent), trailing]);

		// Width 40: plain Group fits its own 6 chars and stays flat; the
		// trailing content overflows the line WITHOUT triggering a break
		// inside the Group (probe-blind behavior).
		final plainOut:String = Renderer.render(plainGroup, 40);
		Assert.equals('[a, b] = LongTrailingContentThatPushesPastWidth', plainOut);

		// Same width, probe variant: the rest-of-stack walker sees the
		// trailing text width, subtracts from the budget — Group's 6 chars
		// no longer fit, the Group breaks.
		final probeOut:String = Renderer.render(probeGroup, 40);
		Assert.equals('[a,\nb] = LongTrailingContentThatPushesPastWidth', probeOut);
	}

	function testGroupRestProbeForceFlatPropagation() {
		// ω-group-rest-probe: inside a Flatten region, the rest-probe is
		// bypassed (same as plain Group's force-flat short-circuit). The
		// inner content renders flat regardless of trailing content.
		final inner:Doc = Concat([Text('['), Text('a'), Text(','), Line(' '), Text('b'), Text(']')]);
		final trailing:Doc = Text(' = LongTrailingContentThatPushesPastWidth');
		final flatRegion:Doc = Flatten(Concat([GroupWithRestProbe(inner), trailing]));

		// Width 40: probe would normally break (per previous test), but
		// Flatten forces MFlat throughout.
		Assert.equals('[a, b] = LongTrailingContentThatPushesPastWidth', Renderer.render(flatRegion, 40));
	}

	function testFillRestProbeEmptyStackBehavesLikeFill() {
		// ω-fill-rest-probe: with nothing trailing, the rest-probe variant
		// must behave identically to plain Fill — restW returns 0 from an
		// empty stack, so the per-item-fit decision sees the same budget.
		// Bare Fill at top of stack — outer frame mode is MBreak, so Fill
		// enters its per-item FillCont path (the probe consumer) directly,
		// without an outer Group flipping it to all-flat.
		final items:Array<Doc> = [Text('aa'), Text('bb'), Text('cc')];
		final sep:Doc = Concat([Text(','), Line(' ')]);
		final fillDoc:Doc = Fill(items, sep);
		final probeDoc:Doc = FillWithRestProbe(items, sep);

		// Width 80: per-item probes all fit; both pack inline.
		Assert.equals('aa, bb, cc', Renderer.render(fillDoc, 80));
		Assert.equals('aa, bb, cc', Renderer.render(probeDoc, 80));

		// Width 5: per-item probes all fail; both break per-item the same way.
		Assert.equals('aa,\nbb,\ncc', Renderer.render(fillDoc, 5));
		Assert.equals('aa,\nbb,\ncc', Renderer.render(probeDoc, 5));
	}

	function testFillRestProbeBreaksWhenTrailingContent() {
		// ω-fill-rest-probe: when significant content trails on the same
		// line, the probe variant breaks BEFORE THE LAST ITEM — fork's
		// `wrapFillLine2AfterLast` semantic: pack items normally; only
		// the last item's probe reserves room for the rest-of-line tail.
		// Middle items break only when they themselves overflow.
		//
		// Bare Fill (no outer Group): an enclosing `Group(Fill(...))` whose
		// inner subtree fits flat in the budget commits to MFlat, collapsing
		// Fill to the all-flat branch — FillCont never built, probe never
		// fires. The slice's mech lives in FillCont resumption. For the
		// real-world consumer (typedef LHS+RHS), `GroupWithRestProbe` (slice
		// 1) flips the outer Group to MBreak via its own rest-of-stack probe
		// — this test exercises the Fill-layer probe in isolation.
		final items:Array<Doc> = [Text('aa'), Text('bb'), Text('cc')];
		final sep:Doc = Concat([Text(','), Line(' ')]);
		final trailing:Doc = Text(' = LongTrailingContentThatPushesPastWidth');

		final plainFill:Doc = Concat([Fill(items, sep), trailing]);
		final probeFill:Doc = Concat([FillWithRestProbe(items, sep), trailing]);

		// Width 30: plain Fill packs all items inline (per-item probe sees
		// only `width - col - tailReserve`); rest-of-line trailing tail
		// overflows the line WITHOUT triggering a per-item break.
		final plainOut:String = Renderer.render(plainFill, 30);
		Assert.equals('aa, bb, cc = LongTrailingContentThatPushesPastWidth', plainOut);

		// Same width, probe variant: only the LAST item's probe subtracts
		// `restW` (= 41, the trailing text width). Item 1 (`bb`, middle)
		// fits without restW pressure → packs. Item 2 (`cc`, last) probes
		// `width - col - 0 - 41 = -17 < 4` → BREAK before `cc`.
		final probeOut:String = Renderer.render(probeFill, 30);
		Assert.equals('aa, bb,\ncc = LongTrailingContentThatPushesPastWidth', probeOut);
	}

	function testFillRestProbeForceFlatPropagation() {
		// ω-fill-rest-probe: inside a Flatten region, the rest-probe is
		// bypassed (same as plain Fill's force-flat short-circuit). All
		// items render flat regardless of trailing content.
		final items:Array<Doc> = [Text('aa'), Text('bb'), Text('cc')];
		final sep:Doc = Concat([Text(','), Line(' ')]);
		final trailing:Doc = Text(' = LongTrailingContentThatPushesPastWidth');
		final flatRegion:Doc = Flatten(Concat([FillWithRestProbe(items, sep), trailing]));

		// Width 30: probe would normally break per-item (per previous
		// test), but Flatten forces MFlat throughout.
		Assert.equals('aa, bb, cc = LongTrailingContentThatPushesPastWidth', Renderer.render(flatRegion, 30));
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

	function testFlattenCollapsesBlockShape() {
		// `{ <hardline>nest(stmt;)<hardline> }` flattens to `{stmt;}` —
		// the canonical use case (slice ω-expression-if-with-blocks).
		final body:Doc = D.concat([
			D.text('{'),
			D.nest(1, D.concat([D.hardline(), D.text('"";')])),
			D.hardline(),
			D.text('}'),
		]);
		Assert.equals('{"";}', Renderer.render(D.flatten(body), 80));
	}

	function testFlattenPicksFlatSideOfIfBreak() {
		// IfBreak / IfWidthExceeds / IfFirstLineExceeds / IfLineExceeds
		// all collapse to their flat side regardless of width.
		final doc:Doc = D.concat([
			IfBreak(D.text('BRK1'), D.text('flatA')),
			IfWidthExceeds(0, D.text('BRK2'), D.text('flatB')),
			IfFirstLineExceeds(0, D.text('BRK3'), D.text('flatC')),
			IfLineExceeds(0, D.text('BRK4'), D.text('flatD')),
		]);
		Assert.equals('flatAflatBflatCflatD', Renderer.render(D.flatten(doc), 80));
	}

	function testFlattenForcesGroupFlatRegardlessOfWidth() {
		// A Group with break-mode hardlines and break-mode-only width
		// would normally pick brk shape under tight budget. After
		// flatten, the inner content collapses to its flat-mode shape.
		final inner:Doc = D.concat([
			D.text('a'), D.line(), D.text('b'), D.line(), D.text('c'),
		]);
		final doc:Doc = D.group(inner);
		// Width 3 forces brk in normal render: "a\nb\nc".
		Assert.equals('a\nb\nc', Renderer.render(doc, 3));
		// flatten pulls the flat shape regardless: "a b c".
		Assert.equals('a b c', Renderer.render(D.flatten(doc), 3));
	}

	function testFlattenDropsNestIndent() {
		// `Nest(1, hardline + text)` after flatten loses the indent
		// (irrelevant in flat mode) AND drops the hardline.
		final doc:Doc = D.nest(1, D.concat([D.hardline(), D.text('inner')]));
		Assert.equals('inner', Renderer.render(D.flatten(doc), 80));
	}

	function testFlattenFillIntersperseSep() {
		// `Fill(items, sep)` flattens into Concat with flatten(sep)
		// interspersed between flatten(items).
		final doc:Doc = D.fill([D.text('x'), D.text('y'), D.text('z')], D.line());
		// flatten(D.line()) → Text(' ') (Line(' ') with non-`\n` flat).
		Assert.equals('x y z', Renderer.render(D.flatten(doc), 80));
	}

	function testFlattenOptHardlineDrops() {
		// OptHardline / OptHardlineSkipAtOpenDelim drop entirely;
		// OptSpace becomes Text(s).
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardline,
			D.optSpace(' '),
			D.text('b'),
			OptHardlineSkipAtOpenDelim,
			D.text('c'),
		]);
		Assert.equals('a bc', Renderer.render(D.flatten(doc), 80));
	}

	// ω-force-flat-engine slice B: render-time `Doc.Flatten(inner)` /
	// `Doc.WrapBoundary(inner)` markers. Distinct from `D.flatten` (a
	// structural transform that rewrites the tree); the ctors below
	// preserve the input shape and let the renderer's `forceFlat`
	// dispatch interpret them at emit time. Tests pin the dispatch
	// behaviour now so slice C/D wiring can rely on it.

	function testRenderFlattenForcesGroupFlatAtNarrowWidth() {
		// Without Flatten: a Group with two `D.line()` separators at
		// width=3 commits to MBreak (`a\nb\nc`). With Flatten wrapping
		// the same Group, `fitsFlat` is skipped and the Group renders
		// as MFlat regardless of width — softlines emit their flat
		// substring (' ' for `D.line()`).
		final inner:Doc = D.concat([
			D.text('a'), D.line(), D.text('b'), D.line(), D.text('c'),
		]);
		final group:Doc = D.group(inner);
		Assert.equals('a\nb\nc', Renderer.render(group, 3));
		Assert.equals('a b c', Renderer.render(Flatten(group), 3));
	}

	function testRenderFlattenPicksFlatBranchOfEveryIfStar() {
		// All five branch-or-flat primitives (`IfBreak`, `IfWidthExceeds`,
		// `IfFirstLineExceeds`, `IfLineExceeds`, `IfFullLineExceeds`)
		// pick `flatDoc` inside a `Flatten` region — the probes are
		// skipped entirely. Thresholds of `0` would normally fire `brk`.
		final inside:Doc = D.concat([
			IfBreak(D.text('BRK1'), D.text('a')),
			IfWidthExceeds(0, D.text('BRK2'), D.text('b')),
			IfFirstLineExceeds(0, D.text('BRK3'), D.text('c')),
			IfLineExceeds(0, D.text('BRK4'), D.text('d')),
			IfFullLineExceeds(0, D.text('BRK5'), D.text('e')),
		]);
		Assert.equals('abcde', Renderer.render(Flatten(inside), 80));
	}

	function testRenderFlattenDropsOptHardlineKeepsOptSpace() {
		// Inside Flatten, `OptHardline` and `OptHardlineSkipAtOpenDelim`
		// are dropped entirely; `OptSpace(' ')` still emits its space;
		// `OptSpaceSkipAfterHardline` emits a space (no preceding
		// hardline can exist inside the force-flat region).
		final inside:Doc = D.concat([
			D.text('a'),
			OptHardline,
			D.optSpace(' '),
			D.text('b'),
			OptHardlineSkipAtOpenDelim,
			D.optSpaceSkipAfterHardline(),
			D.text('c'),
		]);
		Assert.equals('a b c', Renderer.render(Flatten(inside), 80));
	}

	function testRenderFlattenFillJoinsAllFlat() {
		// Inside Flatten, `Fill(items, sep)` skips per-item-fit dispatch
		// and emits items interspersed with `sep` in MFlat. The `sep`
		// (`D.line()`) renders as its flat substring ' '.
		final fill:Doc = D.fill([D.text('x'), D.text('y'), D.text('z')], D.line());
		Assert.equals('x y z', Renderer.render(Flatten(fill), 3));
	}

	function testRenderWrapBoundaryResetsForceFlatInsideFlatten() {
		// `WrapBoundary` clears `forceFlat` for its subtree. A Group
		// nested inside `Flatten(WrapBoundary(...))` decides flat/break
		// normally — at width=3, the boundary-wrapped Group reverts to
		// MBreak because `fitsFlat` runs again.
		final inner:Doc = D.concat([
			D.text('a'), D.line(), D.text('b'), D.line(), D.text('c'),
		]);
		final wrapped:Doc = WrapBoundary(D.group(inner));
		// Outside Flatten, WrapBoundary is a no-op pass-through.
		Assert.equals('a\nb\nc', Renderer.render(wrapped, 3));
		// Inside Flatten, the boundary resets force-flat so the inner
		// Group's `fitsFlat` fires and picks MBreak at width=3.
		Assert.equals('a\nb\nc', Renderer.render(Flatten(wrapped), 3));
	}

	function testRenderNestedFlattenIsIdempotent() {
		// `Flatten(Flatten(x))` is the same as `Flatten(x)` — pushing
		// `forceFlat=true` over an already-`true` frame is a no-op.
		final inner:Doc = D.group(D.concat([
			D.text('a'), D.line(), D.text('b'),
		]));
		Assert.equals(
			Renderer.render(Flatten(inner), 3),
			Renderer.render(Flatten(Flatten(inner)), 3)
		);
	}

	// ω-opthardlineskipbeforehardline: forward-looking opt-hardline.
	// `OptHardlineSkipBeforeHardline` defers `\n+indent` emit until
	// the next content-bearing follower fires; an incoming hardline-
	// like emit drops the pending slot without write. Pins both
	// branches of the drop-on-following semantic.

	function testOHSBHFiresWhenFollowedByContent() {
		// Pending OHSBH + Text → flush pending first, then write Text.
		// No follower hardline, so the deferred `\n` lands.
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			D.text('b'),
		]);
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHDropsWhenFollowedByHardline() {
		// Pending OHSBH + MBreak `Line('\n')` → drop pending, emit only
		// the incoming hardline. Single `\n` between `a` and `b` —
		// without OHSBH's collision drop the result would be `a\n\nb`.
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			D.hardline(),
			D.text('b'),
		]);
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHDropsWhenFollowedByOptHardline() {
		// Pending OHSBH + `OptHardline` → drop pending; OptHardline
		// then sees lastEmit=Other (no prior hardline) and emits its
		// own `\n`. Single newline total — the collision suppression
		// generalises across hardline ctors.
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			OptHardline,
			D.text('b'),
		]);
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHConsecutivesCollapseToOne() {
		// Two `OptHardlineSkipBeforeHardline` in a row: the inner
		// overwrites the slot, the outer's deferred emit is silently
		// dropped (its emit was never committed). Followed by Text →
		// single `\n+indent` flushes for the inner ctor. The semantic
		// mirrors `OptHardline`'s collision-drop "more-specific inner
		// wins" pattern.
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			OptHardlineSkipBeforeHardline,
			D.text('b'),
		]);
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHDropsPendingOptSpaceOnFlush() {
		// Pending OHSBH + pending OptSpace + Text: flushPendingHardline
		// drops pendingOptSpace as part of break-mode-Line semantic.
		// Result `a\nb` — the optional trailing space vanishes before
		// the deferred newline lands.
		final doc:Doc = D.concat([
			D.text('a'),
			D.optSpace(' '),
			OptHardlineSkipBeforeHardline,
			D.text('b'),
		]);
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHForcesGroupBreak() {
		// `OptHardlineSkipBeforeHardline` forces `fitsFlat` to refuse
		// flatten — any enclosing Group commits MBreak even with ample
		// budget. Pins the parity with `OptHardline` / `Line('\n')` in
		// `fitsFlat`'s walker arm.
		final doc:Doc = D.group(D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			D.text('b'),
		]));
		Assert.equals('a\nb', Renderer.render(doc, 80));
	}

	function testOHSBHDroppedInsideFlatten() {
		// Inside `Flatten(...)`, `OptHardlineSkipBeforeHardline` drops
		// entirely — mirror of `OptHardline`'s force-flat arm. No
		// pending slot is set, so the follower Text writes immediately
		// at the current column without an interleaved hardline.
		final doc:Doc = D.concat([
			D.text('a'),
			OptHardlineSkipBeforeHardline,
			D.text('b'),
		]);
		Assert.equals('ab', Renderer.render(Flatten(doc), 80));
	}

	function testOHSBHWithNestUsesInnerIndent() {
		// `Nest(2, OHSBH)` sets the pending slot's indent to 2 cols.
		// On flush, the `\n+indent` uses that inner-most indent value
		// — mirror of `OptHardline`'s "more-specific inner wins"
		// indent propagation. Renderer's pendingHardline carries the
		// frame indent through to flushPendingHardline.
		final doc:Doc = D.concat([
			D.text('a'),
			D.nest(2, OptHardlineSkipBeforeHardline),
			D.text('b'),
		]);
		Assert.equals('a\n  b', Renderer.render(doc, 80));
	}
}
