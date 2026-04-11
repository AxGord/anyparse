package anyparse.grammar.json;

/**
	One key-value pair of a JSON object.

	Represented as a typedef over an anonymous structure rather than as a
	class: we want structural comparison for tests and cheap construction in
	generated code.
**/
typedef JEntry = {
	key:String,
	value:JValue,
}
