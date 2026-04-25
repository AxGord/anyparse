package anyparse.grammar.haxe.format;

/**
 * `whitespace` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`functionTypeHaxe3Policy`,
 * `functionTypeHaxe4Policy`, `tryPolicy`, `ifPolicy`,
 * `arrowFunctionsPolicy`, `forPolicy`, `ternaryPolicy`, …) are silently
 * dropped by the ByName struct parser's `UnknownPolicy.Skip` — they
 * land with the slice that introduces the matching writer knob.
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
 */
@:peg typedef HxFormatWhitespaceSection = {

	@:optional var objectFieldColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeHintColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamOpenPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamClosePolicy:HxFormatWhitespacePolicy;

	@:optional var parenConfig:HxFormatParenConfigSection;

	@:optional var bracesConfig:HxFormatBracesConfigSection;
};
