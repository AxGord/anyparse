package anyparse.grammar.haxe;

/**
 * Element type of the bodies inside a `#if` region that sits in modifier-prefix position —
 * the Stars of `HxConditionalMod` and `HxElseifMod`. Widens the plain modifier keyword set
 * with the metadata tags and the bare `enum` / `macro` keywords that a branch may
 * contribute to the declaration FOLLOWING the `#end`:
 *
 * ```haxe
 * #if (haxe_ver >= 4.2) extern #else @:extern #end public inline function new(p: P) this = p;
 * #if (haxe_ver>=4.0) private enum #else @:enum private #end abstract T(Int)
 * public static #if !macro macro #end function includeFile(...)
 * ```
 *
 * The branches straddle the modifier/metadata boundary exactly as `HxCondDeclPrefix`
 * straddles the metadata/decl-keyword one: the true branch contributes the `extern`
 * MODIFIER, the false branch the legacy `@:extern` TAG.
 *
 * Why a dedicated element enum rather than widening `HxModifier` itself: scope discipline,
 * the `HxCondDeclPrefix` argument. A bare `enum` in `HxTopLevelDecl.modifiers` would let the
 * ordinary modifier Star eat the `enum` of `enum Foo {}` and then fail declaration dispatch;
 * `macro` is absent from `HxModifier` on purpose (`macro class` is not Haxe); and a `Meta`
 * branch in the ordinary modifier Star would race the `meta` Stars for every `@`-led prefix.
 * Referencing this enum ONLY from the two conditional-body Stars keeps all of that
 * unreachable outside a `#if`, and the widened Star cannot steal a region from the metadata
 * Star that runs before it: it can only NEWLY succeed on a region whose every branch is
 * prefix-only, disjoint from "a branch holds a complete member or declaration".
 *
 * The keyword branches are spelled out rather than delegated through a `Mod(m: HxModifier)`
 * descent so the emitted AST keeps its shape (`#if x extern #end` stays `(Conditional
 * (Extern))`), and each ctor NAME matches the ctor whose AST output it must stay compatible
 * with (`Macro` from `HxMemberModifier`, `EnumKw` from `HxCondDeclPrefix`).
 *
 * `final` and `abstract` are DEFERRED, not ruled out: in `#if (haxe_ver >= 4.2) final #else
 * @:final #end class C` the keyword introduces a SEALED or ABSTRACT CLASS, which at the top
 * level is declaration-keyword dispatch (`HxDecl.FinalDecl`, `HxDecl.AbstractClassDecl`), so
 * admitting them here would emit a Conditional-modifier `Final` plus a bare `ClassDecl`
 * instead of the `FinalDecl(ClassForm)` the unguarded form produces. Ordering: keyword
 * branches first (none can start a metadata entry), then the nested `#if` branch, then
 * `Meta` — `HxMetadata` carries its own `@:kw('#if')` ctor, so `Meta` first would route a
 * nested region through the metadata-only `HxCondDeclPrefix`.
 */
@:peg
enum HxCondModPrefix {

	@:kw('public') Public;
	@:kw('private') Private;
	@:kw('static') Static;
	@:kw('inline') Inline;
	@:kw('override') Override;
	@:kw('dynamic') Dynamic;
	@:kw('extern') Extern;
	@:kw('overload') Overload;
	@:kw('macro') Macro;
	@:kw('enum') EnumKw;

	@:kw('#if') @:trail('#end')
	Conditional(inner: HxConditionalMod);

	Meta(entry: HxMetadata);

}
