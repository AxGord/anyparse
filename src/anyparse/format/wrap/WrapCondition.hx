package anyparse.format.wrap;

/**
 * Single predicate inside a `WrapRule.conditions` list. Pairs a kind
 * (`WrapConditionType`) with the integer threshold it compares against.
 *
 * For the three SET predicates — `ExceedsMaxLineLength`,
 * `HasMultilineItems`, `EqualItemLengths` — `value` is not a threshold
 * but a polarity: `1` matches when the signal holds, `0` when it does
 * not. The fork ships `exceedsMaxLineLength` in both polarities (254 rules at `0`, 94 at `1` across its own corpus); the other two it only ever ships at `1`, but the schema declares both for all three.
 *
 * A condition whose `value` the config OMITS reads `1` here, matching
 * haxe-formatter's own `@:default(1)` on this field. That default is load-bearing for exactly those three: `0` silently
 * INVERTS a polarity rule. For a threshold predicate the two defaults
 * differ only in degree — and `1` is the more useful degree, turning
 * `itemCount <= n` into "sole item" and `complexItemCount >= n` into "any
 * complex item" where `0` made them unmatchable and tautological. No
 * shipped config omits `value` on a threshold predicate.
 */
typedef WrapCondition = {
	var cond: WrapConditionType;
	var value: Int;
};
