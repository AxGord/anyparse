package anyparse.grammar.json;

/**
 * JSON boolean-literal terminal. A transparent abstract over `Bool`,
 * matching exactly `true` / `false`. Used by typed-JSON schemas for
 * `Bool` fields — the generated parser decodes the matched slice by
 * comparing against `'true'`.
 */
@:re('true|false')
abstract JBoolLit(Bool) from Bool to Bool {}
