package anyparse.grammar.haxe;

/**
 * `whitespace.parenConfig` section of a haxe-formatter `hxformat.json`
 * config. Houses per-paren-kind spacing policies.
 *
 * Added in slice ω-E-whitespace. Only `funcParamParens` is modelled —
 * `callParens`, `ifParens`, `forParens`, `whileParens`,
 * `switchParens`, `catchParens`, `newParens`, `typeCheckParens`,
 * `castParens`, `checkParens`, `expressionParens` from haxe-formatter
 * land with their own slices when a writer knob catches up.
 */
@:peg typedef HxFormatParenConfigSection = {

	@:optional var funcParamParens:HxFormatParenPolicySection;
};
