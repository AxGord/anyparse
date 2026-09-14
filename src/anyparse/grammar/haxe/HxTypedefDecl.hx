package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe typedef declaration: `typedef Name<TypeParams> = Type [& Type]*`.
 * The `typedef` keyword lives on the `name` field via `@:kw('typedef')` so the generated
 * parser enforces a word boundary; the trailing semicolon lives on the `TypedefDecl` branch
 * in `HxDecl`, not here, matching `HxVarDecl` and `HxFnDecl`. `typeParams` is the
 * close-peek-Star sibling of `HxFnDecl.typeParams` over `HxTypeParamDecl` elements.
 *
 * `type` is a full `HxType`, so struct typedefs and function types compose through
 * `HxType.Anon` and `HxType.Arrow`. Writer-side `=` spacing is driven by
 * `@:fmt(typedefAssign)` (ω-typedef-assign): the default `WhitespacePolicy.Both` emits
 * `typedef Foo = Bar;` (haxe-formatter's `binopPolicy` default), `None` the tight form.
 *
 * `@:fmt(multilineWhenFieldCtorAndOpt('type', 'Anon', 'anonTypeLeftCurly',
 * 'anyparse.format.BracePlacement.Next'))` (ω-typedef-between-blank) tags the typedef as
 * structurally multi-line when its bound type is an anonymous structure AND
 * `anonTypeLeftCurly` is Allman (`Next`). The grammar-derived predicate feeds
 * `HxModule.decls`'s `blankLinesAfterCtorIf('decl', 'multiline', …, 'TypedefDecl',
 * 'afterMultilineDecl')` cascade so two consecutive multi-line typedefs get a blank-line slot
 * between them (haxe-formatter's `emptyLines.betweenTypes`); under `Same` the predicate
 * stays false because the same source emits single-line, and the cascade falls through to
 * `betweenSingleLineTypes`. `@:fmt(multilineWhenStarFieldWrapsCascade('typeParams',
 * 'typeParameterWrap', 'name'))` OR-folds a second condition into the same predicate via
 * `WriterLowering.buildMultilinePredicate`: the typedef counts as multi-line when its
 * declare-site typeParams would render through a non-`NoWrap` cascade mode, approximated
 * at predicate-eval time from `name.length` plus the `(n-1) * (sep + space)` correction
 * `WrapList.emit` applies, then probed via `WrapList.decideWithLineLengthState`.
 *
 * `@:fmt(groupRestProbe)` on `typeParams` flips the outer Group emitted by
 * `WrapList.shapeFillLine` to `GroupWithRestProbe` so the per-line fit check subtracts
 * `flatTokenWidthOfRestStack(stack)` from the budget: a fitting-by-itself LHS `<...>` sees
 * the trailing `= Rhs<...>;` content and proactively breaks (the fork's `lengthAfter` bias).
 *
 * `intersections` is a bare `Array<HxIntersectionClause>` annotated `@:trivia @:tryparse
 * @:fmt(padLeading)`, structurally identical to `HxClassDecl.heritage`; it captures the `&
 * Type` tail with the first operand in `type` (scoping `&` here keeps `HxType` free of it —
 * see `HxIntersectionClause`). `@:fmt(operandBreakAfterMultilineBrace)` on the Star makes
 * each `& Type` clause whose PRECEDING clause rendered multi-line and ended with a close
 * brace break onto its own line (`} &\n\tB`), the fork's `lineEndAfter` on the `&` after a
 * `BrClose`; threaded with the per-clause `@:fmt(typedefIntersectionBreak)`.
 */
@:peg
@:fmt(multilineWhenFieldCtorAndOpt('type', 'Anon', 'anonTypeLeftCurly', 'anyparse.format.BracePlacement.Next'))
@:fmt(multilineWhenStarFieldWrapsCascade('typeParams', 'typeParameterWrap', 'name'))
typedef HxTypedefDecl = {
	@:kw('typedef') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:fmt(typedefAssign, propagateTypedefContext) @:lead('=') var type: HxType;
	@:trivia @:tryparse @:fmt(padLeading, operandBreakAfterMultilineBrace) var intersections: Array<HxIntersectionClause>;
}
