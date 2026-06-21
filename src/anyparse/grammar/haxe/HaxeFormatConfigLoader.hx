package anyparse.grammar.haxe;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapCondition;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRule;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;
import anyparse.grammar.haxe.format.HxFormatBodyPolicy;
import anyparse.grammar.haxe.format.HxFormatBracesConfigSection;
import anyparse.grammar.haxe.format.HxFormatBracketConfigSection;
import anyparse.grammar.haxe.format.HxFormatClassEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatCommentEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatConfig;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatCurlyLineEndPolicy;
import anyparse.grammar.haxe.format.HxFormatEmptyCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatEmptyLinesSection;
import anyparse.grammar.haxe.format.HxFormatEnumEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatImportAndUsingConfig;
import anyparse.grammar.haxe.format.HxFormatIndentationSection;
import anyparse.grammar.haxe.format.HxFormatInterfaceEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatKeepEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatKeywordPlacement;
import anyparse.grammar.haxe.format.HxFormatLeftCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatLineEndCharacter;
import anyparse.grammar.haxe.format.HxFormatLineEndsSection;
import anyparse.grammar.haxe.format.HxFormatMetadataLineEndPolicy;
import anyparse.grammar.haxe.format.HxFormatParenConfigSection;
import anyparse.grammar.haxe.format.HxFormatParenPolicySection;
import anyparse.grammar.haxe.format.HxFormatRightCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatSameLinePolicy;
import anyparse.grammar.haxe.format.HxFormatSameLineSection;
import anyparse.grammar.haxe.format.HxFormatTrailingCommaPolicy;
import anyparse.grammar.haxe.format.HxFormatTrailingCommasSection;
import anyparse.grammar.haxe.format.HxFormatTypedefEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatWhitespacePolicy;
import anyparse.grammar.haxe.format.HxFormatWhitespaceSection;
import anyparse.grammar.haxe.format.HxFormatWrapCondition;
import anyparse.grammar.haxe.format.HxFormatWrapRule;
import anyparse.grammar.haxe.format.HxFormatWrapRules;
import anyparse.grammar.haxe.format.HxFormatWrappingSection;

/**
 * Loads a haxe-formatter `hxformat.json` config and maps the subset of
 * fields the `HxModule` writer understands into `HxModuleWriteOptions`.
 *
 * The mapping is strictly additive: anything the loader does not
 * recognise is silently ignored (forward-compatible), and every field
 * it does not find falls back to `HaxeFormat.instance.defaultWriteOptions`.
 * This makes round-tripping `HaxeFormatConfigLoader.loadHxFormatJson('{}')`
 * byte-identical to using the defaults directly.
 *
 * Recognised key paths (all optional):
 *
 * - `indentation.character`: string — `"tab"` → `indentChar = Tab, indentSize = 1`;
 *   any string composed entirely of spaces → `indentChar = Space, indentSize = length`.
 *   Every other value is ignored.
 * - `indentation.tabWidth`: int → `tabWidth`.
 * - `indentation.trailingWhitespace`: bool → `trailingWhitespace`
 *   (opt-in — default `false` keeps `Renderer.render`'s deferred-indent
 *   behaviour, `true` preserves the surrounding indent on blank rows).
 * - `indentation.indentCaseLabels` (ω-indent-case-labels): boolean —
 *   `true` (default) keeps `case` / `default` labels nested one indent
 *   level inside a `switch` body's `{ ... }`; `false` flushes the
 *   labels with the `switch` keyword and only the per-case body is
 *   indented. Routed to `opt.indentCaseLabels`.
 * - `indentation.indentObjectLiteral` (ω-indent-objectliteral): boolean —
 *   `true` (default) AND `lineEnds.objectLiteralCurly.leftCurly == both/before`
 *   (Allman) adds one extra indent step in front of an `ObjectLit` value's
 *   `{` on `=`/`:`/`(`/`[` RHS (`var x =\n\t{...}`); `false` (or
 *   leftCurly=`after`/`none`/cuddled) keeps the layout unchanged.
 *   Routed to `opt.indentObjectLiteral`; fires at sites tagged
 *   `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 *   'objectLiteralLeftCurly'))` in the grammar.
 * - `indentation.indentComplexValueExpressions` (ω-indent-complex-value-expr):
 *   boolean — `true` adds one extra indent step to an `IfExpr` value
 *   on the right-hand side of `=`/`:`/`(`/`[`/keyword (the `{ … } else
 *   { … }` block bodies of `var x = if (cond) … else …;` shift one tab
 *   right). `false` (default) keeps the layout unchanged. Routed to
 *   `opt.indentComplexValueExpressions`; fires at sites tagged
 *   `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
 *   in the grammar (currently `HxVarDecl.init`).
 * - `wrapping.maxLineLength`: int → `lineWidth`.
 * - `wrapping.arrayWrap` (ω-arraylit-wraprules + ω-peg-byname-array):
 *   `WrapRules` cascade → `arrayLiteralWrap`. `defaultWrap:String` sets
 *   the cascade's `defaultMode`; `rules:Array<HxFormatWrapRule>` is
 *   ingested verbatim into the runtime cascade — `type` strings map to
 *   `WrapMode`, `cond` strings map to `WrapConditionType` (including
 *   `lineLength >= n` since slice ω-linelen-static — interpreted as
 *   `totalItemFlatLength >= n`, the construct's flat width without
 *   column prefix), rules with an unrecognised `cond` are still
 *   dropped so the cascade falls through cleanly. Absent keys preserve
 *   the runtime
 *   baseline; `rules: []` resets the cascade to unconditional
 *   `defaultMode`.
 * - `wrapping.anonType` (ω-anontype-wraprules): same `WrapRules` ingest
 *   shape as `arrayWrap`, routed to `anonTypeWrap`. Drives
 *   `HxType.Anon.fields` via `wrapRules('anonTypeWrap')`.
 * - `wrapping.methodChain` (ω-methodchain-wraprules-capability +
 *   ω-methodchain-emit): `WrapRules` cascade → `methodChainWrap`.
 *   Read at writer time by the chain extractor wired through
 *   `@:fmt(methodChain('methodChainWrap'))` on `HxExpr.Call` and
 *   `HxExpr.FieldAccess`. Custom rules from `.hxtest` configs (e.g.
 *   `anyItemLength >= 25 → onePerLine`) now load through the same
 *   cascade-ingest path as `arrayWrap` / `anonType`.
 * - `wrapping.callParameter` (ω-wrapping-callParameter-ingest): same
 *   `WrapRules` ingest shape as `arrayWrap`, routed to
 *   `callParameterWrap`. Drives `HxExpr.Call.args` and
 *   `HxNewExpr.args` via `@:fmt(wrapRules('callParameterWrap'))` —
 *   field, default, and writer dispatch were already wired; this
 *   slice closes the loader-side gap.
 * - `wrapping.objectLiteral` (ω-wrapping-objectLiteral-ingest): same
 *   `WrapRules` ingest shape as `arrayWrap`, routed to
 *   `objectLiteralWrap`. Drives `HxObjectLit.fields` via
 *   `@:fmt(wrapRules('objectLiteralWrap'))` — field, default, and
 *   writer dispatch were already wired; this slice closes the loader-
 *   side gap.
 * - `wrapping.metadataCallParameter` (ω-metadataCallParameter-wrap-ingest):
 *   same `WrapRules` ingest shape as `arrayWrap`, routed to
 *   `metadataCallParameterWrap`. Drives `HxMetaCallArgs.args` via
 *   `@:fmt(wrapRules('metadataCallParameterWrap'))` — field, default,
 *   loader, and grammar opt-in all land in the same slice. Default
 *   `{rules: [totalItemLength>=140 → FillLine, lineLength>=160 →
 *   FillLine, exceedsMaxLineLength → FillLine], defaultMode: NoWrap}`
 *   keeps `@:overload(function(...))` parens tight even when the inner
 *   FnExpr params wrap internally — replaces the legacy `sepList`
 *   Group-with-softlines layout that propagated inner breaks outward as
 *   `@:overload(\n\tfunction(...)\n)`.
 * - `wrapping.typeParameter` (ω-typeparameter-wrap-ingest): same
 *   `WrapRules` ingest shape as `arrayWrap`, routed to
 *   `typeParameterWrap`. Drives declare-site `<T, U, V>` lists on
 *   `HxClassDecl.typeParams`, `HxTypedefDecl.typeParams`,
 *   `HxFnDecl.typeParams`, `HxFnExpr.typeParams`,
 *   `HxEnumDecl.typeParams`, `HxAbstractDecl.typeParams`,
 *   `HxInterfaceDecl.typeParams` plus use-site `HxTypeRef.params`
 *   (`Map<K, V>`, `Array<T>`) via
 *   `@:fmt(wrapRules('typeParameterWrap'))`. Default
 *   `{rules: [anyItemLength>=50 → FillLine, totalItemLength>=70 →
 *   FillLine], defaultMode: NoWrap}` — short lists stay flat, long
 *   lists pack Wadler-style.
 * - `sameLine.ifElse` / `sameLine.tryCatch` / `sameLine.doWhile`: enum
 *   string — `"same"` → `SameLinePolicy.Same`, `"next"` →
 *   `SameLinePolicy.Next`, `"keep"` → `SameLinePolicy.Keep` (reads the
 *   trivia-mode parser's captured slot at runtime; degrades to `Same`
 *   in plain mode). `"fitLine"` still collapses to `Same` — no
 *   `FitLine` branch exists on these keyword-join sites yet.
 * - `sameLine.elseIf` (ψ₈): enum string — `"same"` (default) maps to
 *   `KeywordPlacement.Same`, `"next"` maps to `KeywordPlacement.Next`.
 *   `"keep"` degrades to `Same` (no per-node source-shape tracking).
 *   The knob only affects the `IfStmt` ctor of `elseBody` — non-if
 *   else branches still route through `sameLine.elseBody`.
 * - `sameLine.fitLineIfWithElse` (ψ₁₂): boolean — `true` keeps the
 *   `FitLine` body policy active for `if`s with an `else` clause,
 *   `false` (default) degrades those bodies to `Next`. Matches haxe-
 *   formatter's `sameLine.fitLineIfWithElse: @:default(false)`.
 * - `sameLine.expressionIf` (ω-expr-body-keep + ω-expr-else-sameline):
 *   enum string. Two-channel fanout. Channel A (BodyPolicy, gated):
 *   `keep` and `same` propagate into the three body knobs
 *   `expressionIfBody` / `expressionElseBody` / `expressionForBody`.
 *   `same` force-flattens expression-position `if/else/for` bodies,
 *   which is unconditionally safe because `Same` collapses to
 *   `_dop(' ')` regardless of surrounding context (no arrow-context
 *   ambiguity). `next` / `fitLine` are still ignored on this channel:
 *   `BodyPolicy.Next` on the inner body force-breaks legitimate inline
 *   arrow bodies because the bodyPolicyWrap engine cannot derive
 *   surrounding-context fit (would regress `fitline_arrow_body_if.hxtest`).
 *   Default at the WriteOptions level is `Keep` so the honoured branch
 *   is a no-op when omitted; programmatic users can set the three
 *   knobs independently when they need finer control. Distinct from
 *   the statement-level `ifBody` / `elseBody` / `forBody` defaults
 *   (`Next`).
 *   Channel B (SameLinePolicy, ungated): the same JSON value also
 *   fans out into `sameLineExpressionElse:SameLinePolicy`, the per-
 *   `else` gap for `HxIfExpr.elseBranch`. `same` → `Same` (force
 *   inline space), `keep` and `next` → `Keep` (read the synth
 *   `BeforeKwNewline` slot, preserve source layout), `fitLine` →
 *   `Same` fallback. `next` maps to `Keep` rather than `Next` because
 *   fork's `expressionIf=next` semantic is block-shape-aware (`} else
 *   {` cuddles even with `next`); the source-preserving Keep mapping
 *   reproduces this correctly across the corpus without a dedicated
 *   shape-aware dispatch. Default `Same` keeps the pre-slice
 *   hardcoded space behaviour when no JSON setting is present.
 * - `sameLine.expressionTry` (ω-expression-try): enum string — same
 *   `"same"` / `"next"` / `"keep"` collapse as `sameLine.tryCatch`,
 *   routed to `opt.expressionTry`. Default `Same`. Drives the
 *   separator between the body and `catch` clauses of an
 *   expression-position `try` (`HxTryCatchExpr.catches`). Independent
 *   of `sameLine.tryCatch`, which keeps driving the statement-form.
 * - `trailingCommas.arrayLiteralDefault` / `trailingCommas.callArgumentDefault`
 *   / `trailingCommas.functionParameterDefault` /
 *   `trailingCommas.objectLiteralDefault`: enum string — `"yes"`
 *   maps to `true`, every other value (`"no"`, `"keep"`, `"ignore"`) to
 *   `false`. `keep` requires an AST that remembers whether the source
 *   had a trailing comma — a debt to address once the parser records
 *   that detail; for now the writer only knows "always" or "never".
 *   `objectLiteralDefault` is anyparse-specific (haxe-formatter
 *   upstream omits this knob) — slice ω-objectlit-trailing-comma.
 * - `lineEnds.leftCurly` (ψ₆): enum string — `"before"` / `"both"`
 *   map to `BracePlacement.Next`; `"after"` / `"none"` map to
 *   `BracePlacement.Same`. `"none"` degrades because the inline
 *   `{ ... }` shape is not representable by the current two-value
 *   surface without per-node source-shape tracking. Sets `opt.leftCurly`
 *   AND cascades into `opt.objectLiteralLeftCurly` (ω-objectlit-leftCurly-cascade)
 *   so a single `lineEnds.leftCurly` knob drives every per-construct
 *   curly placement at once. Mirrors haxe-formatter's
 *   `MarkLineEnds.getCurlyPolicy(ObjectDecl)` precedence.
 * - `lineEnds.objectLiteralCurly.leftCurly` (ω-objectlit-leftCurly):
 *   per-construct sub-section that overrides only the cascade for
 *   `opt.objectLiteralLeftCurly` — applied AFTER the cascade so it
 *   wins. Same enum-string vocabulary. With knob `Next`, short
 *   object literals chosen flat by the wrap engine stay cuddled —
 *   `triviaSepStarExpr` wires the leftCurly Doc through
 *   `WrapList.emit`'s `(leadFlat, leadBreak)` so the wrap cascade's
 *   flat/break decision picks cuddled vs Allman per literal.
 * - `whitespace.objectFieldColonPolicy` (ψ₇): enum string —
 *   `"before"` / `"onlyBefore"` → `WhitespacePolicy.Before`,
 *   `"after"`  / `"onlyAfter"`  → `WhitespacePolicy.After`,
 *   `"around"` → `WhitespacePolicy.Both`,
 *   `"none"` / `"noneBefore"` / `"noneAfter"` → `WhitespacePolicy.None`.
 *   The `only*` / `none*` values in haxe-formatter encode extra
 *   semantics about the opposite side; the four-way collapse here
 *   matches the information content the generated writer actually
 *   exposes today.
 * - `whitespace.typeHintColonPolicy` (ω-E-whitespace): same enum /
 *   same collapse as `objectFieldColonPolicy`, routed to
 *   `opt.typeHintColon` (the type-annotation `:` on `HxVarDecl.type`,
 *   `HxParam.type`, `HxFnDecl.returnType`). Default `None` leaves
 *   `x:Int` / `f():Void` tight; `"around"` produces `x : Int` /
 *   `f() : Void`.
 * - `whitespace.parenConfig.funcParamParens.openingPolicy`
 *   (ω-E-whitespace): same enum, routed to `opt.funcParamParens`.
 *   `Before` / `Both` emit a single space before the `(` on
 *   `HxFnDecl.params` (`function main ()`); `After` / `None` leave the
 *   paren tight (the paren-after axis is not yet wired). The sibling
 *   `closingPolicy` key is parsed and silently ignored.
 * - `whitespace.parenConfig.callParens.openingPolicy`
 *   (ω-call-parens): same enum, routed to `opt.callParens`.
 *   `Before` / `Both` emit a single space before the `(` on
 *   `HxExpr.Call.args` (`trace (x)`); `After` / `None` leave the paren
 *   tight. The sibling `closingPolicy` key is parsed and silently
 *   ignored.
 * - `whitespace.parenConfig.anonFuncParamParens.openingPolicy`
 *   (ω-anon-fn-paren-policy): same enum, routed to
 *   `opt.anonFuncParens`. `Before` / `Both` emit a single space
 *   between the `function` keyword and the opening `(` of an
 *   anonymous-function expression (`function (args)…`); `After` /
 *   `None` collapse the gap to `function(args)…`. The sibling
 *   `closingPolicy` key is parsed and silently ignored.
 * - `whitespace.parenConfig.anonFuncParamParens.removeInnerWhenEmpty`
 *   (ω-anon-fn-empty-paren-inner-space): boolean inverted at the
 *   loader and routed to `opt.anonFuncParamParensKeepInnerWhenEmpty`
 *   (`false` in JSON → `true` in opt). Default `true` collapses an
 *   empty anon-fn parameter list to the tight `function()`; setting
 *   `false` keeps a single inside space (`function ( ) body`,
 *   haxe-formatter `issue_251_space_after_anon_function_empty`).
 * - `whitespace.typeParamOpenPolicy` (ω-typeparam-spacing): same enum
 *   / same collapse, routed to `opt.typeParamOpen`. `Before` / `Both`
 *   emit a space outside before `<`; `After` / `Both` emit a space
 *   inside after `<`. Default `None` leaves `Array<Int>` tight.
 * - `whitespace.typeParamClosePolicy` (ω-typeparam-spacing): same enum,
 *   routed to `opt.typeParamClose`. `Before` / `Both` emit a space
 *   inside before `>`. `After` is exposed for parity but has no effect
 *   yet — the writer's `sepList` shape concatenates the close delim
 *   tight against whatever follows.
 * - `whitespace.bracesConfig.anonTypeBraces.openingPolicy`
 *   (ω-anontype-braces): same enum / same collapse, routed to
 *   `opt.anonTypeBracesOpen`. `After` / `Both` (haxe-formatter
 *   `"around"`) emit a space inside after `{` of `HxType.Anon`;
 *   `Before` / `None` keep the brace tight (no outside-before-open
 *   path exists for the `lowerEnumStar` Alt-branch site).
 * - `whitespace.bracesConfig.anonTypeBraces.closingPolicy`
 *   (ω-anontype-braces): same enum, routed to
 *   `opt.anonTypeBracesClose`. `Before` / `Both` (haxe-formatter
 *   `"around"`) emit a space inside before `}`; `After` / `None`
 *   leave the close tight. Combined opening + closing = `"around"`
 *   reproduces haxe-formatter's `space_inside_anon_type_hint`
 *   fixture (`{ x:Int }`). The sibling
 *   `bracesConfig.anonTypeBraces.removeInnerWhenEmpty` key is
 *   parsed and silently ignored.
 * - `whitespace.binopPolicy` (ω-typeparam-default-equals): same enum
 *   / same collapse, routed to `opt.typeParamDefaultEquals` (the `=`
 *   joining a declare-site type-parameter to its default type on
 *   `HxTypeParamDecl.defaultValue`). Default `Around` (= `Both`)
 *   emits `<T = Int>`; `"none"` emits the tight `<T=Int>`.
 *   Upstream's `binopPolicy` controls every binary operator; here it
 *   only routes to the single binop site the writer currently exposes
 *   as a per-field `WhitespacePolicy` knob. Future binop sites with
 *   their own `@:fmt(...)` flag should extend this mapping, not add a
 *   separate JSON key.
 * - `whitespace.functionTypeHaxe4Policy` (ω-arrow-fn-type): same enum
 *   / same collapse, routed to `opt.functionTypeHaxe4` (the `->`
 *   separator inside a new-form arrow function type,
 *   `HxArrowFnType.ret`'s `@:lead('->')`). Default `Around` (= `Both`)
 *   emits `(Int) -> Bool`; `"none"` emits the tight `(Int)->Bool`. The
 *   sibling `functionTypeHaxe3Policy` (old-form curried `Int->Bool`)
 *   routes to `opt.functionTypeHaxe3` via the same enum / same
 *   collapse — default `None` emits the tight `Int->Bool`, `"around"`
 *   flips to spaced `Int -> Bool`. Wired in Writer Slice 6.
 * - `whitespace.arrowFunctionsPolicy` (ω-arrow-fn-expr): same enum
 *   / same collapse, routed to `opt.arrowFunctions` (the `->`
 *   separator inside a parenthesised arrow lambda expression,
 *   `HxThinParenLambda.body`'s `@:lead('->')`). Default `Around`
 *   (= `Both`) emits `(arg) -> body`; `"none"` emits the tight
 *   `(arg)->body`. Independent of `functionTypeHaxe4Policy` (the
 *   type-position sibling).
 * - `whitespace.ifPolicy` (ω-if-policy): same enum / same collapse,
 *   routed to `opt.ifPolicy` (the gap between `if` keyword and the
 *   opening `(` of its condition; consumed by `HxStatement.IfStmt` and
 *   `HxExpr.IfExpr`). Default `After` emits `if (cond)`; `"onlyBefore"`
 *   / `"none"` collapse to `if(cond)`. The before-`if` slot is owned
 *   by the preceding token's separator and is unaffected by this knob.
 * - `whitespace.{forPolicy,whilePolicy,switchPolicy}`
 *   (ω-control-flow-policies): same enum / same collapse, routed to
 *   `opt.forPolicy` / `opt.whilePolicy` / `opt.switchPolicy`. Same
 *   shape as `ifPolicy` — gates the trailing space after `for`,
 *   `while`, `switch`. Default `After`; `"onlyBefore"` / `"none"`
 *   collapse to `for(`, `while(`, `switch(`. The bare switch form
 *   (`switch cond { ... }`) honours the same knob — `Before` / `None`
 *   produce a parse-incompatible `switchcond` so the bare form should
 *   keep the default in practice.
 * - `whitespace.tryPolicy` (ω-try-policy): same enum / same collapse,
 *   routed to `opt.tryPolicy`. Same shape as `ifPolicy` — gates the
 *   trailing space after `try`. Default `After` emits `try {`;
 *   `"onlyBefore"` / `"none"` collapse to `try{`. Consumed by the
 *   block-form `HxStatement.TryCatchStmt` only — the bare-form
 *   sibling's `bareBodyBreaks` predicate gates the slot to `null`
 *   regardless of policy.
 * - `whitespace.addLineCommentSpace` (ω-line-comment-space): boolean —
 *   `true` (default) rewrites captured `//foo` line comments as
 *   `// foo`; decoration runs (`//*****`, `//------`, `////`) survive
 *   tight via the `^[/\*\-\s]+` guard. `false` skips the space-insert
 *   pass (still rtrims the body). Routed to `opt.addLineCommentSpace`.
 * - `whitespace.compressSuccessiveParenthesis`
 *   (ω-compress-successive-paren): boolean — `true` (default) glues a
 *   call-arg open `(` tight to a following object-literal `{` argument
 *   (`TPath({…})`); `false` keeps a leading space (`TPath( {…})`).
 *   Routed to `opt.compressSuccessiveParenthesis`. Consumed by the
 *   `HxExpr.Call` paren-open Star in `WriterLowering.lowerPostfixStar`.
 * - `whitespace.formatStringInterpolation` (ω-string-interp-noformat):
 *   boolean — `true` (default) re-renders each `${expr}` segment of a
 *   single-quoted Haxe string by recursing into the parsed `HxExpr`
 *   (canonical Pratt spacing, e.g. `i+1` becomes `i + 1`). `false`
 *   emits the parser-captured byte slice between `${` and `}`
 *   verbatim, preserving the author's exact spacing inside the
 *   braces. Routed to `opt.formatStringInterpolation`. Carrier is the
 *   trivia-pair synth ctor `HxStringSegmentT.Block`'s positional
 *   `sourceText:String` arg, populated by Lowering Case 3 when the
 *   grammar ctor carries `@:fmt(captureSource('formatStringInterpolation'))`;
 *   plain-mode pipelines have no carrier and the knob is silently
 *   inert there.
 * - `whitespace.bracesConfig.objectLiteralBraces.openingPolicy`
 *   (ω-objectlit-braces): same enum / same collapse, routed to
 *   `opt.objectLiteralBracesOpen`. `After` / `Both` emit a space
 *   inside after `{` of `HxObjectLit`; `Before` / `None` keep the
 *   brace tight.
 * - `whitespace.bracesConfig.objectLiteralBraces.closingPolicy`
 *   (ω-objectlit-braces): same enum, routed to
 *   `opt.objectLiteralBracesClose`. `Before` / `Both` emit a space
 *   inside before `}`; `After` / `None` leave the close tight.
 *   Combined opening + closing = `"around"` produces `{ a: 1 }`.
 *   The sibling `removeInnerWhenEmpty` key is silently ignored.
 * - `emptyLines.afterFieldsWithDocComments` (ω-C-empty-lines-doc):
 *   enum string — `"ignore"` → `CommentEmptyLinesPolicy.Ignore`,
 *   `"none"` → `CommentEmptyLinesPolicy.None`, `"one"` →
 *   `CommentEmptyLinesPolicy.One`. Routed to
 *   `opt.afterFieldsWithDocComments`. Default `One` adds one blank
 *   line after a class member whose leading trivia carries a doc
 *   comment even when the source had none; `Ignore` respects the
 *   captured source blank-line count; `None` strips any blank line
 *   after such a field.
 * - `emptyLines.classEmptyLines.existingBetweenFields`
 *   (ω-C-empty-lines-between-fields): enum string — `"keep"` →
 *   `KeepEmptyLinesPolicy.Keep`, `"remove"` →
 *   `KeepEmptyLinesPolicy.Remove`. Routed to
 *   `opt.existingBetweenFields`. Default `Keep` preserves source
 *   blank lines between class members; `Remove` strips every blank
 *   line between siblings regardless of source.
 * - `emptyLines.externClassEmptyLines.existingBetweenFields`
 *   (ω-extern-existing-between-split-leading): same enum mapping as
 *   the regular variant, routed to `opt.externExistingBetweenFields`.
 *   Engine consults this knob in place of `existingBetweenFields`
 *   whenever `_classExtern` is true; `Remove` then strips the
 *   inter-member source blank for any next member whose leading
 *   carries the split shape (a trailing doc comment preceded by
 *   `//` line comments). Default `Keep`.
 * - `emptyLines.classEmptyLines.{betweenVars, betweenFunctions,
 *   afterVars}` (ω-interblank): non-negative Int counts routed to
 *   `opt.betweenVars`, `opt.betweenFunctions`, `opt.afterVars`.
 *   A positive count currently collapses to a single blank-line
 *   contribution on the grammar sites tagged with
 *   `@:fmt(interMemberBlankLines('classifierField', 'VarCtorName', 'FnCtorName'))` — multi-blank emission is a
 *   future extension. `HxClassDecl.members` and `HxAbstractDecl.members`
 *   read these knobs.
 * - `emptyLines.interfaceEmptyLines.{betweenVars, betweenFunctions,
 *   afterVars}` (ω-iface-interblank): non-negative Int counts routed to
 *   `opt.interfaceBetweenVars`, `opt.interfaceBetweenFunctions`,
 *   `opt.interfaceAfterVars`. Same semantics as `classEmptyLines`
 *   but with separate runtime knobs read by `HxInterfaceDecl.members`
 *   via the 6-arg form of `interMemberBlankLines`. Defaults are all
 *   `0`, matching haxe-formatter's `InterfaceFieldsEmptyLinesConfig`.
 * - `emptyLines.beforeDocCommentEmptyLines` (ω-C-empty-lines-before-doc):
 *   enum string — same three-way collapse as
 *   `afterFieldsWithDocComments` (`"ignore"` / `"none"` / `"one"`),
 *   routed to `opt.beforeDocCommentEmptyLines`. Default `One` adds one
 *   blank line before a class member whose leading trivia starts with
 *   a doc comment even when the source had none; `Ignore` respects the
 *   captured source blank-line count; `None` strips any blank line
 *   before such a field.
 * - `emptyLines.afterPackage` (ω-after-package): non-negative Int routed
 *   to `opt.afterPackage`. Default `1` matches haxe-formatter's
 *   `emptyLines.afterPackage: @:default(1)`. Drives the exact number
 *   of blank lines between a top-level `package …;` decl and the next
 *   decl in the same module — override semantics, not floor: the
 *   source-captured blank-line count is replaced with this value, so
 *   `0` strips any existing blank line and `2` always emits two.
 * - `emptyLines.beforePackage` (ω-before-package): non-negative Int
 *   routed to `opt.beforePackage`. Default `0` matches haxe-formatter's
 *   `emptyLines.beforePackage: @:default(0)`. Drives the exact number
 *   of blank lines emitted at file head BEFORE a leading `package …;`
 *   decl — override semantics, head-of-Star only: applied once at the
 *   start of the module, so `0` keeps the file leading edge tight and
 *   `1` inserts one blank line before `package …;` regardless of
 *   source.
 * - `emptyLines.importAndUsing.beforeUsing` (ω-imports-using-blank):
 *   non-negative Int routed to `opt.beforeUsing`. Default `1` matches
 *   haxe-formatter's `emptyLines.importAndUsing.beforeUsing:
 *   @:default(1)`. Drives the exact number of blank lines at the
 *   `import → using` transition (current decl is `using`, previous decl
 *   is not) — override semantics, not floor: source-captured count is
 *   replaced with this value, so `0` strips the slot and `2` doubles
 *   it. Consecutive `using` decls fall through to source-driven
 *   binary `blankBefore`.
 * - `emptyLines.importAndUsing.betweenImports` +
 *   `emptyLines.importAndUsing.betweenImportsLevel`
 *   (ω-imports-using-between): non-negative Int routed to
 *   `opt.betweenImports` (default `0`) and JSON-string token routed
 *   through `betweenImportsLevelFromString` to `opt.betweenImportsLevel`
 *   (default `All`). Together drive blank-line insertion between two
 *   consecutive same-kind imports / usings whose dotted-ident paths
 *   fall into different groups at the configured level. Fork accepts
 *   `"all"` / `"firstLevelPackage"` / `"secondLevelPackage"` /
 *   `"thirdLevelPackage"` / `"fourthLevelPackage"` /
 *   `"fifthLevelPackage"` / `"fullPackage"`; unknown tokens leave the
 *   default in place.
 * - `emptyLines.enumEmptyLines.{existingBetweenFields, betweenFields,
 *   beginType, endType}` (ω-enum-empty-lines): drives blank-line
 *   behaviour inside `enum` bodies. `existingBetweenFields` /
 *   `beginType` / `endType` feed the GLOBAL `opt.existingBetweenFields`
 *   / `opt.beginType` / `opt.endType` knobs (last-write-wins relative
 *   to `classEmptyLines` / `interfaceEmptyLines` for fixtures that
 *   define multiple type sections — single-type fixtures land cleanly).
 *   `betweenFields` feeds the dedicated `opt.betweenEnumCtors` knob
 *   (default `0`), exact blank-line count between adjacent enum
 *   constructors. `HxEnumDecl.ctors` opts in via `@:fmt(beginEndType,
 *   existingBetweenFields, uniformBetween('betweenEnumCtors'))`.
 * - `emptyLines.importAndUsing.beforeType`
 *   (ω-imports-using-before-type): non-negative Int routed to
 *   `opt.beforeType`. Default `1` matches haxe-formatter's
 *   `emptyLines.importAndUsing.beforeType: @:default(1)`. Drives the
 *   exact number of blank lines at the import/using → type-decl
 *   transition (current decl is `ClassDecl` / `InterfaceDecl` /
 *   `AbstractDecl` / `EnumDecl` / `TypedefDecl` / `FnDecl`, previous
 *   decl is `import` / `using`) — override semantics, not floor:
 *   source-captured count is replaced with this value, so `0` strips
 *   the slot and `2` doubles it.
 *
 * Deliberately NOT supported in this slice (no corresponding
 * `HxModuleWriteOptions` field yet): `wrapping.*` beyond
 * `maxLineLength`, other `lineEnds.*` keys (`rightCurly`, `blockCurly`,
 * `anonTypeCurly`, `typedefCurly`, …), other
 * `emptyLines.*` keys
 * (`finalNewline`, `maxAnywhereInFile`,
 * `betweenTypes`, per-type-kind sections
 * `macroClassEmptyLines` /
 * `abstractEmptyLines` /
 * `typedefEmptyLines`, other `classEmptyLines.*` sub-keys beyond
 * `existingBetweenFields`, other `externClassEmptyLines.*` sub-keys
 * beyond `existingBetweenFields`, …), other `whitespace.*` keys
 * (`ternaryPolicy`, …), other
 * `whitespace.parenConfig.*` kinds (`ifParens`, `forParens`, …),
 * `indentation.conditionalPolicy`, `baseTypeHints`, `disableFormatting`,
 * `excludes`. They will land with the slices that introduce the
 * matching knobs.
 *
 * Two-stage pipeline: `HxFormatConfigParser` (macro-generated ByName
 * struct parser) reads the JSON into a typed `HxFormatConfig`, then
 * this class maps that struct onto `HxModuleWriteOptions` with no
 * `JValue` walks, no field-name strings, no runtime-typed switches.
 * Adding a new recognised key means extending the schema in
 * `HxFormatConfig.hx` and adding one line here.
 *
 * All-static utility: the loader holds no state.
 */
@:nullSafety(Strict)
final class HaxeFormatConfigLoader {

	/**
	 * Parses a `hxformat.json` document and returns the equivalent
	 * `HxModuleWriteOptions`, starting from the Haxe format defaults
	 * and overwriting only the fields the config explicitly sets.
	 */
	public static function loadHxFormatJson(json: String): HxModuleWriteOptions {
		final cfg: HxFormatConfig = HxFormatConfigParser.parse(json);
		final base: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final result: HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			maxConsecutiveBlanks: base.maxConsecutiveBlanks,
			commentStyle: base.commentStyle,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			sameLineExpressionElse: base.sameLineExpressionElse,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			trailingCommaObjectLits: base.trailingCommaObjectLits,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			returnBody: base.returnBody,
			returnBodySingleLine: base.returnBodySingleLine,
			throwBody: base.throwBody,
			catchBody: base.catchBody,
			tryBody: base.tryBody,
			caseBody: base.caseBody,
			expressionCase: base.expressionCase,
			functionBody: base.functionBody,
			anonFunctionBody: base.anonFunctionBody,
			untypedBody: base.untypedBody,
			expressionIfBody: base.expressionIfBody,
			expressionElseBody: base.expressionElseBody,
			expressionForBody: base.expressionForBody,
			expressionIfWithBlocks: base.expressionIfWithBlocks,
			leftCurly: base.leftCurly,
			emptyCurly: base.emptyCurly,
			objectLiteralLeftCurly: base.objectLiteralLeftCurly,
			anonTypeLeftCurly: base.anonTypeLeftCurly,
			anonFunctionLeftCurly: base.anonFunctionLeftCurly,
			blockLeftCurly: base.blockLeftCurly,
			anonFunctionEmptyCurly: base.anonFunctionEmptyCurly,
			blockEmptyCurly: base.blockEmptyCurly,
			blockRightCurly: base.blockRightCurly,
			anonFunctionRightCurly: base.anonFunctionRightCurly,
			anonTypeRightCurly: base.anonTypeRightCurly,
			objectLiteralRightCurly: base.objectLiteralRightCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			typeCheckColon: base.typeCheckColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			anonFuncParens: base.anonFuncParens,
			anonFuncParamParensKeepInnerWhenEmpty: base.anonFuncParamParensKeepInnerWhenEmpty,
			ifPolicy: base.ifPolicy,
			forPolicy: base.forPolicy,
			whilePolicy: base.whilePolicy,
			switchPolicy: base.switchPolicy,
			tryPolicy: base.tryPolicy,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			ifElseSemicolonNextLine: base.ifElseSemicolonNextLine,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			externExistingBetweenFields: base.externExistingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			afterStaticVars: base.afterStaticVars,
			betweenStaticFunctions: base.betweenStaticFunctions,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			betweenEnumCtors: base.betweenEnumCtors,
			beginType: base.beginType,
			endType: base.endType,
			typedefBeginType: base.typedefBeginType,
			typedefBetweenFields: base.typedefBetweenFields,
			typedefExistingBetweenFields: base.typedefExistingBetweenFields,
			typedefEndType: base.typedefEndType,
			afterLeftCurly: base.afterLeftCurly,
			beforeRightCurly: base.beforeRightCurly,
			typedefAssign: base.typedefAssign,
			typedefIntersection: base.typedefIntersection,
			typeParamDefaultEquals: base.typeParamDefaultEquals,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: base.objectLiteralBracesOpen,
			objectLiteralBracesClose: base.objectLiteralBracesClose,
			accessBracketsOpen: base.accessBracketsOpen,
			accessBracketsClose: base.accessBracketsClose,
			arrayLiteralBracketsOpen: base.arrayLiteralBracketsOpen,
			arrayLiteralBracketsClose: base.arrayLiteralBracketsClose,
			mapLiteralBracketsOpen: base.mapLiteralBracketsOpen,
			mapLiteralBracketsClose: base.mapLiteralBracketsClose,
			comprehensionBracketsOpen: base.comprehensionBracketsOpen,
			comprehensionBracketsClose: base.comprehensionBracketsClose,
			callParensInsideOpen: base.callParensInsideOpen,
			callParensInsideClose: base.callParensInsideClose,
			ifCondParensInsideOpen: base.ifCondParensInsideOpen,
			ifCondParensInsideClose: base.ifCondParensInsideClose,
			whileCondParensInsideOpen: base.whileCondParensInsideOpen,
			whileCondParensInsideClose: base.whileCondParensInsideClose,
			switchCondParensInsideOpen: base.switchCondParensInsideOpen,
			switchCondParensInsideClose: base.switchCondParensInsideClose,
			catchParensGap: base.catchParensGap,
			catchParensInsideOpen: base.catchParensInsideOpen,
			catchParensInsideClose: base.catchParensInsideClose,
			sharpCondParensGap: base.sharpCondParensGap,
			sharpCondParensInsideOpen: base.sharpCondParensInsideOpen,
			sharpCondParensInsideClose: base.sharpCondParensInsideClose,
			objectLiteralWrap: base.objectLiteralWrap,
			callParameterWrap: base.callParameterWrap,
			arrayLiteralWrap: base.arrayLiteralWrap,
			multiVarWrap: base.multiVarWrap,
			casePatternWrap: base.casePatternWrap,
			anonTypeWrap: base.anonTypeWrap,
			methodChainWrap: base.methodChainWrap,
			opBoolChainWrap: base.opBoolChainWrap,
			opAddSubChainWrap: base.opAddSubChainWrap,
			conditionWrap: base.conditionWrap,
			ternaryWrap: base.ternaryWrap,
			functionSignatureWrap: base.functionSignatureWrap,
			anonFunctionSignatureWrap: base.anonFunctionSignatureWrap,
			metadataCallParameterWrap: base.metadataCallParameterWrap,
			typeParameterWrap: base.typeParameterWrap,
			expressionWrappingWrap: base.expressionWrappingWrap,
			implementsExtendsWrap: base.implementsExtendsWrap,
			arrayMatrixWrap: base.arrayMatrixWrap,
			conditionalPolicy: base.conditionalPolicy,
			alignInlineSwitchCaseBody: base.alignInlineSwitchCaseBody,
			addLineCommentSpace: base.addLineCommentSpace,
			compressSuccessiveParenthesis: base.compressSuccessiveParenthesis,
			expressionTry: base.expressionTry,
			indentCaseLabels: base.indentCaseLabels,
			indentObjectLiteral: base.indentObjectLiteral,
			indentComplexValueExpressions: base.indentComplexValueExpressions,
			indentVarTypeHintAnon: base.indentVarTypeHintAnon,
			functionTypeHaxe4: base.functionTypeHaxe4,
			functionTypeHaxe3: base.functionTypeHaxe3,
			arrowFunctions: base.arrowFunctions,
			afterPackage: base.afterPackage,
			beforePackage: base.beforePackage,
			beforeUsing: base.beforeUsing,
			betweenImports: base.betweenImports,
			betweenImportsLevel: base.betweenImportsLevel,
			keepSourceBlankAcrossConditional: base.keepSourceBlankAcrossConditional,
			beforeType: base.beforeType,
			afterMultilineDecl: base.afterMultilineDecl,
			beforeMultilineDecl: base.beforeMultilineDecl,
			afterConditionalBlock: base.afterConditionalBlock,
			afterFileHeaderComment: base.afterFileHeaderComment,
			betweenMultilineComments: base.betweenMultilineComments,
			betweenSingleLineTypes: base.betweenSingleLineTypes,
			formatStringInterpolation: base.formatStringInterpolation,
			metadataFunctionLineEnd: base.metadataFunctionLineEnd,
			_inExprPosition: base._inExprPosition,
			_inValueIfBranch: base._inValueIfBranch,
			_classExtern: base._classExtern,
			_inAnonFnBody: base._inAnonFnBody,
			_inTypedefBody: base._inTypedefBody,
			_fnSigBodyEmpty: base._fnSigBodyEmpty,
			_chainModeOverride: base._chainModeOverride,
			_callArgChainNest: base._callArgChainNest,
			_suppressMore: base._suppressMore,
			_parenInCondition: base._parenInCondition,
			_varKwNewline: base._varKwNewline,
			_inFieldLevelVar: base._inFieldLevelVar,
			_keepFlatInner: base._keepFlatInner,
			_keepChainInParen: base._keepChainInParen,
			_intersectionOperandBreak: base._intersectionOperandBreak,
			blockCommentAdapter: base.blockCommentAdapter,
			lineCommentAdapter: base.lineCommentAdapter,
			endsWithCloseBrace: base.endsWithCloseBrace,
			caseBodyRefusesFlat: base.caseBodyRefusesFlat,
			operandIsBlockExpr: base.operandIsBlockExpr,
			arrayBracketKind: base.arrayBracketKind,
			betweenImportsPathDiffers: base.betweenImportsPathDiffers,
			betweenImportsTailLeafClassify: base.betweenImportsTailLeafClassify,
			betweenImportsHeadLeafClassify: base.betweenImportsHeadLeafClassify,
			tailLeafKeepsBlankAfterConditional: base.tailLeafKeepsBlankAfterConditional,
			elementIsConditional: base.elementIsConditional,
		};
		if (cfg.indentation != null) applyIndentation(cfg.indentation, result);
		if (cfg.wrapping != null) applyWrapping(cfg.wrapping, result);
		// ω-D6-casebody-fork-default: fork's `SameLineConfig` declares
		// `caseBody: Next`. Anyparse's `defaultWriteOptions` ships `Keep`
		// (dogfood track preserves source `case X(v): body;` shape when no
		// config is supplied), so any JSON load path must re-baseline to
		// the fork canonical before `applySameLine` merges JSON overrides
		// on top. Reset BEFORE the section-presence guard so a fixture
		// that omits the entire `sameLine` block still gets the fork
		// default (corpus parity Δ 0/0/0 invariant). Sister to the
		// `afterLeftCurly`/`beforeRightCurly` re-baseline above
		// `applyEmptyLines`.
		result.caseBody = BodyPolicy.Next;
		// ω-D7-ctrlflow-body-fork-default: fork's `SameLineConfig` declares
		// `ifBody`/`elseBody`/`forBody`/`whileBody`/`doWhileBody: Next`.
		// Anyparse's `defaultWriteOptions` ships `Keep` for the same five
		// knobs (dogfood track preserves source `if (cond) stmt;` /
		// `else stmt;` / `for (x in xs) stmt;` / `while (cond) stmt;` /
		// `do stmt while (cond);` shape when no config is supplied), so any
		// JSON load path must re-baseline to the fork canonical before
		// `applySameLine` merges JSON overrides on top. Same outside-section-
		// guard placement as `caseBody` above so a fixture that omits the
		// entire `sameLine` block still gets the fork default (corpus parity
		// Δ 0/0/0 invariant). `elseBody` flip (D8) is safe under the
		// ω-D8-keep-block-trivia engine fix in WriterLowering's
		// `bodyPolicyWrap`: Keep + block ctor + captured kw-trivia now
		// routes through `blockLayoutExpr` (Allman) instead of
		// `nextLayoutExpr` (which over-indented `{` by +cols).
		result.ifBody = BodyPolicy.Next;
		result.elseBody = BodyPolicy.Next;
		result.forBody = BodyPolicy.Next;
		result.whileBody = BodyPolicy.Next;
		result.doBody = BodyPolicy.Next;
		if (cfg.sameLine != null) applySameLine(cfg.sameLine, result);
		if (cfg.trailingCommas != null) applyTrailingCommas(cfg.trailingCommas, result);
		if (cfg.lineEnds != null) applyLineEnds(cfg.lineEnds, result);
		if (cfg.whitespace != null) applyWhitespace(cfg.whitespace, result);
		// ω-D5-curly-blanks-fork-default: fork's `EmptyLinesConfig` declares
		// `afterLeftCurly` / `beforeRightCurly` `@:default(Remove)`. Anyparse's
		// `defaultWriteOptions` ships `Keep` (dogfood track preserves source
		// blanks the user wrote when no config is supplied), so any JSON load
		// path must re-baseline to the fork canonical before `applyEmptyLines`
		// merges JSON overrides on top. Reset BEFORE the section-presence
		// guard so a fixture that omits the entire `emptyLines` block still
		// gets the fork default (corpus parity Δ 0/0/0 invariant).
		result.afterLeftCurly = KeepEmptyLinesPolicy.Remove;
		result.beforeRightCurly = KeepEmptyLinesPolicy.Remove;
		if (cfg.emptyLines != null) applyEmptyLines(cfg.emptyLines, result);
		return result;
	}

	private function new() {}

	private static function applyIndentation(section: HxFormatIndentationSection, opt: HxModuleWriteOptions): Void {
		final character: Null<String> = section.character;
		if (character != null) {
			if (character == 'tab') {
				opt.indentChar = Tab;
				opt.indentSize = 1;
			} else if (isAllSpaces(character) && character.length > 0) {
				opt.indentChar = Space;
				opt.indentSize = character.length;
			}
		}
		if (section.tabWidth != null) opt.tabWidth = section.tabWidth;
		if (section.trailingWhitespace != null) opt.trailingWhitespace = section.trailingWhitespace;
		if (section.indentCaseLabels != null) opt.indentCaseLabels = section.indentCaseLabels;
		if (section.indentObjectLiteral != null) opt.indentObjectLiteral = section.indentObjectLiteral;
		if (section.indentComplexValueExpressions != null) opt.indentComplexValueExpressions = section.indentComplexValueExpressions;
		if (section.indentVarTypeHintAnon != null) opt.indentVarTypeHintAnon = section.indentVarTypeHintAnon;
		if (section.alignInlineSwitchCaseBody != null) opt.alignInlineSwitchCaseBody = section.alignInlineSwitchCaseBody;
		final policyName: Null<String> = section.conditionalPolicy;
		if (policyName != null) {
			final resolved: Null<ConditionalIndentationPolicy> = policyName;
			if (resolved != null) opt.conditionalPolicy = resolved;
		}
	}

	private static function applyWrapping(section: HxFormatWrappingSection, opt: HxModuleWriteOptions): Void {
		applyWrappingScalars(section, opt);
		applyWrappingRulesA(section, opt);
		applyWrappingRulesB(section, opt);
	}

	/**
	 * Converts a parsed `HxFormatWrapRules` into the runtime `WrapRules`
	 * used by `WrapList.emit`.
	 *
	 * `defaultWrap` overrides the cascade's `defaultMode` when it parses;
	 * an unrecognised string falls back to the runtime `base.defaultMode`.
	 *
	 * `rules` is ingested verbatim — slice ω-peg-byname-array lifted the
	 * `@:peg` ByName Array<T> limitation so the JSON-side rules array now
	 * round-trips into the runtime cascade. Rules with an unrecognised
	 * `type` are dropped, and rules with at least one unrecognised `cond`
	 * predicate are dropped wholesale so the cascade falls through to
	 * the next rule instead of producing a partially-evaluated decision.
	 * Slice ω-linelen-static added `lineLength >= n` to the recognised
	 * set (mapped to `LineLengthLargerThan`, evaluated statically against
	 * the construct's flat width). A configured `rules: []` resets the
	 * cascade to empty (unconditional `defaultMode`); an absent `rules`
	 * key preserves the runtime baseline cascade.
	 *
	 * `clearRulesOnDefaultWrap` (chain classes only) mirrors the fork's
	 * json2object replace-semantics for `opBoolChain` / `opAddSubChain`:
	 * a user block that sets `defaultWrap` but omits `rules` selects that
	 * mode unconditionally (the fork's parsed config object carries an
	 * empty `rules` array, replacing the built-in cascade). Anyparse's
	 * default preserves `base.rules` on rules-absent so partial configs
	 * keep sensible gates — but for the two chain classes the fork's
	 * `wrapping.opBoolChain.defaultWrap: fillLine` fixtures expect the
	 * built-in `itemCount<=3`/`totalItemLength<=120`/`itemCount>=4` gates
	 * gone, so the user's `defaultWrap` is the primary mode. Scoped to
	 * the chain callsites; every other wrap class keeps the rules-
	 * preserve default. Only triggers when `defaultWrap` resolved (an
	 * unrecognised string falls through to the preserve path).
	 */
	private static function wrapRulesFromConfig(cfg: HxFormatWrapRules, base: WrapRules, clearRulesOnDefaultWrap: Bool = false): WrapRules {
		final resolvedDefault: Null<WrapMode> = cfg.defaultWrap != null ? wrapModeFromString(cfg.defaultWrap) : null;
		final defaultMode: WrapMode = resolvedDefault ?? base.defaultMode;
		final defaultLocation: Null<WrappingLocation> = cfg.defaultLocation != null
			? wrappingLocationFromString(cfg.defaultLocation) ?? base.defaultLocation
			: base.defaultLocation;
		final defaultAdditionalIndent: Null<Int> = cfg.defaultAdditionalIndent ?? base.defaultAdditionalIndent;
		final src: Null<Array<HxFormatWrapRule>> = cfg.rules;
		if (src == null) {
			final clearing: Bool = clearRulesOnDefaultWrap && resolvedDefault != null;
			final inheritedRules: Array<WrapRule> = clearing ? [] : base.rules;
			// B4 ω-implements-extends-wrap: when a `defaultWrap`-only block
			// CLEARS the built-in cascade (chain classes + implementsExtends),
			// the fork models continuation indent as a PER-RULE
			// `additionalIndent` — so a rules-less `defaultWrap` carries NO
			// extra indent. Don't inherit the base cascade's
			// `defaultAdditionalIndent` (which encodes the cleared rules' indent);
			// honour an explicit `defaultAdditionalIndent` if present, else 0.
			// Chain emitters ignore `defaultAdditionalIndent` (WrapRules doc), so
			// this is a no-op for opBoolChain / opAddSubChain.
			final clearedIndent: Null<Int> = clearing ? (cfg.defaultAdditionalIndent ?? 0) : defaultAdditionalIndent;
			return {
				rules: inheritedRules,
				defaultMode: defaultMode,
				defaultLocation: defaultLocation,
				defaultAdditionalIndent: clearedIndent
			};
		}
		final rules: Array<WrapRule> = [];
		for (raw in src) {
			final mapped: Null<WrapRule> = wrapRuleFromConfig(raw);
			if (mapped != null) rules.push(mapped);
		}
		return {
			rules: rules,
			defaultMode: defaultMode,
			defaultLocation: defaultLocation,
			defaultAdditionalIndent: defaultAdditionalIndent
		};
	}

	private static function wrapRuleFromConfig(raw: HxFormatWrapRule): Null<WrapRule> {
		final typeStr: Null<String> = raw.type;
		if (typeStr == null) return null;
		final mode: Null<WrapMode> = wrapModeFromString(typeStr);
		if (mode == null) return null;
		final rawConds: Null<Array<HxFormatWrapCondition>> = raw.conditions;
		final mapped: Array<WrapCondition> = [];
		if (rawConds != null) for (rc in rawConds) {
			final condStr: Null<String> = rc.cond;
			if (condStr == null) return null;
			final ct: Null<WrapConditionType> = wrapCondFromString(condStr);
			if (ct == null) return null;
			final condNarrow: WrapConditionType = ct;
			mapped.push({ cond: condNarrow, value: rc.value ?? 0 });
		}
		final locStr: Null<String> = raw.location;
		final location: Null<WrappingLocation> = locStr != null ? wrappingLocationFromString(locStr) : null;
		return location != null
			? {
				conditions: mapped,
				mode: mode,
				location: location
			}
			: {
				conditions: mapped,
				mode: mode
			};
	}

	private static function wrappingLocationFromString(s: String): Null<WrappingLocation> {
		return switch s {
			case 'beforeLast': WrappingLocation.BeforeLast;
			case 'afterLast': WrappingLocation.AfterLast;
			case _: null;
		};
	}

	// Accepts BOTH the symbolic JSON form (`'onePerLine'`, the fork's
	// `WrappingType` enum-abstract-string VALUES) AND the legacy identifier
	// form (`'OnePerLine'`, the enum-abstract IDENTIFIERS as serialized by
	// json2object in older fork fixtures). Fixtures in the wild use both
	// (e.g. `wrapping_method_chain_per_line.hxtest` uses identifier form;
	// `wrapping_of_function_signature_keep.hxtest` uses symbolic form).
	private static function wrapModeFromString(s: String): Null<WrapMode> {
		return switch s {
			case 'noWrap' | 'NoWrap': WrapMode.NoWrap;
			case 'onePerLine' | 'OnePerLine': WrapMode.OnePerLine;
			case 'onePerLineAfterFirst' | 'OnePerLineAfterFirst': WrapMode.OnePerLineAfterFirst;
			case 'fillLine' | 'FillLine': WrapMode.FillLine;
			case 'fillLineWithLeadingBreak' | 'FillLineWithLeadingBreak':
				WrapMode.FillLineWithLeadingBreak;
			// ω-keep-objectlit: fork's `WrappingType.Keep` preserves
			// source-newline pattern per-element. Loader maps it to
			// `WrapMode.Keep`; `triviaSepStarExpr` (`WriterLowering.hx`)
			// consumes it for trivia-bearing Stars (ObjectLit, Anon-type,
			// etc.) via the `_keepEmit` gate. `BinaryChainEmit` and
			// `MethodChainEmit` route `Keep` to their `shapeNoWrap` arms
			// — chain Keep semantics is a follow-up slice; the NoWrap
			// fallback preserves the pre-recognition baseline byte-
			// identically for chain-config Keep fixtures.
			case 'keep' | 'Keep':
				WrapMode.Keep;
			// ω-cascade-emits-comments: fork's `WrappingType.Ignore`
			// drops source-newline signal and lets the cascade pick a
			// width-driven layout. Sister to Keep on the same axis.
			// `triviaSepStarExpr` consumes it via the `_ignoreEmit`
			// gate; chain emitters route `Ignore → shapeNoWrap` as a
			// defensive fallback.
			case 'ignore' | 'Ignore': WrapMode.Ignore;
			case _: null;
		};
	}

	// Accepts BOTH the symbolic JSON form (`'itemCount >= n'`, the fork's
	// `WrapConditionType` enum-abstract-string VALUES) AND the identifier
	// form (`'ItemCountLargerThan'`, the enum-abstract IDENTIFIERS as
	// serialized by json2object in older fork fixtures). See sister
	// `wrapModeFromString` for rationale.
	private static function wrapCondFromString(s: String): Null<WrapConditionType> {
		return switch s {
			case 'itemCount <= n' | 'ItemCountLessThan': WrapConditionType.ItemCountLessThan;
			case 'itemCount >= n' | 'ItemCountLargerThan': WrapConditionType.ItemCountLargerThan;
			case 'anyItemLength >= n' | 'AnyItemLengthLargerThan': WrapConditionType.AnyItemLengthLargerThan;
			case 'allItemLengths < n' | 'AllItemLengthsLessThan': WrapConditionType.AllItemLengthsLessThan;
			case 'totalItemLength >= n' | 'TotalItemLengthLargerThan': WrapConditionType.TotalItemLengthLargerThan;
			case 'totalItemLength <= n' | 'TotalItemLengthLessThan': WrapConditionType.TotalItemLengthLessThan;
			case 'exceedsMaxLineLength' | 'ExceedsMaxLineLength': WrapConditionType.ExceedsMaxLineLength;
			case 'lineLength >= n' | 'LineLengthLargerThan': WrapConditionType.LineLengthLargerThan;
			case 'hasMultilineItems' | 'HasMultilineItems': WrapConditionType.HasMultilineItems;
			case _: null;
		};
	}

	private static function applySameLine(section: HxFormatSameLineSection, opt: HxModuleWriteOptions): Void {
		if (section.ifElse != null) opt.sameLineElse = sameLineToRuntime(section.ifElse);
		if (section.tryCatch != null) opt.sameLineCatch = sameLineToRuntime(section.tryCatch);
		if (section.doWhile != null) opt.sameLineDoWhile = sameLineToRuntime(section.doWhile);
		if (section.ifBody != null) opt.ifBody = bodyPolicyToRuntime(section.ifBody);
		if (section.elseBody != null) opt.elseBody = bodyPolicyToRuntime(section.elseBody);
		if (section.forBody != null) opt.forBody = bodyPolicyToRuntime(section.forBody);
		if (section.whileBody != null) opt.whileBody = bodyPolicyToRuntime(section.whileBody);
		if (section.doWhileBody != null) opt.doBody = bodyPolicyToRuntime(section.doWhileBody);
		if (section.returnBody != null) opt.returnBody = bodyPolicyToRuntime(section.returnBody);
		// ω-return-body-single-line: `sameLine.returnBodySingleLine` refines
		// the kw→value separator for returns whose value is NOT a control-flow
		// or block construct (literals, idents, ternaries, array / object /
		// comprehension literals, calls). Control-flow / block values
		// (`if` / `switch` / `for` / `while` / `try` / `{ … }`) keep using
		// `returnBody`. The runtime dual-dispatch lives in `bodyPolicyWrap`
		// via the `bodyPolicySingleLine('returnBodySingleLine', '<ctor>'...)`
		// knob on `HxStatement.ReturnStmt`; the discriminator matches the
		// value's `Type.enumConstructor` against the listed control-flow ctors,
		// mirroring the fork's `shouldReturnBeSameLine` AST classification.
		if (section.returnBodySingleLine != null) opt.returnBodySingleLine = bodyPolicyToRuntime(section.returnBodySingleLine);
		if (section.catchBody != null) opt.catchBody = bodyPolicyToRuntime(section.catchBody);
		if (section.tryBody != null) opt.tryBody = bodyPolicyToRuntime(section.tryBody);
		if (section.caseBody != null) opt.caseBody = bodyPolicyToRuntime(section.caseBody);
		if (section.expressionCase != null) opt.expressionCase = bodyPolicyToRuntime(section.expressionCase);
		if (section.functionBody != null) opt.functionBody = bodyPolicyToRuntime(section.functionBody);
		// Slice ω-anonfnbody-keep: `sameLine.anonFunctionBody` drives the
		// signature→body separator on `HxFnExpr.body`'s `ExprBody` branch
		// (the bare-expr anon-fn body, e.g. `function() trace(i)`), the
		// expression-position sibling of `functionBody`. Wired through
		// `@:fmt(bodyPolicyForCtor('ExprBody', 'anonFunctionBody'))` on the
		// `HxFnExpr.body` optional Ref. Default `Same` reproduces the
		// pre-slice cuddle, so the knob is byte-inert until set.
		if (section.anonFunctionBody != null) opt.anonFunctionBody = bodyPolicyToRuntime(section.anonFunctionBody);
		if (section.untypedBody != null) opt.untypedBody = bodyPolicyToRuntime(section.untypedBody);
		// Slice ω-expr-body-keep: the JSON key `sameLine.expressionIf`
		// is parsed via the schema (so unknown-key validation passes)
		// and `Keep` / `Same` are honoured at runtime. `Same` force-
		// flattens expression-position `if/else/for` bodies, which is
		// unconditionally safe because the bodyPolicyWrap `Same` branch
		// emits `_dop(' ')` regardless of surrounding context — no arrow-
		// context ambiguity. `Next` / `FitLine` still need surrounding-
		// context propagation that the bodyPolicyWrap engine cannot
		// derive in isolation (a `Next` on the inner body force-breaks
		// legitimate inline arrow bodies — see `fitline_arrow_body_if.hxtest`).
		// Programmatic users can still set the three knobs independently
		// for finer control.
		// ω-expression-case-flat-fanout: HxCaseBranch.body uses
		// `expressionCase` (NOT `expressionIfBody`) as the swap source,
		// so propagating `expressionIf: next/fitLine` here would leak
		// into HxIfExpr.thenBranch's `bodyPolicy('expressionIfBody')` and
		// break the existing arrow-body fixture. The Next/FitLine gate
		// stays.
		if (section.expressionIf != null) {
			final p: BodyPolicy = bodyPolicyToRuntime(section.expressionIf);
			if (p == BodyPolicy.Keep || p == BodyPolicy.Same) {
				opt.expressionIfBody = p;
				opt.expressionElseBody = p;
				opt.expressionForBody = p;
			}
			// ω-expression-if-next-with-fitline-body: fanout `Next` / `FitLine`
			// into `expressionIfBody` / `expressionElseBody` only.
			// `expressionForBody` is intentionally excluded — `for` has no
			// `else` sibling, so the noSiblingFallback gate cannot kick in,
			// and arrow-body / comprehension `for` would regress. The arrow-
			// body if-without-else and comprehension filter-if cases are
			// caught by `HxIfExpr.thenBranch`'s `@:fmt(noSiblingFallback(
			// 'ifBody'))`: when `elseBranch` is `null` at runtime, the body
			// policy falls back to `opt.ifBody` (FitLine) instead of
			// `opt.expressionIfBody` (Next), preserving inline shape for
			// `item -> if (cond) body` and `[for (x in xs) if (cond) x]`.
			// Mirrors fork's `MarkSameLine.markIf` `parent.tok==Arrow` and
			// `isComprehensionFilterIf` short-circuits onto `ifBody`.
			else if (p == BodyPolicy.Next || p == BodyPolicy.FitLine) {
				opt.expressionIfBody = p;
				opt.expressionElseBody = p;
			}
			// ω-expr-else-sameline: fanout `sameLine.expressionIf` into
			// `sameLineExpressionElse:SameLinePolicy`, the per-`else` gap
			// for HxIfExpr.elseBranch. Independent of body-placement
			// fanout (which has the arrow-body regression gate above).
			//
			// Mapping rationale: `Next` maps to `Keep` (NOT `Next`) so
			// the writer reads the synth `BeforeKwNewline` slot and
			// preserves whatever the source had. Fork's actual semantic
			// for `expressionIf=next` is block-shape-aware (`} else {`
			// stays cuddled even with `next`, only non-block prev breaks).
			// Mapping to `Keep` reproduces this correctly across the
			// corpus because:
			//  - block-shape branches in source are typically inline →
			//    Keep slot=false → space → matches fork's cuddle.
			//  - non-block (e.g. object-lit) branches in source typically
			//    have the `\n` already → Keep slot=true → hardline →
			//    matches fork's break.
			// True shape-aware Next dispatch (force-break for non-block,
			// cuddle for block, regardless of source) would need a
			// dedicated `@:fmt(shapeAware)` variant — deferred until a
			// fixture surfaces that the source-preserving mapping mishits.
			// `Same` and `Keep` map directly. `FitLine` falls through to
			// `Same` (no SameLinePolicy counterpart).
			opt.sameLineExpressionElse = switch p {
				case BodyPolicy.Keep, BodyPolicy.Next: SameLinePolicy.Keep;
				case _: SameLinePolicy.Same;
			};
		}
		if (section.elseIf != null) opt.elseIf = keywordPlacementToRuntime(section.elseIf);
		if (section.fitLineIfWithElse != null) opt.fitLineIfWithElse = section.fitLineIfWithElse;
		if (section.ifElseSemicolonNextLine != null) opt.ifElseSemicolonNextLine = section.ifElseSemicolonNextLine;
		if (section.expressionTry != null) opt.expressionTry = sameLineToRuntime(section.expressionTry);
		if (section.expressionIfWithBlocks != null) opt.expressionIfWithBlocks = section.expressionIfWithBlocks;
	}

	private static function applyTrailingCommas(section: HxFormatTrailingCommasSection, opt: HxModuleWriteOptions): Void {
		if (section.arrayLiteralDefault != null) opt.trailingCommaArrays = trailingCommaToBool(section.arrayLiteralDefault);
		if (section.callArgumentDefault != null) opt.trailingCommaArgs = trailingCommaToBool(section.callArgumentDefault);
		if (section.functionParameterDefault != null) opt.trailingCommaParams = trailingCommaToBool(section.functionParameterDefault);
		if (section.objectLiteralDefault != null) opt.trailingCommaObjectLits = trailingCommaToBool(section.objectLiteralDefault);
	}

	private static function applyLineEnds(section: HxFormatLineEndsSection, opt: HxModuleWriteOptions): Void {
		if (section.leftCurly != null) {
			final placement: BracePlacement = leftCurlyToRuntime(section.leftCurly);
			opt.leftCurly = placement;
			// ω-objectlit-leftCurly-cascade: cascade global `lineEnds.leftCurly`
			// into per-construct `objectLiteralLeftCurly`. Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy` precedence — global lineEnd seeds
			// every per-construct knob, sub-keys override individually.
			//
			// Cascade is now safe (was rejected pre-slice per
			// `feedback_no_global_cascade_per_construct.md`) because the
			// knob-form leftCurly emission inside `triviaSepStarExpr` wires
			// `WrapList.emit`'s `(leadFlat, leadBreak)` parameters: short
			// object literals chosen flat by the wrap engine stay cuddled
			// regardless of `Next`, multi-line ones go Allman. The fixtures
			// the original memory worried about (issue_178, issue_185,
			// issue_42_if_after_assign_with_blocks_on_same_line,
			// object_literal_else_not_same_line) carry short literals the
			// wrap cascade chooses NoWrap for — they continue to emit
			// cuddled `{` even with `objectLiteralLeftCurly = Next`.
			opt.objectLiteralLeftCurly = placement;
			// ω-anontype-left-curly: cascade global `lineEnds.leftCurly`
			// into `opt.anonTypeLeftCurly`. With `Next`, typedef RHS
			// anon-types (`typedef Foo = {...}`) and inner var-type anons
			// (`var a:{...}`) flip to Allman (`=\n{ ... }`). Default
			// `Same` keeps the cuddled layout. Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(AnonType)` precedence — global
			// lineEnd seeds every per-construct knob, sub-keys override.
			opt.anonTypeLeftCurly = placement;
			// ω-anonfunction-left-curly: cascade global `lineEnds.leftCurly`
			// into `opt.anonFunctionLeftCurly`. With `Next`, anonymous
			// function expression bodies (`function() {…}`) flip to Allman
			// (`function()\n{…}`). Default `Same` keeps the cuddled
			// layout. Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(AnonymousFunction)` precedence
			// — global lineEnd seeds every per-construct knob, sub-keys
			// override. Arrow-lambda body (`() -> {…}`) is NOT covered
			// here — the lambda body is `HxExpr.BlockExpr` which keeps
			// reading the global `leftCurly`; per-context routing through
			// the lambda parent is a follow-up slice.
			opt.anonFunctionLeftCurly = placement;
			// ω-blockcurly + ω-blockcurly-broader: cascade global
			// `lineEnds.leftCurly` into `opt.blockLeftCurly`. With
			// `Next`, every plain block body flips to Allman —
			// `HxFnDecl.body` (`function f()\n{…}`),
			// `HxStatement.BlockStmt` (`if (cond)\n{…}`),
			// `HxExpr.BlockExpr` (block-as-expression),
			// `HxSwitchStmt.cases` / `HxSwitchStmtBare.cases`
			// (`switch (e)\n{…}`), `HxUntypedFnBody.block`
			// (`untyped\n{…}`). Default `Same` keeps the cuddled
			// layout. Mirrors haxe-formatter's
			// `MarkLineEnds.detectCurlyPolicy(Block)` precedence —
			// global lineEnd seeds every per-construct knob, sub-keys
			// override.
			opt.blockLeftCurly = placement;
		}
		if (section.objectLiteralCurly != null) {
			final sub: HxFormatCurlyLineEndPolicy = section.objectLiteralCurly;
			if (sub.leftCurly != null) opt.objectLiteralLeftCurly = leftCurlyToRuntime(sub.leftCurly);
			// ω-objectlit-right-curly: per-construct sub-key
			// `lineEnds.objectLiteralCurly.rightCurly` overrides the cascade
			// for object-literal body closes (`HxObjectLit.fields`). Mirrors
			// haxe-formatter's `MarkLineEnds.getCurlyPolicy(ObjectDecl).rightCurly`
			// precedence.
			if (sub.rightCurly != null) opt.objectLiteralRightCurly = rightCurlyToRuntime(sub.rightCurly);
		}
		if (section.anonFunctionCurly != null) {
			final sub: HxFormatCurlyLineEndPolicy = section.anonFunctionCurly;
			if (sub.leftCurly != null) opt.anonFunctionLeftCurly = leftCurlyToRuntime(sub.leftCurly);
			// ω-anonfunction-empty-curly: per-construct sub-key
			// `lineEnds.anonFunctionCurly.emptyCurly` overrides the cascade
			// for empty anonymous function bodies (`function(){}` →
			// `function()\n{\n}`). Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(AnonymousFunction).emptyCurly`
			// precedence — global lineEnd seeds the knob, the sub-key
			// wins when present.
			if (sub.emptyCurly != null) opt.anonFunctionEmptyCurly = emptyCurlyToRuntime(sub.emptyCurly);
			// ω-anonfunction-right-curly: per-construct sub-key
			// `lineEnds.anonFunctionCurly.rightCurly` overrides the cascade
			// for anonymous function body closes. Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(AnonymousFunction).rightCurly`
			// precedence.
			if (sub.rightCurly != null) opt.anonFunctionRightCurly = rightCurlyToRuntime(sub.rightCurly);
		}
		if (section.anonTypeCurly != null) {
			// ω-anontype-right-curly: per-construct sub-key
			// `lineEnds.anonTypeCurly.rightCurly` overrides the cascade
			// for anonymous type body closes (`HxType.Anon`). Mirrors
			// haxe-formatter's `MarkLineEnds.getCurlyPolicy(AnonType).rightCurly`
			// precedence.
			final sub: HxFormatCurlyLineEndPolicy = section.anonTypeCurly;
			if (sub.rightCurly != null) opt.anonTypeRightCurly = rightCurlyToRuntime(sub.rightCurly);
		}
		if (section.blockCurly != null) {
			// ω-blockcurly: per-construct sub-key
			// `lineEnds.blockCurly.leftCurly` overrides the cascade for
			// plain block body braces (currently `HxFnDecl.body`).
			// Mirrors haxe-formatter's `MarkLineEnds.getCurlyPolicy(Block)`
			// precedence.
			final sub: HxFormatCurlyLineEndPolicy = section.blockCurly;
			if (sub.leftCurly != null) opt.blockLeftCurly = leftCurlyToRuntime(sub.leftCurly);
			// ω-blockempty: per-construct sub-key
			// `lineEnds.blockCurly.emptyCurly` overrides the cascade for
			// empty plain block bodies (`HxStatement.BlockStmt`,
			// `HxExpr.BlockExpr`, `HxSwitchStmt.cases`,
			// `HxSwitchStmtBare.cases`). Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(Block).emptyCurly` precedence.
			if (sub.emptyCurly != null) opt.blockEmptyCurly = emptyCurlyToRuntime(sub.emptyCurly);
			// ω-blockright-curly: per-construct sub-key
			// `lineEnds.blockCurly.rightCurly` overrides the cascade for
			// plain block body closes. Mirrors haxe-formatter's
			// `MarkLineEnds.getCurlyPolicy(Block).rightCurly` precedence.
			if (sub.rightCurly != null) opt.blockRightCurly = rightCurlyToRuntime(sub.rightCurly);
		}
		if (section.emptyCurly != null) {
			final empty: EmptyCurly = emptyCurlyToRuntime(section.emptyCurly);
			opt.emptyCurly = empty;
			// ω-anonfunction-empty-curly: cascade global `lineEnds.emptyCurly`
			// into `opt.anonFunctionEmptyCurly` (same pattern as
			// `anonFunctionLeftCurly` cascade above). The sub-key handler
			// runs before this block when both are present, so the explicit
			// `anonFunctionCurly.emptyCurly` override wins regardless of
			// global ingest order.
			if (section.anonFunctionCurly == null || section.anonFunctionCurly.emptyCurly == null) opt.anonFunctionEmptyCurly = empty;
			// ω-blockempty: cascade global `lineEnds.emptyCurly` into
			// `opt.blockEmptyCurly`. The `lineEnds.blockCurly.emptyCurly`
			// sub-key handler runs before this block when both are present,
			// so the explicit override wins regardless of global ingest order.
			if (section.blockCurly == null || section.blockCurly.emptyCurly == null) opt.blockEmptyCurly = empty;
		}
		// ω-blockright-curly + ω-anonfunction-right-curly: cascade global
		// `lineEnds.rightCurly` into every per-construct
		// `RightCurlyPlacement` knob. With `Inline` (mapped from `"after"`
		// / `"none"`), block bodies emit `{ body }` without a hardline
		// before `}`; `Same` (mapped from `"before"` / `"both"`, default)
		// keeps the standard close-on-own-line layout. The per-construct
		// sub-key handlers (`lineEnds.blockCurly.rightCurly`,
		// `lineEnds.anonFunctionCurly.rightCurly`) run before this block
		// when present, so explicit overrides win regardless of global
		// ingest order. Mirrors haxe-formatter's
		// `MarkLineEnds.detectCurlyPolicy(...).rightCurly` precedence —
		// global lineEnd seeds every per-construct knob, sub-keys override.
		if (section.rightCurly != null) {
			final placement: RightCurlyPlacement = rightCurlyToRuntime(section.rightCurly);
			if (section.blockCurly == null || section.blockCurly.rightCurly == null) opt.blockRightCurly = placement;
			// ω-anonfunction-right-curly: cascade global lineEnd into
			// `anonFunctionRightCurly` unless the
			// `anonFunctionCurly.rightCurly` sub-key already set it.
			if (section.anonFunctionCurly == null || section.anonFunctionCurly.rightCurly == null) opt.anonFunctionRightCurly = placement;
			// ω-anontype-right-curly: cascade global lineEnd into
			// `anonTypeRightCurly` unless the `anonTypeCurly.rightCurly`
			// sub-key already set it.
			if (section.anonTypeCurly == null || section.anonTypeCurly.rightCurly == null) opt.anonTypeRightCurly = placement;
			// ω-objectlit-right-curly: cascade global lineEnd into
			// `objectLiteralRightCurly` unless the
			// `objectLiteralCurly.rightCurly` sub-key already set it.
			if (section.objectLiteralCurly == null || section.objectLiteralCurly.rightCurly == null)
				opt.objectLiteralRightCurly = placement;
		}
		// ω-metadata-line-end-function: `lineEnds.metadataFunction` →
		// `opt.metadataFunctionLineEnd`. Default `None` preserves source-
		// driven inter-meta separator; `After` / `AfterLast` /
		// `ForceAfterLast` force a hardline after the last function meta
		// (and override inter-element sep for `After` / `ForceAfterLast`).
		if (section.metadataFunction != null) opt.metadataFunctionLineEnd = metadataLineEndToRuntime(section.metadataFunction);
		// ω-lineend-character: `lineEnds.lineEndCharacter` → `opt.lineEnd`
		// (base WriteOptions String). `"LF"` / `"CRLF"` / `"CR"` map to
		// `\n` / `\r\n` / `\r`; `"Auto"` falls back to `\n` because the
		// writer is decoupled from the source byte stream (no
		// `parsedCode.lineSeparator` equivalent).
		if (section.lineEndCharacter != null) opt.lineEnd = lineEndCharacterToRuntime(section.lineEndCharacter);
	}

	private static function applyWhitespace(section: HxFormatWhitespaceSection, opt: HxModuleWriteOptions): Void {
		if (section.objectFieldColonPolicy != null) opt.objectFieldColon = whitespaceToRuntime(section.objectFieldColonPolicy);
		if (section.typeHintColonPolicy != null) opt.typeHintColon = whitespaceToRuntime(section.typeHintColonPolicy);
		if (section.typeCheckColonPolicy != null) opt.typeCheckColon = whitespaceToRuntime(section.typeCheckColonPolicy);
		if (section.typeParamOpenPolicy != null) opt.typeParamOpen = whitespaceToRuntime(section.typeParamOpenPolicy);
		if (section.typeParamClosePolicy != null) opt.typeParamClose = whitespaceToRuntime(section.typeParamClosePolicy);
		if (section.binopPolicy != null) opt.typeParamDefaultEquals = whitespaceToRuntime(section.binopPolicy);
		if (section.functionTypeHaxe4Policy != null) opt.functionTypeHaxe4 = whitespaceToRuntime(section.functionTypeHaxe4Policy);
		if (section.functionTypeHaxe3Policy != null) opt.functionTypeHaxe3 = whitespaceToRuntime(section.functionTypeHaxe3Policy);
		if (section.arrowFunctionsPolicy != null) opt.arrowFunctions = whitespaceToRuntime(section.arrowFunctionsPolicy);
		if (section.ifPolicy != null) opt.ifPolicy = whitespaceToRuntime(section.ifPolicy);
		if (section.forPolicy != null) opt.forPolicy = whitespaceToRuntime(section.forPolicy);
		if (section.whilePolicy != null) opt.whilePolicy = whitespaceToRuntime(section.whilePolicy);
		if (section.switchPolicy != null) opt.switchPolicy = whitespaceToRuntime(section.switchPolicy);
		if (section.tryPolicy != null) opt.tryPolicy = whitespaceToRuntime(section.tryPolicy);
		if (section.addLineCommentSpace != null) opt.addLineCommentSpace = section.addLineCommentSpace;
		if (section.compressSuccessiveParenthesis != null) opt.compressSuccessiveParenthesis = section.compressSuccessiveParenthesis;
		if (section.formatStringInterpolation != null) opt.formatStringInterpolation = section.formatStringInterpolation;
		final paren: Null<HxFormatParenConfigSection> = section.parenConfig;
		if (paren != null) {
			final funcParam: Null<HxFormatParenPolicySection> = paren.funcParamParens;
			if (funcParam != null && funcParam.openingPolicy != null) opt.funcParamParens = whitespaceToRuntime(funcParam.openingPolicy);
			final call: Null<HxFormatParenPolicySection> = paren.callParens;
			if (call != null) {
				// ω-call-parens-inside (Stage B): `callParens.openingPolicy`
				// drives TWO axes of the open `(` token, mirroring fork's
				// per-token whitespace policy. The `before` sub-policy is the
				// gap BEFORE `(` (existing `opt.callParens`); the `after`
				// sub-policy is the INNER pad right after `(` (new
				// `opt.callParensInsideOpen`). `closingPolicy.before` is the
				// inner pad before `)` (`opt.callParensInsideClose`). So
				// `openingPolicy: "onlyAfter"` keeps `bar1(` tight AND pads
				// `( {…`; `closingPolicy: "before"` pads `…} )`.
				final callOpening: Null<HxFormatWhitespacePolicy> = call.openingPolicy;
				if (callOpening != null) {
					opt.callParens = whitespaceToRuntime(callOpening);
					opt.callParensInsideOpen = whitespaceToRuntime(callOpening);
				}
				final callClosing: Null<HxFormatWhitespacePolicy> = call.closingPolicy;
				if (callClosing != null) opt.callParensInsideClose = whitespaceToRuntime(callClosing);
			}
			final anonFunc: Null<HxFormatParenPolicySection> = paren.anonFuncParamParens;
			if (anonFunc != null) {
				if (anonFunc.openingPolicy != null) opt.anonFuncParens = whitespaceToRuntime(anonFunc.openingPolicy);
				if (anonFunc.removeInnerWhenEmpty != null) opt.anonFuncParamParensKeepInnerWhenEmpty = !anonFunc.removeInnerWhenEmpty;
			}
			// ω-condition-parens (Stage C): apply the `conditionParens`
			// catch-all FIRST (haxe-formatter scopes it to if / while / switch
			// / `#if`), then the per-category sections override. Each section's
			// `openingPolicy` drives the kw→`(` gap (paren-side `before`,
			// flipped to the kw-after knob) AND the inner `( ` pad
			// (`after`); `closingPolicy.before` drives the inner ` )` pad.
			applyConditionParens(paren.conditionParens, opt, true);
			applyConditionParens(paren.ifConditionParens, opt, false, 'if');
			applyConditionParens(paren.whileConditionParens, opt, false, 'while');
			applyConditionParens(paren.switchConditionParens, opt, false, 'switch');
			applyConditionParens(paren.catchParens, opt, false, 'catch');
			applyConditionParens(paren.sharpConditionParens, opt, false, 'sharp');
		}
		final braces: Null<HxFormatBracesConfigSection> = section.bracesConfig;
		if (braces != null) {
			final anonType: Null<HxFormatParenPolicySection> = braces.anonTypeBraces;
			if (anonType != null) {
				if (anonType.openingPolicy != null) opt.anonTypeBracesOpen = whitespaceToRuntime(anonType.openingPolicy);
				if (anonType.closingPolicy != null) opt.anonTypeBracesClose = whitespaceToRuntime(anonType.closingPolicy);
			}
			final objectLit: Null<HxFormatParenPolicySection> = braces.objectLiteralBraces;
			if (objectLit != null) {
				if (objectLit.openingPolicy != null) opt.objectLiteralBracesOpen = whitespaceToRuntime(objectLit.openingPolicy);
				if (objectLit.closingPolicy != null) opt.objectLiteralBracesClose = whitespaceToRuntime(objectLit.closingPolicy);
			}
		}
		// ω-bracket-config: `whitespace.bracketConfig.*` → the eight
		// `{access|arrayLiteral|mapLiteral|comprehension}Brackets{Open|
		// Close}` knobs. Mirrors the `bracesConfig` block above; each of
		// the four bracket kinds reuses the `HxFormatParenPolicySection`
		// opening / closing policy pair. `HxExpr.IndexAccess` reads the
		// `accessBrackets` pair; `HxExpr.ArrayExpr` runtime-dispatches
		// among the other three on its first element's enum constructor.
		final bracket: Null<HxFormatBracketConfigSection> = section.bracketConfig;
		if (bracket != null) {
			final access: Null<HxFormatParenPolicySection> = bracket.accessBrackets;
			if (access != null) {
				if (access.openingPolicy != null) opt.accessBracketsOpen = whitespaceToRuntime(access.openingPolicy);
				if (access.closingPolicy != null) opt.accessBracketsClose = whitespaceToRuntime(access.closingPolicy);
			}
			final arrayLit: Null<HxFormatParenPolicySection> = bracket.arrayLiteralBrackets;
			if (arrayLit != null) {
				if (arrayLit.openingPolicy != null) opt.arrayLiteralBracketsOpen = whitespaceToRuntime(arrayLit.openingPolicy);
				if (arrayLit.closingPolicy != null) opt.arrayLiteralBracketsClose = whitespaceToRuntime(arrayLit.closingPolicy);
			}
			final mapLit: Null<HxFormatParenPolicySection> = bracket.mapLiteralBrackets;
			if (mapLit != null) {
				if (mapLit.openingPolicy != null) opt.mapLiteralBracketsOpen = whitespaceToRuntime(mapLit.openingPolicy);
				if (mapLit.closingPolicy != null) opt.mapLiteralBracketsClose = whitespaceToRuntime(mapLit.closingPolicy);
			}
			final compr: Null<HxFormatParenPolicySection> = bracket.comprehensionBrackets;
			if (compr != null) {
				if (compr.openingPolicy != null) opt.comprehensionBracketsOpen = whitespaceToRuntime(compr.openingPolicy);
				if (compr.closingPolicy != null) opt.comprehensionBracketsClose = whitespaceToRuntime(compr.closingPolicy);
			}
		}
	}

	private static function applyEmptyLines(section: HxFormatEmptyLinesSection, opt: HxModuleWriteOptions): Void {
		if (section.afterFieldsWithDocComments != null)
			opt.afterFieldsWithDocComments = commentEmptyLinesToRuntime(section.afterFieldsWithDocComments);
		if (section.beforeDocCommentEmptyLines != null)
			opt.beforeDocCommentEmptyLines = commentEmptyLinesToRuntime(section.beforeDocCommentEmptyLines);
		final classSection: Null<HxFormatClassEmptyLinesConfig> = section.classEmptyLines;
		if (classSection != null) {
			if (classSection.existingBetweenFields != null)
				opt.existingBetweenFields = keepEmptyLinesToRuntime(classSection.existingBetweenFields);
			if (classSection.betweenVars != null) opt.betweenVars = classSection.betweenVars;
			if (classSection.betweenFunctions != null) opt.betweenFunctions = classSection.betweenFunctions;
			if (classSection.afterVars != null) opt.afterVars = classSection.afterVars;
			if (classSection.afterStaticVars != null) opt.afterStaticVars = classSection.afterStaticVars;
			if (classSection.betweenStaticFunctions != null) opt.betweenStaticFunctions = classSection.betweenStaticFunctions;
			if (classSection.beginType != null) opt.beginType = classSection.beginType;
			if (classSection.endType != null) opt.endType = classSection.endType;
		}
		// ω-abstract-static-fn-cascade: `abstractEmptyLines` reuses the
		// shared `HxFormatClassEmptyLinesConfig` runtime knobs (fork shares
		// `ClassFieldsEmptyLinesConfig` across class / abstract scopes). Only
		// `betweenStaticFunctions` is consumed today — the rest land with
		// their abstract-scoped fixtures. Last-write wins against any
		// `classEmptyLines` block that set the same shared knob.
		final abstractSection: Null<HxFormatClassEmptyLinesConfig> = section.abstractEmptyLines;
		if (abstractSection != null && abstractSection.betweenStaticFunctions != null)
			opt.betweenStaticFunctions = abstractSection.betweenStaticFunctions;
		final externClassSection: Null<HxFormatClassEmptyLinesConfig> = section.externClassEmptyLines;
		if (externClassSection != null && externClassSection.existingBetweenFields != null)
			opt.externExistingBetweenFields = keepEmptyLinesToRuntime(externClassSection.existingBetweenFields);
		final interfaceSection: Null<HxFormatInterfaceEmptyLinesConfig> = section.interfaceEmptyLines;
		if (interfaceSection != null) {
			if (interfaceSection.betweenVars != null) opt.interfaceBetweenVars = interfaceSection.betweenVars;
			if (interfaceSection.betweenFunctions != null) opt.interfaceBetweenFunctions = interfaceSection.betweenFunctions;
			if (interfaceSection.afterVars != null) opt.interfaceAfterVars = interfaceSection.afterVars;
		}
		final enumSection: Null<HxFormatEnumEmptyLinesConfig> = section.enumEmptyLines;
		if (enumSection != null) {
			if (enumSection.existingBetweenFields != null)
				opt.existingBetweenFields = keepEmptyLinesToRuntime(enumSection.existingBetweenFields);
			if (enumSection.betweenFields != null) opt.betweenEnumCtors = enumSection.betweenFields;
			if (enumSection.beginType != null) opt.beginType = enumSection.beginType;
			if (enumSection.endType != null) opt.endType = enumSection.endType;
		}
		// ω-typedef-between-fields: `typedefEmptyLines` routes the four
		// sub-keys to the dedicated typedef-scoped knobs (no shared-knob
		// last-write-wins, unlike `enumEmptyLines`). Drives the
		// `HxType.Anon.fields` `@:sep`-Star force-multi blank inserts when
		// the descendant anon body carries `_inTypedefBody == true`.
		final typedefSection: Null<HxFormatTypedefEmptyLinesConfig> = section.typedefEmptyLines;
		if (typedefSection != null) {
			if (typedefSection.existingBetweenFields != null)
				opt.typedefExistingBetweenFields = keepEmptyLinesToRuntime(typedefSection.existingBetweenFields);
			if (typedefSection.betweenFields != null) opt.typedefBetweenFields = typedefSection.betweenFields;
			if (typedefSection.beginType != null) opt.typedefBeginType = typedefSection.beginType;
			if (typedefSection.endType != null) opt.typedefEndType = typedefSection.endType;
		}
		if (section.afterPackage != null) opt.afterPackage = section.afterPackage;
		if (section.beforePackage != null) opt.beforePackage = section.beforePackage;
		if (section.afterFileHeaderComment != null) opt.afterFileHeaderComment = section.afterFileHeaderComment;
		if (section.betweenMultilineComments != null) opt.betweenMultilineComments = section.betweenMultilineComments;
		if (section.betweenSingleLineTypes != null) opt.betweenSingleLineTypes = section.betweenSingleLineTypes;
		// ω-max-anywhere-in-file: feed the JSON `emptyLines.maxAnywhereInFile`
		// knob into the generic `Renderer.render` cap parameter via
		// `WriteOptions.maxConsecutiveBlanks`. Fork's `@:default(1)` matches
		// our `HaxeFormat.defaultWriteOptions` default, so the override only
		// kicks in when the fixture explicitly sets a different value.
		if (section.maxAnywhereInFile != null) opt.maxConsecutiveBlanks = section.maxAnywhereInFile;
		// ω-D5-curly-blanks-fork-default: see `loadHxFormatJson` head — fork
		// canonical `Remove` is re-applied at JSON-load entry before this
		// section runs, so here we only honour an explicit JSON override.
		if (section.afterLeftCurly != null) opt.afterLeftCurly = keepEmptyLinesToRuntime(section.afterLeftCurly);
		if (section.beforeRightCurly != null) opt.beforeRightCurly = keepEmptyLinesToRuntime(section.beforeRightCurly);
		final importAndUsing: Null<HxFormatImportAndUsingConfig> = section.importAndUsing;
		if (importAndUsing != null) {
			if (importAndUsing.beforeUsing != null) opt.beforeUsing = importAndUsing.beforeUsing;
			if (importAndUsing.betweenImports != null) opt.betweenImports = importAndUsing.betweenImports;
			final levelRaw: Null<String> = importAndUsing.betweenImportsLevel;
			if (levelRaw != null) {
				final mapped: Null<HxBetweenImportsLevel> = betweenImportsLevelFromString(levelRaw);
				if (mapped != null) opt.betweenImportsLevel = mapped;
			}
			if (importAndUsing.beforeType != null) opt.beforeType = importAndUsing.beforeType;
			if (importAndUsing.keepSourceBlankAcrossConditional != null)
				opt.keepSourceBlankAcrossConditional = importAndUsing.keepSourceBlankAcrossConditional;
		}
	}

	/**
	 * Map a haxe-formatter `betweenImportsLevel` string token to the
	 * runtime enum. Mirrors fork's `BetweenImportsEmptyLinesLevel` JSON
	 * encoding (`"all"` / `"firstLevelPackage"` / … / `"fullPackage"`).
	 * Unknown tokens return `null` and the caller leaves the existing
	 * `opt.betweenImportsLevel` (defaults `All`) intact — same lenient
	 * behaviour as the rest of the loader's enum mappings.
	 */
	private static function betweenImportsLevelFromString(raw: String): Null<HxBetweenImportsLevel> {
		return switch raw {
			case 'all': HxBetweenImportsLevel.All;
			case 'firstLevelPackage': HxBetweenImportsLevel.FirstLevelPackage;
			case 'secondLevelPackage': HxBetweenImportsLevel.SecondLevelPackage;
			case 'thirdLevelPackage': HxBetweenImportsLevel.ThirdLevelPackage;
			case 'fourthLevelPackage': HxBetweenImportsLevel.FourthLevelPackage;
			case 'fifthLevelPackage': HxBetweenImportsLevel.FifthLevelPackage;
			case 'fullPackage': HxBetweenImportsLevel.FullPackage;
			case _: null;
		};
	}

	private static function sameLineToRuntime(policy: HxFormatSameLinePolicy): SameLinePolicy {
		return switch policy {
			case HxFormatSameLinePolicy.Next: SameLinePolicy.Next;
			case HxFormatSameLinePolicy.Keep: SameLinePolicy.Keep;
			case _: SameLinePolicy.Same;
		};
	}

	private static inline function trailingCommaToBool(policy: HxFormatTrailingCommaPolicy): Bool {
		return policy == HxFormatTrailingCommaPolicy.Yes;
	}

	private static function bodyPolicyToRuntime(policy: HxFormatBodyPolicy): BodyPolicy {
		return switch policy {
			case HxFormatBodyPolicy.Same: BodyPolicy.Same;
			case HxFormatBodyPolicy.Next: BodyPolicy.Next;
			case HxFormatBodyPolicy.FitLine: BodyPolicy.FitLine;
			case HxFormatBodyPolicy.Keep: BodyPolicy.Keep;
			case _: BodyPolicy.Same;
		};
	}

	private static function leftCurlyToRuntime(policy: HxFormatLeftCurlyPolicy): BracePlacement {
		return switch policy {
			case HxFormatLeftCurlyPolicy.Before | HxFormatLeftCurlyPolicy.Both: BracePlacement.Next;
			case _: BracePlacement.Same;
		};
	}

	private static function emptyCurlyToRuntime(policy: HxFormatEmptyCurlyPolicy): EmptyCurly {
		return switch policy {
			case HxFormatEmptyCurlyPolicy.Break: EmptyCurly.Break;
			case _: EmptyCurly.Same;
		};
	}

	private static function rightCurlyToRuntime(policy: HxFormatRightCurlyPolicy): RightCurlyPlacement {
		// "before" / "both" → Same (hardline before `}`, default — the
		// trailing newline after `}` is contributed by the outer sibling
		// sep, not by `blockBody`, so `Before` and `Both` collapse).
		// "after" / "none" → Inline (no hardline before `}`).
		return switch policy {
			case HxFormatRightCurlyPolicy.After | HxFormatRightCurlyPolicy.None: RightCurlyPlacement.Inline;
			case _: RightCurlyPlacement.Same;
		};
	}

	private static function lineEndCharacterToRuntime(policy: HxFormatLineEndCharacter): String {
		return switch policy {
			case HxFormatLineEndCharacter.CRLF: '\r\n';
			case HxFormatLineEndCharacter.CR: '\r';
			case _: '\n';
		};
	}

	private static function metadataLineEndToRuntime(policy: HxFormatMetadataLineEndPolicy): MetadataLineEndPolicy {
		return switch policy {
			case HxFormatMetadataLineEndPolicy.After: MetadataLineEndPolicy.After;
			case HxFormatMetadataLineEndPolicy.AfterLast: MetadataLineEndPolicy.AfterLast;
			case HxFormatMetadataLineEndPolicy.ForceAfterLast: MetadataLineEndPolicy.ForceAfterLast;
			case _: MetadataLineEndPolicy.None;
		};
	}

	private static function whitespaceToRuntime(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before | HxFormatWhitespacePolicy.OnlyBefore: WhitespacePolicy.Before;
			case HxFormatWhitespacePolicy.After | HxFormatWhitespacePolicy.OnlyAfter: WhitespacePolicy.After;
			case HxFormatWhitespacePolicy.Around: WhitespacePolicy.Both;
			case _: WhitespacePolicy.None;
		};
	}

	/**
	 * ω-condition-parens (Stage C): map a condition-paren `openingPolicy`'s
	 * `before` sub-policy (gap BEFORE the `(` = gap AFTER the keyword) onto
	 * the kw-after `WhitespacePolicy` consumed by `@:fmt(ifPolicy)` etc.
	 * (`After`/`Both` → space). Paren `Before`/`Both`/`OnlyBefore` carry a
	 * before-`(` space → kw `After`; everything else (`After`/`OnlyAfter`/
	 * `None`) → kw `None` (no space). So `openingPolicy: "onlyAfter"`
	 * collapses `if (` to `if(` while still padding the inner `( `.
	 */
	private static function parenGapToKwAfter(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before | HxFormatWhitespacePolicy.OnlyBefore | HxFormatWhitespacePolicy.Around
				| HxFormatWhitespacePolicy.NoneAfter: WhitespacePolicy.After;
			case _: WhitespacePolicy.None;
		};
	}

	/**
	 * ω-condition-parens (Stage C): map a condition-paren `openingPolicy`'s
	 * `after` sub-policy (gap AFTER the `(` = inner `( ` pad) onto the
	 * `WhitespacePolicy` consumed by the `*InsideOpen` knobs through
	 * `whitespacePolicyLead`. Only the after-`(` component belongs to the
	 * inner pad — the before-`(` component is the kw→`(` gap, already owned by
	 * `parenGapToKwAfter`. `After`/`OnlyAfter`/`Around`/`NoneBefore` carry an
	 * inner space → `After`; everything else (incl. `Before`/`OnlyBefore`) →
	 * `None`. Without this split a `before`/`around` policy would also emit a
	 * space BEFORE the `(` via the inner-pad knob, stacking with the gap into a
	 * double `catch  (` / `switch  (` / `} while  (`.
	 */
	private static function parenOpeningToInnerPad(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.After | HxFormatWhitespacePolicy.OnlyAfter | HxFormatWhitespacePolicy.Around
				| HxFormatWhitespacePolicy.NoneBefore: WhitespacePolicy.After;
			case _: WhitespacePolicy.None;
		};
	}

	/**
	 * ω-condition-parens (Stage C): apply one `parenConfig` condition-paren
	 * section to `opt`. `category` is null for the `conditionParens`
	 * catch-all (fans out to if / while / switch / sharp simultaneously),
	 * or one of `'if'|'while'|'switch'|'catch'|'sharp'`. `openingPolicy`
	 * drives the kw→`(` gap (paren-before flipped to the kw-after knob —
	 * reuses `ifPolicy`/`whilePolicy`/`switchPolicy` for those three, the
	 * dedicated `catchParensGap`/`sharpCondParensGap` for the other two)
	 * AND the inner `( ` pad (`openingPolicy` → `*InsideOpen`);
	 * `closingPolicy` drives the inner ` )` pad (`*InsideClose`).
	 */
	private static function applyConditionParens(
		section: Null<HxFormatParenPolicySection>, opt: HxModuleWriteOptions, isCatchAll: Bool, ?category: String
	): Void {
		if (section == null) return;
		final opening: Null<HxFormatWhitespacePolicy> = section.openingPolicy;
		final closing: Null<HxFormatWhitespacePolicy> = section.closingPolicy;
		final gap: Null<WhitespacePolicy> = opening != null ? parenGapToKwAfter(opening) : null;
		final insideOpen: Null<WhitespacePolicy> = opening != null ? parenOpeningToInnerPad(opening) : null;
		final insideClose: Null<WhitespacePolicy> = closing != null ? whitespaceToRuntime(closing) : null;
		if (isCatchAll) {
			for (c in ['if', 'while', 'switch', 'catch', 'sharp']) applyParenTriple(opt, c, gap, insideOpen, insideClose);
			return;
		}
		if (category != null) applyParenTriple(opt, category, gap, insideOpen, insideClose);
	}

	private static function keywordPlacementToRuntime(policy: HxFormatKeywordPlacement): KeywordPlacement {
		return switch policy {
			case HxFormatKeywordPlacement.Next: KeywordPlacement.Next;
			case _: KeywordPlacement.Same;
		};
	}

	private static function commentEmptyLinesToRuntime(policy: HxFormatCommentEmptyLinesPolicy): CommentEmptyLinesPolicy {
		return switch policy {
			case HxFormatCommentEmptyLinesPolicy.None: CommentEmptyLinesPolicy.None;
			case HxFormatCommentEmptyLinesPolicy.One: CommentEmptyLinesPolicy.One;
			case _: CommentEmptyLinesPolicy.Ignore;
		};
	}

	private static function keepEmptyLinesToRuntime(policy: HxFormatKeepEmptyLinesPolicy): KeepEmptyLinesPolicy {
		return switch policy {
			case HxFormatKeepEmptyLinesPolicy.Remove: KeepEmptyLinesPolicy.Remove;
			case _: KeepEmptyLinesPolicy.Keep;
		};
	}

	private static function isAllSpaces(s: String): Bool {
		for (i in 0...s.length) if (s.charCodeAt(i) != ' '.code) return false;
		return true;
	}

	private static function applyWrappingScalars(section: HxFormatWrappingSection, opt: HxModuleWriteOptions): Void {
		if (section.maxLineLength != null) opt.lineWidth = section.maxLineLength;
		if (section.arrayMatrixWrap != null) {
			final resolved: Null<ArrayMatrixWrap> = ArrayMatrixWrap.resolve(section.arrayMatrixWrap);
			if (resolved != null) opt.arrayMatrixWrap = resolved;
		}
	}

	private static function applyWrappingRulesA(section: HxFormatWrappingSection, opt: HxModuleWriteOptions): Void {
		if (section.arrayWrap != null) opt.arrayLiteralWrap = wrapRulesFromConfig(section.arrayWrap, opt.arrayLiteralWrap);
		if (section.multiVar != null) opt.multiVarWrap = wrapRulesFromConfig(section.multiVar, opt.multiVarWrap);
		if (section.casePattern != null) opt.casePatternWrap = wrapRulesFromConfig(section.casePattern, opt.casePatternWrap);
		if (section.anonType != null) opt.anonTypeWrap = wrapRulesFromConfig(section.anonType, opt.anonTypeWrap);
		if (section.methodChain != null) opt.methodChainWrap = wrapRulesFromConfig(section.methodChain, opt.methodChainWrap);
		if (section.opBoolChain != null) opt.opBoolChainWrap = wrapRulesFromConfig(section.opBoolChain, opt.opBoolChainWrap, true);
		if (section.opAddSubChain != null) opt.opAddSubChainWrap = wrapRulesFromConfig(section.opAddSubChain, opt.opAddSubChainWrap, true);
		if (section.callParameter != null) opt.callParameterWrap = wrapRulesFromConfig(section.callParameter, opt.callParameterWrap);
		if (section.objectLiteral != null) opt.objectLiteralWrap = wrapRulesFromConfig(section.objectLiteral, opt.objectLiteralWrap);
		if (section.conditionWrapping != null) opt.conditionWrap = wrapRulesFromConfig(section.conditionWrapping, opt.conditionWrap);
		if (section.ternaryExpression != null) opt.ternaryWrap = wrapRulesFromConfig(section.ternaryExpression, opt.ternaryWrap);
	}

	private static function applyWrappingRulesB(section: HxFormatWrappingSection, opt: HxModuleWriteOptions): Void {
		if (section.functionSignature != null)
			opt.functionSignatureWrap = wrapRulesFromConfig(section.functionSignature, opt.functionSignatureWrap);
		if (section.anonFunctionSignature != null)
			opt.anonFunctionSignatureWrap = wrapRulesFromConfig(section.anonFunctionSignature, opt.anonFunctionSignatureWrap);
		if (section.metadataCallParameter != null)
			opt.metadataCallParameterWrap = wrapRulesFromConfig(section.metadataCallParameter, opt.metadataCallParameterWrap);
		if (section.typeParameter != null) opt.typeParameterWrap = wrapRulesFromConfig(section.typeParameter, opt.typeParameterWrap);
		if (section.expressionWrapping != null)
			opt.expressionWrappingWrap = wrapRulesFromConfig(section.expressionWrapping, opt.expressionWrappingWrap);
		if (section.implementsExtends != null)
			opt.implementsExtendsWrap = wrapRulesFromConfig(section.implementsExtends, opt.implementsExtendsWrap, true);
	}

	private static function applyParenTriple(
		opt: HxModuleWriteOptions, category: String, gap: Null<WhitespacePolicy>, insideOpen: Null<WhitespacePolicy>,
		insideClose: Null<WhitespacePolicy>
	): Void {
		switch category {
			case 'if':
				if (gap != null) opt.ifPolicy = gap;
				if (insideOpen != null) opt.ifCondParensInsideOpen = insideOpen;
				if (insideClose != null)
					opt.ifCondParensInsideClose = insideClose;
			case 'while':
				if (gap != null) opt.whilePolicy = gap;
				if (insideOpen != null) opt.whileCondParensInsideOpen = insideOpen;
				if (insideClose != null)
					opt.whileCondParensInsideClose = insideClose;
			case 'switch':
				if (gap != null) opt.switchPolicy = gap;
				if (insideOpen != null) opt.switchCondParensInsideOpen = insideOpen;
				if (insideClose != null)
					opt.switchCondParensInsideClose = insideClose;
			case _:
				applyParenTripleCatchSharp(opt, category, gap, insideOpen, insideClose);
		}
	}

	private static function applyParenTripleCatchSharp(
		opt: HxModuleWriteOptions, category: String, gap: Null<WhitespacePolicy>, insideOpen: Null<WhitespacePolicy>,
		insideClose: Null<WhitespacePolicy>
	): Void {
		switch category {
			case 'catch':
				if (gap != null) opt.catchParensGap = gap;
				if (insideOpen != null) opt.catchParensInsideOpen = insideOpen;
				if (insideClose != null)
					opt.catchParensInsideClose = insideClose;
			case 'sharp':
				if (gap != null) opt.sharpCondParensGap = gap;
				if (insideOpen != null) opt.sharpCondParensInsideOpen = insideOpen;
				if (insideClose != null)
					opt.sharpCondParensInsideClose = insideClose;
			case _:
		}
	}

}
