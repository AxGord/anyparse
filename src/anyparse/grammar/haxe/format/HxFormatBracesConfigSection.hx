package anyparse.grammar.haxe.format;

/**
 * `whitespace.bracesConfig` section of a haxe-formatter `hxformat.json`
 * config. Houses per-brace-kind spacing policies. Mirrors the
 * `parenConfig` shape — each kind carries the same opening / closing
 * policy pair (`HxFormatParenPolicySection` reused as the value
 * shape since the policy surface is identical).
 *
 * Added in slice ω-anontype-braces. `anonTypeBraces` and
 * `objectLiteralBraces` are modelled. `unknownBraces` and any future
 * per-kind sections (`codeBlocks`, `enumBraces`, …) land with their
 * own slices once a writer knob picks up the corresponding grammar site. `singleStatementBraces` (ω-single-stmt-braces) is a two-value `"keep"` / `"remove"` policy: `"remove"` drops the braces around a single-statement `if` / `else` / `for` / `while` body (maps onto the runtime `dropSingleStmtBraces` boolean). Default `"keep"` — braces preserved, byte-inert.
 */
@:peg typedef HxFormatBracesConfigSection = {

	@:optional var anonTypeBraces: HxFormatParenPolicySection;
	@:optional var objectLiteralBraces: HxFormatParenPolicySection;
	@:optional var singleStatementBraces: HxFormatSingleStatementBracesPolicy;
};
