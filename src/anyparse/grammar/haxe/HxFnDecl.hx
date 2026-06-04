package anyparse.grammar.haxe;

/**
 * Function declaration body for a class member `function`.
 *
 * Shape: `name <typeParams> ( params ) : ReturnType <body>` where
 * `typeParams` is an optional angle-bracketed comma-separated list of
 * type-parameter names, `params` is a comma-separated list of `HxParam`
 * entries (possibly empty), and `<body>` is one of two `HxFnBody`
 * variants: `{ stmts }` braced statements (`BlockBody`) or a bare
 * terminating `;` (`NoBody`) for interface methods / `@:overload`
 * stubs.
 *
 * The `function` keyword lives on the enclosing `HxClassMember.FnMember`
 * constructor via `@:kw` — this typedef only describes the inside.
 *
 * `typeParams` is the close-peek-Star sibling of `HxTypeRef.params`:
 * `@:optional @:lead('<') @:trail('>') @:sep(',')`. The element type
 * is `HxTypeParamDecl` — declare-site wrapper with `name` and optional
 * single-bound `constraint` (`<T:Foo>`). Defaults (`<T = Int>`) and
 * multi-constraint syntax (`<T:A&B>`) are deferred follow-up slices
 * extending `HxTypeParamDecl`.
 *
 * The `params` field uses `@:lead('(') @:trail(')') @:sep(',')` which
 * selects the sep-peek termination mode in `emitStarFieldSteps`:
 * peek close-char for empty list, then sep-separated loop. Zero params
 * yields an empty array.
 *
 * Return type is `@:optional @:lead(':')` — when absent the function
 * relies on Haxe type inference. The lead `:` is the commit point for
 * the optional: `matchLit` peeks it, and the sub-rule parse only fires
 * when the peek hits (D24).
 *
 * The `body` field is a Ref to `HxFnBody`. The brace / semicolon
 * grammar and the `@:trivia` capture for inner statements live on the
 * `BlockBody` branch of that enum (via the `HxFnBlock` Seq wrapper —
 * the orphan-trivia synth slots only attach to Seq Stars, not Alt-
 * branch Stars). The field-level `@:fmt(leftCurly)` is intentionally
 * kept here: `WriterLowering` consumes it on the bare-Ref path to
 * emit a `Type.enumConstructor`-gated `BracePlacement` separator —
 * that gate is what suppresses the inter-field space ahead of `;` for
 * `NoBody` while preserving the policy-aware ` {` / `\n\t{` for
 * `BlockBody`. `HxFnBody` is trivia-bearing (paired type `HxFnBodyT`).
 *
 * The `@:fmt(metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr'))` flag
 * handles a metadata-prefixed block body — `function f():Ret @:meta
 * { … }`. Such a body parses as `ExprBody(MetaExpr(_, BlockExpr))`
 * (the metadata routes it through the HxExpr parser instead of the
 * `BlockBody` branch), so the default `bodyPolicyForCtor('ExprBody',
 * 'functionBody')` would treat it like a non-block expression body and
 * break the metadata onto its own line (plus an extra body indent
 * step). `metaBlockGlue` makes `WriterLowering` detect the
 * meta-wrapped-block runtime shape and glue `<sig> @:meta {` on the
 * signature line instead, the block's own Nest supplying the body
 * indent. A meta-wrapped non-block body (`@:meta return x`) keeps the
 * `functionBody` policy.
 */
@:peg
@:fmt(multilineWhenFieldShape('body'), propagateFnBodyEmpty('body'))
typedef HxFnDecl = {
	var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), funcParamParens, wrapRules('functionSignatureWrap'), bodyAwareCompactIndent, groupRestProbe, ignoreSourceNewlinesForWrap) var params:Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType:Null<HxType>;
	@:fmt(leftCurly('blockLeftCurly'), bodyPolicyForCtor('UntypedBlockBody', 'untypedBody'), bodyPolicyForCtor('ExprBody', 'functionBody'), metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr')) var body:HxFnBody;
}
