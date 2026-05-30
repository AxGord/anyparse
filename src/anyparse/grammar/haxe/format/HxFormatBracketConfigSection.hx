package anyparse.grammar.haxe.format;

/**
 * `whitespace.bracketConfig` section of a haxe-formatter `hxformat.json`
 * config — the square-bracket sibling of `parenConfig`. Houses interior
 * spacing policy pairs for the four `[` / `]` bracket kinds.
 *
 * Added in slice ω-bracket-config. Each kind reuses
 * `HxFormatParenPolicySection` (an `openingPolicy` / `closingPolicy`
 * pair):
 *  - `accessBrackets` — subscript `arr[ i ]` (`HxExpr.IndexAccess`).
 *  - `arrayLiteralBrackets` — plain array literal `[ 1, 2 ]`.
 *  - `mapLiteralBrackets` — map literal `[ k => v ]`.
 *  - `comprehensionBrackets` — comprehension `[ for (…) … ]`.
 *
 * The three literal kinds share one grammar ctor (`HxExpr.ArrayExpr`);
 * the writer dispatches on the first element's shape at emission time to
 * pick the matching policy, so each kind is configured independently.
 * Combined `openingPolicy: "onlyAfter"` + `closingPolicy: "before"`
 * produces `[ 1 ]`. Defaults (absent keys) keep the tight `[1]` form.
 */
@:peg typedef HxFormatBracketConfigSection = {

	@:optional var accessBrackets:HxFormatParenPolicySection;
	@:optional var arrayLiteralBrackets:HxFormatParenPolicySection;
	@:optional var mapLiteralBrackets:HxFormatParenPolicySection;
	@:optional var comprehensionBrackets:HxFormatParenPolicySection;
};
