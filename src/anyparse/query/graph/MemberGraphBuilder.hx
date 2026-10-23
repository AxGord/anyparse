package anyparse.query.graph;

import anyparse.query.CallGraph;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.Clusters.ClusterReport;
import anyparse.query.SymbolIndex;
import anyparse.query.graph.CodeGraph.GraphEdgeKind;

/**
 * Lifts a `CallGraph` to the member level of a `CodeGraph`: each function node folds into the member
 * that declares it — a lambda or a local function into its enclosing member, a further `#if` body into
 * its first — and nests in its type, the type in its package. An edge inside one member is dropped
 * unless it is the member calling itself; a local function's own recursion stays inside.
 *
 * The package of a node is its file's, as the call graph's index reads it; an external node, a call
 * target outside the scope, has a type and no package.
 */
@:nullSafety(Strict)
final class MemberGraphBuilder {

	/** What joins a function's id and a lambda or local function declared in it (`CallGraphNodes`). */
	private static inline final LOCAL_MARK: String = '#';

	public final graph: CodeGraph = new CodeGraph();

	/** File -> its package, for every file the call graph's index holds. */
	private final _packages: Map<String, String> = [];

	private final _calls: CallGraph;

	public function new(calls: CallGraph) {
		_calls = calls;
		final index: Null<SymbolIndex> = calls.index;
		if (index != null) for (info in index.allFiles()) _packages[info.file] = info.pkg;
	}

	/** Count the call-graph edge `e` on the members its ends fold into. */
	public inline function edge(e: CallEdge): Void {
		link(e.from, e.to, e.kind, 1);
	}

	/** The member node the function `fnId` folds into, added with its type and package. */
	public function member(fnId: String): String {
		final fn: FnNode = fnOf(memberRoot(fnId));
		return memberIn(fn, typeNode(fn));
	}

	/** Count `weight` sites of `kind` from the function `from` to the function `to` on the members they fold into. */
	public function link(from: String, to: String, kind: EdgeKind, weight: Int): Void {
		final source: String = member(from);
		final target: String = member(to);
		// inside one member only the member's own recursion is drawn, never a local function's
		if (source == target && (from != to || memberRoot(from) != from)) return;
		graph.addEdge(source, target, kindOf(kind), weight);
	}

	/** Mark the member `fnId` folds into as one the query asked about. */
	public function focus(fnId: String): Void {
		graph.markFocus(member(fnId));
	}

	/** The type node of `fn`, added with its package; null for a function no type declares. */
	private function typeNode(fn: FnNode): Null<String> {
		final typeName: Null<String> = fn.typeName;
		if (typeName == null) return null;
		final pkg: String = fn.isExternal ? '' : _packages[fn.file] ?? '';
		final packageId: Null<String> = pkg == '' ? null : graph.addNode(Package, pkg, pkg, null, false);
		return graph.addNode(Type, qualify(pkg, typeName), typeName, packageId, fn.isExternal);
	}

	/** The member node of `fn` under `parent`, unless the graph holds it already. */
	private function memberIn(fn: FnNode, parent: Null<String>): String {
		final typeName: Null<String> = fn.typeName;
		final label: String = typeName != null && fn.id.startsWith('$typeName.') ? fn.id.substr(typeName.length + 1) : fn.id;
		final pkg: String = fn.isExternal ? '' : _packages[fn.file] ?? '';
		return graph.addNode(Member, qualify(pkg, fn.id), label, parent, fn.isExternal);
	}

	/** Each member's call-graph id -> every function folding into it (`memberRoot`). */
	private function foldedFunctions(): Map<String, Array<String>> {
		final out: Map<String, Array<String>> = [];
		for (id in _calls.nodes.keys()) {
			final root: String = memberRoot(id);
			final list: Null<Array<String>> = out[root];
			if (list == null)
				out[root] = [id]
			else
				list.push(id);
		}
		return out;
	}

	private function fnOf(id: String): FnNode {
		final fn: Null<FnNode> = _calls.node(id);
		if (fn == null) throw new Exception('graph: the call graph holds no function $id');
		return fn;
	}

	/** The id of the member `fnId` folds into: its enclosing member, its first body; itself when no such node exists. */
	private function memberRoot(fnId: String): String {
		final local: Int = fnId.indexOf(LOCAL_MARK);
		final enclosing: String = local < 0 ? fnId : fnId.substring(0, local);
		final body: Int = enclosing.lastIndexOf(CallGraph.BODY_MARK);
		final first: String = body < 0 ? enclosing : enclosing.substring(0, body);
		return if (_calls.node(first) != null)
			first
		else if (_calls.node(enclosing) != null)
			enclosing
		else
			fnId;
	}

	/**
	 * The graph `callees` (`outward`) or `callers` draws: every edge a walk of `depth` member hops from `roots` crosses, the
	 * roots focused. A member is expanded once, at the first hop that reaches it, through every function folding into it, so
	 * a lambda or a local function costs no hop; `kinds` null or empty is all.
	 */
	public static function chains(
		calls: CallGraph, roots: Array<String>, depth: Int, outward: Bool, kinds: Null<Array<EdgeKind>>
	): CodeGraph {
		final builder: MemberGraphBuilder = new MemberGraphBuilder(calls);
		final kindFilter: Array<EdgeKind> = kinds ?? [];
		final folded: Map<String, Array<String>> = builder.foldedFunctions();
		// a member reached -> the hop that reached it
		final reached: Map<String, Int> = [];
		var frontier: Array<String> = [];
		for (root in roots) {
			builder.focus(root);
			final member: String = builder.memberRoot(root);
			if (reached.exists(member)) continue;
			reached[member] = 0;
			frontier.push(member);
		}
		for (hop in 1...depth + 1) {
			final next: Array<String> = [];
			for (member in frontier) for (fn in folded[member] ?? [member]) for (e in (
				outward ? calls.outEdges(fn) : calls.inEdges(fn)
			)) if (kindFilter.length == 0 || kindFilter.contains(e.kind)) {
				builder.edge(e);
				final other: String = builder.memberRoot(outward ? e.to : e.from);
				if (reached.exists(other)) continue;
				reached[other] = hop;
				next.push(other);
			}
			frontier = next;
		}
		return builder.graph;
	}

	/** The graph `reach` draws: the edges of every path found, each path's two ends focused. */
	public static function paths(calls: CallGraph, found: Array<Array<CallEdge>>): CodeGraph {
		final builder: MemberGraphBuilder = new MemberGraphBuilder(calls);
		for (path in found) if (path.length > 0) {
			for (e in path) builder.edge(e);
			builder.focus(path[0].from);
			builder.focus(path[path.length - 1].to);
		}
		return builder.graph;
	}

	/**
	 * The graph `clusters` draws: the type's members in one group per component and one for the hubs, joined by the
	 * report's aggregated intra-type edges.
	 */
	public static function clusters(calls: CallGraph, report: ClusterReport): CodeGraph {
		final builder: MemberGraphBuilder = new MemberGraphBuilder(calls);
		final any: Null<FnNode> = if (report.components.length > 0 && report.components[0].length > 0)
			report.components[0][0]
		else if (report.hubs.length > 0)
			calls.node(report.hubs[0].id)
		else
			null;
		if (any == null) return builder.graph;
		final typeId: Null<String> = builder.typeNode(any);
		final typeName: String = builder.graph.node(typeId ?? '')?.name ?? report.typeName;
		if (report.hubs.length > 0) {
			final hubs: String = builder.graph.addNode(Group, '$typeName hubs', 'hubs', typeId, false);
			for (h in report.hubs) builder.memberIn(builder.fnOf(h.id), hubs);
		}
		for (i => component in report.components) {
			final group: String = builder.graph.addNode(Group, '$typeName component ${i + 1}', 'component ${i + 1}', typeId, false);
			for (n in component) builder.memberIn(n, group);
		}
		for (e in report.edges) builder.link(e.from, e.to, e.kind, e.weight);
		return builder.graph;
	}

	private static inline function qualify(pkg: String, name: String): String {
		return pkg == '' ? name : '$pkg.$name';
	}

	private static function kindOf(kind: EdgeKind): GraphEdgeKind {
		return switch kind {
			case Call: GraphEdgeKind.Call;
			case Ref: GraphEdgeKind.Ref;
			case New: GraphEdgeKind.New;
			case Virtual: GraphEdgeKind.Virtual;
			case Contains: GraphEdgeKind.Contains;
			case Accessor: GraphEdgeKind.Accessor;
		};
	}

}
