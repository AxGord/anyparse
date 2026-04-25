package anyparse.grammar.haxe.format;

/**
 * `whitespace.parenConfig` section of a haxe-formatter `hxformat.json`
 * config. Houses per-paren-kind spacing policies.
 *
 * Added in slice ω-E-whitespace. `funcParamParens` and `callParens`
 * are modelled — `ifParens`, `forParens`, `whileParens`,
 * `switchParens`, `catchParens`, `newParens`, `typeCheckParens`,
 * `castParens`, `checkParens`, `expressionParens` from haxe-formatter
 * land with their own slices when a writer knob catches up.
 */
@:peg typedef HxFormatParenConfigSection = {

	@:optional var funcParamParens:HxFormatParenPolicySection;
	@:optional var callParens:HxFormatParenPolicySection;
};
