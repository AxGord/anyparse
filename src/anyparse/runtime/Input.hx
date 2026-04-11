package anyparse.runtime;

/**
 * Byte/character stream abstraction used by generated and hand-written
 * parsers. The runtime never accesses the underlying source directly —
 * everything goes through `Input` so we can later swap `StringInput` for
 * `BytesInput`, `FileInput`, or a memory-mapped variant without touching
 * the parser logic.
 *
 * Implementations must:
 *
 * - Return a stable `length` for the duration of a parse.
 * - Return `-1` from `charCodeAt` for positions outside `[0, length)`;
 *   callers rely on this as an end-of-input sentinel rather than
 *   propagating `null`.
 * - Return a plain `String` slice from `substring(from, to)` with the
 *   usual `to`-exclusive semantics. Implementations are free to share
 *   underlying storage where that is safe.
 */
interface Input {
	var length(get, never):Int;

	function charCodeAt(pos:Int):Int;

	function substring(from:Int, to:Int):String;
}
