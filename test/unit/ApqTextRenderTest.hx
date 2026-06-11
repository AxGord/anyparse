package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Matcher;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta;
import anyparse.query.Meta.MetaHit;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * Regression-locks the declarative line-diagnostic renderers
 * (`Text.renderRefs` / `renderSearchMatches` / `renderMeta`, now
 * driven by `LineDiagFormat` + macro-generated writers) against an
 * inline reference reproduction of the previous hand-rolled format.
 *
 * The assertion is `declarative output == reference-formula output`:
 * if a grammar `@:lead`/`@:trail`/`@:sep` meta or the format config
 * drifts, the writer output diverges from the formula and the test
 * fails — independent of concrete span values.
 */
class ApqTextRenderTest extends Test {

	public function testRenderRefsMatchesReference(): Void {
		final src: String = 'class T { var x:Int = 0; static function f():Void { var y:Int = x; } }';
		final file: String = 'T.hx';
		final hits: Array<RefHit> = refsOf(src, 'x');
		Assert.isTrue(hits.length >= 2, 'fixture must yield decl+read');
		// `flat=true` — the reference reproduction below mirrors the flat
		// `file:line:col: …` form; the grouped (default) form is the
		// pretty surface and not regression-locked here.
		Assert.equals(referenceRefs(file, src, hits), Text.renderRefs(file, src, hits, false, false, true));
	}

	public function testRenderRefsEmpty(): Void {
		Assert.equals('T.hx: no refs\n', Text.renderRefs('T.hx', 'class T {}', [], false, false, true));
	}

	public function testRenderSearchMatchesMatchesReference(): Void {
		final src: String = 'class T { static function a() { throw new IoError("x"); } }';
		final file: String = 'T.hx';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final pattern: Pattern = plugin.parsePattern("throw new $E($_)");
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.isTrue(matches.length >= 1, 'fixture must yield a match');
		Assert.equals(referenceSearch(file, src, matches), Text.renderSearchMatches(file, src, matches, true));
	}

	public function testRenderSearchMatchesEmpty(): Void {
		Assert.equals('T.hx: no matches\n', Text.renderSearchMatches('T.hx', 'class T {}', [], true));
	}

	public function testRenderMetaMatchesReference(): Void {
		final src: String = 'class T { @:foo(a, b) var n:Int; @:keep function g():Void {} }';
		final file: String = 'T.hx';
		final hits: Array<MetaHit> = metaOf(src);
		Assert.isTrue(hits.length >= 2, 'fixture must yield two annotations');
		Assert.equals(referenceMeta(file, src, hits), Text.renderMeta(file, src, hits, true));
	}

	public function testRenderMetaEmpty(): Void {
		Assert.equals('T.hx: no meta\n', Text.renderMeta('T.hx', 'class T {}', [], true));
	}

	// --- reference reproductions of the pre-refactor StringBuf format ---

	private static function referenceRefs(file: String, source: String, hits: Array<RefHit>): String {
		final buf: StringBuf = new StringBuf();
		for (h in hits) {
			final pos: Position = h.span.lineCol(source);
			buf.add('$file:${pos.line}:${pos.col - 1}: [${h.kind.toString()}] ${h.name}');
			final bs: Null<Span> = h.bindingSpan;
			if (bs != null && bs.from != h.span.from) {
				final bp: Position = bs.lineCol(source);
				buf.add(' -> ${bp.line}:${bp.col - 1}');
			}
			buf.add('\n');
		}
		return buf.toString();
	}

	private static function referenceSearch(file: String, source: String, matches: Array<Match>): String {
		final buf: StringBuf = new StringBuf();
		for (m in matches) {
			final pos: Position = m.span.lineCol(source);
			buf.add('$file:${pos.line}:${pos.col - 1}: match');
			var n: Int = 0;
			for (_ in m.bindings) n++;
			if (n > 0) {
				buf.add(' (');
				var first: Bool = true;
				for (name => bound in m.bindings) {
					if (!first) buf.add(', ');
					first = false;
					buf.add(name);
					buf.add('=');
					buf.add(boundText(source, bound));
				}
				buf.add(')');
			}
			buf.add('\n');
		}
		return buf.toString();
	}

	private static function referenceMeta(file: String, source: String, hits: Array<MetaHit>): String {
		final buf: StringBuf = new StringBuf();
		for (h in hits) {
			final span: Null<Span> = h.metaSpan;
			if (span != null) {
				final pos: Position = span.lineCol(source);
				buf.add('$file:${pos.line}:${pos.col - 1}: ');
			} else {
				buf.add('$file: ');
			}
			buf.add(h.annotation);
			if (h.args.length > 0) {
				buf.add('(');
				buf.add(h.args.join(', '));
				buf.add(')');
			}
			buf.add(' on ${h.declKind}');
			final dn: Null<String> = h.declName;
			if (dn != null) buf.add(' $dn');
			buf.add('\n');
		}
		return buf.toString();
	}

	// Mirrors Text.summariseBound so the search reference matches the
	// renderer's binding-value text exactly.
	private static function boundText(source: String, bound: QueryNode): String {
		if (bound.kind == 'NameOnly') {
			final n: Null<String> = bound.name;
			return n ?? '';
		}
		final span: Null<Span> = bound.span;
		if (span == null) return '?';
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to > source.length ? source.length : span.to;
		if (from >= to) return '';
		final slice: String = source.substring(from, to);
		final flat: String = StringTools.replace(StringTools.replace(slice, '\n', ' '), '\r', '');
		return StringTools.trim(flat);
	}

	private static function refsOf(source: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function metaOf(source: String): Array<MetaHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: MetaShape = plugin.metaShape();
		return Meta.find(tree, shape, source);
	}

}
