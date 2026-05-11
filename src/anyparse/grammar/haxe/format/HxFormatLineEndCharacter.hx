package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.lineEndCharacter`
 * field accepts. Mapped by `HaxeFormatConfigLoader` to the runtime
 * `WriteOptions.lineEnd` String emitted by the renderer for every
 * break-mode `Line` / `OptHardline`:
 *
 * - `"LF"` → `"\n"` (Unix)
 * - `"CRLF"` → `"\r\n"` (Windows)
 * - `"CR"` → `"\r"` (legacy Mac)
 * - `"auto"` → `"\n"` (default — no source-detection plumbing yet;
 *   fork uses `parsedCode.lineSeparator` here, we fall back to LF
 *   because the writer is decoupled from the source byte stream)
 *
 * Slice ω-lineend-character.
 */
enum abstract HxFormatLineEndCharacter(String) to String {

	final Auto = 'auto';

	final LF = 'LF';

	final CR = 'CR';

	final CRLF = 'CRLF';
}
