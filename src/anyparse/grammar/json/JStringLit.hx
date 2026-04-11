package anyparse.grammar.json;

/**
 * JSON string-literal terminal. A transparent abstract over `String`,
 * kept as its own type so the macro pipeline's `Re` strategy can read
 * the `@:re` pattern off it without entangling the pattern with the
 * enclosing `JValue` enum.
 *
 * `from String to String` makes the abstract transparent to existing
 * user code (`JString("hello")` literals compile unchanged, and
 * `JValueTools.equals` keeps comparing values as plain strings).
 *
 * The `@:re` metadata matches a complete JSON double-quoted string
 * including its surrounding quotes. The generated parser strips the
 * quotes and decodes escape sequences through
 * `JsonFormat.instance.unescapeChar`.
 */
@:re('"(?:[^"\\\\]|\\\\.)*"')
abstract JStringLit(String) from String to String {}
