package anyparse.grammar.haxe.format;

/**
 * `whitespace` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`functionTypeHaxe3Policy`,
 * `tryPolicy`, `ifPolicy`, `forPolicy`, `ternaryPolicy`, …) are
 * silently dropped by the ByName struct parser's `UnknownPolicy.Skip`
 * — they land with the slice that introduces the matching writer knob.
 *
 * Added in slice ψ₇ (feeds `opt.objectFieldColon`).
 *
 * Extended in slice ω-E-whitespace:
 *  - `typeHintColonPolicy` feeds `opt.typeHintColon` (the `:` on
 *    `HxVarDecl.type`, `HxParam.type`, `HxFnDecl.returnType`).
 *  - `parenConfig` is the nested section that houses
 *    `parenConfig.funcParamParens.openingPolicy`, feeding
 *    `opt.funcParamParens` (the space before the `(` on
 *    `HxFnDecl.params`).
 *
 * Extended in slice ω-call-parens:
 *  - `parenConfig.callParens.openingPolicy` feeds `opt.callParens`
 *    (the space before the `(` on `HxExpr.Call.args`).
 *
 * Extended in slice ω-typeparam-spacing:
 *  - `typeParamOpenPolicy` feeds `opt.typeParamOpen` (the `<` of every
 *    type-parameter list, both `HxTypeRef.params` and the declare-site
 *    `typeParams` fields).
 *  - `typeParamClosePolicy` feeds `opt.typeParamClose` (the matching
 *    `>`). Combined `typeParamOpenPolicy: "after"` +
 *    `typeParamClosePolicy: "before"` produces `Array< Int >`.
 *
 * Extended in slice ω-anontype-braces:
 *  - `bracesConfig.anonTypeBraces.openingPolicy` feeds
 *    `opt.anonTypeBracesOpen` (the `{` of `HxType.Anon`).
 *  - `bracesConfig.anonTypeBraces.closingPolicy` feeds
 *    `opt.anonTypeBracesClose` (the matching `}`). Combined
 *    `openingPolicy: "around"` + `closingPolicy: "around"` produces
 *    `{ x:Int }`.
 *
 * Extended in slice ω-typeparam-default-equals:
 *  - `binopPolicy` feeds `opt.typeParamDefaultEquals` (the `=` joining
 *    a declare-site type-parameter to its default type on
 *    `HxTypeParamDecl.defaultValue`). Upstream's `binopPolicy` controls
 *    spacing of every binary operator; here it routes to the only
 *    binop site the writer currently exposes as a knob. Future binop
 *    sites adopting their own `@:fmt(...)` flag should extend this
 *    mapping rather than introduce a separate JSON key.
 *
 * Extended in slice ω-line-comment-space:
 *  - `addLineCommentSpace` feeds `opt.addLineCommentSpace`. Bool — when
 *    `true` (haxe-formatter default) `//foo` is rewritten to `// foo`;
 *    decoration runs (`//*****`, `//------`, `////`) survive tight. The
 *    knob is consumed by `HaxeCommentNormalizer.normalizeLineComment`
 *    inside the writer's leading / trailing line-comment helpers.
 *
 * Extended in slice ω-arrow-fn-type:
 *  - `functionTypeHaxe4Policy` feeds `opt.functionTypeHaxe4` (the `->`
 *    separator inside a new-form arrow function type, `HxArrowFnType.
 *    ret`'s `@:lead('->')`). `Around` (default) emits
 *    `(Int) -> Bool`; `None` keeps the tight `(Int)->Bool` form. The
 *    sibling `functionTypeHaxe3Policy` (old-form curried `Int->Bool`)
 *    has its own `@:fmt(tight)` on `HxType.Arrow` and stays tight by
 *    construction — no JSON-side knob needed.
 *
 * Extended in slice ω-arrow-fn-expr:
 *  - `arrowFunctionsPolicy` feeds `opt.arrowFunctions` (the `->`
 *    separator inside a parenthesised arrow lambda expression,
 *    `HxThinParenLambda.body`'s `@:lead('->')`). `Around` (default)
 *    emits `(arg) -> body`; `None` keeps the tight `(arg)->body` form.
 *    Independent of `functionTypeHaxe4Policy` (the type-position
 *    sibling). The single-ident infix form `arg -> body`
 *    (`HxExpr.ThinArrow`) rides the Pratt infix path which adds
 *    surrounding spaces by default and is unaffected.
 */
@:peg typedef HxFormatWhitespaceSection = {

	@:optional var objectFieldColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeHintColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamOpenPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamClosePolicy:HxFormatWhitespacePolicy;

	@:optional var binopPolicy:HxFormatWhitespacePolicy;

	@:optional var functionTypeHaxe4Policy:HxFormatWhitespacePolicy;

	@:optional var arrowFunctionsPolicy:HxFormatWhitespacePolicy;

	@:optional var addLineCommentSpace:Bool;

	@:optional var parenConfig:HxFormatParenConfigSection;

	@:optional var bracesConfig:HxFormatBracesConfigSection;
};
