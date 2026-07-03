package anyparse.query;

import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnNode;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * Rendered transitive call tree for `apq callees` / `apq callers` — the two
 * subcommands share this walker because they differ only in edge direction:
 * `callees` follows OUT edges from the root, `callers` follows IN edges.
 * Cycle-safe (an ancestor reappearing on the path is marked `(cycle)` and not
 * expanded); output is capped at `maxLines` tree lines (`maxLines <= 0` = uncapped).
 */
@:nullSafety(Strict)
final class CallChains {

	/**
	 * Render the call tree from `rootId` — outward (callees) or inward
	 * (callers) — to `depth` levels. `kinds` filters edge kinds (null = all);
	 * `sourceOf` supplies file sources for `line:col` rendering.
	 */
	public static function render(
		graph: CallGraph, rootId: String, depth: Int, outward: Bool, kinds: Null<Array<EdgeKind>>, sourceOf: (file:String) -> Null<String>,
		maxLines: Int
	): String {
		final buf: StringBuf = new StringBuf();
		buf.add(nodeLabel(graph, rootId, sourceOf) + '\n');
		var lines: Int = 1;
		var truncated: Bool = false;
		final arrow: String = outward ? '->' : '<-';
		final kindFilter: Array<EdgeKind> = kinds ?? [];

		function walk(id: String, level: Int, ancestors: Array<String>): Void {
			if (truncated || level > depth) return;
			final edgeList: Array<CallEdge> = outward ? graph.outEdges(id) : graph.inEdges(id);
			for (edge in edgeList) {
				if (kindFilter.length > 0 && !kindFilter.contains(edge.kind)) continue;
				if (maxLines > 0 && lines >= maxLines) {
					truncated = true;
					return;
				}
				final next: String = outward ? edge.to : edge.from;
				final indent: String = StringTools.rpad('', ' ', level * 2);
				final viaText: String = edge.via != null ? ' via ${edge.via}' : '';
				final cycle: Bool = ancestors.contains(next);
				final cycleText: String = cycle ? ' (cycle)' : '';
				buf.add(
					'$indent$arrow [${edge.kind.label()}$viaText] ${nodeLabel(graph, next, sourceOf)}${siteOf(edge, sourceOf)}$cycleText\n'
				);
				lines++;
				if (cycle) continue;
				ancestors.push(next);
				walk(next, level + 1, ancestors);
				ancestors.pop();
			}
		}
		walk(rootId, 1, [rootId]);
		if (truncated) buf.add('... line limit reached (raise with --limit)\n');
		return buf.toString();
	}

	/** `id (file:line:col)` for an in-scope node, `id [external]` for a call target outside the scanned scope. */
	public static function nodeLabel(graph: CallGraph, id: String, sourceOf: (file:String) -> Null<String>): String {
		final n: Null<FnNode> = graph.node(id);
		if (n == null) return id;
		if (n.isExternal) return '$id [external]';
		final span: Null<Span> = n.span;
		final source: Null<String> = sourceOf(n.file);
		if (span == null || source == null) return '$id (${n.file})';
		final pos: Position = span.lineCol(source);
		return '$id (${n.file}:${pos.line}:${pos.col})';
	}

	/** ` @ file:line:col` of the call / reference site, or empty when unavailable. */
	public static function siteOf(edge: CallEdge, sourceOf: (file:String) -> Null<String>): String {
		final span: Null<Span> = edge.span;
		final source: Null<String> = sourceOf(edge.file);
		if (span == null || source == null) return '';
		final pos: Position = span.lineCol(source);
		return ' @ ${edge.file}:${pos.line}:${pos.col}';
	}

}
