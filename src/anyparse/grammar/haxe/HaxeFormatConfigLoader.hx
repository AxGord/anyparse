package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapCondition;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRule;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.format.HxFormatBodyPolicy;
import anyparse.grammar.haxe.format.HxFormatBracesConfigSection;
import anyparse.grammar.haxe.format.HxFormatClassEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatCommentEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatConfig;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatCurlyLineEndPolicy;
import anyparse.grammar.haxe.format.HxFormatEmptyLinesSection;
import anyparse.grammar.haxe.format.HxFormatImportAndUsingConfig;
import anyparse.grammar.haxe.format.HxFormatIndentationSection;
import anyparse.grammar.haxe.format.HxFormatInterfaceEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatKeepEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatKeywordPlacement;
import anyparse.grammar.haxe.format.HxFormatLeftCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatLineEndsSection;
import anyparse.grammar.haxe.format.HxFormatParenConfigSection;
import anyparse.grammar.haxe.format.HxFormatParenPolicySection;
import anyparse.grammar.haxe.format.HxFormatSameLinePolicy;
import anyparse.grammar.haxe.format.HxFormatSameLineSection;
import anyparse.grammar.haxe.format.HxFormatTrailingCommaPolicy;
import anyparse.grammar.haxe.format.HxFormatTrailingCommasSection;
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
 *   `WrapMode`, `cond` strings map to `WrapConditionType`, rules whose
 *   `cond` is still unmodelled (`lineLength >= n`) are dropped so the
 *   cascade falls through cleanly. Absent keys preserve the runtime
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
 * - `sameLine.expressionIf` (ω-expr-body-keep): enum string. Parsed
 *   through the schema for unknown-key validation but only the
 *   `keep` value is honoured at runtime — fans out into all three
 *   knobs `expressionIfBody` / `expressionElseBody` /
 *   `expressionForBody`. Other values (`same` / `next` / `fitLine`)
 *   are currently ignored: `BodyPolicy.Next` on the inner body
 *   force-breaks legitimate inline arrow bodies because the
 *   bodyPolicyWrap engine cannot derive surrounding-context fit.
 *   Default at the WriteOptions level is already `Keep` so the
 *   honoured branch is a no-op; programmatic users can set the
 *   three knobs independently when they need finer control.
 *   Distinct from the statement-level `ifBody` / `elseBody` /
 *   `forBody` defaults (`Next`).
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
 *   maps to `@:fmt(tight)` on `HxType.Arrow` and is fixed at parse
 *   time — no JSON key is exposed.
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
 * - `emptyLines.importAndUsing.beforeUsing` (ω-imports-using-blank):
 *   non-negative Int routed to `opt.beforeUsing`. Default `1` matches
 *   haxe-formatter's `emptyLines.importAndUsing.beforeUsing:
 *   @:default(1)`. Drives the exact number of blank lines at the
 *   `import → using` transition (current decl is `using`, previous decl
 *   is not) — override semantics, not floor: source-captured count is
 *   replaced with this value, so `0` strips the slot and `2` doubles
 *   it. Consecutive `using` decls fall through to source-driven
 *   binary `blankBefore`.
 *
 * Deliberately NOT supported in this slice (no corresponding
 * `HxModuleWriteOptions` field yet): `wrapping.*` beyond
 * `maxLineLength`, other `lineEnds.*` keys (`rightCurly`, `blockCurly`,
 * `anonTypeCurly`, `typedefCurly`, `anonFunctionCurly`, …), other
 * `emptyLines.*` keys
 * (`finalNewline`, `maxAnywhereInFile`, `beforePackage`,
 * `betweenTypes`, per-type-kind sections
 * `macroClassEmptyLines` / `externClassEmptyLines` /
 * `abstractEmptyLines` / `enumEmptyLines` /
 * `typedefEmptyLines`, other `classEmptyLines.*` sub-keys beyond
 * `existingBetweenFields`, …), other `whitespace.*` keys
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
	public static function loadHxFormatJson(json:String):HxModuleWriteOptions {
		final cfg:HxFormatConfig = HxFormatConfigParser.parse(json);
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final result:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
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
			throwBody: base.throwBody,
			catchBody: base.catchBody,
			tryBody: base.tryBody,
			caseBody: base.caseBody,
			expressionCase: base.expressionCase,
			functionBody: base.functionBody,
			untypedBody: base.untypedBody,
			expressionIfBody: base.expressionIfBody,
			expressionElseBody: base.expressionElseBody,
			expressionForBody: base.expressionForBody,
			leftCurly: base.leftCurly,
			objectLiteralLeftCurly: base.objectLiteralLeftCurly,
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
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
			typeParamDefaultEquals: base.typeParamDefaultEquals,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: base.objectLiteralBracesOpen,
			objectLiteralBracesClose: base.objectLiteralBracesClose,
			objectLiteralWrap: base.objectLiteralWrap,
			callParameterWrap: base.callParameterWrap,
			arrayLiteralWrap: base.arrayLiteralWrap,
			anonTypeWrap: base.anonTypeWrap,
			methodChainWrap: base.methodChainWrap,
			opBoolChainWrap: base.opBoolChainWrap,
			opAddSubChainWrap: base.opAddSubChainWrap,
			addLineCommentSpace: base.addLineCommentSpace,
			expressionTry: base.expressionTry,
			indentCaseLabels: base.indentCaseLabels,
			indentObjectLiteral: base.indentObjectLiteral,
			indentComplexValueExpressions: base.indentComplexValueExpressions,
			functionTypeHaxe4: base.functionTypeHaxe4,
			arrowFunctions: base.arrowFunctions,
			afterPackage: base.afterPackage,
			beforeUsing: base.beforeUsing,
			afterMultilineDecl: base.afterMultilineDecl,
			beforeMultilineDecl: base.beforeMultilineDecl,
			formatStringInterpolation: base.formatStringInterpolation,
			blockCommentAdapter: base.blockCommentAdapter,
			lineCommentAdapter: base.lineCommentAdapter,
			endsWithCloseBrace: base.endsWithCloseBrace,
		};
		if (cfg.indentation != null) applyIndentation(cfg.indentation, result);
		if (cfg.wrapping != null) applyWrapping(cfg.wrapping, result);
		if (cfg.sameLine != null) applySameLine(cfg.sameLine, result);
		if (cfg.trailingCommas != null) applyTrailingCommas(cfg.trailingCommas, result);
		if (cfg.lineEnds != null) applyLineEnds(cfg.lineEnds, result);
		if (cfg.whitespace != null) applyWhitespace(cfg.whitespace, result);
		if (cfg.emptyLines != null) applyEmptyLines(cfg.emptyLines, result);
		return result;
	}

	private function new() {}

	private static function applyIndentation(section:HxFormatIndentationSection, opt:HxModuleWriteOptions):Void {
		final character:Null<String> = section.character;
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
	}

	private static function applyWrapping(section:HxFormatWrappingSection, opt:HxModuleWriteOptions):Void {
		if (section.maxLineLength != null) opt.lineWidth = section.maxLineLength;
		if (section.arrayWrap != null) opt.arrayLiteralWrap = wrapRulesFromConfig(section.arrayWrap, opt.arrayLiteralWrap);
		if (section.anonType != null) opt.anonTypeWrap = wrapRulesFromConfig(section.anonType, opt.anonTypeWrap);
		if (section.methodChain != null) opt.methodChainWrap = wrapRulesFromConfig(section.methodChain, opt.methodChainWrap);
		if (section.opBoolChain != null) opt.opBoolChainWrap = wrapRulesFromConfig(section.opBoolChain, opt.opBoolChainWrap);
		if (section.opAddSubChain != null) opt.opAddSubChainWrap = wrapRulesFromConfig(section.opAddSubChain, opt.opAddSubChainWrap);
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
	 * `type` are dropped, and rules with at least one unmodelled `cond`
	 * predicate (currently `lineLength >= n`) are dropped wholesale so
	 * the cascade falls through to the next rule instead of producing
	 * a partially-evaluated decision. A configured `rules: []` resets the
	 * cascade to empty (unconditional `defaultMode`); an absent `rules`
	 * key preserves the runtime baseline cascade.
	 */
	private static function wrapRulesFromConfig(cfg:HxFormatWrapRules, base:WrapRules):WrapRules {
		final defaultMode:WrapMode = cfg.defaultWrap != null
			? wrapModeFromString(cfg.defaultWrap) ?? base.defaultMode
			: base.defaultMode;
		final defaultLocation:Null<WrappingLocation> = cfg.defaultLocation != null
			? wrappingLocationFromString(cfg.defaultLocation) ?? base.defaultLocation
			: base.defaultLocation;
		final src:Null<Array<HxFormatWrapRule>> = cfg.rules;
		if (src == null)
			return {rules: base.rules, defaultMode: defaultMode, defaultLocation: defaultLocation};
		final rules:Array<WrapRule> = [];
		for (raw in src) {
			final mapped:Null<WrapRule> = wrapRuleFromConfig(raw);
			if (mapped != null) rules.push(mapped);
		}
		return {rules: rules, defaultMode: defaultMode, defaultLocation: defaultLocation};
	}

	private static function wrapRuleFromConfig(raw:HxFormatWrapRule):Null<WrapRule> {
		final typeStr:Null<String> = raw.type;
		if (typeStr == null) return null;
		final mode:Null<WrapMode> = wrapModeFromString(typeStr);
		if (mode == null) return null;
		final rawConds:Null<Array<HxFormatWrapCondition>> = raw.conditions;
		final mapped:Array<WrapCondition> = [];
		if (rawConds != null) for (rc in rawConds) {
			final condStr:Null<String> = rc.cond;
			if (condStr == null) return null;
			final ct:Null<WrapConditionType> = wrapCondFromString(condStr);
			if (ct == null) return null;
			final condNarrow:WrapConditionType = ct;
			mapped.push({cond: condNarrow, value: rc.value ?? 0});
		}
		final locStr:Null<String> = raw.location;
		final location:Null<WrappingLocation> = locStr != null ? wrappingLocationFromString(locStr) : null;
		return location != null
			? {conditions: mapped, mode: mode, location: location}
			: {conditions: mapped, mode: mode};
	}

	private static function wrappingLocationFromString(s:String):Null<WrappingLocation> {
		return switch s {
			case 'beforeLast': WrappingLocation.BeforeLast;
			case 'afterLast': WrappingLocation.AfterLast;
			case _: null;
		};
	}

	private static function wrapModeFromString(s:String):Null<WrapMode> {
		return switch s {
			case 'noWrap': WrapMode.NoWrap;
			case 'onePerLine': WrapMode.OnePerLine;
			case 'onePerLineAfterFirst': WrapMode.OnePerLineAfterFirst;
			case 'fillLine': WrapMode.FillLine;
			case 'fillLineWithLeadingBreak': WrapMode.FillLineWithLeadingBreak;
			case _: null;
		};
	}

	private static function wrapCondFromString(s:String):Null<WrapConditionType> {
		return switch s {
			case 'itemCount <= n': WrapConditionType.ItemCountLessThan;
			case 'itemCount >= n': WrapConditionType.ItemCountLargerThan;
			case 'anyItemLength >= n': WrapConditionType.AnyItemLengthLargerThan;
			case 'allItemLengths < n': WrapConditionType.AllItemLengthsLessThan;
			case 'totalItemLength >= n': WrapConditionType.TotalItemLengthLargerThan;
			case 'totalItemLength <= n': WrapConditionType.TotalItemLengthLessThan;
			case 'exceedsMaxLineLength': WrapConditionType.ExceedsMaxLineLength;
			case _: null;
		};
	}

	private static function applySameLine(section:HxFormatSameLineSection, opt:HxModuleWriteOptions):Void {
		if (section.ifElse != null) opt.sameLineElse = sameLineToRuntime(section.ifElse);
		if (section.tryCatch != null) opt.sameLineCatch = sameLineToRuntime(section.tryCatch);
		if (section.doWhile != null) opt.sameLineDoWhile = sameLineToRuntime(section.doWhile);
		if (section.ifBody != null) opt.ifBody = bodyPolicyToRuntime(section.ifBody);
		if (section.elseBody != null) opt.elseBody = bodyPolicyToRuntime(section.elseBody);
		if (section.forBody != null) opt.forBody = bodyPolicyToRuntime(section.forBody);
		if (section.whileBody != null) opt.whileBody = bodyPolicyToRuntime(section.whileBody);
		if (section.doWhileBody != null) opt.doBody = bodyPolicyToRuntime(section.doWhileBody);
		if (section.returnBody != null) opt.returnBody = bodyPolicyToRuntime(section.returnBody);
		if (section.catchBody != null) opt.catchBody = bodyPolicyToRuntime(section.catchBody);
		if (section.tryBody != null) opt.tryBody = bodyPolicyToRuntime(section.tryBody);
		if (section.caseBody != null) opt.caseBody = bodyPolicyToRuntime(section.caseBody);
		if (section.expressionCase != null) opt.expressionCase = bodyPolicyToRuntime(section.expressionCase);
		if (section.functionBody != null) opt.functionBody = bodyPolicyToRuntime(section.functionBody);
		if (section.untypedBody != null) opt.untypedBody = bodyPolicyToRuntime(section.untypedBody);
		// Slice ω-expr-body-keep: the JSON key `sameLine.expressionIf`
		// is parsed via the schema (so unknown-key validation passes)
		// but ONLY `Keep` is honoured at runtime. `Same` / `Next` /
		// `FitLine` for expression-position `if`/`for` bodies need
		// surrounding-context propagation that the bodyPolicyWrap
		// engine cannot derive in isolation (a `Next` on the inner
		// body force-breaks legitimate inline arrow bodies — see
		// `fitline_arrow_body_if.hxtest`). When the user writes
		// `expressionIf: keep` the runtime defaults already give Keep,
		// so the fan-out is a no-op; when they write any other value
		// it is currently ignored. Programmatic users can still set
		// the three knobs independently.
		// ω-expression-case-flat-fanout: HxCaseBranch.body uses
		// `expressionCase` (NOT `expressionIfBody`) as the swap source,
		// so propagating `expressionIf: same/next/fitLine` here would
		// leak into HxIfExpr.thenBranch's `bodyPolicy('expressionIfBody')`
		// and break the existing arrow-body fixture. The Keep-only gate
		// stays.
		if (section.expressionIf != null) {
			final p:BodyPolicy = bodyPolicyToRuntime(section.expressionIf);
			if (p == BodyPolicy.Keep) {
				opt.expressionIfBody = p;
				opt.expressionElseBody = p;
				opt.expressionForBody = p;
			}
		}
		if (section.elseIf != null) opt.elseIf = keywordPlacementToRuntime(section.elseIf);
		if (section.fitLineIfWithElse != null) opt.fitLineIfWithElse = section.fitLineIfWithElse;
		if (section.expressionTry != null) opt.expressionTry = sameLineToRuntime(section.expressionTry);
	}

	private static function applyTrailingCommas(section:HxFormatTrailingCommasSection, opt:HxModuleWriteOptions):Void {
		if (section.arrayLiteralDefault != null)
			opt.trailingCommaArrays = trailingCommaToBool(section.arrayLiteralDefault);
		if (section.callArgumentDefault != null)
			opt.trailingCommaArgs = trailingCommaToBool(section.callArgumentDefault);
		if (section.functionParameterDefault != null)
			opt.trailingCommaParams = trailingCommaToBool(section.functionParameterDefault);
		if (section.objectLiteralDefault != null)
			opt.trailingCommaObjectLits = trailingCommaToBool(section.objectLiteralDefault);
	}

	private static function applyLineEnds(section:HxFormatLineEndsSection, opt:HxModuleWriteOptions):Void {
		if (section.leftCurly != null) {
			final placement:BracePlacement = leftCurlyToRuntime(section.leftCurly);
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
		}
		if (section.objectLiteralCurly != null) {
			final sub:HxFormatCurlyLineEndPolicy = section.objectLiteralCurly;
			if (sub.leftCurly != null) opt.objectLiteralLeftCurly = leftCurlyToRuntime(sub.leftCurly);
		}
	}

	private static function applyWhitespace(section:HxFormatWhitespaceSection, opt:HxModuleWriteOptions):Void {
		if (section.objectFieldColonPolicy != null)
			opt.objectFieldColon = whitespaceToRuntime(section.objectFieldColonPolicy);
		if (section.typeHintColonPolicy != null)
			opt.typeHintColon = whitespaceToRuntime(section.typeHintColonPolicy);
		if (section.typeCheckColonPolicy != null)
			opt.typeCheckColon = whitespaceToRuntime(section.typeCheckColonPolicy);
		if (section.typeParamOpenPolicy != null)
			opt.typeParamOpen = whitespaceToRuntime(section.typeParamOpenPolicy);
		if (section.typeParamClosePolicy != null)
			opt.typeParamClose = whitespaceToRuntime(section.typeParamClosePolicy);
		if (section.binopPolicy != null)
			opt.typeParamDefaultEquals = whitespaceToRuntime(section.binopPolicy);
		if (section.functionTypeHaxe4Policy != null)
			opt.functionTypeHaxe4 = whitespaceToRuntime(section.functionTypeHaxe4Policy);
		if (section.arrowFunctionsPolicy != null)
			opt.arrowFunctions = whitespaceToRuntime(section.arrowFunctionsPolicy);
		if (section.ifPolicy != null)
			opt.ifPolicy = whitespaceToRuntime(section.ifPolicy);
		if (section.forPolicy != null)
			opt.forPolicy = whitespaceToRuntime(section.forPolicy);
		if (section.whilePolicy != null)
			opt.whilePolicy = whitespaceToRuntime(section.whilePolicy);
		if (section.switchPolicy != null)
			opt.switchPolicy = whitespaceToRuntime(section.switchPolicy);
		if (section.tryPolicy != null)
			opt.tryPolicy = whitespaceToRuntime(section.tryPolicy);
		if (section.addLineCommentSpace != null)
			opt.addLineCommentSpace = section.addLineCommentSpace;
		if (section.formatStringInterpolation != null)
			opt.formatStringInterpolation = section.formatStringInterpolation;
		final paren:Null<HxFormatParenConfigSection> = section.parenConfig;
		if (paren != null) {
			final funcParam:Null<HxFormatParenPolicySection> = paren.funcParamParens;
			if (funcParam != null && funcParam.openingPolicy != null)
				opt.funcParamParens = whitespaceToRuntime(funcParam.openingPolicy);
			final call:Null<HxFormatParenPolicySection> = paren.callParens;
			if (call != null && call.openingPolicy != null)
				opt.callParens = whitespaceToRuntime(call.openingPolicy);
			final anonFunc:Null<HxFormatParenPolicySection> = paren.anonFuncParamParens;
			if (anonFunc != null) {
				if (anonFunc.openingPolicy != null)
					opt.anonFuncParens = whitespaceToRuntime(anonFunc.openingPolicy);
				if (anonFunc.removeInnerWhenEmpty != null)
					opt.anonFuncParamParensKeepInnerWhenEmpty = !anonFunc.removeInnerWhenEmpty;
			}
		}
		final braces:Null<HxFormatBracesConfigSection> = section.bracesConfig;
		if (braces != null) {
			final anonType:Null<HxFormatParenPolicySection> = braces.anonTypeBraces;
			if (anonType != null) {
				if (anonType.openingPolicy != null)
					opt.anonTypeBracesOpen = whitespaceToRuntime(anonType.openingPolicy);
				if (anonType.closingPolicy != null)
					opt.anonTypeBracesClose = whitespaceToRuntime(anonType.closingPolicy);
			}
			final objectLit:Null<HxFormatParenPolicySection> = braces.objectLiteralBraces;
			if (objectLit != null) {
				if (objectLit.openingPolicy != null)
					opt.objectLiteralBracesOpen = whitespaceToRuntime(objectLit.openingPolicy);
				if (objectLit.closingPolicy != null)
					opt.objectLiteralBracesClose = whitespaceToRuntime(objectLit.closingPolicy);
			}
		}
	}

	private static function applyEmptyLines(section:HxFormatEmptyLinesSection, opt:HxModuleWriteOptions):Void {
		if (section.afterFieldsWithDocComments != null)
			opt.afterFieldsWithDocComments = commentEmptyLinesToRuntime(section.afterFieldsWithDocComments);
		if (section.beforeDocCommentEmptyLines != null)
			opt.beforeDocCommentEmptyLines = commentEmptyLinesToRuntime(section.beforeDocCommentEmptyLines);
		final classSection:Null<HxFormatClassEmptyLinesConfig> = section.classEmptyLines;
		if (classSection != null) {
			if (classSection.existingBetweenFields != null)
				opt.existingBetweenFields = keepEmptyLinesToRuntime(classSection.existingBetweenFields);
			if (classSection.betweenVars != null) opt.betweenVars = classSection.betweenVars;
			if (classSection.betweenFunctions != null) opt.betweenFunctions = classSection.betweenFunctions;
			if (classSection.afterVars != null) opt.afterVars = classSection.afterVars;
		}
		final interfaceSection:Null<HxFormatInterfaceEmptyLinesConfig> = section.interfaceEmptyLines;
		if (interfaceSection != null) {
			if (interfaceSection.betweenVars != null) opt.interfaceBetweenVars = interfaceSection.betweenVars;
			if (interfaceSection.betweenFunctions != null)
				opt.interfaceBetweenFunctions = interfaceSection.betweenFunctions;
			if (interfaceSection.afterVars != null) opt.interfaceAfterVars = interfaceSection.afterVars;
		}
		if (section.afterPackage != null) opt.afterPackage = section.afterPackage;
		final importAndUsing:Null<HxFormatImportAndUsingConfig> = section.importAndUsing;
		if (importAndUsing != null) {
			if (importAndUsing.beforeUsing != null) opt.beforeUsing = importAndUsing.beforeUsing;
		}
	}

	private static function sameLineToRuntime(policy:HxFormatSameLinePolicy):SameLinePolicy {
		return switch policy {
			case HxFormatSameLinePolicy.Next: SameLinePolicy.Next;
			case HxFormatSameLinePolicy.Keep: SameLinePolicy.Keep;
			case _: SameLinePolicy.Same;
		};
	}

	private static inline function trailingCommaToBool(policy:HxFormatTrailingCommaPolicy):Bool {
		return policy == HxFormatTrailingCommaPolicy.Yes;
	}

	private static function bodyPolicyToRuntime(policy:HxFormatBodyPolicy):BodyPolicy {
		return switch policy {
			case HxFormatBodyPolicy.Same: BodyPolicy.Same;
			case HxFormatBodyPolicy.Next: BodyPolicy.Next;
			case HxFormatBodyPolicy.FitLine: BodyPolicy.FitLine;
			case HxFormatBodyPolicy.Keep: BodyPolicy.Keep;
			case _: BodyPolicy.Same;
		};
	}

	private static function leftCurlyToRuntime(policy:HxFormatLeftCurlyPolicy):BracePlacement {
		return switch policy {
			case HxFormatLeftCurlyPolicy.Before | HxFormatLeftCurlyPolicy.Both: BracePlacement.Next;
			case _: BracePlacement.Same;
		};
	}

	private static function whitespaceToRuntime(policy:HxFormatWhitespacePolicy):WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before | HxFormatWhitespacePolicy.OnlyBefore: WhitespacePolicy.Before;
			case HxFormatWhitespacePolicy.After | HxFormatWhitespacePolicy.OnlyAfter: WhitespacePolicy.After;
			case HxFormatWhitespacePolicy.Around: WhitespacePolicy.Both;
			case _: WhitespacePolicy.None;
		};
	}

	private static function keywordPlacementToRuntime(policy:HxFormatKeywordPlacement):KeywordPlacement {
		return switch policy {
			case HxFormatKeywordPlacement.Next: KeywordPlacement.Next;
			case _: KeywordPlacement.Same;
		};
	}

	private static function commentEmptyLinesToRuntime(policy:HxFormatCommentEmptyLinesPolicy):CommentEmptyLinesPolicy {
		return switch policy {
			case HxFormatCommentEmptyLinesPolicy.None: CommentEmptyLinesPolicy.None;
			case HxFormatCommentEmptyLinesPolicy.One: CommentEmptyLinesPolicy.One;
			case _: CommentEmptyLinesPolicy.Ignore;
		};
	}

	private static function keepEmptyLinesToRuntime(policy:HxFormatKeepEmptyLinesPolicy):KeepEmptyLinesPolicy {
		return switch policy {
			case HxFormatKeepEmptyLinesPolicy.Remove: KeepEmptyLinesPolicy.Remove;
			case _: KeepEmptyLinesPolicy.Keep;
		};
	}

	private static function isAllSpaces(s:String):Bool {
		for (i in 0...s.length) if (s.charCodeAt(i) != ' '.code) return false;
		return true;
	}
}
