package anyparse.format.wrap;

/**
 * Per-construct wrap cascade: the writer measures a delimited list (element
 * count, widest item, total flat width, an `exceedsMaxLineLength` flag), walks
 * `rules` in order and takes the first whose conditions all hold, falling back
 * to `defaultMode`.
 *
 * Format-neutral — any delimited-list site in any text grammar opts in through
 * `@:fmt(wrapRules('<optionFieldName>'))` on its `Star` field, and the rule set
 * lives in `WriteOptions` (or a grammar-specific extension struct) so end-user
 * config can override it without a recompile. A per-RULE `additionalIndent` is
 * deliberately absent: it has no analogue in the Doc IR.
 *
 * The two optional fallbacks are read by disjoint emitters, so each is inert on
 * the other's shapes: `defaultLocation` is the operator-placement fallback for
 * the chain emitters, `defaultAdditionalIndent` bumps every break-mode
 * continuation indent by N `indentSize` / `tabWidth` units and is consumed only
 * by `WrapList.emit`.
 */
typedef WrapRules = {
	var rules: Array<WrapRule>;
	var defaultMode: WrapMode;
	@:optional var defaultLocation: WrappingLocation;
	@:optional var defaultAdditionalIndent: Int;

	/**
	 * Does this cascade count a `.` as a chain item only when it follows a `)`?
	 * `MethodChainEmit.emit` then keeps a non-item first segment glued to the head
	 * even under a break shape that would otherwise strand it, so `Actuate.tween(…)`
	 * stays whole.
	 *
	 * A user `wrapping.methodChain` section is rebuilt from scratch and does NOT
	 * inherit this field from the built-in cascade, so an explicitly configured
	 * `onePerLine` that stays silent about the key keeps the fork's literal
	 * every-segment semantic. Absent or `false` is the every-segment behaviour
	 * everywhere.
	 */
	@:optional var chainItemsAfterCloseParenOnly: Bool;
};
