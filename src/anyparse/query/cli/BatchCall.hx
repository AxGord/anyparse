package anyparse.query.cli;

/** One invocation of an `apq --batch` run: the argv after the program name, the directory it runs in, and its standard input. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef BatchCall = {
	var argv: Array<String>;
	var cwd: String;
	var ?stdin: Null<String>;
}
