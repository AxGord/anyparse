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
}
