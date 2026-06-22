package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SourceSlice;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.Span;

using Lambda;

/**
 * `--doc` / `--source` opt-ins: `SourceSlice` slice + leading-doc
 * reconstruction, and the render-layer wiring for `refs` (text + json).
 *
 * The doc/source text is rebuilt from offsets only — the parse tree
 * never carries comments — so the default `refs`/`ast` output stays
 * byte-identical (asserted directly: no `doc`/`source` keys, no doc
 * lines, when the flags are off).
 *
 * All fixture sources are double-quoted: verbatim text with no Haxe
 * string interpolation.
 */
class ApqDocSourceTest extends Test {

	public function testSliceVerbatimAndClamp(): Void {
		final s: String = "abcdef";
		Assert.equals("cd", SourceSlice.slice(s, new Span(2, 4)));
		Assert.equals("abcdef", SourceSlice.slice(s, new Span(-1, 100)));
		Assert.equals("", SourceSlice.slice(s, new Span(3, 3)));
		Assert.equals("", SourceSlice.slice(s, null));
	}

	public function testLeadingDocAdjacentBlock(): Void {
		final src: String = "class C {\n\t/** field doc */\n\tvar count:Int = 0;\n}";
		final span: Span = spanAt(src, "var count");
		Assert.equals("\t/** field doc */", SourceSlice.leadingDoc(src, span));
	}

	public function testLeadingDocSkipsAnnotationLines(): Void {
		final src: String = "/**\n * Widget doc.\n */\n@:keep\nclass Widget {}";
		final span: Span = spanAt(src, "class Widget");
		Assert.equals("/**\n * Widget doc.\n */", SourceSlice.leadingDoc(src, span));
	}

	public function testLeadingDocLineCommentRun(): Void {
		final src: String = "/// line one\n/// line two\nclass D {}";
		final span: Span = spanAt(src, "class D");
		Assert.equals("/// line one\n/// line two", SourceSlice.leadingDoc(src, span));
	}

	public function testLeadingDocBlockCommentNonDoc(): Void {
		final src: String = "/* note */\nclass F {}";
		final span: Span = spanAt(src, "class F");
		Assert.equals("/* note */", SourceSlice.leadingDoc(src, span));
	}

	public function testLeadingDocAbsentReturnsNull(): Void {
		final src: String = "class E {}";
		Assert.isNull(SourceSlice.leadingDoc(src, spanAt(src, "class E")));
		Assert.isNull(SourceSlice.leadingDoc(src, null));
	}

	public function testRefsTextDocOptIn(): Void {
		final src: String = "class C {\n\t/** doc for count. */\n\tvar count:Int = 0;\n}";
		final decls: Array<RefHit> = declHits(src, "count");
		Assert.isTrue(decls.length > 0, "expected a decl hit for count");

		final withDoc: String = Text.renderRefs("F.hx", src, decls, true, false);
		Assert.isTrue(withDoc.indexOf("/** doc for count. */") >= 0, "doc block must appear with --doc");

		final plain: String = Text.renderRefs("F.hx", src, decls, false, false);
		Assert.isTrue(plain.indexOf("/**") < 0, "default text output must carry no doc block");
	}

	public function testRefsTextSourceOptIn(): Void {
		final src: String = "class C {\n\tvar count:Int = 0;\n}";
		final decls: Array<RefHit> = declHits(src, "count");
		final withSource: String = Text.renderRefs("F.hx", src, decls, false, true);
		Assert.isTrue(withSource.indexOf("var count:Int = 0;") >= 0, "verbatim slice must appear with --source");
	}

	public function testRefsJsonDefaultByteIdentical(): Void {
		final src: String = "class C {\n\t/** doc */\n\tvar count:Int = 0;\n}";
		final entries: Array<{ file: String, source: String, hits: Array<RefHit> }> = [
			{
				file: "F.hx",
				source: src,
				hits: declHits(src, "count")
			}
		];

		final off: String = Json.renderRefs(entries, false, false);
		Assert.isTrue(off.indexOf("\"doc\"") < 0, "default refs json must omit doc key");
		Assert.isTrue(off.indexOf("\"source\"") < 0, "default refs json must omit source key");

		final on: String = Json.renderRefs(entries, true, true);
		Assert.isTrue(on.indexOf("\"doc\"") >= 0, "--doc must add the doc key");
		Assert.isTrue(on.indexOf("\"source\"") >= 0, "--source must add the source key");
	}

	private function declHits(src: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final all: Array<RefHit> = Refs.find(name, tree, plugin.refShape());
		return all.filter(h -> h.kind == RefKind.Decl);
	}

	private function spanAt(src: String, needle: String): Span {
		final idx: Int = src.indexOf(needle);
		return new Span(idx, idx);
	}

}
