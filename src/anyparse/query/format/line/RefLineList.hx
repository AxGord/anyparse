package anyparse.query.format.line;

/**
 * Envelope for `apq refs` text output: the lines of one file,
 * newline-separated with a trailing newline (matching the previous
 * hand-rolled `StringBuf` output byte-for-byte). The empty case is
 * handled by the renderer (`$file: no refs\n`), so the writer never
 * sees a zero-element list.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef RefLineList = {
	@:sep("\n") @:trail("\n") var lines:Array<RefLine>;
};
