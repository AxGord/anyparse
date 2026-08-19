package anyparse.grammar.haxe.format;

/**
 * `WrapRules` cascade as it appears in `hxformat.json` (e.g.
 * `wrapping.arrayWrap`, `wrapping.objectLiteral`,
 * `wrapping.callParameter`).
 *
 * `defaultWrap` carries the cascade's fallback `WrapMode` string
 * (`noWrap` / `onePerLine` / …). `rules` is the first-match-wins
 * cascade body — each rule pairs a `WrapMode` (`type`) with an
 * AND-list of `conditions`.
 *
 * Slice ω-peg-byname-array landed `Array<T>` support in the `@:peg`
 * ByName lowering, lifting the prior limitation that forced the
 * loader to drop `rules` and collapse every config to a flat
 * `defaultWrap`-only override. The loader now ingests the rules array
 * verbatim, mapping `type` / `cond` strings to the runtime enums and
 * silently dropping rules whose `cond` string is still unmodelled
 * (e.g. `lineLength >= n`) so the cascade falls through cleanly to
 * the next rule.
 */
@:peg typedef HxFormatWrapRules = {

	@:optional var defaultWrap: String;

	@:optional var defaultLocation: String;

	@:optional var defaultAdditionalIndent: Int;

	@:optional var rules: Array<HxFormatWrapRule>;

	/**
	 * F3 ω-methodchain-config-key — opt into fork's `isDotAfterPClose`
	 * definition of a chain ITEM (a `.` counts as one only when it follows a
	 * `)`) for an EXPLICITLY configured cascade. Read only by
	 * `wrapping.methodChain`; every other wrap class carries it into the
	 * runtime struct where no consumer looks at it.
	 *
	 * Absent is NOT inherited from the built-in cascade. `wrapRulesFromConfig`
	 * rebuilds `WrapRules` from scratch, so before this key a user section
	 * silently dropped `HaxeFormat.defaultMethodChainWrap`'s
	 * `chainItemsAfterCloseParenOnly` and a broken chain stranded its head
	 * (`Actuate` alone above `.tween(…)`). Inheriting it by default would fix
	 * that and cost fork parity: five corpus fixtures encode the literal
	 * every-segment `onePerLine`. So the key is opt-in, absent == `false`, and
	 * a project that wants the Haxe layout policy alongside a configured
	 * cascade names it.
	 */
	@:optional var itemsAfterCloseParenOnly: Bool;
};
