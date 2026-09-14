package anyparse.grammar.haxe;

/**
 * For-loop statement grammar: `for (varName in iterable) body`.
 *
 * The opening `(` is a literal lead on the `varName` field; the `in` keyword is a `@:kw` lead
 * on `iterable` (word-boundary enforced via `expectKw`) and the closing `)` its literal trail.
 * The `body` is a bare `HxStatement` Ref — any statement branch (including `BlockStmt`) is
 * accepted; the expression parser returns cleanly on `)` because no Pratt/postfix operator
 * matches it.
 *
 * ω-condwrap-forstmt: `@:fmt(condWrap('conditionWrap'))` on `varName` (start of the cond
 * span) paired with `@:fmt(condWrapEnd)` on `iterable` (end of the span) routes the
 * `(varName in iterable)` paren group through `WrapList.emitCondition`. A single-field
 * `@:fmt(condWrap)` is insufficient because the open paren lives on `varName.@:lead` and the
 * close paren on `iterable.@:trail`; the span engine wraps everything between the two
 * literals in one Group/IfBreak decided by `opt.conditionWrap` plus the rest-of-line
 * measurement. Mirrors the fork's `markPWrapping` `ForLoop` dispatch to `wrapCondition`.
 *
 * Map key-value iteration `for (k => v in m)` goes through the optional `valueName` field —
 * `@:optional @:lead('=>')`, the optional-single-Ref-with-literal-commit pattern of
 * `HxParamBody.defaultValue` and `HxFnDecl.returnType`. Plain `for (v in m)` leaves it null
 * (the `=>` peek fails on `in`); it sits inside the `conditionWrap` span and the generic
 * optional-Ref writer path emits ` => v` when present. The slot holds `HxKeyValueBinder` — a
 * `@:spanned('KeyValueBinder')` one-field wrapper — rather than a bare `HxIdentLit`, because
 * a Terminal projects no `QueryNode` and the value binder would be invisible to `refs` /
 * `rename` and to every declaration-walking check; the emitted bytes are unchanged.
 */
@:peg
typedef HxForStmt = {
	@:lead('(') @:fmt(condWrap('conditionWrap')) var varName: HxIdentLit;
	@:optional @:lead('=>') var valueName: Null<HxKeyValueBinder>;
	@:kw('in') @:trail(')') @:fmt(condWrapEnd) var iterable: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('forBody'), dropSingleStmtBraces, loopBodyIfElseNext(
		'loopBodyIfElseNext', 'IfStmt', 'elseBody'
	)) var body: HxStatement;
};
