package anyparse.query.format.line;

/**
 * Envelope for `apq search` text output: one file's match lines,
 * newline-separated with a trailing newline. The empty case is the
 * renderer's concern (`$file: no matches\n`), so the writer never
 * sees a zero-element list.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef SearchLineList = {
	@:sep("\n") @:trail("\n") var lines:Array<SearchLine>;
};
