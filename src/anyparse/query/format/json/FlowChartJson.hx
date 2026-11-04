package anyparse.query.format.json;

/**
 * A function's flow chart as JSON (`anyparse.query.format.FlowJson`), the
 * `--format json` output of `graph --flow`: the nodes in reading order, then the edges.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FlowChartJson = {

	/** The qualified name of the function drawn. */
	var name: String;

	var nodes: Array<FlowNodeJson>;

	var edges: Array<FlowEdgeJson>;
};
