package anyparse.grammar.haxe;

/**
 * Single-quoted Haxe string literal with interpolation support.
 *
 * Wraps `Array<HxStringSegment>` between `'` delimiters. The Star
 * loop uses close-peek termination: the loop body tries to parse one
 * `HxStringSegment` per iteration, and the loop exits when the next
 * character is `'` (the closing quote).
 *
 * `@:raw` suppresses `skipWs` in the generated parse function — the
 * content between the quotes is whitespace-sensitive. The opening `'`
 * delimiter is preceded by `skipWs` from the CALLER (the non-raw
 * `HxExpr` atom branch), not from this rule.
 *
 * An empty string `''` produces `{parts: []}`.
 *
 * A string without interpolation like `'hello'` produces
 * `{parts: [Literal("hello")]}`.
 *
 * A string with interpolation like `'hello $name!'` produces
 * `{parts: [Literal("hello "), Ident("name"), Literal("!")]}`.
 */
@:peg
@:raw
typedef HxInterpString = {
	@:lead("'") @:trail("'")
	var parts:Array<HxStringSegment>;
};
