package anyparse.grammar.haxe.format;

/**
 * `whitespace` section of a haxe-formatter `hxformat.json` config.
 *
 * Only keys whose runtime knob already exists on `HxModuleWriteOptions`
 * are modelled here. Missing keys (`functionTypeHaxe3Policy`,
 * `catchPolicy`, `ternaryPolicy`, …) are silently dropped by the
 * ByName struct parser's `UnknownPolicy.Skip` — they land with the
 * slice that introduces the matching writer knob.
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
 *    knob is consumed by `anyparse.format.comment.LineCommentNormalizer.normalizeLineComment`
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
 *
 * Extended in slice ω-check-type:
 *  - `typeCheckColonPolicy` feeds `opt.typeCheckColon` (the `:` inside
 *    a type-check expression `(expr : Type)`, `HxECheckType.type`'s
 *    `@:lead(':')`). `Around` (default) emits `("" : String)`; `None`
 *    keeps the tight `("":String)` form. Separate from
 *    `typeHintColonPolicy` so the type-annotation default can stay
 *    `None` (`x:Int`) while the type-check default stays `Around` —
 *    upstream's two `:` sites use opposite conventions.
 *
 * Extended in slice ω-if-policy:
 *  - `ifPolicy` feeds `opt.ifPolicy` (the gap between the `if` keyword
 *    and the opening `(` of the condition; consumed by both
 *    `HxStatement.IfStmt` and `HxExpr.IfExpr` via `@:fmt(ifPolicy)` on
 *    the ctor). `After` (default) emits `if (cond)` with a single space;
 *    `Before` / `None` (mapped from `"onlyBefore"` / `"none"`) collapse
 *    to `if(cond)`. The "before" relative to `if` keyword leans on
 *    surrounding context (e.g. `return if(...)` already has space
 *    before `if` from the preceding token) — this knob only controls
 *    the after-`if` gap.
 *
 * Extended in slice ω-control-flow-policies:
 *  - `forPolicy` / `whilePolicy` / `switchPolicy` feed
 *    `opt.forPolicy` / `opt.whilePolicy` / `opt.switchPolicy`. Same
 *    shape as `ifPolicy` — gates the trailing space after `for`,
 *    `while`, `switch`. Consumed by `HxStatement.ForStmt` /
 *    `HxExpr.ForExpr`, `HxStatement.WhileStmt` / `HxExpr.WhileExpr`,
 *    and all four switch ctors (parens / bare × stmt / expr) via
 *    `@:fmt(<knobName>)`. Default `After`; `"onlyBefore"` / `"none"`
 *    collapse the gap.
 *
 * Extended in slice ω-try-policy:
 *  - `tryPolicy` feeds `opt.tryPolicy`. Same shape as `ifPolicy` —
 *    gates the trailing space after the `try` keyword. Consumed by
 *    `HxStatement.TryCatchStmt` only (block-body form) via
 *    `@:fmt(tryPolicy)`. Default `After` emits `try {`;
 *    `"onlyBefore"` / `"none"` collapse to `try{`. The bare-body
 *    sibling `TryCatchStmtBare` does NOT carry the flag — its first
 *    field's `@:fmt(bareBodyBreaks)` triggers the
 *    `stripKwTrailingSpace` predicate which gates the slot to `null`
 *    regardless of policy.
 *
 * Extended in slice ω-string-interp-noformat:
 *  - `formatStringInterpolation` feeds `opt.formatStringInterpolation`.
 *    Bool — when `true` (default) `${expr}` segments are re-rendered
 *    by recursing into the parsed `HxExpr`; when `false` the writer
 *    emits the parser-captured byte slice between `${` and `}`
 *    verbatim, preserving the author's exact spacing inside the
 *    braces. Consumed via the trivia-pair synth ctor's positional
 *    `sourceText:String` arg on `HxStringSegmentT.Block`, populated
 *    by Lowering Case 3 when the grammar ctor carries
 *    `@:fmt(captureSource)`.
 */
@:peg typedef HxFormatWhitespaceSection = {

	@:optional var objectFieldColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeHintColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeCheckColonPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamOpenPolicy:HxFormatWhitespacePolicy;

	@:optional var typeParamClosePolicy:HxFormatWhitespacePolicy;

	@:optional var binopPolicy:HxFormatWhitespacePolicy;

	@:optional var functionTypeHaxe4Policy:HxFormatWhitespacePolicy;

	@:optional var arrowFunctionsPolicy:HxFormatWhitespacePolicy;

	@:optional var ifPolicy:HxFormatWhitespacePolicy;

	@:optional var forPolicy:HxFormatWhitespacePolicy;

	@:optional var whilePolicy:HxFormatWhitespacePolicy;

	@:optional var switchPolicy:HxFormatWhitespacePolicy;

	@:optional var tryPolicy:HxFormatWhitespacePolicy;

	@:optional var addLineCommentSpace:Bool;

	@:optional var formatStringInterpolation:Bool;

	@:optional var parenConfig:HxFormatParenConfigSection;

	@:optional var bracesConfig:HxFormatBracesConfigSection;
};
