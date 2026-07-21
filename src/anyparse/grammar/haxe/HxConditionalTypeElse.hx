package anyparse.grammar.haxe;

/**
 * `#else <type>;` clause of a type-position conditional-compilation
 * region. Reached via `HxConditionalType.elseClause`'s
 * `@:optional @:kw('#else')` Ref.
 *
 * Exists as a one-field wrapper purely so the branch type's
 * `@:trailOpt(';')` sits on a NON-optional field — `@:trailOpt` is
 * dropped on `@:optional` fields, so the trailing `;` of the
 * `#else`-branch type could not otherwise be consumed before the
 * host's `@:trail('#end')`. See `HxConditionalType` for the full
 * rationale. The `#else` keyword itself is owned by the parent
 * optional-kw-Ref, not by this typedef.
 *
 * Two further slots let the `#else` branch carry what its source
 * position actually allows after a type:
 *
 *  - `init` - the optional `= <expr>` a guarded FIELD type may drag
 *    along, the `#else` twin of `HxConditionalType.init`; see that doc
 *    for why the annotation is `@:optional @:lead('=')`.
 *
 *  - `heritage` - trailing `extends` / `implements` clauses, for the
 *    one shape where the `#else` branch of a type-slot conditional
 *    replaces a superclass AND adds an interface (openfl
 *    `display/Tilemap.hx:40`):
 *
 *    ```haxe
 *    class Tilemap extends #if !flash DisplayObject #else Bitmap implements IDisplayObject #end implements ITileContainer
 *    ```
 *
 *    Distinct from `HxHeritageClause.Conditional`, where the whole
 *    `extends` / `implements` keyword sits inside the guard: here the
 *    `extends` is OUTSIDE, the guard occupies only its type slot, and
 *    the extra clause rides along inside the `#else`. The two do not
 *    compose into one another - `HxHeritageClause.Conditional` cannot
 *    parse this because the region does not start at a clause
 *    boundary.
 *
 *    The mirror slot on `HxConditionalType`'s own then-branch is
 *    deliberately absent. No checkout in the dependency trees writes
 *    `extends #if x A implements Y #else B #end`, and adding the Star
 *    there would put an `@:kw('#if')`-dispatched
 *    `HxHeritageClause.Conditional` in the path of a NESTED `#if`
 *    directly after a then-branch type, which currently belongs to
 *    nobody. Add it when a real shape demands it.
 */
@:peg
typedef HxConditionalTypeElse = {
	@:trailOpt(';') var type: HxType;
	@:optional @:lead('=') var init: Null<HxExpr>;
	@:trivia @:tryparse @:fmt(padLeading) var heritage: Array<HxHeritageClause>;
};
