package anyparse.query.format.json;

/** One edge of a `FlowChartJson`; the `label` names the branch it leaves a decision by and is absent on the others. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FlowEdgeJson = {
	var from: String;
	var to: String;
	@:optional var label: Null<String>;
};
