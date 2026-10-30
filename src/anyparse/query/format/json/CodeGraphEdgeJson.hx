package anyparse.query.format.json;

/**
 * One edge of a `CodeGraphJson`: the ids of its ends, its kind (`call`, `ref`, `new`, `virtual`,
 * `accessor`, `contains`, `import`), the number of sites it stands for, and whether its ends depend on each other.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CodeGraphEdgeJson = {

	var from: String;

	var to: String;

	var kind: String;

	var weight: Int;

	/** Present and true when an edge runs back from `to` to `from`: the two ends depend on each other. */
	@:optional var mutual: Null<Bool>;
};
