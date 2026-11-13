package unit.core;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.core.DocMeasure;
import anyparse.core.LeafTag;
import anyparse.core.Renderer;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

using StringTools;

/** What a leaf leaves open at its end is read off its tag by the renderer and the glue / head probes, never its bytes. */
@:nullSafety(Strict)
class LeafEndEdgeReadTest extends Test {

	/** A composite literal is tagged by its end: an open or an arrow at the last non-blank byte, a close at the last byte. */
	@:pin('control')
	@:killer('M-LEAFEND-OPENS-PLAIN')
	public function testTagOfReadsTheEndEdge(): Void {
		Assert.same(Delimiter(NoOpen, Opens), DelimiterLeaf.tagOf('foo('));
		Assert.same(Delimiter(NoOpen, Opens), DelimiterLeaf.tagOf(') {'));
		Assert.same(Delimiter(Paren, Opens), DelimiterLeaf.tagOf('( '));
		Assert.same(Delimiter(NoOpen, Arrow), DelimiterLeaf.tagOf(' -> '));
		Assert.same(Delimiter(NoOpen, Closes), DelimiterLeaf.tagOf(')'));
		Assert.isNull(DelimiterLeaf.tagOf(') '));
		Assert.isNull(DelimiterLeaf.tagOf('->a'));
	}

	/** The renderer skips a skip-at-open hardline after a tagged open, and not after the same bytes untagged. */
	@:pin('control')
	@:killer('M-LEAFEND-EMIT-BYTES')
	public function testLastEmitReadsTheTag(): Void {
		Assert.equals('foo(a', Renderer.render(Concat([DelimiterLeaf.leaf('foo('), OptHardlineSkipAtOpenDelim, Text('a')]), 80));
		Assert.equals('foo(\na', Renderer.render(Concat([Text('foo('), OptHardlineSkipAtOpenDelim, Text('a')]), 80));
	}

	/** An arrow ends a head at an open construct, the way an open delimiter does. */
	@:pin('control')
	@:killer('M-LEAFEND-MEASURE-ARROW')
	public function testArrowEndsTheHeadOpen(): Void {
		Assert.isTrue(DocMeasure.breakableHead(Concat([Text('f'), DelimiterLeaf.leaf(' -> '), Line(' ')])).endsAtOpenDelim);
		Assert.isFalse(DocMeasure.breakableHead(Concat([Text('f'), Line(' ')])).endsAtOpenDelim);
	}

	/** A tagged open ends the head open across a blank leaf after it; the same bytes untagged do not. */
	@:pin('control')
	@:killer('M-LEAFEND-MEASURE-BYTES')
	public function testHeadVerdictReadsTheTag(): Void {
		Assert.isTrue(DocMeasure.breakableHead(Concat([DelimiterLeaf.leaf('f('), Text(' '), Line(' ')])).endsAtOpenDelim);
		Assert.isFalse(DocMeasure.breakableHead(Concat([Text('f('), Line(' ')])).endsAtOpenDelim);
	}

	/** Every leaf the generated writer builds that ends on an open delimiter or an arrow says so in its tag. */
	@:pin('control')
	@:killer('M-DELIMLEAF-MACRO-UNTAGGED')
	public function testWriterTagsEveryOpenEnd(): Void {
		final leaves: Array<{ s: String, tag: Null<LeafTag> }> = [];
		collect(
			HaxeModuleTriviaWriter.writeDoc(
				HaxeModuleTriviaParser.parse(
					'class A {\n\tfunction f() {\n\t\tfor (i in a) if (c) g(x -> x, [1], { b: 2 });\n'
					+ '\t\tvar h: Int -> Void = null;\n\t}\n}\n'
				),
				HaxeFormat.instance.defaultWriteOptions
			),
			new DocIdentityMap(), leaves
		);
		final openEnds: Array<{ s: String, tag: Null<LeafTag> }> = leaves.filter(l -> endsOpenByBytes(l.s));
		Assert.isTrue(openEnds.length > 3);
		for (l in openEnds) Assert.isTrue(DelimiterLeaf.leavesOpen(l.tag, true), 'untagged open end: "${l.s}"');
	}

	/** The test's own byte reading of an open end, the reference the writer's tags are checked against. */
	private static function endsOpenByBytes(s: String): Bool {
		final t: String = s.rtrim();
		return t.endsWith('(') || t.endsWith('[') || t.endsWith('{') || t.endsWith('->');
	}

	/** Every distinct `Text` leaf of `d` with its tag. */
	private static function collect(d: Doc, seen: DocIdentityMap<Bool>, out: Array<{ s: String, tag: Null<LeafTag> }>): Void {
		if (seen.exists(d)) return;
		seen.set(d, true);
		switch d {
			case Text(s, _, t):
				out.push({ s: s, tag: t });
			case _:
		}
		D.mapChildren(d, c -> {
			collect(c, seen, out);
			return c;
		});
	}

}
