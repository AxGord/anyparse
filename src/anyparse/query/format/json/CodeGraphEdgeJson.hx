package anyparse.query.format.json;

/**
 * One edge of a `CodeGraphJson`: the ids of its ends, its kind (`call`, `ref`, `new`, `virtual`,
 * `accessor`, `contains`, `import`) and the number of sites it stands for.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CodeGraphEdgeJson = {

	var from: String;

	var to: String;

	var kind: String;

	var weight: Int;
};
