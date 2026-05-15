package anyparse.grammar.haxe;

/**
 * Haxe EReg regex-literal terminal.
 *
 * Matches a complete `~/pattern/flags` literal including the `~/`
 * opener, the body, the closing `/`, and any trailing flag letters
 * (`g`, `i`, `m`, `s`, `u`). `@:rawString` instructs the parser to
 * store the matched slice VERBATIM and the writer to emit it
 * unchanged — a regex pattern is opaque text whose every backslash,
 * character class, and metacharacter must round-trip byte-perfect, so
 * any decode/re-encode pass would corrupt it. Same source-verbatim
 * contract as `HxDoubleStringLit`.
 *
 * The `@:re` pattern is the regex-literal grammar itself: after `~/`,
 * the body is a run of either an escaped pair (`\` followed by any
 * char — covers `\/`, `\\`, `\.`, ...) or any character that is not
 * `/`, `\`, or a newline; then the closing `/`; then `[a-z]*` flags.
 * Unescaped `/` inside a `[...]` class is not modelled (rare in real
 * source and absent from the dogfood corpus) — extend the body
 * alternation if a fixture needs it.
 *
 * `~/` is unambiguous against the `@:prefix('~')` bitwise-not operator:
 * the pattern requires `/` immediately after `~`, and the literal
 * ctor is declared before the prefix ctors so the atom dispatch tries
 * it first.
 *
 * `from String to String` keeps test assertion literals compiling
 * without explicit casts.
 */
@:re('~/(?:[^/\\\\\n]|\\\\.)*/[a-z]*')
@:rawString
abstract HxRegexLit(String) from String to String {}
