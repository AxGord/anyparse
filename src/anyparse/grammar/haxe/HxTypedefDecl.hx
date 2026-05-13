package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe typedef declaration.
 *
 * Shape: `typedef Name<TypeParams> = TypeRef` — a type alias binding
 * a name (with optional declare-site type parameters) to a type
 * reference. The `typedef` keyword lives on the `name` field via
 * `@:kw('typedef')` so the generated parser enforces a word boundary
 * (`typedefine` is rejected).
 *
 * `typeParams` is the symmetric close-peek-Star sibling of
 * `HxFnDecl.typeParams` — `HxTypeParamDecl` element type carrying
 * `name` and optional single-bound `constraint` (`<T:Foo>`).
 * Defaults and multi-bound syntax are deferred.
 *
 * The trailing semicolon lives on the `TypedefDecl` branch in
 * `HxDecl` via `@:trail(';')`, not here — this typedef only
 * describes the inside, matching the pattern used by `HxVarDecl`
 * and `HxFnDecl`.
 *
 * The `type` field is a full `HxType`, so struct typedefs
 * (`typedef Foo = {a:Int, b:String}`) and function types (`typedef
 * Foo = Int->Void`) compose through `HxType.Anon` and `HxType.Arrow`.
 * Writer-side `=` spacing on the rhs is driven by `@:fmt(typedefAssign)`
 * (slice ω-typedef-assign): default `WhitespacePolicy.Both` emits
 * `typedef Foo = Bar;` matching haxe-formatter's
 * `whitespace.binopPolicy: @:default(Around)`. Setting
 * `typedefAssign: WhitespacePolicy.None` reverts to the pre-slice
 * tight layout (`typedef Foo=Bar;`). The optional-Ref `=` leads on
 * `HxVarDecl.init` and `HxParam.defaultValue` still flow through the
 * bare-optional fallback path, which already emits ` = `.
 *
 * `@:fmt(multilineWhenFieldCtorAndOpt('type', 'Anon',
 * 'anonTypeLeftCurly', 'anyparse.format.BracePlacement.Next'))`
 * (slice ω-typedef-between-blank) tags
 * the typedef as structurally multi-line when its bound type is an
 * anonymous structure AND `anonTypeLeftCurly` is Allman (`Next` — `{`
 * on its own line, the placement under which the typedef body force-
 * multi rule fires per slice ω-typedef-anon-force-multi). The grammar-
 * derived predicate feeds into `HxModule.decls`'s
 * `blankLinesAfterCtorIf('decl', 'multiline', …, 'TypedefDecl',
 * 'afterMultilineDecl')` cascade so two consecutive multi-line typedefs
 * get a blank-line slot between them (matches haxe-formatter's
 * `emptyLines.betweenTypes: @:default(1)` for typedef→typedef). Under
 * `Same` (cuddled) the predicate stays false because the same source
 * emits single-line — the cascade falls through to
 * `betweenSingleLineTypes` (default 0) instead.
 *
 * `@:fmt(groupRestProbe)` on `typeParams` (slice ω-group-rest-probe-2)
 * flips the outer Group emitted by `WrapList.shapeFillLine` to
 * `GroupWithRestProbe` so the per-line fit check subtracts
 * `flatTokenWidthOfRestStack(stack)` from the budget. Without it, a
 * fitting-by-itself LHS `<...>` flat-emits and forces the RHS use-site
 * `<...>` to wrap; with it, the LHS sees the trailing
 * `= Rhs<...>;` content and proactively breaks, matching fork's
 * `wrapFillLine2AfterLast` `lengthAfter` bias. Targets the LHS-vs-RHS
 * competing-wraps pair on `wrapping/issue_494_type_parameter`. Mech-
 * live at outer Group layer; closing the byte-diff fully also requires
 * a sister rest-of-stack mech inside `Doc.Fill`'s per-item-fit probe.
 *
 * `@:fmt(multilineWhenStarFieldWrapsCascade('typeParams',
 * 'typeParameterWrap', 'name'))` (slice ω-typedef-typeparam-multiline)
 * OR-folds an additional condition into the multi-line predicate via
 * `WriterLowering.buildMultilinePredicate`: the typedef counts as
 * multi-line when its declare-site typeParams would render through a
 * non-`NoWrap` cascade mode. At predicate-eval time the engine
 * approximates per-item width via `name.length` and the same
 * `(n-1) * (sep + space)` correction `WrapList.emit` applies (2 chars
 * for `, ` sep), then probes `opt.typeParameterWrap` via
 * `WrapList.decideWithLineLengthState`. Closes the gap on
 * `wrapping/issue_494_type_parameter` between flat-typedef → wrapped-
 * typedef pairs: long type parameter lists drive `blankLinesBeforeCtorIf`
 * to insert the `betweenTypes=1`-equivalent blank line.
 */
@:peg
@:fmt(multilineWhenFieldCtorAndOpt('type', 'Anon', 'anonTypeLeftCurly', 'anyparse.format.BracePlacement.Next'))
@:fmt(multilineWhenStarFieldWrapsCascade('typeParams', 'typeParameterWrap', 'name'))
typedef HxTypedefDecl = {
	@:kw('typedef') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:fmt(typedefAssign, propagateTypedefContext) @:lead('=') var type:HxType;
}
