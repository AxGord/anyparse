package anyparse.query.cli;

/** What `apq --batch` writes: one answer per call, in the order of the calls. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BatchAnswers = {
	var answers: Array<BatchAnswer>;
}
