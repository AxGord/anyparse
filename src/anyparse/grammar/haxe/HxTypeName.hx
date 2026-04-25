package anyparse.grammar.haxe;

/**
 * Possibly module-qualified type name terminal — one or more identifiers
 * separated by dots, captured verbatim as a single matched slice.
 *
 * Covers the bare `Int`, sub-module `Module.SubType`, and pack-qualified
 * `haxe.io.Bytes` forms in one regex match. Type-parameter brackets,
 * function arrow types, and anonymous-struct types live elsewhere — this
 * terminal only owns the dotted-ident sequence that prefixes them on a
 * `HxTypeRef`.
 *
 * Captured as `@:rawString` so the writer round-trips the dotted slice
 * byte-for-byte without running it through the JSON-style unescape loop.
 *
 * `from String to String` keeps existing call-site literals compiling —
 * tests can compare against `'haxe.io.Bytes'` without explicit casts.
 */
@:re('[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*')
@:rawString
abstract HxTypeName(String) from String to String {}
