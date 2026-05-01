package anyparse.format.wrap;

/**
 * One rule in a `WrapRules.rules` cascade. Pairs a list of conditions
 * (AND semantics — every condition must hold) with the `WrapMode` to
 * apply when the rule matches.
 *
 * The cascade is first-match-wins: the rules are evaluated in order;
 * the first rule whose conditions all match selects the mode. When no
 * rule matches, the parent `WrapRules.defaultMode` applies.
 */
typedef WrapRule = {
	var conditions:Array<WrapCondition>;
	var mode:WrapMode;
};
