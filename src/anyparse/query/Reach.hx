package anyparse.query;

import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;

/**
 * Path search for `apq reach --from A --to B` — BFS over the filtered edge
 * kinds, one SHORTEST path per (from, to) pair, `maxPaths` total. Triage
 * output, not an exhaustive path enumeration: the point is "does main-context
 * code reach this blocking call, and through which chain".
 */
@:nullSafety(Strict)
final class Reach {

	/**
	 * Shortest path from each id in `fromIds` to each reachable id in
	 * `toIds`. BFS parent-links make each path linear; a `from` that equals a
	 * `to` is skipped (the empty path says nothing).
	 */
	public static function paths(
		graph: CallGraph, fromIds: Array<String>, toIds: Array<String>, maxPaths: Int, kinds: Array<EdgeKind>
	): Array<Array<CallEdge>> {
		final result: Array<Array<CallEdge>> = [];
		for (fromId in fromIds) {
			if (result.length >= maxPaths) break;
			final parent: Map<String, CallEdge> = [];
			final queue: Array<String> = [fromId];
			var qi: Int = 0;
			while (qi < queue.length) {
				final id: String = queue[qi++];
				for (edge in graph.outEdges(id)) {
					if (!kinds.contains(edge.kind)) continue;
					final next: String = edge.to;
					if (next == fromId || parent.exists(next)) continue;
					parent[next] = edge;
					queue.push(next);
				}
			}
			for (toId in toIds) {
				if (result.length >= maxPaths) break;
				if (toId == fromId || !parent.exists(toId)) continue;
				final path: Array<CallEdge> = [];
				var cursor: String = toId;
				while (cursor != fromId) {
					final edge: Null<CallEdge> = parent[cursor];
					if (edge == null) break;
					path.unshift(edge);
					cursor = edge.from;
				}
				if (path.length > 0) result.push(path);
			}
		}
		return result;
	}

	/** One path: a summary chain line, then one indented line per hop with its edge kind and call site. */
	public static function render(graph: CallGraph, path: Array<CallEdge>, sourceOf: (file:String) -> Null<String>): String {
		if (path.length == 0) return '';
		final buf: StringBuf = new StringBuf();
		final chain: Array<String> = [path[0].from];
		for (edge in path) chain.push(edge.to);
		buf.add(chain.join(' -> ') + '\n');
		buf.add('  ${CallChains.nodeLabel(graph, path[0].from, sourceOf)}\n');
		for (edge in path) {
			final viaText: String = edge.via != null ? ' via ${edge.via}' : '';
			buf.add('  -> [${edge.kind.label()}$viaText] ${CallChains.nodeLabel(graph, edge.to, sourceOf)}${CallChains.siteOf(edge, sourceOf)}\n');
		}
		return buf.toString();
	}

}
