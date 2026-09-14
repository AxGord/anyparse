package anyparse.grammar.haxe;

/**
 * Function declaration body for a class member `function`: `name <typeParams> ( params ) :
 * ReturnType <body>`, where `<body>` is one of the `HxFnBody` variants — `{ stmts }`
 * (`BlockBody`) or a bare terminating `;` (`NoBody`) for interface methods / `@:overload`
 * stubs. The `function` keyword lives on the enclosing `HxClassMember.FnMember` constructor
 * via `@:kw` — this typedef only describes the inside.
 *
 * `typeParams` is the close-peek-Star sibling of `HxTypeRef.params` (`@:optional @:lead('<')
 * @:trail('>') @:sep(',')`) over `HxTypeParamDecl` elements. `params` uses `@:lead('(')
 * @:trail(')') @:sep(',')`, which selects the sep-peek termination mode in
 * `emitStarFieldSteps`: peek the close char for an empty list, then a sep-separated loop.
 * The return type is `@:optional @:lead(':')` — the lead `:` is the commit point: `matchLit`
 * peeks it, and the sub-rule parse only fires when the peek hits (D24).
 *
 * `body` is a Ref to `HxFnBody`. The brace / semicolon grammar and the `@:trivia` capture for
 * inner statements live on the `BlockBody` branch of that enum (via the `HxFnBlock` Seq
 * wrapper — the orphan-trivia synth slots only attach to Seq Stars). The field-level
 * `@:fmt(leftCurly)` is intentionally kept here: `WriterLowering` consumes it on the bare-Ref
 * path to emit a `Type.enumConstructor`-gated `BracePlacement` separator — that gate is what
 * suppresses the inter-field space ahead of `;` for `NoBody` while preserving the
 * policy-aware ` {` / `\n\t{` for `BlockBody`. `HxFnBody` is trivia-bearing (paired type
 * `HxFnBodyT`).
 *
 * `@:fmt(metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr'))` handles a metadata-prefixed
 * block body — `function f():Ret @:meta { … }`. Such a body parses as
 * `ExprBody(MetaExpr(_, BlockExpr))`, so the default `bodyPolicyForCtor('ExprBody',
 * 'functionBody')` would treat it like a non-block expression body and break the metadata
 * onto its own line; `metaBlockGlue` makes `WriterLowering` detect the meta-wrapped-block
 * runtime shape and glue `<sig> @:meta {` on the signature line, the block's own Nest
 * supplying the body indent. A meta-wrapped non-block body keeps the `functionBody` policy.
 */
@:peg
@:fmt(multilineWhenFieldShape('body'))
typedef HxFnDecl = {
	var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), funcParamParens,
		wrapRules('functionSignatureWrap'), bodyAwareCompactIndent, groupRestProbe, ignoreSourceNewlinesForWrap) var params: Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType: Null<HxType>;
	@:fmt(leftCurly('blockLeftCurly'), bodyPolicyForCtor('UntypedBlockBody', 'untypedBody'),
		bodyPolicyForCtor('ExprBody', 'functionBody'), metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr')) var body: HxFnBody;
}
