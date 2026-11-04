package anyparse.query.graph;

/** What a node of a function's flow chart stands for. */
enum abstract FlowKind(String) to String {

	final Start = 'start';
	final End = 'end';

	/** A run of consecutive declarations folded into one node. */
	final Declarations = 'declarations';

	/** A run of consecutive plain statements folded into one node. */
	final Steps = 'steps';

	/** An `if`: its condition, left by a `yes` and a `no` edge. */
	final Decision = 'decision';

	/** A loop's header, left by a `body` and a `done` edge, or the entry of a `do … while`. */
	final Loop = 'loop';

	final Switch = 'switch';
	final Try = 'try';
	final Catch = 'catch';
	final Return = 'return';
	final Throw = 'throw';
	final Break = 'break';
	final Continue = 'continue';

}

/**
 * One node of a flow chart: its `id`, what it is, the text a reader sees (a
 * folded run holds one line per statement) and the 1-based `line` it starts at.
 */
typedef FlowNode = {
	final id: String;
	final kind: FlowKind;
	var label: String;
	final line: Int;
}

/** One edge of a flow chart; a `label` names the branch it leaves a decision by. */
typedef FlowEdge = {
	final from: String;
	final to: String;
	final label: Null<String>;
}

/**
 * The control-flow chart of ONE function body (`FlowBuilder`): nodes in the order the body is read, edges in the order
 * they are drawn. The model the flow outputs (`FlowMermaid`, `FlowText`, `FlowJson`) all read.
 */
@:nullSafety(Strict)
final class FlowGraph {

	/** What the chart is of: the function's qualified name. */
	public final name: String;

	private final _nodes: Array<FlowNode> = [];
	private final _edges: Array<FlowEdge> = [];

	public function new(name: String) {
		this.name = name;
	}

	public inline function nodes(): Array<FlowNode> {
		return _nodes.copy();
	}

	/** A new node, numbered after the nodes already in the chart. */
	public function add(kind: FlowKind, label: String, line: Int): FlowNode {
		final node: FlowNode = {
			id: 'n${_nodes.length}',
			kind: kind,
			label: label,
			line: line
		};
		_nodes.push(node);
		return node;
	}

	public function connect(from: FlowNode, to: FlowNode, label: Null<String>): Void {
		_edges.push({ from: from.id, to: to.id, label: label });
	}

	public function edges(): Array<FlowEdge> {
		return _edges.copy();
	}

}
