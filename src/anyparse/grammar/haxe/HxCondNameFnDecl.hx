package anyparse.grammar.haxe;

/**
 * A class-member `function` whose NAME is a `#if ... #end` region:
 *
 * ```haxe
 * override function #if (haxe_211 || haxe3) set_bigEndian #else setEndian #end(b) {
 * ```
 *
 * (`format/format/tools/MemoryInput.hx:46`, identical in haxelib
 * `format` 3,5,0 / 3,7,0 / 3,8,0 - the only source in the dependency
 * trees with a guarded function name.)
 *
 * WHY A SEPARATE DECL TYPE INSTEAD OF WIDENING `HxFnDecl.name`:
 * `HxFnDecl.name` is `HxIdentLit`, non-optional. Both root-level shapes
 * change its static type - either to a two-branch enum, or to
 * `Null<HxIdentLit>` guarded by `@:absentOn('(')` beside an optional
 * `@:kw('#if')` region field (the `HxVarDecl.condInit` / `HxVarInitRegion`
 * layering). Every `HxFnDecl` consumer would then have to handle an
 * absent name: `HxFnDecl` is Ref'd from six grammar sites (`HxClassMember`,
 * `HxDecl`, `HxStatement` x2, `HxExpr`, `HxAnonField`,
 * `HxFinalModifierMember`) and read in ~40 unit tests, and the query
 * plugin's `FnMember:<name>` selector is keyed off that slot. Paying that
 * across the whole engine for one third-party module is the wrong trade;
 * a scope-narrow ctor confines the widening to the shape that needs it,
 * the same discipline `HxMemberModifier` vs `HxModifier` and
 * `HxCondDeclPrefix` follow.
 *
 * The cost is that `typeParams`, `params`, `returnType` and `body` repeat
 * `HxFnDecl`'s field declarations verbatim, including their `@:fmt`
 * flags. They are a deliberate mirror: any change to `HxFnDecl`'s
 * signature-layout policy belongs here too. `typeParams` is carried even
 * though the motivating source has none, so a guarded name never silently
 * disables generics.
 *
 * Dispatch: `HxClassMember.CondNameFnMember` is tried BEFORE `FnMember`,
 * both on `@:kw('function')`. A plain `function foo(...)` fails this type's
 * mandatory `@:kw('#if')` on its first field, `tryBranch` restores
 * `ctx.pos`, and dispatch falls through - the same ordered first-match
 * rollback as `FinalModifiedMember` before `FinalMember`.
 */
@:peg
@:fmt(multilineWhenFieldShape('body'), propagateFnBodyEmpty('body'))
typedef HxCondNameFnDecl = {
	@:kw('#if') var region: HxFnNameRegion;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), funcParamParens,
		wrapRules('functionSignatureWrap'), bodyAwareCompactIndent, groupRestProbe, ignoreSourceNewlinesForWrap) var params: Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType: Null<HxType>;
	@:fmt(leftCurly('blockLeftCurly'), bodyPolicyForCtor('UntypedBlockBody', 'untypedBody'),
		bodyPolicyForCtor('ExprBody', 'functionBody'), metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr')) var body: HxFnBody;
}
