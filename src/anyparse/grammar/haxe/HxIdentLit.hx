package anyparse.grammar.haxe;

/**
 * Haxe identifier terminal. A transparent abstract over `String` so the
 * `Re` strategy picks up the `@:re` pattern and uses the abstract's name
 * as the generated sub-rule name.
 *
 * Every slot typed by it DECLARES a name (a parameter, a binder, a type, an enum constructor, a structure field, a type parameter),
 * so the leading negative lookahead refuses each word the Haxe 4.3 lexer reserves: `final dynamic = 1;` is `Unexpected keyword
 * "dynamic"` to the compiler, and a parser that took it let an op hand over a tree its own re-parse gate accepted and Haxe rejects.
 * `operator` and `overload` stay out of the list though both are reserved since 4.0 / 4.2: code gated on an older compiler still
 * declares them (lime's `Cairo` has `public var operator` under `#if (haxe_ver < "4.0.0")`), and every branch of a region is
 * parsed. The slots that take a keyword are `HxWordLit`. The pattern matches a standard Haxe identifier: an ASCII letter or
 * underscore, followed by any number of ASCII letters, digits, or
 * underscores. Unicode identifiers are out of scope for the Phase 3
 * skeleton.
 *
 * `@:rawString` instructs `TerminalParseLowering.lowerTerminal` to use the matched
 * slice directly as the result value instead of running it through the
 * JSON string-unescape helper. This is the minimal workaround to the
 * closed Phase 2 decoder table (D13) for identifier-like String
 * terminals; a format-contributed decoder table will replace it once a
 * third Terminal type (e.g. a real Haxe string literal with escapes)
 * demands it. `@:rawString` was chosen over a bare `@:raw` to avoid
 * collision with Haxe's built-in `@:raw` meta for verbatim code
 * injection.
 *
 * `from String to String` keeps existing call-site literals compiling —
 * tests can build expected ASTs with plain strings without explicit
 * casts.
 */
@:re('(?!(?:abstract|break|case|cast|catch|class|continue|default|do|dynamic|else|enum|extends|extern|false|final|for|function|if|implements|import|in|inline|interface|macro|new|null|override|package|private|public|return|static|switch|this|throw|true|try|typedef|untyped|using|var|while)\\b)[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxIdentLit(String) from String to String {}
