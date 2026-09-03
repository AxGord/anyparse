package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceSlice;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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
		final s: String = 'abcdef';
		Assert.equals('cd', SourceSlice.slice(s, new Span(2, 4)));
		Assert.equals('abcdef', SourceSlice.slice(s, new Span(-1, 100)));
		Assert.equals('', SourceSlice.slice(s, new Span(3, 3)));
		Assert.equals('', SourceSlice.slice(s, null));
	}

	public function testLeadingDocAdjacentBlock(): Void {
		final src: String = 'class C {\n\t/** field doc */\n\tvar count:Int = 0;\n}';
		final span: Span = spanAt(src, 'var count');
		Assert.equals('\t/** field doc */', SourceSlice.leadingDoc(src, span, new HaxeQueryPlugin().lexicalRegions(src)));
	}

	/**
	 * A doc whose TEXT contains a backticked block-comment opener is ONE comment token,
	 * so the WHOLE block is returned. The line scan this used to do started at the line
	 * carrying that literal and dropped the real opener line.
	 */
	public function testLeadingDocWithBlockOpenerInText(): Void {
		final src: String = 'class C {\n\t/**\n\t * Holds a `//` or `/*` opener.\n\t */\n\tvar count:Int = 0;\n}';
		final span: Span = spanAt(src, 'var count');
		Assert.equals(
			'\t/**\n\t * Holds a `//` or `/*` opener.\n\t */', SourceSlice.leadingDoc(src, span, new HaxeQueryPlugin().lexicalRegions(src))
		);
	}

	public function testLeadingDocSkipsAnnotationLines(): Void {
		final src: String = '/**\n * Widget doc.\n */\n@:keep\nclass Widget {}';
		final span: Span = spanAt(src, 'class Widget');
		Assert.equals('/**\n * Widget doc.\n */', SourceSlice.leadingDoc(src, span, new HaxeQueryPlugin().lexicalRegions(src)));
	}

	public function testLeadingDocLineCommentRun(): Void {
		final src: String = '/// line one\n/// line two\nclass D {}';
		final span: Span = spanAt(src, 'class D');
		Assert.equals('/// line one\n/// line two', SourceSlice.leadingDoc(src, span, new HaxeQueryPlugin().lexicalRegions(src)));
	}

	public function testLeadingDocBlockCommentNonDoc(): Void {
		final src: String = '/* note */\nclass F {}';
		final span: Span = spanAt(src, 'class F');
		Assert.equals('/* note */', SourceSlice.leadingDoc(src, span, new HaxeQueryPlugin().lexicalRegions(src)));
	}

	/**
	 * A block comment TRAILING the previous declaration on that declaration's own line
	 * is not this one's documentation, however adjacent it looks. The line scan accepts
	 * any line ending in a comment closer, so without the own-line rule the slice handed
	 * back the previous declaration's CODE as the doc.
	 */
	public function testLeadingDocIgnoresPreviousDeclarationsTrailingComment(): Void {
		final src: String = 'class C {\n\tvar keep:Int = 0; /** about keep */\n\n\tvar count:Int = 0;\n}';
		Assert.isNull(SourceSlice.leadingDoc(src, spanAt(src, 'var count'), new HaxeQueryPlugin().lexicalRegions(src)));
	}

	public function testLeadingDocAbsentReturnsNull(): Void {
		final src: String = 'class E {}';
		Assert.isNull(SourceSlice.leadingDoc(src, spanAt(src, 'class E'), new HaxeQueryPlugin().lexicalRegions(src)));
		Assert.isNull(SourceSlice.leadingDoc(src, null, new HaxeQueryPlugin().lexicalRegions(src)));
	}

	public function testRefsTextDocOptIn(): Void {
		final src: String = 'class C {\n\t/** doc for count. */\n\tvar count:Int = 0;\n}';
		final decls: Array<RefHit> = declHits(src, 'count');
		Assert.isTrue(decls.length > 0, 'expected a decl hit for count');

		final withDoc: String = Text.renderRefs('F.hx', src, decls, true, false, new HaxeQueryPlugin().lexicalRegions(src));
		Assert.isTrue(withDoc.indexOf('/** doc for count. */') >= 0, 'doc block must appear with --doc');

		final plain: String = Text.renderRefs('F.hx', src, decls, false, false, new HaxeQueryPlugin().lexicalRegions(src));
		Assert.isTrue(plain.indexOf('/**') < 0, 'default text output must carry no doc block');
	}

	public function testRefsTextSourceOptIn(): Void {
		final src: String = 'class C {\n\tvar count:Int = 0;\n}';
		final decls: Array<RefHit> = declHits(src, 'count');
		final withSource: String = Text.renderRefs('F.hx', src, decls, false, true, new HaxeQueryPlugin().lexicalRegions(src));
		Assert.isTrue(withSource.indexOf('var count:Int = 0;') >= 0, 'verbatim slice must appear with --source');
	}

	public function testRefsJsonDefaultByteIdentical(): Void {
		final src: String = 'class C {\n\t/** doc */\n\tvar count:Int = 0;\n}';
		final entries: Array<{ file: String, source: String, hits: Array<RefHit> }> = [
			{
				file: 'F.hx',
				source: src,
				hits: declHits(src, 'count')
			}
		];

		final off: String = Json.renderRefs(entries, false, false, new HaxeQueryPlugin().lexicalRegions);
		Assert.isTrue(off.indexOf('\"doc\"') < 0, 'default refs json must omit doc key');
		Assert.isTrue(off.indexOf('\"source\"') < 0, 'default refs json must omit source key');

		final on: String = Json.renderRefs(entries, true, true, new HaxeQueryPlugin().lexicalRegions);
		Assert.isTrue(on.indexOf('\"doc\"') >= 0, '--doc must add the doc key');
		Assert.isTrue(on.indexOf('\"source\"') >= 0, '--source must add the source key');
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
