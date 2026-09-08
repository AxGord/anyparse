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
 *
 * Query projection: this rule projects as a `SingleStringExpr` node carrying NO name of its own —
 * its content lives in the `parts` CHILDREN, one node per segment, because that is the only shape
 * in which a `$name` read can be told apart from the text around it. The non-interpolating sibling
 * `HxDoubleStringLit` is one raw terminal and carries its whole source slice, quote marks included,
 * in its own `name` instead. Neither form is DECODED: both are `@:rawString`, so `'a\tb'` yields a
 * four-character `Literal` and not a tab (`HxStringEscape` is what decodes). The asymmetry is the
 * grammar's rather than the projection's, and `CondQuery.collectNames` records what it costs a
 * consumer that has to treat the two alike.
 */
@:peg
@:raw
@:lexical(StringLit)
typedef HxInterpString = {
	@:lead("'") @:trail("'")
	var parts: Array<HxStringSegment>;
};
