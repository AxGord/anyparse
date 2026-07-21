package anyparse.grammar.haxe;

/**
 * Preprocessor-guarded region occupying a function's name slot -
 * `HxCondNameFnDecl.region`'s Ref.
 *
 * A one-branch enum rather than a direct Ref to `HxConditionalFnName`
 * so the `#end` marker rides an enum BRANCH, mirroring `HxVarInitRegion`:
 * the `#if` marker rides the referencing field (`@:kw('#if')`), the `#end`
 * rides this branch. The split keeps the region's two markers on the two
 * sides of the payload without a mid-struct keyword field.
 *
 * `@:fmt(spaceBeforeTrail)` - the flag `HxVarInitRegion` needs for the
 * same boundary - is deliberately absent: the payload's own
 * `@:fmt(padTrailing)` on `name` / `elseifs` / `elseName` already emits
 * the space before `#end`, and adding both produced `setEndian  #end`.
 * The source shape is `... setEndian #end(b)`: space before the marker,
 * none after, since the parameter list follows immediately.
 */
@:peg
enum HxFnNameRegion {

	@:trail('#end')
	Conditional(inner: HxConditionalFnName);

}
