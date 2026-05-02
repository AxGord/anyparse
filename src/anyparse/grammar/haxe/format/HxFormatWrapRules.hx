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

	@:optional var defaultWrap:String;

	@:optional var rules:Array<HxFormatWrapRule>;
};
