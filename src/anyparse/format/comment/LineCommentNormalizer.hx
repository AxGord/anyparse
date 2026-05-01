package anyparse.format.comment;

/**
 * Engine-level adapter for captured C-family line comments (`//…`).
 *
 * Lives next to `BlockCommentNormalizer` so any grammar (Haxe, AS3,
 * JS, C/C++, Rust, …) wires `normalizeLineComment` into its format's
 * `defaultWriteOptions.lineCommentAdapter` and gets the standard
 * `// foo` ↔ `//foo` policy without plugin code.
 *
 * Mirrors haxe-formatter's `MarkTokenText.printCommentLine`:
 *  - body matches `^[/\*\-\s]+` (decoration runs like `//*****`,
 *    `//---------`, `////`, or already-spaced bodies) → keep tight,
 *    rtrim trailing whitespace
 *  - `addSpace == true` → emit `// <trimmed body>` (insert one space
 *    after `//`)
 *  - `addSpace == false` → emit `//<trimmed body>` (knob off: no
 *    leading-space pass)
 *
 * `verbatim` is the captured string WITH the `//` delimiter
 * (`leadingComments[i]` and the `collectTrailingFull` close-trail
 * slot store it that way). For the body-only `collectTrailing`
 * trailing form, callers pass `'//' + body`.
 *
 * Non-`//` input (block comment, plain text, anything else) is
 * returned untouched — the helper short-circuits so callers can
 * route every captured trivia string through here without a type-
 * tag dispatch.
 */
class LineCommentNormalizer {

	public static function normalizeLineComment(verbatim:String, addSpace:Bool):String {
		if (!StringTools.startsWith(verbatim, '//')) return verbatim;
		final body:String = verbatim.substr(2);
		if (isDecorationPrefix(body)) return '//' + StringTools.rtrim(body);
		final trimmed:String = StringTools.trim(body);
		return addSpace ? '// ' + trimmed : '//' + trimmed;
	}

	private static function isDecorationPrefix(body:String):Bool {
		if (body.length == 0) return false;
		final c:Int = StringTools.fastCodeAt(body, 0);
		return c == '/'.code || c == '*'.code || c == '-'.code
			|| c == ' '.code || c == '\t'.code || c == '\r'.code;
	}
}
