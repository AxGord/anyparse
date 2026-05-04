package anyparse.grammar.haxe;

/**
 * Raw-string regex terminal capturing a single metadata tag verbatim:
 * `@name`, `@:name`, or `@:name(args)` with up to three levels of
 * nested parentheses. The fallthrough catch-all branch of the
 * `HxMetadata` enum — preserves the byte-exact regex semantics of the
 * pre-enum `HxMetadata` abstract for non-structurally-parsed metas
 * (`@:enum`, `@:allow(pack.Cls)`, `@:keep`, `@test("foo")`, etc.).
 *
 * Strategically split out so the enum's `PlainMeta(raw:HxMetaRaw)`
 * branch is a Case 3 single-Ref descent that emits the raw bytes
 * via `@:rawString`'s `_dt(value)` path with no surrounding wrap —
 * preserving byte-perfect round-trip for every meta the
 * structurally-parsed branches don't claim.
 *
 * Pattern caveats inherited from the pre-enum `HxMetadata`:
 *  - Up to three levels of nested parens. Deeper literals truncate
 *    the match, leaving inner parens for the next field to choke on.
 *  - Strings embedding `(` / `)` inside the argument block (e.g.
 *    `@:deprecated("has (parens) inside")`) are NOT understood — a
 *    paren-counting regex cannot track string boundaries. No such
 *    form is in the current target fixture set; a future slice can
 *    swap in a string-aware runtime helper when needed.
 *
 * `@:rawString` routes the matched slice through
 * `Lowering.lowerTerminal` without running the JSON-style unescape
 * loop — metadata source is not a Haxe string literal and must be
 * preserved byte-exact.
 *
 * `from String to String` keeps existing call-site literals
 * compiling — tests can build expected values with plain strings
 * without explicit casts and read them back with `(raw : String)`.
 */
@:re('@:?[A-Za-z_][A-Za-z0-9_]*(?:\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))?')
@:rawString
abstract HxMetaRaw(String) from String to String {}
