package anyparse.grammar.haxe;

/**
 * Leading metadata tag on a class member — `@name` (user metadata) or
 * `@:name` (compiler metadata), with an optional parenthesised argument
 * block.
 *
 * Captured verbatim as the matched substring, prefix and argument block
 * included, so `@:allow(pack.Cls)`, `@:overload(function<T>():Void {})`,
 * `@in(true)` etc. round-trip byte-for-byte. The stored value drives
 * the writer directly (via the `@:rawString` pipeline in
 * `Lowering.lowerTerminal`), so no structured access to metadata
 * contents is offered — a future analysis pass can re-parse the string
 * if introspection becomes necessary.
 *
 * The regex permits up to three levels of nested parentheses, enough
 * for the idiomatic fork-corpus forms: `@:final` / `@:optional` / `@new`
 * (no args), `@:allow(dotted.Ident)` (1), `@:overload(function<T>():Void {})`
 * (2), and simple `@:foo(a.b(c))`-style compound arguments (3). A
 * deeper-than-3 literal will truncate the match, leaving the inner
 * parens in the stream for the next field to choke on — deepen the
 * pattern when a real grammar site demands it.
 *
 * Strings that embed `(` or `)` inside the argument block (for example
 * `@:deprecated("has (parens) inside")`) are NOT understood: a
 * paren-counting regex cannot track string boundaries, so the counter
 * desyncs and the match mis-anchors. No such form is in the current
 * target fixture set; a future slice can swap in a string-aware
 * runtime helper when `@:deprecated`-style metas become the next
 * blocker.
 *
 * `@:rawString` routes the matched slice through `Lowering.lowerTerminal`
 * without running the JSON-style unescape loop — metadata source is not
 * a Haxe string literal and must be preserved byte-exact.
 */
@:re('@:?[A-Za-z_][A-Za-z0-9_]*(?:\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))?')
@:rawString
abstract HxMetadata(String) from String to String {}
