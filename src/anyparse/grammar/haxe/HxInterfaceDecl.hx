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
 * `extends` is deferred to a future slice.
 *
 * The `members` field carries the same `interMemberBlankLines` knob as
 * `HxClassDecl.members` and `HxAbstractDecl.members`, but uses the
 * 6-arg form to route the per-pair counts through the dedicated
 * `interfaceBetweenVars` / `interfaceBetweenFunctions` /
 * `interfaceAfterVars` `HxModuleWriteOptions` fields instead of the
 * shared `betweenVars` / `betweenFunctions` / `afterVars`. Defaults are
 * all `0`, matching haxe-formatter's `InterfaceFieldsEmptyLinesConfig`
 * (interfaces stay tight unless the user opts in via
 * `hxformat.json`'s `emptyLines.interfaceEmptyLines`). The other
 * trivia-aware empty-line knobs (`afterFieldsWithDocComments`,
 * `existingBetweenFields`, `beforeDocCommentEmptyLines`) ship in
 * follow-up slices.
 */
@:peg
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxInterfaceDecl = {
	@:kw('interface') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:fmt(leftCurly, interMemberBlankLines('member', 'VarMember', 'FnMember', 'interfaceBetweenVars', 'interfaceBetweenFunctions', 'interfaceAfterVars')) @:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
