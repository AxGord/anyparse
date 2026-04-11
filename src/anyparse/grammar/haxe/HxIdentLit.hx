package anyparse.grammar.haxe;

/**
 * Haxe identifier terminal. A transparent abstract over `String` so the
 * `Re` strategy picks up the `@:re` pattern and uses the abstract's name
 * as the generated sub-rule name.
 *
 * The pattern matches a standard Haxe identifier: an ASCII letter or
 * underscore, followed by any number of ASCII letters, digits, or
 * underscores. Unicode identifiers are out of scope for the Phase 3
 * skeleton.
 *
 * `@:rawString` instructs `Lowering.lowerTerminal` to use the matched
 * slice directly as the result value instead of running it through the
 * JSON string-unescape helper. This is the minimal workaround to the
 * closed Phase 2 decoder table (D13) for identifier-like String
 * terminals; a format-contributed decoder table will replace it once a
 * third Terminal type (e.g. a real Haxe string literal with escapes)
 * demands it. `@:rawString` was chosen over a bare `@:raw` to avoid
 * collision with Haxe's built-in `@:raw` meta for verbatim code
 * injection.
 *
 * `from String to String` keeps existing call-site literals compiling —
 * tests can build expected ASTs with plain strings without explicit
 * casts.
 */
@:re('[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxIdentLit(String) from String to String {}
