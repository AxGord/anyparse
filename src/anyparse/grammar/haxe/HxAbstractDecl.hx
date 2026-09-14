package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe abstract declaration: `abstract Name<TypeParams>(UnderlyingType)
 * [from Type]* [to Type]* { members }`. The `abstract` keyword lives on the `name` field via
 * `@:kw('abstract')` so the generated parser enforces a word boundary.
 *
 * `typeParams` is an optional close-peek-Star matching `HxFnDecl.typeParams` over
 * `HxTypeParamDecl` elements. The underlying type is wrapped in parentheses via `@:lead('(')`
 * and `@:trail(')')` on `underlyingType`, which is `@:optional Null<HxType>` for the
 * `@:coreType` bare-abstract shape (`abstract Foo from Int to Int {}`) — the
 * `@:optional + @:lead + @:trail` mechanism (bracket-pair close inside the lead-led commit
 * branch; trail emit inside `optParts` so it rides the `_optVal != null` runtime gate). The
 * `padLeading` flag on `clauses` supplies the pre-`from`/`to` space, so an absent underlying
 * type lands as `abstract Foo from …` without a phantom `()` slot. The grammar does not
 * enforce the `@:coreType` precondition — a semantic restriction outside the parser's
 * responsibility, as for `@:op` / `@:to`.
 *
 * `clauses` is a bare `Array<HxAbstractClause>` annotated `@:fmt(padLeading,
 * lineLengthAwareSeps)`. It is not the last struct field, so `emitStarFieldSteps` selects
 * try-parse mode: the loop attempts `HxAbstractClause` on each iteration and breaks when
 * neither `from` nor `to` matches (the next token is `{`). `padLeading` closes the
 * `(UnderlyingType)`↔`from` gap on the writer side — without it the bare-Star path's
 * internal-only sep glues `(Bar)from`; `padTrailing` is not needed because `members` carries
 * `@:lead('{')`, a spaced lead whose own separator covers the gap. `lineLengthAwareSeps`
 * (ω-abstract-clauses-linewrap) switches the hard `_dt(' ')` separators to
 * `IfLineExceeds(opt.lineWidth, _dhl(), _dt(' '))` probes and wraps the body in
 * `Nest(_cols, ...)` so break-mode hardlines indent +1, mirroring the fork's `wrapAfter`:
 * when the full decl line exceeds the width, the first `from`/`to` clause breaks to the next
 * line at +1 indent.
 *
 * Members reuse `HxMemberDecl`, as `HxClassDecl` and `HxInterfaceDecl` do, and `members`
 * carries the same `@:fmt(...)` knob set as `HxClassDecl.members`; the fork's
 * `EnumAbstractFieldsEmptyLinesConfig` shares the class defaults, so abstract routes through
 * the same `HxModuleWriteOptions` fields without a dedicated typedef.
 *
 * `enum abstract Name(T) { ... }` is handled at the `HxDecl` level via the `EnumAbstractDecl`
 * ctor (ω-enum-abstract), which consumes the leading `enum` keyword and reuses this typedef
 * verbatim; the legacy `@:enum abstract` metadata form rides the `HxTopLevelDecl.meta` Star
 * and reaches the plain `AbstractDecl` branch.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxAbstractDecl = {
	@:kw('abstract') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:optional @:lead('(') @:trail(')') @:fmt(tightLead) var underlyingType: Null<HxType>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps) var clauses: Array<HxAbstractClause>;
	@:fmt(leftCurly, emptyCurlyBreak, beginEndType, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines,
		beforeDocCondLookThrough('member', 'Conditional', 'body'), blankBeforeFinalDocCommentInLeading, blankBeforeOrphanLineCommentTrail,
		interMemberBlankLines('member', 'VarMember|FinalMember', 'FnMember'), staticVarSubdivision, betweenMultilineCommentsBlanks,
		blankAroundMultilineMembers('aroundMultilineFields')) @:lead('{') @:trail('}') @:trivia var members: Array<HxMemberDecl>;
}
