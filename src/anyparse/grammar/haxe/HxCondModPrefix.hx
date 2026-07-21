package anyparse.grammar.haxe;

/**
 * Element type of the bodies inside a `#if` region that sits in
 * modifier-prefix position - the Stars of `HxConditionalMod` and
 * `HxElseifMod`. Widens the plain modifier keyword set with the
 * metadata tags and the bare `enum` / `macro` keywords that a branch
 * may contribute to the declaration FOLLOWING the `#end`.
 *
 * Motivating shape - 100 of Pony's 132 unparseable modules, plus
 * lime's `ArrayBufferView`:
 *
 * ```haxe
 * #if (haxe_ver >= 4.2) extern #else @:extern #end
 * public inline function new(p: OrState<A, B>) this = p;
 * ```
 *
 * The two branches straddle the modifier/metadata boundary exactly as
 * `HxCondDeclPrefix` straddles the metadata/decl-keyword one: the true
 * branch contributes the `extern` MODIFIER, the false branch the legacy
 * `@:extern` TAG. `HxConditionalMod.body` was `Array<HxModifier>`, so
 * the `@:extern` arm had nowhere to land and the whole region failed.
 *
 * Three further real-world branch shapes need the same widening:
 *
 * ```haxe
 * // lime NativeWindow / System - two tokens per branch, a modifier
 * // mixed in with the declaration keyword
 * #if (haxe_ver>=4.0) private enum #else @:enum private #end abstract T(Int)
 * // std js/_std/haxe/Json.hx - metadata AND a modifier in ONE branch
 * #if !haxeJSON @:native("JSON") extern #end class Json
 * // std haxe/macro/Compiler - `macro` is the spliced keyword
 * public static #if !macro macro #end function includeFile(...)
 * ```
 *
 * Why a dedicated element enum rather than widening `HxModifier`
 * itself: scope discipline, the same argument `HxCondDeclPrefix`
 * documents. A bare `enum` in `HxTopLevelDecl.modifiers` would let the
 * ordinary modifier Star eat the `enum` of `enum Foo {}` and then fail
 * declaration dispatch; `macro` is absent from `HxModifier` on purpose
 * (`macro class` is not Haxe); and a `Meta` branch in the ordinary
 * modifier Star would race `HxTopLevelDecl.meta` / `HxMemberDecl.meta`
 * for every `@`-led prefix. Referencing this enum ONLY from the two
 * conditional-body Stars keeps all of that unreachable outside a `#if`.
 *
 * That scoping is also why the widened Star cannot steal a region from
 * the metadata Star that runs before it: this Star only ever runs
 * between `#if <cond>` and the next `#elseif` / `#else` / `#end`, and it
 * can only NEWLY succeed on a region whose every branch is prefix-only.
 * That set is disjoint from "a branch holds a complete member or
 * declaration", which stays with `HxConditionalMember` /
 * `HxConditionalDecl`, and the enclosing ctor's `@:trail('#end')` check
 * forces a rollback for everything in between.
 *
 * The keyword branches are spelled out rather than delegated through a
 * `Mod(m: HxModifier)` single-Ref descent so the emitted AST keeps its
 * pre-slice shape: `#if x extern #end` stays `(Conditional (Extern))`
 * instead of gaining a wrapper level. The duplication mirrors the
 * existing `HxModifier` / `HxMemberModifier` split. For the same reason
 * the ctor NAMES are not normalised to one convention - each matches the
 * ctor whose AST output it must stay compatible with (`Macro` from
 * `HxMemberModifier`, `EnumKw` from `HxCondDeclPrefix`), so
 * `#if x enum #end` prints `(EnumKw)` whichever Star claims the region.
 *
 * `final` and `abstract` are DEFERRED, not ruled out. Pony carries both
 * in the same straddle shape - `#if (haxe_ver >= 4.2) final #else
 * @:final #end class RPCPing` (5 sites) and `#if (haxe_ver >= 4.2)
 * abstract #end class AnimCore` (11 sites) - so ~15 more of its modules
 * would parse if they were added here. They are left out because in
 * those shapes the keyword introduces a SEALED or ABSTRACT CLASS: at the
 * top level `final` and `abstract` are not modifiers at all but
 * declaration-keyword dispatch (`HxDecl.FinalDecl` -> `HxFinalDecl`,
 * `HxDecl.AbstractClassDecl`), so admitting them here would emit a
 * Conditional-modifier `Final` plus a bare `ClassDecl` instead of the
 * `FinalDecl(ClassForm)` those forms produce unguarded. Deciding that
 * divergence belongs to the abstract/final-in-decl-keyword-slot slice,
 * not to this one. The `#if`-scoping argument above means adding them
 * would NOT endanger an unguarded `final FOO = 1;`.
 *
 * Ordering: keyword branches first - `@:kw` enforces a word boundary and
 * none of them can start a metadata entry - then the nested `#if`
 * branch, then `Meta`. `Conditional` MUST precede `Meta`: `HxMetadata`
 * carries its own `@:kw('#if') Conditional(HxConditionalMeta)` ctor, so
 * the two branches both dispatch on `#if`, and putting `Meta` first
 * would route a nested region through the metadata-only
 * `HxCondDeclPrefix` and change the pre-slice AST for nested regions.
 *
 * `Meta` is a Case 3 single-Ref descent onto the full `HxMetadata`
 * enum, so `@:meta(args)`, dot-path tag names and the verbatim
 * catch-all all compose unchanged.
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
