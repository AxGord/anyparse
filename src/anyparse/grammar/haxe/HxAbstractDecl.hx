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
 * Slice 40 lifts `underlyingType` to `@:optional Null<HxType>` for the
 * `@:coreType` bare-abstract shape (`abstract Foo from Int to Int {}` —
 * Haxe spec allows a `@:coreType` abstract to declare no underlying
 * type at all). First consumer of the macro pipeline's new
 * `@:optional + @:lead + @:trail` mechanism (Lowering.hx — bracket-
 * pair close inside the lead-led commit branch; WriterLowering.hx —
 * trail emit inside `optParts` so it rides the `_optVal != null`
 * runtime gate). Absent and present forms both emit byte-identical to
 * source. The `padLeading` flag on `clauses` already supplies the
 * pre-`from`/`to` space, so an absent underlying type lands as
 * `abstract Foo from …` without a phantom `()` slot. The grammar does
 * not enforce the `@:coreType` precondition — that's a semantic
 * restriction outside the parser's responsibility (HxAbstractDecl
 * mirrors the same stance for `@:op` / `@:to` annotations).
 *
 * The `clauses` field is a bare `Array<HxAbstractClause>` annotated
 * with `@:fmt(padLeading, lineLengthAwareSeps)`. It is not the last
 * struct field, so `emitStarFieldSteps` selects try-parse mode (line
 * 1074): the loop attempts to parse `HxAbstractClause` on each
 * iteration and breaks when neither `from` nor `to` keyword matches
 * (i.e. the next token is `{`). This is the first grammar consumer
 * exercising positional try-parse on a bare Star field. The
 * `padLeading` flag closes the `(UnderlyingType)`↔`from` gap on the
 * writer side: without it the bare-Star path's internal-only sep
 * glues `(Bar)from` together. `padTrailing` is not needed — the next
 * field (`members`) carries `@:lead('{')`, a spaced lead whose own
 * separator covers the gap.
 *
 * `lineLengthAwareSeps` (ω-abstract-clauses-linewrap) switches the
 * hard `_dt(' ')` separators (leading pad + inter-element) to
 * `IfLineExceeds(opt.lineWidth, _dhl(), _dt(' '))` probes and wraps
 * the body in `Nest(_cols, ...)` so break-mode hardlines indent +1.
 * Mirrors fork's `wrapAfter` mechanism for `abstract <T>(...) [from
 * X]*` (MarkWhitespace.hx:79 + codedata/CodeLine.hx:47): when the
 * full decl line exceeds `maxLineLength` (default 160), the first
 * `from`/`to` clause breaks to the next line at +1 indent. The
 * engine implementation lives in `WriterLowering.hx`'s bare-Star
 * `padLeading || padTrailing` emit branch.
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
 * `enum abstract Name(T) { ... }` is handled at the `HxDecl` level via
 * the `EnumAbstractDecl` ctor (slice ω-enum-abstract), which consumes
 * the leading `enum` keyword and reuses this `HxAbstractDecl` verbatim
 * for the rest. The legacy `@:enum abstract` metadata form is
 * orthogonal — the `@:enum` tag rides the `HxTopLevelDecl.meta` Star
 * and reaches the plain `AbstractDecl` branch.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxAbstractDecl = {
	@:kw('abstract') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:optional @:lead('(') @:trail(')') @:fmt(tightLead) var underlyingType:Null<HxType>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps) var clauses:Array<HxAbstractClause>;
	@:fmt(leftCurly, emptyCurlyBreak, beginEndType, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines, blankBeforeFinalDocCommentInLeading, blankBeforeOrphanLineCommentTrail, interMemberBlankLines('member', 'VarMember', 'FnMember'), staticVarSubdivision, betweenMultilineCommentsBlanks) @:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
