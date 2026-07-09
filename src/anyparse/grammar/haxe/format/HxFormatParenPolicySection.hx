package anyparse.grammar.haxe.format;

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
 *
 * `removeInnerWhenEmpty` (slice ω-anon-fn-empty-paren-inner-space):
 * when explicitly set to `false` on `anonFuncParamParens`, the writer
 * preserves a single inside space for an empty parameter list
 * (`function ( ) body`). Default `true` collapses to the tight
 * `function()` regardless of `openingPolicy`/`closingPolicy`.
 * Recognised on `anonFuncParamParens` only today — sibling kinds
 * (`funcParamParens`, `callParens`, …) still parse and silently
 * ignore the key until a writer knob catches up.
 */
@:peg typedef HxFormatParenPolicySection = {

	@:optional var openingPolicy: HxFormatWhitespacePolicy;

	@:optional var closingPolicy: HxFormatWhitespacePolicy;

	@:optional var removeInnerWhenEmpty: Bool;

	// ω-arrow-body-objlit-pad-keep: `objectLiteralBraces`-only key —
	// `true` keeps the `openingPolicy` inner pad on an object literal
	// that is an arrow-lambda body (`u -> { email: v }`); absent /
	// `false` mirrors the fork's compress-mode Arrow suppression
	// (`u -> {email: v }`). Sibling kinds parse and ignore the key.
	@:optional var arrowBodyOpenPad: Bool;

	// ω-arrow-body-objlit-reflow: `objectLiteralBraces`-only key —
	// `true` re-flows a source-multiline object literal that is an
	// arrow-lambda body by width (collapses to `u -> { a: 1 }` when it
	// fits); absent / `false` keeps the source-multiline shape (fork
	// parity). Sibling kinds parse and ignore the key.
	@:optional var arrowBodyReflow: Bool;
};
