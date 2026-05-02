package anyparse.grammar.haxe.format;

/**
 * One predicate inside a `WrapRule.conditions` array as it appears in
 * `hxformat.json` (e.g. `{"cond": "itemCount <= n", "value": 3}`).
 *
 * `cond` carries the haxe-formatter-flavoured predicate string; the
 * loader maps it to a runtime `WrapConditionType` and drops the rule
 * when the string isn't recognised (e.g. the still-unmodelled
 * `lineLength >= n`).
 *
 * `value` is the numeric threshold the predicate compares against. For
 * predicates that ignore the threshold (`exceedsMaxLineLength`) the
 * field is parsed but unused — haxe-formatter writes `1` by convention.
 *
 * Schema added in slice ω-peg-byname-array — first consumer of the
 * `@:peg` ByName Array<T> ingestion lift.
 */
@:peg typedef HxFormatWrapCondition = {

	@:optional var cond:String;

	@:optional var value:Int;
};
