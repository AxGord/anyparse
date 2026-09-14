package anyparse.grammar.haxe;

/**
 * Grammar type for a single Haxe class declaration — a stand-alone root (driven by
 * `HaxeParser`) alongside `HxModule` (driven by `HaxeModuleParser`), which wraps zero or more
 * `HxDecl` branches for multi-declaration files. Two roots on one grammar package is what
 * validates that the marker-class pattern scales to multiple entry points.
 *
 * Grammar metadata: `@:peg` marks the grammar entry point; `@:schema(HaxeFormat)` binds the
 * grammar to `HaxeFormat` so the macro pipeline's `FormatReader` reads its `whitespace` field
 * at compile time; `@:ws` activates cross-cutting whitespace skipping before every literal
 * and regex match in the generated parser.
 *
 * `name` uses `@:kw('class')` — the Kw strategy matches the keyword with a word boundary, so
 * `classy` is not accepted as `class` followed by `y`.
 *
 * `typeParams` is the close-peek-Star sibling of `HxTypeRef.params`, gated on `@:optional` so
 * the common no-generics case skips the angle brackets; the element type `HxTypeParamDecl`
 * carries the name, constraints and default, so those extend that wrapper rather than
 * reshape this field.
 *
 * `heritage` is a bare `Array<HxHeritageClause>` between `typeParams` and `members`,
 * annotated `@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps)` — the structural
 * twin of `HxAbstractDecl.clauses`. The `@:tryparse` loop terminates naturally when the next
 * token is not `extends`/`implements` (i.e. the `{` of `members`), so the no-heritage case
 * adds no output. The parser accepts any number/order of `extends`/`implements`; semantic
 * policing is a later pass. `lineLengthAwareSeps` mirrors abstract `clauses`: when the full
 * decl line exceeds `opt.lineWidth`, the first clause breaks to the next line at +1 indent.
 *
 * `members` is a `Star` wrapped in `{` / `}` with no separator between items — each
 * `HxMemberDecl` is self-terminating via its own `;` or `{}` tail, and `Lowering`'s
 * separator-less Star path drives the loop until the closing brace.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxClassDecl = {
	@:kw('class') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps, heritageWrap) var heritage: Array<HxHeritageClause>;
	@:fmt(leftCurly, emptyCurlyBreak, beginEndType, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines,
		beforeDocCondLookThrough('member', 'Conditional', 'body'), blankBeforeFinalDocCommentInLeading, blankBeforeOrphanLineCommentTrail,
		interMemberBlankLines('member', 'VarMember|FinalMember', 'FnMember|FinalModifiedMember'),
		interMemberCondLookThrough('member', 'Conditional', 'body'), staticVarSubdivision, betweenMultilineCommentsBlanks,
		blankAroundMultilineMembers('aroundMultilineFields')) @:lead('{') @:trail('}') @:trivia var members: Array<HxMemberDecl>;
}
