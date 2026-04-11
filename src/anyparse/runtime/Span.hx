package anyparse.runtime;

/**
 * Line-and-column position resolved from a `Span`'s byte offset.
 * Both fields are 1-indexed to match what editors and IDEs expect.
 */
typedef Position = {
	line:Int,
	col:Int,
};

/**
 * Byte-offset range into the parser input, used for error reporting and
 * AST node location metadata. A zero-width span (`from == to`) is valid
 * and is used when the error is at a point rather than over a range.
 *
 * Line and column resolution is lazy — `Span` itself stores only offsets,
 * and callers pass the source text to `lineCol` to get a 1-indexed
 * `{line, col}` for human-facing output. Phase 1 walks the source
 * linearly on every call; a shared incremental `LineColumnIndex` can be
 * plugged in later without changing the `Span` contract.
 */
@:nullSafety(Strict)
final class Span {

	public final from:Int;
	public final to:Int;

	public function new(from:Int, to:Int) {
		this.from = from;
		this.to = to;
	}

	/**
	 * Resolve the 1-indexed line and column of `from` within `source`.
	 *
	 * Walks `source` linearly up to `from`, counting `\n` as a line
	 * break. If `from` is past the end of `source` the walk stops at
	 * the end and the returned position points at one past the last
	 * character — the conventional "end of file" cursor behaviour.
	 */
	public function lineCol(source:String):Position {
		final end:Int = from < source.length ? from : source.length;
		var line:Int = 1;
		var col:Int = 1;
		for (i in 0...end) {
			if (source.charCodeAt(i) == '\n'.code) {
				line++;
				col = 1;
			} else {
				col++;
			}
		}
		return {line: line, col: col};
	}

	public function toString():String {
		return from == to ? '$from' : '$from..$to';
	}
}
