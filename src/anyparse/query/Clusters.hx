package anyparse.query;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnNode;
import anyparse.runtime.Span;

using Lambda;

import haxe.Exception;

/**
 * One extracted hub: a high-fan-in member pulled into the "utils bucket"
 * before component search so it does not glue unrelated members into one
 * blob. `fanIn` is the number of DISTINCT member callers within the type.
 */
typedef ClusterHub = {
	var id: String;
	var fanIn: Int;
}

/**
 * Aggregated member-level edge: all call sites from `from` to `to`
 * collapsed into one record with their count as `weight`.
 */
typedef MemberEdge = {
	var from: String;
	var to: String;
	var weight: Int;
}

/**
 * Hub traffic of one component — the component's interface to the utils
 * bucket. `toHub` counts component-member -> hub call sites, `fromHub`
 * counts hub -> component-member call sites (a nonzero `fromHub` is a
 * smell: the "utility" calls back into a specific cluster).
 */
typedef HubUse = {
	var component: Int;
	var hubId: String;
	var toHub: Int;
	var fromHub: Int;
}

/**
 * Partition analytics result for one type. `components` holds non-hub
 * members grouped by undirected call-edge connectivity, largest first.
 * Coverage counts are graph-quality metrics: `resolvedSites` is every
 * resolved call/ref/new site inside the type's members (any target),
 * `unresolvedSites` is every unresolved site inside a member span.
 */
typedef ClusterReport = {
	var typeName: String;
	var memberCount: Int;
	var intraEdgeSites: Int;
	var autoHubs: Bool;
	var hubs: Array<ClusterHub>;
	var components: Array<Array<FnNode>>;
	var hubUses: Array<HubUse>;
	var resolvedSites: Int;
	var unresolvedSites: Int;
}

/**
 * Partition analytics over the approximate `CallGraph` — the `apq clusters`
 * subcommand. Answers "along which lines does this god-type split?": member
 * nodes of one type are clustered by connected components over aggregated
 * intra-type call edges, after high-fan-in hubs are extracted into a utils
 * bucket (else one hub glues everything into a single blob). Lambdas and
 * local functions are condensed into their enclosing member (`a#1` -> `a`),
 * so the clustering unit is always the top-level member.
 */
@:nullSafety(Strict)
final class Clusters {

	/**
	 * Largest-component share of remaining members above which auto mode
	 * keeps extracting hubs — a blob this size means connected components
	 * alone cannot split the type.
	 */
	private static inline final AUTO_BLOB_SHARE: Float = 0.5;

	/**
	 * Auto mode never extracts more than this share of the type's members;
	 * past that the "utils bucket" stops being a bucket.
	 */
	private static inline final AUTO_HUB_SHARE: Float = 0.1;

	/**
	 * A component at or below this size is already a reviewable unit — auto
	 * mode never extracts hubs from it (guards tiny graphs, where any
	 * connected pair exceeds AUTO_BLOB_SHARE).
	 */
	private static inline final MIN_BLOB_MEMBERS: Int = 4;

	/**
	 * Coverage display scale (percent).
	 */
	private static inline final PERCENT: Int = 100;

	/**
	 * Cluster the members of `typeName`. `hubCount` selects hub extraction:
	 * `null` = auto (extract while the largest component stays a blob),
	 * `0` = off, `N` = exactly the top-N fan-in members (fan-in 0 excluded).
	 * `kinds` filters the edges used for connectivity (default call/ref/new;
	 * `Contains` self-condenses, `Virtual` never targets the own type).
	 * Returns `null` when the graph holds no members for `typeName`.
	 */
	public static function analyze(
		graph: CallGraph, typeName: String, hubCount: Null<Int>, kinds: Null<Array<EdgeKind>>
	): Null<ClusterReport> {
		final members: Array<FnNode> = [
			for (id => n in graph.nodes)
				if (n.typeName == typeName && n.name != null && !n.isExternal && id.indexOf('#') == -1) n
		];
		if (members.length == 0) return null;
		members.sort(byPosition);
		final memberIds: Array<String> = [for (m in members) m.id];

		final effectiveKinds: Array<EdgeKind> = kinds ?? [Call, Ref, New];
		final intraEdges: Array<MemberEdge> = aggregateIntraEdges(graph, memberIds, effectiveKinds);
		final adj: Map<String, Array<String>> = [];
		final inNeighbors: Map<String, Array<String>> = [];
		for (e in intraEdges) {
			neighborAdd(adj, e.from, e.to);
			neighborAdd(adj, e.to, e.from);
			neighborAdd(inNeighbors, e.to, e.from);
		}
		function fanIn(id: String): Int return (inNeighbors[id] ?? []).length;

		final hubIds: Array<String> = pickHubs(memberIds, adj, fanIn, hubCount);
		final hubs: Array<ClusterHub> = [for (id in hubIds) { id: id, fanIn: fanIn(id) }];
		hubs.sort((a, b) -> a.fanIn == b.fanIn ? (a.id < b.id ? -1 : 1) : b.fanIn - a.fanIn);

		final components: Array<Array<String>> = componentsOf(memberIds, adj, hubIds);
		components.sort((a, b) -> a.length == b.length ? (a[0] < b[0] ? -1 : 1) : b.length - a.length);
		final componentNodes: Array<Array<FnNode>> = [
			for (comp in components) {
				final nodes: Array<FnNode> = [for (id in comp) nodeOf(graph, id)];
				nodes.sort(byPosition);
				nodes;
			}
		];

		var intraEdgeSites: Int = 0;
		for (e in intraEdges) intraEdgeSites += e.weight;

		return {
			typeName: typeName,
			memberCount: members.length,
			intraEdgeSites: intraEdgeSites,
			autoHubs: hubCount == null,
			hubs: hubs,
			components: componentNodes,
			hubUses: collectHubUses(intraEdges, componentNodes, hubIds),
			resolvedSites: countResolvedSites(graph, memberIds),
			unresolvedSites: countUnresolvedSites(graph, members),
		};
	}

	/**
	 * Human-readable report: header with coverage, the hub bucket, then each
	 * component with its members and its hub traffic. `sourceOf` resolves
	 * file contents for line:col display (same seam as `CallChains.render`).
	 */
	public static function render(graph: CallGraph, report: ClusterReport, sourceOf: (file:String) -> Null<String>): String {
		final out: StringBuf = new StringBuf();
		final totalSites: Int = report.resolvedSites + report.unresolvedSites;
		final coverage: String = totalSites == 0
			? 'no call sites'
			: 'coverage ${Math.round(report.resolvedSites * PERCENT / totalSites)}% '
				+ '(${report.resolvedSites} resolved / ${report.unresolvedSites} unresolved call sites)';
		out.add(
			'clusters for ${report.typeName} — ${report.memberCount} members, ' + '${report.intraEdgeSites} intra-edge sites; $coverage\n'
		);

		if (report.hubs.length > 0) {
			final mode: String = report.autoHubs ? 'auto' : 'explicit';
			out.add('\nhubs ($mode — ${report.hubs.length} extracted):\n');
			for (h in report.hubs) out.add('  ${CallChains.nodeLabel(graph, h.id, sourceOf)}  fan-in ${h.fanIn}\n');
		}

		for (i => comp in report.components) {
			final index: Int = i + 1;
			out.add('\ncomponent $index — ${comp.length} member(s):\n');
			for (n in comp) out.add('  ${CallChains.nodeLabel(graph, n.id, sourceOf)}\n');
			final uses: Array<HubUse> = report.hubUses.filter(u -> u.component == index);
			final toHub: Array<String> = [for (u in uses) if (u.toHub > 0) '${shortName(u.hubId)} ×${u.toHub}'];
			final fromHub: Array<String> = [for (u in uses) if (u.fromHub > 0) '${shortName(u.hubId)} ×${u.fromHub}'];
			if (toHub.length > 0) out.add('  -> hubs: ${toHub.join(', ')}\n');
			if (fromHub.length > 0) out.add('  <- hubs: ${fromHub.join(', ')}\n');
		}
		return out.toString();
	}

	/**
	 * Condense a node id to its top-level member: lambdas and local
	 * functions (`Type.m#1`, `Type.m#helper`) belong to `Type.m`.
	 */
	private static function memberRoot(id: String): String {
		final hash: Int = id.indexOf('#');
		return hash == -1 ? id : id.substring(0, hash);
	}

	private static function shortName(id: String): String {
		final dot: Int = id.lastIndexOf('.');
		return dot == -1 ? id : id.substring(dot + 1);
	}

	private static function nodeOf(graph: CallGraph, id: String): FnNode {
		final n: Null<FnNode> = graph.node(id);
		if (n == null) throw new Exception('clusters: unknown node id $id');
		return n;
	}

	private static function byPosition(a: FnNode, b: FnNode): Int {
		if (a.file != b.file) return a.file < b.file ? -1 : 1;
		final af: Int = a.span?.from ?? 0;
		final bf: Int = b.span?.from ?? 0;
		return af - bf;
	}

	private static function neighborAdd(map: Map<String, Array<String>>, key: String, value: String): Void {
		final list: Array<String> = map[key] ?? [];
		if (list.length == 0) map[key] = list;
		if (!list.contains(value)) list.push(value);
	}

	/**
	 * Collapse every kind-filtered edge between two DIFFERENT members of the
	 * type into one weighted member-level edge, in first-seen order.
	 */
	private static function aggregateIntraEdges(graph: CallGraph, memberIds: Array<String>, kinds: Array<EdgeKind>): Array<MemberEdge> {
		final byPair: Map<String, MemberEdge> = [];
		final order: Array<MemberEdge> = [];
		for (e in graph.edges) if (kinds.contains(e.kind)) {
			final from: String = memberRoot(e.from);
			final to: String = memberRoot(e.to);
			if (from == to) continue;
			if (!memberIds.contains(from) || !memberIds.contains(to)) continue;
			final key: String = '$from|$to';
			final existing: Null<MemberEdge> = byPair[key];
			if (existing != null) {
				existing.weight++;
			} else {
				final edge: MemberEdge = { from: from, to: to, weight: 1 };
				byPair[key] = edge;
				order.push(edge);
			}
		}
		return order;
	}

	/**
	 * Hub selection. Explicit `N` takes the top-N by fan-in (ties broken by
	 * id, fan-in 0 never qualifies). Auto extracts the highest-fan-in member
	 * of the largest component while that component exceeds AUTO_BLOB_SHARE
	 * of the remaining members, capped at AUTO_HUB_SHARE of all members.
	 */
	private static function pickHubs(
		memberIds: Array<String>, adj: Map<String, Array<String>>, fanIn: (id:String) -> Int, hubCount: Null<Int>
	): Array<String> {
		if (hubCount != null && hubCount <= 0) return [];
		if (hubCount != null) {
			final ranked: Array<String> = memberIds.filter(id -> fanIn(id) > 0);
			ranked.sort((a, b) -> fanIn(a) == fanIn(b) ? (a < b ? -1 : 1) : fanIn(b) - fanIn(a));
			return ranked.slice(0, hubCount);
		}
		final hubIds: Array<String> = [];
		final cap: Int = Math.ceil(memberIds.length * AUTO_HUB_SHARE);
		while (hubIds.length < cap) {
			final components: Array<Array<String>> = componentsOf(memberIds, adj, hubIds);
			var largest: Array<String> = [];
			for (comp in components) if (comp.length > largest.length) largest = comp;
			if (largest.length <= MIN_BLOB_MEMBERS || largest.length <= AUTO_BLOB_SHARE * (memberIds.length - hubIds.length)) break;
			var best: Null<String> = null;
			for (id in largest) {
				final currentBest: Null<String> = best;
				if (currentBest == null || fanIn(id) > fanIn(currentBest) || (fanIn(id) == fanIn(currentBest) && id < currentBest))
					best = id;
			}
			final picked: Null<String> = best;
			if (picked == null || fanIn(picked) == 0) break;
			hubIds.push(picked);
		}
		return hubIds;
	}

	/**
	 * Undirected connected components over the non-excluded members, in
	 * member order (deterministic given the sorted `memberIds`).
	 */
	private static function componentsOf(
		memberIds: Array<String>, adj: Map<String, Array<String>>, excluded: Array<String>
	): Array<Array<String>> {
		final visited: Array<String> = [];
		final components: Array<Array<String>> = [];
		for (id in memberIds) if (!excluded.contains(id) && !visited.contains(id)) {
			final component: Array<String> = [];
			final queue: Array<String> = [id];
			visited.push(id);
			while (queue.length > 0) {
				final current: Null<String> = queue.shift();
				if (current == null) break;
				component.push(current);
				for (next in adj[current] ?? []) if (!excluded.contains(next) && !visited.contains(next)) {
					visited.push(next);
					queue.push(next);
				}
			}
			components.push(component);
		}
		return components;
	}

	/**
	 * Directed hub traffic per component, sorted by (component, hub id).
	 */
	private static function collectHubUses(
		intraEdges: Array<MemberEdge>, components: Array<Array<FnNode>>, hubIds: Array<String>
	): Array<HubUse> {
		final componentIndex: Map<String, Int> = [];
		for (i => comp in components) for (n in comp) componentIndex[n.id] = i + 1;
		final byKey: Map<String, HubUse> = [];
		final order: Array<HubUse> = [];
		inline function use(component: Int, hubId: String): HubUse {
			final key: String = '$component|$hubId';
			final existing: Null<HubUse> = byKey[key];
			if (existing != null) return existing;
			final created: HubUse = {
				component: component,
				hubId: hubId,
				toHub: 0,
				fromHub: 0
			};
			byKey[key] = created;
			order.push(created);
			return created;
		}
		for (e in intraEdges) {
			final fromComp: Null<Int> = componentIndex[e.from];
			final toComp: Null<Int> = componentIndex[e.to];
			if (fromComp != null && hubIds.contains(e.to)) use(fromComp, e.to).toHub += e.weight;
			if (toComp != null && hubIds.contains(e.from)) use(toComp, e.from).fromHub += e.weight;
		}
		order.sort((a, b) -> a.component == b.component ? (a.hubId < b.hubId ? -1 : 1) : a.component - b.component);
		return order;
	}

	/**
	 * Every resolved call/ref/new site whose source lies in one of the
	 * type's members — fixed kinds, independent of the clustering filter
	 * (`Virtual` would double-count the instance-call sites it accompanies).
	 */
	private static function countResolvedSites(graph: CallGraph, memberIds: Array<String>): Int {
		final coverageKinds: Array<EdgeKind> = [Call, Ref, New];
		var count: Int = 0;
		for (e in graph.edges) if (coverageKinds.contains(e.kind) && memberIds.contains(memberRoot(e.from))) count++;
		return count;
	}

	/**
	 * Unresolved call sites positioned inside any member span of the type.
	 */
	private static function countUnresolvedSites(graph: CallGraph, members: Array<FnNode>): Int {
		var count: Int = 0;
		for (u in graph.unresolved) {
			final span: Null<Span> = u.span;
			if (span == null) continue;
			if (members.exists(m -> {
				final ms: Null<Span> = m.span;
				m.file == u.file && ms != null && span.from >= ms.from && span.to <= ms.to;
			})) count++;
		}
		return count;
	}

}
