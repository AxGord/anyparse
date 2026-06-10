package anyparse.grammar.haxe.format;

/**
 * `whitespace.parenConfig` section of a haxe-formatter `hxformat.json`
 * config. Houses per-paren-kind spacing policies.
 *
 * Added in slice ω-E-whitespace. `funcParamParens`, `callParens`, and
 * `anonFuncParamParens` (added in ω-anon-fn-paren-policy) are modelled
 * — `newParens`, `typeCheckParens`, `castParens`, `checkParens`,
 * `expressionParens` from haxe-formatter land with their own slices when
 * a writer knob catches up.
 *
 * Stage C (ω-condition-parens) adds the control-flow condition-paren
 * categories: `ifConditionParens`, `whileConditionParens`,
 * `switchConditionParens`, `catchParens`, `sharpConditionParens`, and the
 * `conditionParens` catch-all (haxe-formatter applies the catch-all to
 * if / while / switch / `#if`). Each is a `HxFormatParenPolicySection`
 * whose `openingPolicy.before` controls the keyword→`(` gap, `.after`
 * controls the inner `( ` pad, and `closingPolicy.before` controls the
 * inner ` )` pad — `openingPolicy: "onlyAfter"` + `closingPolicy:
 * "before"` produces `if( a )`.
 */
@:peg typedef HxFormatParenConfigSection = {

	@:optional var funcParamParens: HxFormatParenPolicySection;
	@:optional var callParens: HxFormatParenPolicySection;
	@:optional var anonFuncParamParens: HxFormatParenPolicySection;
	@:optional var ifConditionParens: HxFormatParenPolicySection;
	@:optional var whileConditionParens: HxFormatParenPolicySection;
	@:optional var switchConditionParens: HxFormatParenPolicySection;
	@:optional var catchParens: HxFormatParenPolicySection;
	@:optional var sharpConditionParens: HxFormatParenPolicySection;
	@:optional var conditionParens: HxFormatParenPolicySection;
};
