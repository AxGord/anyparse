package anyparse.grammar.haxe;

/**
 * Policy pair for a single kind of parens inside
 * `whitespace.parenConfig.*`. `openingPolicy` carries the full
 * `WhitespacePolicy` surface for the open paren (space before / after
 * / both / none), `closingPolicy` the same for the close paren.
 *
 * Added in slice ω-E-whitespace. `closingPolicy` is declared for
 * schema parity only — the ByName parser's `UnknownPolicy.Skip` would
 * already tolerate it as an unknown key, but declaring the field
 * reserves a wired-up slot for the future close-paren writer knob.
 * Today the loader reads `openingPolicy` only (`HaxeFormatConfigLoader
 * .applyWhitespace`).
 */
@:peg typedef HxFormatParenPolicySection = {

	@:optional var openingPolicy:HxFormatWhitespacePolicy;

	@:optional var closingPolicy:HxFormatWhitespacePolicy;
};
