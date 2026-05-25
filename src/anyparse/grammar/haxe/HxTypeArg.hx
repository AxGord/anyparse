package anyparse.grammar.haxe;

/**
 * Type-parameter value element — one `HxType` with an optional
 * structural-intersection tail (`& B & C & …`).
 *
 * Wraps `HxType` so intersection composes inside type-parameter value
 * positions (`EitherType<Bool, EitherType<A, B & C & D>>`) without
 * adding `&` to the general `HxType` Pratt op set. The latter approach
 * is rejected for the same reason documented on `HxIntersectionClause`:
 * a generic `&` infix on `HxType` would let the `is`-operator right-
 * operand parser greedily eat the first `&` of a following
 * expression-level `&&` (no `&&` in the `HxType` Pratt table to win
 * longest-match), corrupting `expr is X && y`. Scoping `&` to the
 * type-arg element keeps `HxType` free of `&`.
 *
 * Re-uses the existing `HxIntersectionClause` — same `@:lead('&')`
 * single-Ref clause that `HxTypedefDecl.intersections` and
 * `HxTypeParamDecl.constraintMore` already consume. The `intersections`
 * Star is `@:trivia @:tryparse` so it self-terminates when the next
 * token isn't `&` (the `,` outer typeParams sep, or the `>` outer
 * trail); the dominant zero-intersection case yields `intersections: []`
 * and the writer emits nothing extra.
 *
 * The wrapper is the dedicated element type of `HxTypeRef.params` — see
 * `HxTypeRef.hx` for the param-list mechanics (open `<` / sep `,` /
 * close `>`). Consumers that destructured a former `HxType` element now
 * access the inner type via `.type`.
 */
@:peg
typedef HxTypeArg = {
	var type:HxType;
	@:trivia @:tryparse @:fmt(padLeading) var intersections:Array<HxIntersectionClause>;
}
