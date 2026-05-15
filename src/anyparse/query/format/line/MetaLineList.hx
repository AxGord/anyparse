package anyparse.query.format.line;

/**
 * Envelope for `apq meta` text output: one file's annotation lines,
 * newline-separated with a trailing newline. The empty case is the
 * renderer's concern (`$file: no meta\n`), so the writer never sees
 * a zero-element list.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef MetaLineList = {
	@:sep("\n") @:trail("\n") var lines:Array<MetaLine>;
};
