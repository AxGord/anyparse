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
 * — bare-identifier declare-site form, no constraints/defaults yet.
 *
 * The underlying type is wrapped in parentheses via `@:lead('(')` and
 * `@:trail(')')` on the `underlyingType` field — existing Lowering
 * pattern (same as `HxDoWhileStmt.cond` which has `@:kw` + `@:lead` +
 * `@:trail`).
 *
 * The `clauses` field is a bare `Array<HxAbstractClause>` with no
 * annotations. It is not the last struct field, so
 * `emitStarFieldSteps` selects try-parse mode (line 1074): the loop
 * attempts to parse `HxAbstractClause` on each iteration and breaks
 * when neither `from` nor `to` keyword matches (i.e. the next token
 * is `{`). This is the first grammar consumer exercising positional
 * try-parse on a bare Star field.
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
	@:optional @:lead('<') @:trail('>') @:sep(',') var typeParams:Null<Array<HxIdentLit>>;
	@:lead('(') @:trail(')') var underlyingType:HxTypeRef;
	var clauses:Array<HxAbstractClause>;
	@:fmt(leftCurly, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines, interMemberBlankLines('member', 'VarMember', 'FnMember')) @:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
