package dev;

/** A tree outside this one and its lint by the base engine. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef InfraSnapshot = {
	var tree: String;
	var snapshot: String;
}
