package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> = <expr> #end` region occupying the initializer
 * slot of a variable declaration — the `=` sits INSIDE the guard while
 * the binding name and type stay outside it. Reached via
 * `HxVarInitRegion.Conditional`, which owns the `#if` / `#end` markers.
 *
 * Four openfl modules need it:
 *
 * ```haxe
 * public static var current:MovieClip #if flash = flash.Lib.current #end;
 * private static var limitedProfile:Null<Bool> #if !desktop = true #end;
 * @:noCompletion private static var dispatcher:EventDispatcher #if !macro = new EventDispatcher() #end;
 * private static #if !js inline #end var __supportDOM:Bool #if !js = false #end;
 * ```
 *
 * Distinct from the two conditional slots `HxVarDecl` already reaches
 * through: `HxMetadata.Conditional` on the leading meta Star, and
 * `HxConditionalType` in the `type` slot (`var x:#if a A #else B #end`).
 * Here neither the type nor the whole member is guarded, only the
 * assignment — so the region needs its own field rather than a branch of
 * `HxExpr`. The last openfl example combines this slot with a conditional
 * modifier run in the same declaration.
 *
 * `init` is `@:optional @:lead('=')` so the optional-Ref emit path
 * supplies the ` = ` spacing (`=` is in neither `HaxeFormat.spacedLeads`
 * nor `tightLeads`, and the non-optional path emits the lead tight).
 * Guarded MEMBER and STATEMENT regions are unaffected: a `#if` following
 * a terminated declaration is reached only after the host has consumed
 * its `;`, so `HxConditionalMember` / `HxConditionalStmt` still claim it.
 *
 * `#else` / `#elseif` arms are intentionally out of scope — no observed
 * source shape pairs a guarded initializer with an alternative one.
 * Adding them means a second `HxVarInitRegion` branch, mirroring how
 * `#elseif` landed for the other scopes (omega-cond-comp-elseif) and how
 * `HxConditionalType` defers the same extension.
 */
@:peg
typedef HxConditionalVarInit = {
	var cond: HxPpCondLit;
	@:optional @:lead('=') var init: Null<HxExpr>;
};
