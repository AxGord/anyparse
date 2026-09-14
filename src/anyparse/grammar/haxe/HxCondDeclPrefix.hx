package anyparse.grammar.haxe;

/**
 * Element type of the bodies inside a `#if` region that sits in declaration-prefix position
 * — the Stars of `HxConditionalMeta` and `HxElseifMeta`. Widens the plain metadata entry
 * with the bare declaration keywords a conditional may contribute to the decl that FOLLOWS
 * the `#end`:
 *
 * ```haxe
 * #if (haxe_ver >= 4.0) enum #else @:enum #end abstract BlendMode(Null<Int>)
 * ```
 *
 * The two branches straddle the meta/keyword boundary: the true branch contributes the
 * `enum` of `enum abstract`, the false branch the legacy `@:enum` tag. Neither
 * `HxTopLevelDecl.meta` (metadata only) nor `HxDecl.EnumAbstractDecl` (owns `@:kw('enum')`
 * tight to its own `abstract`) can host that alone, so the whole region rides the meta Star
 * and the tail `abstract Name(T)` reaches the plain `HxDecl.AbstractDecl` branch — the
 * routing of the legacy `@:enum abstract Name(T)` form.
 *
 * `AbstractKw` / `FinalKw` extend the same widening to the other two declaration-starting
 * keywords (`#if x abstract #end class C {}`, `#if (haxe_ver >= 4.2) final #else @:final
 * #end class C {}`). `extern` and `private` never needed it — they are plain `HxModifier`
 * entries; `abstract` / `final` can themselves introduce a top-level declaration, so without
 * an arm here the parser would try to parse a full `HxDecl` starting at the bare keyword and
 * then have nothing left to consume `#end` with.
 * Each arm captures the bare keyword token verbatim; the declaration that follows `#end` is
 * parsed independently by the ordinary `HxDecl` dispatch, with no requirement that it match
 * the captured keyword.
 *
 * A FOURTH arm here must also be added to `HaxeQueryPlugin.condDeclPrefixKeywordKinds` and
 * to `RefactorSupport.COND_DECL_PREFIX_KEYWORD_KINDS` (the mirror for the two statics that
 * hold no `RefShape`). Neither copy is checked against this enum, so a missing entry costs no
 * compile error and shows up as `move` / `set-doc` / `replace-node` treating the region as a
 * declaration of its own.
 *
 * Scope discipline mirrors `HxMemberModifier` vs `HxModifier`: this enum is referenced ONLY
 * from the two conditional-body Stars, so a bare `enum` / `abstract` / `final` can never
 * shadow the decl dispatch outside a `#if`. `Meta` is a Case 3 single-Ref descent onto the
 * full `HxMetadata` enum, so nested `#if`, `@:meta(args)` and the verbatim catch-all compose
 * unchanged; the `@:kw` arms are ordered first, but none of the keywords can start a
 * metadata entry, so the branches are disjoint and the order is documentation.
 */
@:peg
enum HxCondDeclPrefix {

	@:kw('enum') EnumKw;

	@:kw('abstract') AbstractKw;

	@:kw('final') FinalKw;

	Meta(entry: HxMetadata);

}
