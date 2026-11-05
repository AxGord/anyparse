package anyparse.query.cli;

/** What `apq --batch` reads: the calls it runs, in order (a schema cannot root on an array). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BatchCalls = {
	var calls: Array<BatchCall>;
}
