package anyparse.query.format;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.LexicalRegions.LexRegion;
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

using StringTools;

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

	public static function renderTree(file: String, source: String, tree: QueryNode): String {
		final dump: AstDumpJson = { file: file, tree: toAst(tree, new LineIndex(source)) };
		return '${AstDumpJsonWriter.write(dump, JsonFormat.instance.defaultWriteOptions)}\n';
	}

	/**
	 * `windows` is parallel to `matches` — same length, same order — or EMPTY; see
	 * `Text.renderMatches`. The `span` key is unaffected either way: it describes the NODE, while
	 * `source` describes the declaration that node belongs to, so a consumer slicing the file by
	 * `span` and one reading `source` get different bytes for the same match by design.
	 */
	public static function renderMatches(
		file: String, source: String, matches: Array<QueryNode>, windows: Array<Null<Span>>, doc: Bool, src: Bool,
		regions: Array<LexRegion>
	): String {
		final index: LineIndex = new LineIndex(source);
		final out: AstMatchesJson = {
			file: file,
			matches: [
				for (i => n in matches) {
					final ast: AstNodeJson = toAst(n, index);
					final window: Null<Span> = i < windows.length ? windows[i] : n.span;
					if (doc) {
						final d: Null<String> = SourceSlice.leadingDoc(source, window, regions);
						if (d != null) ast.doc = d;
					}
					if (src) {
						final s: String = SourceSlice.slice(source, window);
						if (s.length > 0) ast.source = s;
					}
					ast;
				}
			]
		};
		return '${AstMatchesJsonWriter.write(out, JsonFormat.instance.defaultWriteOptions)}\n';
	}

	public static function renderMeta(entries: Array<{ file: String, source: String, hits: Array<MetaHit> }>): String {
		final out: Array<AstMetaHit> = [];
		for (entry in entries) {
			final index: LineIndex = new LineIndex(entry.source);
			for (h in entry.hits) {
				final declSpan: Null<Span> = h.declSpan;
				final decl: AstMetaDecl = {
					kind: h.declKind,
					span: declSpan == null ? emptySpan() : spanToJson(declSpan, index)
				};
				final dn: Null<String> = h.declName;
				if (dn != null) decl.name = dn;
				out.push({
					file: entry.file,
					annotation: h.annotation,
					args: h.args,
					decl: decl
				});
			}
		}
		final envelope: AstMetaHits = { hits: out };
		return '${AstMetaHitsWriter.write(envelope, JsonFormat.instance.defaultWriteOptions)}\n';
	}

	public static function renderRefs(
		entries: Array<{ file: String, source: String, hits: Array<RefHit> }>, doc: Bool, src: Bool,
		lexicalRegions: (String) -> Array<LexRegion>
	): String {
		final out: Array<AstRefHit> = [];
		for (entry in entries) {
			final index: LineIndex = new LineIndex(entry.source);
			for (h in entry.hits) {
				final bindingSpan: Null<Span> = h.bindingSpan;
				final hit: AstRefHit = {
					file: entry.file,
					kind: h.kind.toString(),
					span: spanToJson(h.span, index),
					name: h.name
				};
				if (bindingSpan != null) hit.binding = spanToJson(bindingSpan, index);
				if (doc) {
					final d: Null<String> = SourceSlice.leadingDoc(entry.source, h.span, lexicalRegions(entry.source));
					if (d != null) hit.doc = d;
				}
				if (src) {
					final s: String = SourceSlice.slice(entry.source, h.span);
					if (s.length > 0) hit.source = s;
				}
				out.push(hit);
			}
		}
		final envelope: AstRefHits = { hits: out };
		return '${AstRefHitsWriter.write(envelope, JsonFormat.instance.defaultWriteOptions)}\n';
	}

	public static function renderSearchMatches(file: String, source: String, matches: Array<Match>): String {
		final index: LineIndex = new LineIndex(source);
		final entries: Array<AstSearchMatch> = [
			for (m in matches)
				{
					file: file,
					span: spanToJson(m.span, index),
					bindings: collectBindings(m, source, index)
				}
		];
		final envelope: AstSearchMatches = { matches: entries };
		return '${AstSearchMatchesWriter.write(envelope, JsonFormat.instance.defaultWriteOptions)}\n';
	}

	private static inline function emptySpan(): AstSearchSpan {
		return { start: [0, 0], end: [0, 0] };
	}

	private static function toAst(node: QueryNode, index: LineIndex): AstNodeJson {
		final children: Array<AstNodeJson> = node.children.map(c -> toAst(c, index));
		final ast: AstNodeJson = { kind: node.kind, children: children };
		final n: Null<String> = node.name;
		if (n != null) ast.name = n;
		final span: Null<Span> = node.span;
		if (span != null) ast.span = spanToJson(span, index);
		// The declared-type SLOT, not a child - emitted under its own key so a JSON
		// consumer walking `children` sees the same list it always did.
		final declared: Null<QueryNode> = node.type;
		if (declared != null) ast.type = toAst(declared, index);
		return ast;
	}

	private static function collectBindings(m: Match, source: String, index: LineIndex): Array<AstSearchBinding> {
		final out: Array<AstSearchBinding> = [];
		for (name => boundNode in m.bindings) {
			final span: Null<Span> = boundNode.span;
			final text: String = boundNode.kind == 'NameOnly' ? (boundNode.name ?? '') : SourceSlice.slice(source, span);
			out.push({
				name: name,
				text: text,
				span: span == null ? emptySpan() : spanToJson(span, index)
			});
		}
		return out;
	}

	private static function spanToJson(span: Span, index: LineIndex): AstSearchSpan {
		final from: Position = index.positionAt(span.from);
		final to: Position = index.positionAt(span.to);
		// Both line and col are 1-based — the unified apq
		// coordinate convention (refs / ast --at / source agree).
		return {
			start: [from.line, from.col],
			end: [to.line, to.col]
		};
	}

}

/**
 * The line-start offsets of ONE source, built once so a span's line/col is a binary search
 * instead of a scan from byte 0.
 *
 * `Span.lineCol` walks the source from the start on EVERY call and a JSON dump asks it twice
 * per node, so a dump is quadratic in file size — invisible until a big file lands in a
 * sampled slot: `ast --json` over a 16 572-line module measured 58.3 s, 88.7 % of it inside
 * that scan, and `unit.query.ApqAstIntegrationTest` went 5.8 s -> 189.8 s the moment an
 * unrelated slice added three files and re-aligned its every-64th-file stride onto that
 * module. RUN-scoped by construction — one instance per render call, no static state
 * (invariant 1).
 */
@:nullSafety(Strict)
private class LineIndex {

	/** Offset of the first character of each line; `starts[0]` is always 0. */
	private final _starts: Array<Int>;

	private final _length: Int;

	public function new(source: String) {
		final offsets: Array<Int> = [0];
		for (i in 0...source.length) if (source.fastCodeAt(i) == '\n'.code) offsets.push(i + 1);
		_starts = offsets;
		_length = source.length;
	}

	/**
	 * The 1-based line and column of `offset`, clamped to the source's end exactly as
	 * `Span.lineCol` clamps it — this must answer what that walk answers, byte for byte.
	 */
	public function positionAt(offset: Int): Position {
		final at: Int = offset < _length ? offset : _length;
		var lo: Int = 0;
		var hi: Int = _starts.length - 1;
		while (lo < hi) {
			final mid: Int = (lo + hi + 1) >> 1;
			if (_starts[mid] <= at)
				lo = mid;
			else
				hi = mid - 1;
		}
		return { line: lo + 1, col: at - _starts[lo] + 1 };
	}

}
