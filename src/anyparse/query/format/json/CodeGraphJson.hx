package anyparse.query.format.json;

/**
 * A code graph as JSON (`anyparse.query.graph.GraphJson`) — the `--format json` output of `callers`,
 * `callees`, `reach` and `clusters`: the nodes ordered by id, the edges by source, target and kind.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CodeGraphJson = {

	var nodes: Array<CodeGraphNodeJson>;

	var edges: Array<CodeGraphEdgeJson>;
};
