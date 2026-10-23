package anyparse.query.graph;

/**
 * The scale a graph node stands at. A package holds types, a type holds members; a group holds
 * whatever an analysis partitions together (a component of a cluster report) and is no declaration.
 */
enum abstract GraphLevel(String) to String {

	final Package = 'package';
	final Type = 'type';
	final Member = 'member';
	final Group = 'group';

	/** The prefix of a node id at this level: a package and a type of one name stay two nodes. */
	public function idPrefix(): String {
		return switch (cast this: GraphLevel) {
			case Package: 'p_';
			case Type: 't_';
			case Member: 'm_';
			case Group: 'g_';
		};
	}

}

/**
 * What an edge says about its ends: the call-graph kinds (`CallGraph.EdgeKind`) and an import, which
 * joins the file that writes it to the module or package it names.
 */
enum abstract GraphEdgeKind(String) to String {

	final Call = 'call';
	final Ref = 'ref';
	final New = 'new';
	final Virtual = 'virtual';
	final Accessor = 'accessor';
	final Contains = 'contains';
	final Import = 'import';

}

/**
 * One node. `id` is derived from `level` and `name` alone (`CodeGraph.idOf`), so the same declaration
 * gets the same id in every graph and every run, and the id is a valid Mermaid node id as it stands.
 */
typedef GraphNode = {

	final id: String;
	final level: GraphLevel;

	/** The qualified name the id is derived from (`pkg.Type.member`). */
	final name: String;

	/** What a reader sees. */
	final label: String;

	/** The node holding this one, or null for a top-level node. */
	final parent: Null<String>;

	/** A node outside the scanned scope: a call target with no body here. */
	final external: Bool;

	/** A node the query asked about: a `callees` target, a `reach` end. */
	var focus: Bool;
}

/** One edge per (from, to, kind): `weight` counts the sites it stands for. */
typedef GraphEdge = {

	final from: String;
	final to: String;
	final kind: GraphEdgeKind;
	var weight: Int;
}

/**
 * A code graph: package, type and member nodes nested by `parent`, joined by weighted edges. The model
 * every graph output renders — Mermaid (`GraphMermaid`), JSON (`GraphJson`) — and knows no grammar: the
 * builders read declarations through the query layer (`MemberGraphBuilder`, `ImportGraph`).
 *
 * Every listing is ordered by id, so one graph renders to the same bytes whatever order it was built in.
 */
@:nullSafety(Strict)
final class CodeGraph {

	private final _nodes: Map<String, GraphNode> = [];
	private final _edges: Map<String, GraphEdge> = [];

	public function new() {}

	public inline function node(id: String): Null<GraphNode> {
		return _nodes[id];
	}

	/** Add the node at `level` named `name` unless the graph holds it, and answer its id; the first addition's fields stay. */
	public function addNode(level: GraphLevel, name: String, label: String, parent: Null<String>, external: Bool): String {
		final id: String = idOf(level, name);
		if (!_nodes.exists(id)) {
			if (parent != null && !_nodes.exists(parent)) throw new Exception('graph: parent $parent of $id is no node');
			final added: GraphNode = {
				id: id,
				level: level,
				name: name,
				label: label,
				parent: parent,
				external: external,
				focus: false
			};
			_nodes[id] = added;
		}
		return id;
	}

	/** Mark the node `id` as one the query asked about. */
	public function markFocus(id: String): Void {
		final n: Null<GraphNode> = _nodes[id];
		if (n == null) throw new Exception('graph: no node $id');
		n.focus = true;
	}

	/** Count `weight` more sites of `kind` from `from` to `to`, both of them nodes already. */
	public function addEdge(from: String, to: String, kind: GraphEdgeKind, weight: Int = 1): Void {
		if (!_nodes.exists(from) || !_nodes.exists(to)) throw new Exception('graph: an edge $from -> $to joins no node');
		final key: String = '$from $to $kind';
		final existing: Null<GraphEdge> = _edges[key];
		if (existing != null) {
			existing.weight += weight;
		} else {
			final added: GraphEdge = {
				from: from,
				to: to,
				kind: kind,
				weight: weight
			};
			_edges[key] = added;
		}
	}

	/** Every node, ordered by id. */
	public function nodes(): Array<GraphNode> {
		final all: Array<GraphNode> = [for (n in _nodes) n];
		all.sort((a, b) -> compareText(a.id, b.id));
		return all;
	}

	/** The nodes `parent` holds — the top-level nodes for null — ordered by id. */
	public function childrenOf(parent: Null<String>): Array<GraphNode> {
		return nodes().filter(n -> n.parent == parent);
	}

	/** Every edge, ordered by source, then target, then kind. */
	public function edges(): Array<GraphEdge> {
		final all: Array<GraphEdge> = [for (e in _edges) e];
		all.sort((a, b) ->
			if (a.from != b.from)
				compareText(a.from, b.from)
			else if (a.to != b.to)
				compareText(a.to, b.to)
			else
				compareText(a.kind, b.kind)
		);
		return all;
	}

	/**
	 * The id of the node at `level` named `name`: the level's prefix, then the name with every character
	 * but a letter or a digit escaped — `_` as `__`, `.` as `_d`, any other as `_x<hex>_`. Each escape
	 * opens with `_` and is told apart by the character after it, so two names never share an id, and an
	 * id holds nothing Mermaid reads as syntax.
	 */
	public static function idOf(level: GraphLevel, name: String): String {
		final out: StringBuf = new StringBuf();
		out.add(level.idPrefix());
		for (i in 0...name.length) {
			final c: Int = name.fastCodeAt(i);
			if (isAlphanumeric(c))
				out.addChar(c)
			else if (c == '_'.code)
				out.add('__')
			else if (c == '.'.code)
				out.add('_d')
			else
				out.add('_x${c.hex()}_');
		}
		return out.toString();
	}

	private static inline function isAlphanumeric(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

	private static inline function compareText(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

}
