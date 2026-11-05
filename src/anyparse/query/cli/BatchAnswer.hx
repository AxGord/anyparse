package anyparse.query.cli;

/** What one call of an `apq --batch` run answered: its exit status and both output streams. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BatchAnswer = {
	var status: Int;
	var out: String;
	var err: String;
}
