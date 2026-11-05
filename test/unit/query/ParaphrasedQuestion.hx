package unit.query;

/** One held-out question of a benchmark file and the types whose answer it is. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef ParaphrasedQuestion = {
	var question: String;
	var owners: Array<String>;
};
