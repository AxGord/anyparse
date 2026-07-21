package anyparse.grammar.haxe;

/**
 * Preprocessor-guarded region occupying a member field's initializer
 * slot AND supplying that field's terminator -
 * `HxVarSemiCondInitDecl.region`'s Ref.
 *
 * A one-branch enum rather than a direct Ref to `HxConditionalSemiExpr`
 * because THREE writer flags this shape needs are read off an enum
 * BRANCH only and have no struct-field equivalent: `spaceBeforeLead` /
 * `spaceAfterLead` for the ` = ` around the assignment (a non-optional
 * struct-field `@:lead('=')` emits tight), and `spaceBeforeTrail` to keep
 * `#end` off the last branch's terminator (`null;#end` without it).
 * Carrying the `=` here rather than on the referencing field is what
 * makes those flags reachable.
 *
 * The `#if` marker rides `HxConditionalSemiExpr.cond` instead of this
 * branch: the branch already spends its lead slot on `=`, and a branch
 * carrying both (`@:lead('=') @:kw('#if')`, the `HxExpr.MacroTypeExpr`
 * shape) emits the keyword BEFORE the lead - `#if = ...`.
 *
 * Sibling of `HxVarInitRegion`, which covers the mirror-image shape:
 * there the `#if` opens where the `=` would go and the `=` lives INSIDE
 * the guard (`var current:MovieClip #if flash = flash.Lib.current #end;`);
 * here the `=` is outside and the `;` is inside.
 */
@:peg
enum HxVarSemiInitRegion {

	@:lead('=') @:trail('#end') @:fmt(spaceBeforeLead, spaceAfterLead, spaceBeforeTrail)
	Conditional(inner: HxConditionalSemiExpr);

}
