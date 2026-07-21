package anyparse.grammar.haxe;

/**
 * Element type of the bodies inside a `#if` region that sits in
 * declaration-prefix position — the Stars of `HxConditionalMeta` and
 * `HxElseifMeta`. Widens the plain metadata entry with the bare
 * declaration keywords a conditional may contribute to the decl that
 * FOLLOWS the `#end`.
 *
 * Motivating shape (92 of openfl's 114 unparseable modules — every
 * `openfl.display.*` enum-abstract, `BlendMode`, `StageAlign`, …):
 *
 * ```haxe
 * #if (haxe_ver >= 4.0) enum #else @:enum #end abstract BlendMode(Null<Int>)
 * ```
 *
 * The two branches straddle the meta/keyword boundary: the true branch
 * contributes the `enum` of `enum abstract`, the false branch the
 * legacy `@:enum` tag. Neither `HxTopLevelDecl.meta` (metadata only)
 * nor `HxDecl.EnumAbstractDecl` (owns `@:kw('enum')` tight to its own
 * `abstract`) can host that alone, so the whole region rides the meta
 * Star and the tail `abstract Name(T)` reaches the plain
 * `HxDecl.AbstractDecl` branch — byte-identical routing to the legacy
 * `@:enum abstract Name(T)` form, which already parses as
 * `(Meta @:enum) (AbstractDecl …)`. `SymbolIndex.isAbstractType` sees
 * an abstract either way.
 *
 * Scope discipline mirrors `HxMemberModifier` (narrow, ordinary
 * position) vs `HxModifier` (broader, conditional-region bodies only):
 * this enum is referenced ONLY from the two conditional-body Stars, so
 * `HxTopLevelDecl.meta` stays `Array<HxMetadata>` and the bare `enum`
 * can never shadow the `EnumAbstractDecl` / `EnumDecl` dispatch outside
 * a `#if`.
 *
 * `Meta` is a Case 3 single-Ref descent onto the full `HxMetadata`
 * enum (same shape as `HxMetadata.PlainMeta(raw:HxMetaRaw)`), so
 * nested `#if`, `@:meta(args)` and the verbatim catch-all all compose
 * unchanged. `EnumKw` is ordered first because `@:kw` enforces a word
 * boundary and `enum` cannot start a metadata entry — the branches are
 * disjoint, the order is documentation rather than disambiguation.
 */
@:peg
enum HxCondDeclPrefix {

	@:kw('enum') EnumKw;

	Meta(entry: HxMetadata);

}
