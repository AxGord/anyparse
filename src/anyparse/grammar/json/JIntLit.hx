package anyparse.grammar.json;

/**
 * JSON integer-literal terminal. A transparent abstract over `Int`,
 * matching the integer subset of the JSON number grammar (no decimal
 * point, no exponent). Used by typed-JSON schemas that need strict
 * integer fields — `JNumberLit` accepts the full numeric range and
 * returns `Float`, which would silently lose precision on large
 * integers.
 */
@:re('-?(?:0|[1-9][0-9]*)')
abstract JIntLit(Int) from Int to Int {}
