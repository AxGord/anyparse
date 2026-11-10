package anyparse.grammar.haxe;

/**
 * Object-literal field-key terminal — either a bare Haxe identifier or a
 * quoted string literal (`{ "name": value }`, `{ 'kebab-case': v }`).
 *
 * Exact mirror of `HxIdentLit` / `HxFieldNameLit` (transparent `String`
 * abstract, `@:re` picked up by the `Re` strategy, `@:rawString` so the
 * matched slice is used verbatim) differing only by the regex: the
 * double-quoted and single-quoted string alternatives are tried FIRST, then
 * the standard identifier. PEG alternation is ordered and non-backtracking — a
 * leading quote of either kind is consumed by its string alt, a bare
 * identifier starts with neither so it falls cleanly to the last alt. Used solely as the `name`
 * slot of `HxObjectField`; every other identifier position keeps
 * `HxIdentLit` so quoted strings are not accepted as variable/type names.
 *
 * AST-contract note: for a quoted key the surrounding quotes are part of
 * the stored slice (`@:rawString`), so `(field.name : String)` returns
 * `"name"` *with* the quotes — not `name`. The writer's generic terminal
 * emit prints the slice verbatim, so `{ "name": v }` round-trips
 * byte-for-byte with no format-side change.
 *
 * Intentionally permissive, in line with `HxFieldNameLit`'s philosophy.
 * A single-quoted key is kept verbatim like a double-quoted one, `$` included.
 * Deferred (a future slice if a non-compounding corpus
 * fixture demands it): an escaped quote inside a key (the class stops at the
 * first closing quote).
 *
 * `@:re` argument is single-quoted: the pattern contains `"` but no `$`,
 * so interpolation is not a concern and single-quote matches the dominant
 * grammar convention.
 *
 * `from String to String` keeps existing call-site literals and the
 * `(field.name : String)` test casts compiling without explicit casts.
 */
@:re('"[^"]*"|\'[^\']*\'|[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxObjectKeyLit(String) from String to String {}
