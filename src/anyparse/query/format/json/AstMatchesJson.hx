package anyparse.query.format.json;

/**
 * Top-level envelope for `apq ast <file> --json --select <path>`
 * output. Matches the schema in `docs/cli-query-tool.md`:
 *
 *   { "file": "path/to/input", "matches": Node[] }
 *
 * Separate top-level module — see the sub-module gotcha noted on
 * `AstNodeJson`.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstMatchesJson = {
	var file:String;
	var matches:Array<AstNodeJson>;
};
