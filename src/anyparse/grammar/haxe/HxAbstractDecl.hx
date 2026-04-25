package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe abstract declaration.
 *
 * Shape: `abstract Name<TypeParams>(UnderlyingType) [from Type]* [to Type]* { members }`
 *
 * The `abstract` keyword lives on the `name` field via `@:kw('abstract')`
 * so the generated parser enforces a word boundary (`abstractly` is
 * rejected).
 *
 * `typeParams` is an optional close-peek-Star matching `HxFnDecl.typeParams`
 * — `HxTypeParamDecl` element type carrying `name` and optional
 * single-bound `constraint` (`<T:Foo>`). Defaults and multi-bound
 * syntax are deferred.
 *
 * The underlying type is wrapped in parentheses via `@:lead('(')` and
 * `@:trail(')')` on the `underlyingType` field — existing Lowering
 * pattern (same as `HxDoWhileStmt.cond` which has `@:kw` + `@:lead` +
 * `@:trail`).
 *
 * The `clauses` field is a bare `Array<HxAbstractClause>` annotated only
 * with `@:fmt(padLeading)`. It is not the last struct field, so
 * `emitStarFieldSteps` selects try-parse mode (line 1074): the loop
 * attempts to parse `HxAbstractClause` on each iteration and breaks
 * when neither `from` nor `to` keyword matches (i.e. the next token
 * is `{`). This is the first grammar consumer exercising positional
 * try-parse on a bare Star field. The `padLeading` flag closes the
 * `(UnderlyingType)`↔`from` gap on the writer side: without it the
 * bare-Star path's internal-only sep glues `(Bar)from` together.
 * `padTrailing` is not needed — the next field (`members`) carries
 * `@:lead('{')`, a spaced lead whose own separator covers the gap.
 *
 * Members reuse `HxMemberDecl` — same as `HxClassDecl` and
 * `HxInterfaceDecl`. Semantic restrictions (e.g. `@:op` annotations,
 * implicit cast methods) are not the parser's responsibility.
 *
 * The `members` field carries the same `@:fmt(...)` knob set as
 * `HxClassDecl.members` (`leftCurly`, `afterFieldsWithDocComments`,
 * `existingBetweenFields`, `beforeDocCommentEmptyLines`,
 * `interMemberBlankLines('member', 'VarMember', 'FnMember')`). Upstream
 * `EnumAbstractFieldsEmptyLinesConfig` shares the class defaults
 * (`betweenVars: 0`, `betweenFunctions: 1`, `afterVars: 1`), so abstract
 * routes through the same `HxModuleWriteOptions` fields without a
 * dedicated typedef. `HxInterfaceDecl` (upstream `0/0/0`) needs its own
 * knob set and stays on the bare `@:fmt(leftCurly)` until that slice
 * lands.
 *
 * `@:enum abstract` is deferred — it requires recognising the `enum`
 * keyword before `abstract` at the `HxDecl` level.
 */
@:peg
typedef HxAbstractDecl = {
	@:kw('abstract') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:lead('(') @:trail(')') var underlyingType:HxType;
	@:fmt(padLeading) var clauses:Array<HxAbstractClause>;
	@:fmt(leftCurly, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines, interMemberBlankLines('member', 'VarMember', 'FnMember')) @:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
