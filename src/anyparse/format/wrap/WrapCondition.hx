package anyparse.format.wrap;

/**
 * Single predicate inside a `WrapRule.conditions` list. Pairs a kind
 * (`WrapConditionType`) with the integer threshold it compares against.
 *
 * For `ExceedsMaxLineLength` the threshold is unused (haxe-formatter
 * convention is to pass `1`); the cascade checks the boolean
 * "would-overflow-flat" signal computed by the writer per-call.
 */
typedef WrapCondition = {
	var cond:WrapConditionType;
	var value:Int;
};
