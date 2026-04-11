package anyparse.grammar.json;

/**
 * Marker class for the macro-generated Fast-mode parser of `JValue`.
 *
 * The `@:build` metadata invokes `anyparse.macro.Build.buildParser`
 * with `JValue` as the grammar root; the macro reads `JValue`'s
 * metadata (`@:schema`, `@:ws`, per-constructor `@:lit` / `@:lead` /
 * `@:trail` / `@:sep`) and fills this class with a `parse(source)`
 * entry point plus the private `parseXxx` recursive-descent helpers.
 *
 * The class body is empty on purpose: every method here is
 * contributed by the macro. Keep it in sync with `JValue` by leaving
 * this file alone and rebuilding — edits to the grammar take effect
 * automatically because the macro re-runs on every compile.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.json.JValue))
@:nullSafety(Strict)
class JValueFastParser {}
