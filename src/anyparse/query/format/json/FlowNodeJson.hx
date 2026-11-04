package anyparse.query.format.json;

/**
 * One node of a `FlowChartJson`: its `id`, its `kind` (`start`, `end`, `declarations`, `steps`, `decision`, `loop`, `switch`,
 * `try`, `catch`, `return`, `throw`, `break`, `continue`), the `label` a reader sees and the 1-based `line` it starts at.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FlowNodeJson = {

	var id: String;

	var kind: String;

	var label: String;

	var line: Int;
};
