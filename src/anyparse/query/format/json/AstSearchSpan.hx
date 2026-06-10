package anyparse.query.format.json;

/**
 * JSON shape for a source range in `apq search` output.
 *
 * Matches the spec sketch in `docs/cli-query-tool.md`:
 *
 *   Span = { start: [line, col], end: [line, col] }
 *
 * `line` is 1-based, `col` is 0-based. The two-element array form is
 * tighter than `{ line:Int, col:Int }` and produces compact JSON the
 * spec lays out verbatim.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstSearchSpan = {
	var start: Array<Int>;
	var end: Array<Int>;
};
