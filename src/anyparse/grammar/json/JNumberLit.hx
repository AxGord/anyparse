package anyparse.grammar.json;

/**
 * JSON number-literal terminal. A transparent abstract over `Float`,
 * the numeric counterpart of `JStringLit`.
 *
 * `from Float to Float` keeps `JNumber(42)` style literals compiling
 * (Int widens to Float which the abstract accepts) and lets
 * `JValueTools.equals` continue comparing values as plain floats.
 *
 * The `@:re` metadata matches an unsigned or signed JSON numeric
 * literal; the generated parser decodes the matched slice with
 * `Std.parseFloat`.
 */
@:re('-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?')
abstract JNumberLit(Float) from Float to Float {}
