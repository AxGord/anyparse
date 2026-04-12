package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe abstract declaration.
 *
 * Shape: `abstract Name(UnderlyingType) [from Type]* [to Type]* { members }`
 *
 * The `abstract` keyword lives on the `name` field via `@:kw('abstract')`
 * so the generated parser enforces a word boundary (`abstractly` is
 * rejected).
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
 * `@:enum abstract` is deferred — it requires recognising the `enum`
 * keyword before `abstract` at the `HxDecl` level.
 */
@:peg
typedef HxAbstractDecl = {
	@:kw('abstract') var name:HxIdentLit;
	@:lead('(') @:trail(')') var underlyingType:HxTypeRef;
	var clauses:Array<HxAbstractClause>;
	@:lead('{') @:trail('}') var members:Array<HxMemberDecl>;
}
