package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe interface declaration.
 *
 * Structurally identical to `HxClassDecl` — a keyword-introduced
 * name with optional declare-site type parameters followed by a
 * close-peek Star field of members inside braces. Shares
 * `HxMemberDecl` for member declarations, so interfaces accept the
 * same `var`/`function` members with optional modifiers.
 *
 * `typeParams` is the symmetric close-peek-Star sibling of
 * `HxFnDecl.typeParams` — `HxTypeParamDecl` element type carrying
 * `name` and optional single-bound `constraint` (`<T:Foo>`).
 * Defaults and multi-bound syntax are deferred.
 *
 * Semantic differences between interfaces and classes (no function
 * bodies, no `static`, mandatory `public`) are not the parser's
 * responsibility — they belong to a later analysis pass.
 *
 * `heritage` is the same bare `Array<HxHeritageClause>` field as
 * `HxClassDecl.heritage` (`@:trivia @:tryparse @:fmt(padLeading,
 * lineLengthAwareSeps)`), placed between `typeParams` and `members`.
 * Haxe interfaces use `extends` (repeatable); the shared
 * `HxHeritageClause` enum also carries `implements`, which simply never
 * matches in interface position. The parser does not police that
 * distinction — semantic analysis is a later pass.
 *
 * The `members` field carries the same `interMemberBlankLines` knob as
 * `HxClassDecl.members` and `HxAbstractDecl.members`, but uses the
 * 6-arg form to route the per-pair counts through the dedicated
 * `interfaceBetweenVars` / `interfaceBetweenFunctions` /
 * `interfaceAfterVars` `HxModuleWriteOptions` fields instead of the
 * shared `betweenVars` / `betweenFunctions` / `afterVars`. Defaults are
 * all `0`, matching haxe-formatter's `InterfaceFieldsEmptyLinesConfig`
 * (interfaces stay tight unless the user opts in via
 * `hxformat.json`'s `emptyLines.interfaceEmptyLines`). The
 * trivia-aware empty-line knobs `afterFieldsWithDocComments`,
 * `existingBetweenFields`, and `beforeDocCommentEmptyLines` are
 * shared with `HxClassDecl.members` and `HxAbstractDecl.members` —
 * interface fields opt into the same engine paths so a doc-commented
 * function in interface scope (e.g. `issue_385_single_line_doc_comment_fields`)
 * gets the same trailing blank line as in class/abstract scope.
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
		), betweenMultilineCommentsBlanks) @:lead('{') @:trail('}') @:trivia var members: Array<HxMemberDecl>;
}
