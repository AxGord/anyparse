package unit;

import utest.Assert;
import utest.Test;
import anyparse.core.Doc;
import anyparse.core.D;
import anyparse.core.Renderer;

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
}
