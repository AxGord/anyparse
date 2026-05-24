package anyparse.grammar.haxe;

/**
 * For-loop statement grammar.
 *
 * Shape: `for (varName in iterable) body`.
 *
 * The opening `(` is a literal lead on the `varName` field. The `in`
 * keyword is a `@:kw` lead on the `iterable` field (word-boundary
 * enforced via `expectKw`). The closing `)` is a literal trail on the
 * `iterable` field. The `body` is a bare `HxStatement` Ref — any
 * statement branch (including `BlockStmt`) is accepted.
 *
 * Zero Lowering changes for parsing: `@:kw` + `@:trail` on the same
 * field already work in `lowerStruct` — kw lead emits `expectKw`
 * (line 912-914), trail emits `expectLit` (line 985-987). The
 * expression parser returns cleanly on `)` because no Pratt/postfix
 * operator matches it.
 *
 * ω-condwrap-forstmt: writer-side opt-in to the `conditionWrapping`
 * cascade — `@:fmt(condWrap('conditionWrap'))` on `varName` (start of
 * cond span) paired with `@:fmt(condWrapEnd)` on `iterable` (end of
 * cond span) routes the `(varName in iterable)` paren group through
 * `WrapList.emitCondition`. Single-field `@:fmt(condWrap)` is
 * insufficient here because the open paren lives on `varName.@:lead`
 * and the close paren on `iterable.@:trail`; the span engine wraps
 * everything between the two literals in a single Group/IfBreak
 * decided by `opt.conditionWrap` plus the rest-of-line measurement.
 * Mirrors fork's `markPWrapping` `ForLoop` dispatch to `wrapCondition`.
 *
 * Map key-value iteration `for (k => v in m)` is supported via the
 * optional `valueName` field — `@:optional @:lead('=>')`, the same
 * optional-single-Ref-with-literal-commit pattern as
 * `HxParamBody.defaultValue` (`@:optional @:lead('=')`) and
 * `HxFnDecl.returnType` (`@:optional @:lead(':')`). Plain single-iter
 * `for (v in m)` leaves it null (the `=>` peek fails on `in`). It
 * sits inside the `conditionWrap` span (`varName` start … `iterable`
 * end); the generic optional-Ref writer path emits ` => v` when
 * present. Surfacing `valueName` as a second scope binding in the apq
 * refs plugin is a separate, non-parse-blocking enhancement.
 */
@:peg
typedef HxForStmt = {
	@:lead('(') @:fmt(condWrap('conditionWrap')) var varName:HxIdentLit;
	@:optional @:lead('=>') var valueName:Null<HxIdentLit>;
	@:kw('in') @:trail(')') @:fmt(condWrapEnd) var iterable:HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('forBody')) var body:HxStatement;
};
