package anyparse.query.format;

import anyparse.format.text.JsonFormat;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.SourceSlice;
import anyparse.query.format.json.AstDumpJson;
import anyparse.query.format.json.AstDumpJsonWriter;
import anyparse.query.format.json.AstMatchesJson;
import anyparse.query.format.json.AstMatchesJsonWriter;
import anyparse.query.format.json.AstMetaDecl;
import anyparse.query.format.json.AstMetaHit;
import anyparse.query.format.json.AstMetaHits;
import anyparse.query.format.json.AstMetaHitsWriter;
import anyparse.query.format.json.AstNodeJson;
import anyparse.query.format.json.AstRefHit;
import anyparse.query.format.json.AstRefHits;
import anyparse.query.format.json.AstRefHitsWriter;
import anyparse.query.format.json.AstSearchBinding;
import anyparse.query.format.json.AstSearchMatch;
import anyparse.query.format.json.AstSearchMatches;
import anyparse.query.format.json.AstSearchMatchesWriter;
import anyparse.query.format.json.AstSearchSpan;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * JSON renderer for `apq ast` output.
 *
 * Thin adapter — converts a generic `QueryNode` tree into the typed
 * `AstDumpJson` / `AstMatchesJson` schemas and delegates the actual
 * serialization to the macro-generated writers in
 * `anyparse.query.format.json`. The library claim is that any format
 * description can be expressed declaratively; this file dogfoods that
 * claim for `apq` itself.
 *
 * Schemas (see `docs/cli-query-tool.md`):
 *
 *  - Tree mode: `{ file:String, tree:Node }`
 *  - Select mode: `{ file:String, matches:Array<Node> }`
 *
 *  Node = { kind:String, ?name:String, children:Array<Node> }
 *
 * `span` is omitted in Phase 1 — Plain-mode parsers do not emit spans.
 */
@:nullSafety(Strict)
final class Json {

	public static function renderTree(file:String, source:String, tree:QueryNode):String {
		final dump:AstDumpJson = {file: file, tree: toAst(tree, source)};
		return AstDumpJsonWriter.write(dump, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderMatches(file:String, source:String, matches:Array<QueryNode>, doc:Bool, src:Bool):String {
		final out:AstMatchesJson = {file: file, matches: [for (n in matches) {
			final ast:AstNodeJson = toAst(n, source);
			if (doc) {
				final d:Null<String> = SourceSlice.leadingDoc(source, n.span);
				if (d != null) ast.doc = d;
			}
			if (src) {
				final s:String = SourceSlice.slice(source, n.span);
				if (s.length > 0) ast.source = s;
			}
			ast;
		}]};
		return AstMatchesJsonWriter.write(out, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderMeta(entries:Array<{file:String, source:String, hits:Array<MetaHit>}>):String {
		final out:Array<AstMetaHit> = [];
		for (entry in entries) for (h in entry.hits) {
			final declSpan:Null<Span> = h.declSpan;
			final decl:AstMetaDecl = {
				kind: h.declKind,
				span: declSpan == null ? emptySpan() : spanToJson(declSpan, entry.source),
			};
			final dn:Null<String> = h.declName;
			if (dn != null) decl.name = dn;
			out.push({
				file: entry.file,
				annotation: h.annotation,
				args: h.args,
				decl: decl,
			});
		}
		final envelope:AstMetaHits = {hits: out};
		return AstMetaHitsWriter.write(envelope, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderRefs(entries:Array<{file:String, source:String, hits:Array<RefHit>}>, doc:Bool, src:Bool):String {
		final out:Array<AstRefHit> = [];
		for (entry in entries) for (h in entry.hits) {
			final bindingSpan:Null<Span> = h.bindingSpan;
			final hit:AstRefHit = {
				file: entry.file,
				kind: h.kind.toString(),
				span: spanToJson(h.span, entry.source),
				name: h.name,
			};
			if (bindingSpan != null) hit.binding = spanToJson(bindingSpan, entry.source);
			if (doc) {
				final d:Null<String> = SourceSlice.leadingDoc(entry.source, h.span);
				if (d != null) hit.doc = d;
			}
			if (src) {
				final s:String = SourceSlice.slice(entry.source, h.span);
				if (s.length > 0) hit.source = s;
			}
			out.push(hit);
		}
		final envelope:AstRefHits = {hits: out};
		return AstRefHitsWriter.write(envelope, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderSearchMatches(file:String, source:String, matches:Array<Match>):String {
		final entries:Array<AstSearchMatch> = [for (m in matches) {
			file: file,
			span: spanToJson(m.span, source),
			bindings: collectBindings(m, source),
		}];
		final envelope:AstSearchMatches = {matches: entries};
		return AstSearchMatchesWriter.write(envelope, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	private static function toAst(node:QueryNode, source:String):AstNodeJson {
		final children:Array<AstNodeJson> = node.children.map(c -> toAst(c, source));
		final ast:AstNodeJson = {kind: node.kind, children: children};
		final n:Null<String> = node.name;
		if (n != null) ast.name = n;
		final span:Null<Span> = node.span;
		if (span != null) ast.span = spanToJson(span, source);
		return ast;
	}

	private static function collectBindings(m:Match, source:String):Array<AstSearchBinding> {
		final out:Array<AstSearchBinding> = [];
		for (name => boundNode in m.bindings) {
			final span:Null<Span> = boundNode.span;
			final text:String = boundNode.kind == 'NameOnly' ? (boundNode.name ?? '') : SourceSlice.slice(source, span);
			out.push({
				name: name,
				text: text,
				span: span == null ? emptySpan() : spanToJson(span, source),
			});
		}
		return out;
	}

	private static function spanToJson(span:Span, source:String):AstSearchSpan {
		final from:Position = span.lineCol(source);
		final to:Position = new Span(span.to, span.to).lineCol(source);
		// Spec: line 1-based, col 0-based. Span.lineCol returns col
		// 1-based — subtract one for spec compliance.
		return {
			start: [from.line, from.col - 1],
			end: [to.line, to.col - 1],
		};
	}

	private static inline function emptySpan():AstSearchSpan {
		return {start: [0, 0], end: [0, 0]};
	}
}
