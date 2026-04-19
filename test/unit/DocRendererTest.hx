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
}
