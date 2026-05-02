package anyparse.grammar.haxe.format;

/**
 * `WrapRules` cascade as it appears in `hxformat.json` (e.g.
 * `wrapping.arrayWrap`, `wrapping.objectLiteral`,
 * `wrapping.callParameter`).
 *
 * Only `defaultWrap` is modelled here. The `rules:Array<...>` field
 * present in haxe-formatter's schema is silently dropped by the
 * macro parser (`UnknownPolicy.Skip` inherited from `JsonFormat`) —
 * `@:peg` ByName lowering doesn't yet support `Array<T>` struct
 * fields, and full rule ingestion isn't needed for the active corpus
 * fixtures (both `arrayWrap` overrides set `rules: []`).
 *
 * The loader treats the presence of any `arrayWrap` block as a
 * request to reset the per-construct cascade: rules are replaced with
 * an empty array and `defaultWrap` (or the runtime default if
 * unparseable / absent) becomes the unconditional mode. A future
 * slice that ports `rules` ingestion to the schema can extend this
 * typedef without changing call sites.
 */
@:peg typedef HxFormatWrapRules = {

	@:optional var defaultWrap:String;
};
