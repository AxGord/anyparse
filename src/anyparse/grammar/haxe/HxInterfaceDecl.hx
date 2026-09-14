package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe interface declaration.
 *
 * Structurally identical to `HxClassDecl`: a keyword-introduced name with optional
 * declare-site type parameters, a heritage clause list, and a close-peek Star of members
 * inside braces. Shares `HxMemberDecl` for members. Semantic differences between interfaces
 * and classes (no function bodies, no `static`, mandatory `public`; `implements` never
 * matching in interface position) are not the parser's responsibility — they belong to a
 * later analysis pass.
 *
 * `typeParams` is the symmetric close-peek-Star sibling of `HxFnDecl.typeParams`
 * (`HxTypeParamDecl` elements: `name` plus optional single-bound `constraint`). `heritage` is
 * the same bare `Array<HxHeritageClause>` field as `HxClassDecl.heritage` (`@:trivia
 * @:tryparse @:fmt(padLeading, lineLengthAwareSeps)`).
 *
 * `members` carries the same `interMemberBlankLines` knob as `HxClassDecl.members` and
 * `HxAbstractDecl.members`, but the 6-arg form routes the per-pair counts through the
 * dedicated `interfaceBetweenVars` / `interfaceBetweenFunctions` / `interfaceAfterVars`
 * `HxModuleWriteOptions` fields instead of the shared `betweenVars` / `betweenFunctions` /
 * `afterVars`; their defaults are `0` (interfaces stay tight unless `hxformat.json`'s
 * `emptyLines.interfaceEmptyLines` opts in). The trivia-aware knobs
 * `afterFieldsWithDocComments`, `existingBetweenFields` and `beforeDocCommentEmptyLines` are
 * shared with class and abstract scope, so a doc-commented interface function gets the same
 * trailing blank line.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxInterfaceDecl = {
	@:kw('interface') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps, heritageWrap) var heritage: Array<HxHeritageClause>;
	@:fmt(leftCurly, emptyCurlyBreak, beginEndType, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines,
		beforeDocCondLookThrough('member', 'Conditional', 'body'), blankBeforeFinalDocCommentInLeading, blankBeforeOrphanLineCommentTrail,
		interMemberBlankLines(
			'member', 'VarMember|FinalMember', 'FnMember', 'interfaceBetweenVars', 'interfaceBetweenFunctions', 'interfaceAfterVars'
		), betweenMultilineCommentsBlanks, blankAroundMultilineMembers('aroundMultilineFields')) @:lead('{') @:trail('}') @:trivia var members: Array<HxMemberDecl>;
}
