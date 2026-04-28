package anyparse.grammar.haxe;

/**
 * Wildcard import / using path terminal — a dotted-ident sequence
 * suffixed with literal `.*`, captured verbatim as a single matched
 * slice.
 *
 * Covers `haxe.*`, `foo.bar.*`, and the single-segment `Pack.*` forms
 * in one regex. Distinguished from `HxTypeName` by the trailing `.*`,
 * which lets the branch dispatcher in `HxDecl` try the wildcard ctor
 * first and fall through to the plain `HxTypeName` ctor when the
 * trailing `.*` isn't present (mirrors the `PackageDecl` →
 * `PackageEmpty` rollback path).
 *
 * Captured as `@:rawString` so the writer round-trips the dotted slice
 * byte-for-byte without running it through the JSON-style unescape
 * loop.
 *
 * `from String to String` keeps existing call-site literals compiling —
 * tests can compare against `'haxe.*'` without explicit casts.
 */
@:re('[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*\\.\\*')
@:rawString
abstract HxWildPath(String) from String to String {}
