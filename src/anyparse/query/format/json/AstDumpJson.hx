package anyparse.query.format.json;

/**
 * Top-level envelope for `apq ast <file> --json` output in tree mode
 * (no `--select`). Matches the schema in `docs/cli-query-tool.md`:
 *
 *   { "file": "path/to/input", "tree": Node }
 *
 * Separate top-level module — see the sub-module gotcha noted on
 * `AstNodeJson`.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef AstDumpJson = {
	var file: String;
	var tree: AstNodeJson;
};
