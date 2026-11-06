package anyparse.query.format.json;

/** A written dominated lock: the lock and the locks one of which every long hold of it holds. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef DominatedLockRecord = {

	var lock: String;

	var by: Array<String>;
};
