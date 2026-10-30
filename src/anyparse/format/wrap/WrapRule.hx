package anyparse.format.wrap;

/**
 * One rule in a `WrapRules.rules` cascade. Pairs a list of conditions
 * (AND semantics — every condition must hold) with the `WrapMode` to
 * apply when the rule matches.
 *
 * The cascade is first-match-wins: the rules are evaluated in order;
 * the first rule whose conditions all match selects the mode. When no
 * rule matches, the parent `WrapRules.defaultMode` applies.
 *
 * `location` (optional) selects operator placement on continuation
 * lines for chain emission shapes that break across lines
 * (`OnePerLineAfterFirst`, `OnePerLine`, `FillLine`). When unset, a matched rule
 * places the operator `AfterLast` — the parent `WrapRules.defaultLocation`
 * answers only when no rule matches. Has no effect on `NoWrap` rules
 * or on delimited-list shapes (`WrapList.emit`) — only the chain emit
 * (`BinaryChainEmit`) currently consumes it. Mirrors haxe-formatter's
 * per-rule `location` field in `WrapConfig.hx`.
 *
 * `additionalIndent` (optional) is the extra continuation indent, in indent units, this rule
 * charges when it is the one that matched; absent is 0. The parent `WrapRules.defaultAdditionalIndent`
 * answers only when no rule matches — haxe-formatter's per-rule `additionalIndent`.
 */
typedef WrapRule = {
	var conditions: Array<WrapCondition>;
	var mode: WrapMode;
	@:optional var location: WrappingLocation;
	@:optional var additionalIndent: Int;
};
