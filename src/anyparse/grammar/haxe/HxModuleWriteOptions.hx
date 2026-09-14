package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.OperatorSpacing;
import anyparse.format.OptionalSemicolon;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;

/**
 * Write options specific to the Haxe module grammar (`HxModule`), mixed into the base `WriteOptions` shape via
 * struct intersection so the macro-generated writer sees one fully populated struct at runtime. Defaults live
 * in `HaxeFormat.defaultWriteOptions`; `hxformat.json` ingest lives in `HaxeFormatConfigLoader`; the JSON path
 * each knob answers to is the schema field in `format/HxFormat*Section.hx` / `HxFormatConfig.hx`, tabulated in
 * `docs/haxe-format-config.md`. A knob's SEMANTICS — what each value does at the site — is the contract of the
 * grammar field that carries the matching `@:fmt(...)` meta, and lives in that field's doc; this typedef only
 * names the knob families:
 *
 * - Same-line policies (`SameLinePolicy`: `sameLineElse`, `sameLineCatch`, `sameLineDoWhile`,
 *   `sameLineExpressionElse`, `expressionTry`); `Keep` reads a trivia-mode source-shape slot and degrades to
 *   `Same` in plain mode.
 * - Body-placement policies (`BodyPolicy`: `ifBody` … `untypedBody`, `caseBody` / `expressionCase`,
 *   `returnBody` / `throwBody`, the `expression*Body` trio); `Same` keeps the body inline, `Next` pushes it
 *   one indent deeper, `FitLine` keeps it flat when it fits within `lineWidth`, `Keep` preserves the source
 *   layout. A block body (`{ … }`) carries its own hardlines, so the separator before `{` ignores the policy.
 * - Brace placement and empty bodies (`BracePlacement` / `EmptyCurly` / `RightCurlyPlacement`, global plus
 *   per-construct `objectLiteral*`, `anonType*`, `anonFunction*`, `block*`); the loader cascades each global
 *   `lineEnds.leftCurly` / `emptyCurly` / `rightCurly` value into its own per-construct knobs, and a
 *   per-construct sub-key overrides the cascade.
 * - Whitespace policies (`WhitespacePolicy` around `:` / `=` / `->` / `&` and the keyword-to-paren gaps
 *   `ifPolicy` … `tryPolicy`); a value with no padding point at a site is accepted for parity and produces
 *   nothing.
 * - Trailing commas (`trailingComma*`, effective only when the enclosing Group breaks).
 * - Wrap-rules cascades (`WrapRules`, evaluated by `WrapList.emit` / `BinaryChainEmit.emit`: the helper
 *   measures item count and max/total flat width, runs the cascade for both `exceeds` values and picks
 *   `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` / `FillLine`, wrapping the result in `Group(IfBreak(brk,
 *   flat))` when the two disagree).
 * - Blank-line knobs: class-member policies and `Int` counts (an `Int` is an OVERRIDE of the source count, not
 *   a floor; any positive inter-member count collapses to one blank), type-body head/tail blanks,
 *   statement-block interior blanks, and the module-level cascade whose priority order is documented on
 *   `HxModule.decls`.
 * - Indentation, interpolation and metadata line-end flags.
 *
 * Underscore-prefixed fields are internal write-time channels, not user-facing knobs: no JSON loader entry, no
 * `hxformat.json` ingest. They are set by a `@:fmt(propagate*)` / `setBoolFlagFromStarCtor` meta on the
 * descending field and propagate through the standard opt-fanout copy; each field's own doc names its setter
 * and its readers.
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse: SameLinePolicy,
	sameLineCatch: SameLinePolicy,
	sameLineDoWhile: SameLinePolicy,
	sameLineExpressionElse: SameLinePolicy,
	trailingCommaArrays: Bool,
	trailingCommaArgs: Bool,
	trailingCommaParams: Bool,
	trailingCommaObjectLits: Bool,
	trailingCommaAnonTypes: Bool,
	ifBody: BodyPolicy,
	elseBody: BodyPolicy,
	forBody: BodyPolicy,
	whileBody: BodyPolicy,
	doBody: BodyPolicy,
	returnBody: BodyPolicy,
	returnBodySingleLine: BodyPolicy,
	throwBody: BodyPolicy,
	catchBody: BodyPolicy,
	tryBody: BodyPolicy,
	caseBody: BodyPolicy,
	expressionCase: BodyPolicy,
	functionBody: BodyPolicy,
	anonFunctionBody: BodyPolicy,
	untypedBody: BodyPolicy,
	expressionIfBody: BodyPolicy,
	expressionElseBody: BodyPolicy,
	expressionForBody: BodyPolicy,
	expressionIfWithBlocks: Bool,
	expressionIfWithBrackets: Bool,
	leftCurly: BracePlacement,
	emptyCurly: EmptyCurly,
	objectLiteralLeftCurly: BracePlacement,
	anonTypeLeftCurly: BracePlacement,
	anonFunctionLeftCurly: BracePlacement,
	anonFunctionEmptyCurly: EmptyCurly,
	blockLeftCurly: BracePlacement,
	blockEmptyCurly: EmptyCurly,
	blockRightCurly: RightCurlyPlacement,
	anonFunctionRightCurly: RightCurlyPlacement,
	anonTypeRightCurly: RightCurlyPlacement,
	objectLiteralRightCurly: RightCurlyPlacement,
	objectFieldColon: WhitespacePolicy,
	typeHintColon: WhitespacePolicy,
	typeCheckColon: WhitespacePolicy,
	funcParamParens: WhitespacePolicy,
	callParens: WhitespacePolicy,
	anonFuncParens: WhitespacePolicy,

	/**
	 * When `true`, an empty anonymous-function parameter list emits a single inside space
	 * (`function ( ) body`); the loader inverts upstream `anonFuncParamParens.removeInnerWhenEmpty`.
	 * Read by `HxFnExpr.params` through `sepList`'s `keepInnerWhenEmpty` arg — orthogonal to
	 * `anonFuncParens`.
	 */
	anonFuncParamParensKeepInnerWhenEmpty: Bool,
	ifPolicy: WhitespacePolicy,
	forPolicy: WhitespacePolicy,
	whilePolicy: WhitespacePolicy,

	/**
	 * Trailing space after `switch`, for all four switch ctors. Caller trap: for the bare form
	 * (`switch cond { … }`) `Before` / `None` produce `switchcond` — a syntax error; keep the default
	 * there.
	 */
	switchPolicy: WhitespacePolicy,

	/**
	 * Leading space before the `switch` keyword — the `before` / `around`
	 * side of the fork's `whitespace.switchPolicy`, kept separate from the
	 * (conflated) `switchPolicy` field so the `conditionParens` overwrite
	 * does not erase it. Visible only when the keyword follows a tight `(`
	 * (a call argument `f( switch …)` or an expression paren `( switch …)`).
	 */
	switchKwLeadingSpace: Bool,
	tryPolicy: WhitespacePolicy,
	elseIf: KeywordPlacement,

	/**
	 * omega-else-switch: keyword placement for a `switch` BRANCH of an `if`, the
	 * twin of `elseIf` for the other keyword-headed statement a branch
	 * idiomatically carries. `Same` glues it to its keyword's line
	 * (`if (c) switch s { … } else switch s { … }`), `Next` puts it on the next
	 * line, `Keep` (the default) has no opinion and lets the field's own
	 * `ifBody` / `elseBody` policy decide - which is what makes the knob
	 * byte-inert for every config that does not set it.
	 *
	 * Fed by `sameLine.elseSwitch`; read at BOTH branches of `HxIfStmt` and
	 * `HxIfExpr` through `@:fmt(elseSwitch(...))`, which names the `switch` ctors
	 * itself so the core macro spells no grammar ctor. Arming a THEN branch owns
	 * a second seam the else branch never needed: the glued `switch` closes in
	 * the head's own column, so the following `else` cuddles that `}` exactly as
	 * it cuddles a block's (`PrevBodyInfo.headGlue`).
	 */
	elseSwitch: KeywordPlacement,
	fitLineIfWithElse: Bool,

	/**
	 * omega-arrow-value-if-reflow: when `true`, a value-`if`/`else` chain in
	 * an arrow-lambda body becomes one width-decided unit instead of a
	 * per-branch policy cascade - the whole chain renders flat when it fits
	 * at its column, otherwise one arm per line with each branch value glued
	 * to its own condition. Default `false` keeps the `expressionIfBody` /
	 * `expressionElseBody` policies in charge (fork parity), where a
	 * flat-fitting chain in an arrow body still explodes.
	 *
	 * Read at the `HxIfExpr` sites (`arrowValueIfReflow` on the typedef,
	 * `arrowValueIfReflowSite` on both branches) and gated at runtime on
	 * `_inArrowLambdaBody`, on `_arrowValueIfBlocked` (an ancestor member's
	 * refusal) and on an `else`-spine walk for captured comments - a chain
	 * carrying a comment ANYWHERE keeps the policy shape, in one piece.
	 *
	 * "In an arrow-lambda body" is the reach of `_inArrowLambdaBody`, which
	 * is slightly wider than the immediate body: it also survives a
	 * `cast(..., T)` operand, a `untyped` / `@:meta` prefix, and an
	 * enclosing value-`if`'s CONDITION. Those three positions re-flow too,
	 * idempotently; `HxIfExpr`'s own doc lists them. Fed by
	 * `sameLine.expressionIfArrowBodyReflow`.
	 */
	expressionIfArrowBodyReflow: Bool,

	/**
	 * omega-value-if-fit: when `true`, a value-position `if` / `else if` chain is decided by FIT
	 * instead of always exploding — flat on one line when it fits at its column, and otherwise the
	 * EXACT shape the `expressionIfBody` / `expressionElseBody` policies produce today (each branch
	 * value on its own indented line, `else` back at the `if`'s indent).
	 *
	 * Mechanically it is the sibling of `expressionIfArrowBodyReflow` and shares its three seams: the
	 * `Group` wrapping the node, the soft pre-`else` gap, and the branch gap. The two differ in ONE
	 * place — the arrow knob forces each branch policy to `Same`, gluing the value to its condition,
	 * so a broken chain reads `if (c) v` / `else if (d) v` / `else v`; this knob instead softens the
	 * branch gap's own `Line('\n')` to `Line(' ')`, so a broken chain keeps the policy layout and only
	 * a FITTING one collapses. Both are the same idea: give the chain one break axis and let the group
	 * decide it for every arm at once.
	 *
	 * Gated on expression position rather than on `_inArrowLambdaBody`, so it covers every value-`if`
	 * — an initializer, a `return`, a call argument. An arrow body under BOTH knobs keeps the arrow
	 * shape: that gate is checked first. Default `false` keeps every value-`if` exploding (fork
	 * parity). Fed by `sameLine.expressionIfFit`.
	 */
	expressionIfFit: Bool,

	/**
	 * omega-value-if-fit branch cap: the largest number of VALUE BRANCHES an `expressionIfFit` chain
	 * may hold and still be allowed to collapse onto one line. `if (c) a else b` is 2, `if (c) a else
	 * if (d) b else e` is 3. `0` (default) means no cap -- every fitting chain collapses, the
	 * pre-cap behaviour.
	 *
	 * Width alone is the wrong gate for this: a three-branch chain of short atoms fits 140 columns
	 * easily and still reads as two decisions crammed into one line, while the same width buys a
	 * two-branch chain nothing but a saved line. The count is what the reader parses, so the count is
	 * what the knob measures. Refusing a chain leaves it on the exact `expressionIf` policy layout,
	 * the same answer the knob-off path gives. Fed by `sameLine.expressionIfFitMaxBranches`.
	 */
	expressionIfFitMaxBranches: Int,

	/**
	 * omega-elseif-comment-reflow: when `true`, an `else if` whose nested `if`
	 * carries EXACTLY one interposed `//` line comment glues as usual and
	 * re-emits that comment at the end of the nested `if`'s head line - after
	 * the then-body's `{` when it is braced, after the condition's `)` when the
	 * body policy already puts a bare body on the next line. Both are the same
	 * structural position: the first unconditional break after the condition.
	 *
	 * Default `false` keeps the pre-knob layout, which is what the old
	 * haxe-formatter produced and what the writer round-trips byte for byte:
	 * `else` alone on its line, the comment one indent deeper, the nested
	 * `if` back at the outer indent.
	 *
	 * Read at `HxIfStmt.elseBody` (`@:fmt(elseIfCommentReflow)`) on the
	 * `elseIf` glue path only, and refused - layout unchanged - for a block
	 * comment, for more than one comment, for a same-line comment cuddled to
	 * the `else` itself, for a nested `if` head that ALREADY carries a trailing
	 * `//`, for an EMPTY then-body (`{}` closes on the head line, so the next
	 * break already belongs to that `if`'s own `else`), and whenever the nested
	 * `if`'s own emission offers no provable head-line anchor (a body that
	 * renders flat, or any Doc shape the walk cannot name).
	 * `sameLine.elseBody: "keep"` also disables it: a `Keep`
	 * policy routes the else through `buildBodyKeepLayout`, which the knob does
	 * not reach.
	 *
	 * Width never causes a refusal - an over-long glued head line is accepted
	 * rather than re-wrapped - but the relocated comment does stay visible to a
	 * `conditionWrapping` probe that measures the whole rendered line, exactly
	 * as a hand-written trailing comment in that position would; hiding it
	 * there would cost idempotence. Statement position only - the value-position
	 * twin `HxIfExpr` is out of scope. Fed by `sameLine.elseIfCommentReflow`.
	 */
	elseIfCommentReflow: Bool,

	/**
	 * ω-fitline-body-glue: when a `FitLine` construct body (`if` / `for` /
	 * `while`) does not fit on the header line, may it stay GLUED to that line
	 * and break inside itself, instead of always moving one line down and one
	 * indent deeper?
	 *
	 * Only bodies the next line would NOT rescue are affected: the probe asks
	 * whether the body's flat width fits at the continuation indent, and when it
	 * does the body still takes its own line exactly as before. When it does not,
	 * moving it buys nothing — it breaks internally either way — so the glue saves
	 * a line and an indent level:
	 *
	 * ```
	 * if (c)                 →   if (c) ({
	 *     ({                          field: value, …
	 *         field: value, …    })
	 *     })
	 * ```
	 *
	 * The glue itself stays width-gated by `BodyFit.glueLayout`, so the header
	 * line can never run past `maxLineLength` because of it.
	 *
	 * The ARROW-LAMBDA body (`xs.map(m -> ({ … }))`) takes the same answer through
	 * `BodyFit.continuationRescuesArrowBody`: it is the other placement that puts
	 * a body after a header token instead of under it, and it asked the same
	 * question with only one of the two answers available. There the glue is
	 * additionally scoped to a body that IS an expression paren — every other
	 * arrow body measured WORSE glued (an `if` body explodes its own condition at
	 * the deeper column), so only the shape that provably pays is accepted.
	 *
	 * Default `false` is the haxe-formatter layout the corpus pins. Fed by
	 * `sameLine.fitLineBodyGlue`; consumed by `WriterLowering.buildBodyFitExpr`'s
	 * construct-group arm and by the two `@:fmt(arrowBodyLineWrap)` emit sites, so
	 * it reaches exactly the bodies whose placement those own — a `Keep` / `Same` /
	 * `Next` body policy never sees it.
	 */
	fitLineBodyGlue: Bool,

	/**
	 * ω-loop-body-if-else-next: break a `for` / `while` / `do … while` header
	 * away from a body that is an `if` carrying an `else`, placing the whole
	 * `if`/`else` one line down and one indent step in.
	 *
	 * Under `fitLine` a one-line-able body glues to the loop header, under
	 * `same` any body does, and under `keep` a source-glued one is reproduced.
	 * For a bare guard `if` that is the point — `for (x in xs) if
	 * (c) f(x);` is a deliberate idiom and stays glued. For an `if` that owns an
	 * `else`, the same glue leaves the `else` at the LOOP's indent, where it
	 * reads as a branch of the loop rather than of the `if`.
	 *
	 * The gate is therefore the BODY's shape, asked at runtime through
	 * `anyparse.format.LoopBodyShape.isIfWithElse`. That is what config alone
	 * cannot express: `forBody: next` produces the same layout for the `if`/
	 * `else` pair but moves the guard idiom under the header too.
	 *
	 * Distinct from `fitLineIfWithElse` one storey down, which asks whether the
	 * `if` BEING placed has an `else` sibling of its own. That flag is shared
	 * with upstream semantics and is deliberately not widened to loops.
	 *
	 * Default `false` is fork parity. Fed by `sameLine.loopBodyIfElseNext`;
	 * consumed by `WriterBodyPolicyLowering.buildBodyCoreWrap`, which substitutes
	 * `BodyPolicy.Next` for whatever placement the config chose, at each of the
	 * three fields carrying `@:fmt(loopBodyIfElseNext(...))` — so `Same`, `Keep`
	 * and `FitLine` all obey it; gating the `FitLine` LAYOUT alone left a config
	 * on `same` / `keep` unable to decline the defect the key names.
	 */
	loopBodyIfElseNext: Bool,

	/**
	 * ω-cond-expr-fit: break an expression-scope `#if … #end` region at its
	 * directive seams — the way a regular `if / else if / else` chain breaks —
	 * when the GLUED form does not fit the line. One `GroupWithRestProbe` wraps
	 * the whole `ConditionalExpr` emission, so every seam answers TOGETHER: a
	 * fitting region keeps its spaces, an over-wide one drops each directive
	 * onto its own line at the statement indent with each branch value one
	 * indent step deeper. Off (the default), layout stays purely source-driven.
	 *
	 * Fed by `sameLine.conditionalExprFit`; consumed by the `ConditionalExpr`
	 * ctor's `@:fmt(condExprFitGroup)` wrap, `WriterLowering.padTrailingDoc`'s
	 * `@:fmt(condExprFitBreak)` arm, `nestBodyOnSourceNewlineWrap`'s flat arm,
	 * and the `elseifs` Star's inter-element / trailing-pad separators.
	 */
	conditionalExprFit: Bool,
	ifElseSemicolonNextLine: Bool,
	afterFieldsWithDocComments: CommentEmptyLinesPolicy,

	/**
	 * `Keep` honours the source blank between class members, `Remove` strips it. A strip policy removes only the SOURCE
	 * blank: an add policy on the same slot (`afterFieldsWithDocComments = One`, the inter-member counts) still inserts
	 * one, so `Remove` + `One` yields a blank after a doc-commented member.
	 */
	existingBetweenFields: KeepEmptyLinesPolicy,

	/**
	 * `Keep` / `Remove` that takes over from `existingBetweenFields` when `_classExtern` is true
	 * (`emptyLines.externClassEmptyLines.existingBetweenFields`). `Remove` strips the inter-member
	 * source blank only when the next member's leading cluster carries a trailing `/**` doc comment
	 * preceded by `//` line comments; a regular leading cluster keeps its blanks.
	 */
	externExistingBetweenFields: KeepEmptyLinesPolicy,
	beforeDocCommentEmptyLines: CommentEmptyLinesPolicy,
	betweenVars: Int,
	betweenFunctions: Int,
	afterVars: Int,

	/**
	 * Blanks between an instance var and a static var (either order); with `betweenStaticFunctions`,
	 * fires only where the member Star ALSO carries `@:fmt(staticVarSubdivision)` — class and abstract
	 * members opt in, interface members do not — and only when `_classExtern` is false.
	 */
	afterStaticVars: Int,
	betweenStaticFunctions: Int,
	interfaceBetweenVars: Int,
	interfaceBetweenFunctions: Int,
	interfaceAfterVars: Int,
	betweenEnumCtors: Int,

	/**
	 * Blank lines forced between a class / interface / abstract body's `{` and its first member (`endType`: before its
	 * `}`), the fork's `classEmptyLines.beginType` / `endType`; `0` (the default) defers to `afterLeftCurly` /
	 * `beforeRightCurly`. Enum, `enum abstract` and typedef bodies read their own dedicated knobs below, not these.
	 */
	beginType: Int,

	/**
	 * The `}`-side twin of `beginType`.
	 */
	endType: Int,
	// ω-enum-begin-end: dedicated enum-body begin/end blank knobs (fork's
	// `enumEmptyLines: TypedefFieldsEmptyLinesConfig`, `@:default(0)`). Kept
	// distinct from the class-scoped `beginType` / `endType` so a config that
	// sets `classEmptyLines.beginType` (shared knob) no longer leaks a leading
	// blank into `enum` bodies. Read only by `HxEnumDecl.ctors`' parameterised
	// `@:fmt(beginEndType('enumBeginType', 'enumEndType'))`.
	enumBeginType: Int,
	enumEndType: Int,
	// ω-enumabstract-begin-end: dedicated `enum abstract` body begin/end blank
	// knobs (fork's `enumAbstractEmptyLines: EnumAbstractFieldsEmptyLinesConfig`,
	// `@:default(0)`). `enum abstract` shares the `HxAbstractDecl` grammar with a
	// plain `abstract`, so the writer distinguishes them by the transient
	// `_inEnumAbstract` flag (set by `EnumAbstractDecl(decl)`) rather than a
	// per-type knob-name; when set, the `beginEndType` count reads these instead
	// of the class-scoped `beginType` / `endType`.
	enumAbstractBeginType: Int,
	enumAbstractEndType: Int,
	// ω-typedef-between-fields: dedicated typedef-RHS anon-body blank-line
	// knobs (fork's `TypedefFieldsEmptyLinesConfig`), read only by the
	// `@:sep`-Star force-multi branch under `_inTypedefBody`. Kept distinct
	// from the class-scoped `beginType` / `endType` (which the typedef anon
	// path never reads) so typedef + class scopes never cross-contaminate.
	// `typedefExistingBetweenFields` governs source-blank pass-through when
	// `typedefBetweenFields == 0`; a positive `typedefBetweenFields` forces
	// that exact count regardless of the policy. Defaults `0` / `0` / `Keep`
	// / `0` are fork-parity values.
	typedefBeginType: Int,
	typedefBetweenFields: Int,
	typedefExistingBetweenFields: KeepEmptyLinesPolicy,
	typedefEndType: Int,

	/**
	 * `Keep` / `Remove` for the source blank between a `{` and its first item — a type body, a block body that opts in
	 * through `@:fmt(keepCurlyBlanks)`, an anon type's fields (`beforeRightCurly`: before the matching `}`). On a type
	 * body it is consulted only while `beginType` / `endType` is `0` — a positive count wins and inserts regardless of
	 * source. Compiled default `Keep`; `HaxeFormatConfigLoader` re-baselines both to the fork's `Remove` on any JSON load.
	 */
	afterLeftCurly: KeepEmptyLinesPolicy,

	/**
	 * `Keep` / `Remove` for the source blank between a body's last item and its `}` — the mirror of `afterLeftCurly`,
	 * same sites, same `endType` precedence, same `Remove` re-baseline on JSON load.
	 */
	beforeRightCurly: KeepEmptyLinesPolicy,

	/**
	 * `Keep` / `Collapse` over the blank-line gaps BETWEEN adjacent statements of one block
	 * (`@:fmt(uniformStmtBlanks)` sites — never a type member list). `Keep` (default) round-trips
	 * source blanks; `Collapse` applies "separators that separate everything separate nothing": when
	 * every interior gap is blank the blanks are uniform noise and all get stripped, while a selective
	 * mix (or any comment between statements) is left byte-exact. The head/tail `{` / `}` blanks are
	 * resolved by `afterLeftCurly` / `beforeRightCurly` instead. See `UniformStatementBlanksPolicy`.
	 */
	uniformStatementBlanks: UniformStatementBlanksPolicy,
	typedefAssign: WhitespacePolicy,
	typedefIntersection: WhitespacePolicy,
	typeParamDefaultEquals: WhitespacePolicy,
	typeParamOpen: WhitespacePolicy,
	typeParamClose: WhitespacePolicy,
	anonTypeBracesOpen: WhitespacePolicy,
	anonTypeBracesClose: WhitespacePolicy,
	objectLiteralBracesOpen: WhitespacePolicy,
	objectLiteralBracesClose: WhitespacePolicy,
	// ω-arrow-body-objlit-pad-keep: when `true`, the open-side
	// `objectLiteralBracesOpen` inner pad is applied EVEN when the literal
	// is an arrow-lambda body (`u -> { email: v }`). Default `false`
	// mirrors the fork's `MarkWhitespace.successiveParenthesis`
	// compress-mode `case Arrow: return;` which drops the opening-brace
	// pad after a `->` token (`u -> {email: v }`). Fed by
	// `whitespace.bracesConfig.objectLiteralBraces.arrowBodyOpenPad`.
	objectLiteralArrowBodyOpenPad: Bool,
	// ω-arrow-body-objlit-reflow: when `true`, a source-multiline object
	// literal that is an arrow-lambda body drops its source newlines and
	// the wrap cascade re-flows it by width (`u -> { a: 1 }` when it
	// fits). Default `false` keeps the source-multiline force-multi
	// shape (fork parity). Fed by `whitespace.bracesConfig.
	// objectLiteralBraces.arrowBodyReflow`.
	objectLiteralArrowBodyReflow: Bool,
	// ω-single-stmt-braces: when `true`, the writer drops the curly braces
	// around an `if` / `else` / `for` / `while` body whose block holds
	// exactly one safe single statement (`if (c) { return x; }` →
	// `if (c) return x;`). Safety gates (dangling-else, comments,
	// terminator, declaration scoping) live in
	// `anyparse.format.SingleStmtBraces.unwrapStmt` — every gate fails
	// closed (keeps braces). Trivia-mode writer only; the plain writer
	// ignores the knob. Default `false` (keep braces — byte-inert). Fed by
	// `whitespace.bracesConfig.singleStatementBraces` (`"remove"` → true).
	dropSingleStmtBraces: Bool,
	// omega-brace-symmetry: the OTHER direction of the same policy - when `true`, a
	// branch that arrives BARE opposite a brace-keeping sibling GAINS braces
	// (`if (a) { p(); q(); } else r();` -> a fully braced if/else). It is what
	// `singleStatementBraces: "remove"` has always done as gate 7's repair arm, split
	// out so a config can ask for the repair WITHOUT the removal:
	// `"remove"` sets both, `"symmetric"` sets only this one, `"keep"` neither.
	// The three surfaces it arms are the three gate 7 / gate 8 repairs already
	// written: the statement if/else pair, the value-`if` pair
	// (`@:fmt(valueBraceSymmetry)`) and the try/catch group
	// (`@:fmt(tryBraceSymmetry)`). Trivia-mode writer only. Default `false` -
	// byte-inert. Fed by `whitespace.bracesConfig.singleStatementBraces`.
	singleStmtBraceSymmetry: Bool,
	// omega-cond-directive-binop: spacing for the `&&` / `||` inside a `#if` /
	// `#elseif` CONDITION, which the grammar captures as one verbatim text terminal
	// rather than as an expression tree - so `whitespace.binopPolicy`, which acts on
	// operator nodes, never reaches it and the authored spelling has always survived
	// verbatim. `Keep` (the default) is that behaviour; `None` / `Around` normalise
	// it. Fed by `whitespace.conditionalCompilationBinop: true`, which takes the
	// direction from the config's own `binopPolicy` so the two cannot drift.
	// Applied in `anyparse.format.DirectiveCondition.spaceOperators` through the
	// `@:writeNormalize('condOperatorSpacing')` terminal transform.
	condDirectiveOpSpacing: OperatorSpacing,
	// ω-switch-subject-parens: `true` drops the redundant parens around a
	// `switch (subject) { … }` subject (`switch v { … }`); the leading-brace
	// subject carve-out (object literal / block) still keeps them. Covers both
	// statement- and expression-position switch (shared `HxSwitchStmt`
	// grammar). Default `false` (keep parens — byte-inert). Fed by
	// `whitespace.parenConfig.switchSubjectParens` (`"remove"` → true).
	dropSwitchSubjectParens: Bool,
	// ω-optional-semicolon (E11): three-way policy for the `@:trailOpt(';')`
	// statement terminator Haxe lets a `}`-terminated statement omit.
	// `Preserve` (default) re-emits source presence — byte-inert, fork
	// parity. `Always` emits it on every slot carrying
	// `@:fmt(optionalSemicolon(...))`; `Never` drops it wherever that
	// flag's shape gate proves it optional. Trivia-mode writer only; the
	// plain writer keeps its `trailOptShapeGate` AST-shape gate. Fed by
	// `whitespace.optionalSemicolon`.
	optionalSemicolon: OptionalSemicolon,
	// omega-semi-before-else: the SEPARATE three-way policy for the optional
	// `;` Haxe accepts between a value-`if`'s then-branch and its `else`
	// (`final x = if (c) a; else b;`). A distinct key from `optionalSemicolon`
	// because the two answer different questions about the same character: a
	// statement's terminator is a legitimate style choice, while a `;` before
	// `else` is an editing leftover -- a config that wants `Always` for the
	// first wants `Never` for the second, which one shared key cannot express.
	// `Preserve` (default) re-emits source presence (byte-inert, fork parity);
	// `Never` drops it; `Always` emits it. Only ever consulted when the node
	// HAS an `else`: with none, that `;` can be the ENCLOSING statement's own
	// terminator, so source presence always wins there. Fed by
	// `whitespace.semicolonBeforeElse`.
	semicolonBeforeElse: OptionalSemicolon,
	accessBracketsOpen: WhitespacePolicy,
	accessBracketsClose: WhitespacePolicy,
	arrayLiteralBracketsOpen: WhitespacePolicy,
	arrayLiteralBracketsClose: WhitespacePolicy,
	mapLiteralBracketsOpen: WhitespacePolicy,
	mapLiteralBracketsClose: WhitespacePolicy,
	comprehensionBracketsOpen: WhitespacePolicy,
	comprehensionBracketsClose: WhitespacePolicy,
	callParensInsideOpen: WhitespacePolicy,
	callParensInsideClose: WhitespacePolicy,
	// ω-condition-parens: per-condition-paren INNER pad, fed by
	// `whitespace.parenConfig.{if|while|switch}ConditionParens` /
	// `catchParens` / `sharpConditionParens` / `conditionParens`
	// (catch-all). `InsideOpen` (from `openingPolicy.after`) is the inner
	// `( ` pad; `InsideClose` (from `closingPolicy.before`) is the inner
	// ` )` pad. The keyword→`(` gap reuses the existing `ifPolicy` /
	// `whilePolicy` / `switchPolicy` / `tryPolicy` knobs (fed from the
	// same `openingPolicy.before` via a paren→kw flip in the loader);
	// `catchParensGap` / `sharpCondParensGap` are dedicated because catch
	// (`@:kw('catch')`) and `#if` (`HxConditionalStmt`) have no pre-
	// existing gap knob. Default None → tight `if (a)` / `catch (e)`.
	ifCondParensInsideOpen: WhitespacePolicy,
	ifCondParensInsideClose: WhitespacePolicy,
	whileCondParensInsideOpen: WhitespacePolicy,
	whileCondParensInsideClose: WhitespacePolicy,
	switchCondParensInsideOpen: WhitespacePolicy,
	switchCondParensInsideClose: WhitespacePolicy,
	catchParensGap: WhitespacePolicy,
	catchParensInsideOpen: WhitespacePolicy,
	catchParensInsideClose: WhitespacePolicy,
	sharpCondParensGap: WhitespacePolicy,
	sharpCondParensInsideOpen: WhitespacePolicy,
	sharpCondParensInsideClose: WhitespacePolicy,
	objectLiteralWrap: WrapRules,
	callParameterWrap: WrapRules,
	arrayLiteralWrap: WrapRules,
	mapLiteralWrap: WrapRules,
	multiVarWrap: WrapRules,
	casePatternWrap: WrapRules,
	anonTypeWrap: WrapRules,
	methodChainWrap: WrapRules,
	opBoolChainWrap: WrapRules,
	opAddSubChainWrap: WrapRules,
	conditionWrap: WrapRules,
	ternaryWrap: WrapRules,
	functionSignatureWrap: WrapRules,
	anonFunctionSignatureWrap: WrapRules,
	metadataCallParameterWrap: WrapRules,
	typeParameterWrap: WrapRules,
	expressionWrappingWrap: WrapRules,
	implementsExtendsWrap: WrapRules,
	expressionTry: SameLinePolicy,
	indentCaseLabels: Bool,
	indentObjectLiteral: Bool,
	indentComplexValueExpressions: Bool,
	indentVarTypeHintAnon: Bool,
	functionTypeHaxe4: WhitespacePolicy,
	functionTypeHaxe3: WhitespacePolicy,
	intervalPolicy: WhitespacePolicy,
	arrowFunctions: WhitespacePolicy,

	/**
	 * Blank lines forced AFTER a `package` directive by the `blankLinesAfterCtor` cascade on `HxModule.decls` — an
	 * override of the source count, like every count in that cascade (the fork's `emptyLines.afterPackage`).
	 */
	afterPackage: Int,

	/**
	 * Blank lines forced BEFORE a leading `package` directive, read once at file head by the `blankLinesAtHeadIfCtor`
	 * cascade on `HxModule.decls` — an override of the source count. Default `0` keeps the file's leading edge tight
	 * against `package …;`, `1` starts the file with a blank line (the fork's `emptyLines.beforePackage`).
	 */
	beforePackage: Int,
	beforeUsing: Int,
	betweenImports: Int,

	/**
	 * Granularity of the `betweenImports` level test: `All` (default; every same-kind boundary is a
	 * mismatch), `FirstLevelPackage` … `FifthLevelPackage` (compare the first N dot segments),
	 * `FullPackage` (the whole path). Read by the `blankLinesBetweenSameCtorByLevel` cascade on
	 * `HxModule.decls` through the grammar-wired `betweenImportsPathDiffers` adapter.
	 */
	betweenImportsLevel: HxBetweenImportsLevel,
	keepSourceBlankAcrossConditional: Bool,
	beforeType: Int,
	afterMultilineDecl: Int,
	beforeMultilineDecl: Int,
	// ω-after-conditional-block — number of blank lines forced after a
	// module-level `#if … #end` (`HxDecl.Conditional`) whose tail leaf is
	// NEITHER an import / using NOR a type-level decl. Mirrors fork's
	// behaviour: at module top level there is no keep-existing-blanks pass
	// (that only runs inside function bodies), so a `#if … #error … #end`
	// followed by a type decl collapses to zero blanks unless a mark pass
	// re-adds one. Fork's `markImports` re-adds `importAndUsing.beforeType`
	// (=1) when the conditional's tail is an import / using, and
	// `betweenTypes` (=1) re-adds one when the tail is a type-level decl;
	// every other tail (error, package directive, opaque conditional) keeps
	// the module default of 0. Default `0` strips the source blank for those
	// other-tailed conditionals; the import- / type-tailed cases fall
	// through to the source-driven count (kept). See
	// the generated `tailLeafKeepsBlankAfterConditional` for the gate walker.
	afterConditionalBlock: Int,

	/**
	 * Exact blanks AFTER the first top-level block-style comment of a module when fileheader semantics
	 * apply: the decl that comment LEADS is itself a `package` / `import` / `using`, OR it carries 2+
	 * leading comments at module head. Classifying from the head decl rather than a whole-module scan
	 * keeps a doc comment glued to the type it documents in a module whose `import` sits below that
	 * type. Site: `@:fmt(afterFileHeaderCommentBlanks)` on `HxModule.decls`.
	 */
	afterFileHeaderComment: Int,

	/**
	 * Exact blanks BETWEEN two consecutive block-style comments wherever block–block boundaries occur in a
	 * `leadingComments` array or a trailing-orphan array, except the slot `afterFileHeaderComment` already claims.
	 * Site: `@:fmt(betweenMultilineCommentsBlanks)` on `HxModule.decls` and the class / interface / abstract member Stars.
	 */
	betweenMultilineComments: Int,

	/**
	 * Blanks between two consecutive single-line top-level type decls (neither matches the `multiline`
	 * predicate). Insertion-only: the override fires ONLY when the value is `> 0`; at `0` the slot stays
	 * source-driven — this axis never strips blanks. `afterMultilineDecl` / `beforeMultilineDecl` win
	 * when either side is multi-line.
	 */
	betweenSingleLineTypes: Int,
	// ω-blank-around-multiline-members — blank lines forced into the gap
	// between two adjacent TYPE MEMBERS when either of them renders across
	// more than one line. `betweenSingleLineTypes` above is its module-level
	// sibling, but that one resolves multi-line-ness STRUCTURALLY at macro
	// time (a class is multi-line iff it declares members). A field cannot be
	// classified that way — `final a = ['x'];` fits and `final a = [… 20 …];`
	// does not, from the same shape — so this knob is answered by measuring
	// the built Doc instead. `0` (the default) leaves every gap to the
	// source-driven `existingBetweenFields` path.
	aroundMultilineFields: Int,

	/**
	 * When `true` (default) the writer re-emits each `${expr}` segment by recursing into the parsed
	 * `HxExpr`, producing canonical `${a + b}` spacing; when `false` it emits the parser-captured byte
	 * slice between `${` and `}` verbatim. The slice rides `HxStringSegmentT.Block`'s positional
	 * `sourceText` arg (populated under `@:fmt(captureSource)`); plain mode does not capture, so the
	 * knob has no effect there.
	 */
	formatStringInterpolation: Bool,

	/**
	 * Line-end policy for the metadata Star on `HxMemberDecl.meta` (upstream
	 * `lineEnds.metadataFunction`), consumed by `@:fmt(metaLineEndPolicy('metadataFunctionLineEnd'))`.
	 * `None` (default) — source-driven inter-element separator, no forced gap after the last
	 * metadata; `After` — every separator becomes a hardline AND a hardline fires after the last
	 * element (one metadata per line); `AfterLast` — separators stay source-driven, a hardline
	 * ALWAYS fires after the last metadata; `ForceAfterLast` — separators forced to a single space
	 * (source newlines between metas collapse) AND a hardline after the last. Per-construct sisters
	 * (`metadataType` / `metadataVar` / `metadataOther`) do not exist yet.
	 */
	metadataFunctionLineEnd: MetadataLineEndPolicy,

	/**
	 * Set when descending through an expression-position parent (`HxCaseBranch.body` /
	 * `HxDefaultBranch.stmts`, the value-switch ctors, via `@:fmt(propagateExprPosition)`). Read by
	 * the dual-flag `bodyPolicy('caseBody', 'expressionCase')` flat gate: a case nested inside
	 * another case's body inherits the flag and flattens per `expressionCase`, an outer
	 * statement-position `case X:` breaks per `caseBody`.
	 */
	_inExprPosition: Bool,
	// ω-case-sibling-symmetry — ONE placement number for a whole switch's
	// case bodies, written once per switch by the cases Star's
	// `@:fmt(caseSiblingSymmetry(...))` pre-pass and handed to every sibling
	// body. `BodyFit.fitLineLayout` turns it into an `IfIndentWidthExceeds`
	// probe, so all siblings of one switch reach ONE placement verdict: if
	// the number does not fit, every body drops to the next line, including
	// the ones that would fit and the glued ones. THREE values, not two:
	//  - a plain `>= 0` — the WIDTH channel: the widest sibling case
	//    clause's FLAT width (`case <patterns>: <body>`, separator
	//    included);
	//  - `BodyFit.SIBLING_FORCE_BREAK` — the STRUCTURAL channel. Not a
	//    measurement but a verdict, reached because some unit of the switch
	//    renders below its own label at every budget (a multi-statement
	//    body, a flat-refused one, a label-splice region); it is spelled as
	//    an ordinary large width precisely so nothing downstream needs an
	//    arm for it;
	//  - `BodyFit.SIBLING_NONE` (`-1`, the default, and what the pre-pass
	//    records when no sibling could render inline at all) — "no
	//    coordination": every body decides for itself, exactly as before
	//    the slice.
	// `BodyFit.SIBLING_PROBING` (`-2`) also lands here, but only in
	// transit: the pre-pass stamps it for the duration of its own
	// measurement so a nested Star returns its subtree unchanged instead of
	// running a second pre-pass (ω-case-sym-linear). Always written by the
	// pre-pass, never inherited, so a nested switch coordinates its own
	// cases rather than the enclosing switch's.
	_caseSiblingFlatWidth: Int,
	// ω-expressionif-collapse — narrow companion to `_inExprPosition`, set
	// ONLY on the immediate value of a value-yielded `if`/`else` branch
	// (`HxIfExpr.thenBranch` / `elseBranch` carrying
	// `@:fmt(propagateValueIfBranch)`). Read by `HxObjectLit.fields`
	// (`@:fmt(reflowInExprPosition)`) so a source-multiline object literal
	// that is the DIRECT branch value collapses to single-line — mirroring
	// fork's "collapse object literal only when it is a value-if branch
	// body" rule, while leaving source-multiline object literals everywhere
	// else (var-init, call-args, array-elements) untouched. Cleared by
	// `_setExprPosition` on any descent into a fresh expression-position
	// frame (call-arg / array-element / operand / arrow-body) so the flag
	// never leaks into an object literal nested deeper than the immediate
	// branch value. Default `false`.
	_inValueIfBranch: Bool,
	// ω-arrow-body-objlit-pad — sister to `_inValueIfBranch`, set ONLY on the
	// immediate body of an arrow lambda (`HxExpr.ThinArrow` right operand /
	// `HxThinParenLambda.body` carrying `@:fmt(propagateArrowLambdaBody)`).
	// Read by `HxObjectLit.fields` (`@:fmt(arrowBodyOpenPadSuppress)`) to drop
	// the `objectLiteralBracesOpen` inner pad — mirroring fork's
	// `MarkWhitespace.successiveParenthesis` compress-mode `case Arrow:
	// return;`, which never applies the opening-brace policy to a `{`/`(`/`[`
	// whose previous token is `->` (so `u -> {email: v }`, not `u -> { email:
	// v }`, under `objectLiteralBraces.openingPolicy: "after"`). Cleared by
	// `_setExprPosition` on any descent into a fresh expression-position frame
	// (call-arg / array-element / operand / paren inner), so only the
	// LEFTMOST-LEAF object literal of the body — the one whose `{` sits right
	// after the `->` token — sees the flag. Default `false`.
	_inArrowLambdaBody: Bool,
	// omega-arrow-value-if-reflow - set on the branch writes of an `HxIfExpr`
	// that REFUSED the arrow-body reflow (a comment anywhere on its
	// `else`-spine), so every deeper member of the same chain refuses too and
	// the chain renders in ONE shape. Its own field rather than a clear of
	// `_inArrowLambdaBody`: that flag is shared with the object-literal arrow
	// knobs, and borrowing it as a refusal channel silently disabled the
	// objlit open-pad / reflow inside the refused branch. Cleared by
	// `_setExprPosition` on any fresh expression-position frame (call arg,
	// operand, nested arrow body), so it never leaves its own chain. Default
	// `false`.
	_arrowValueIfBlocked: Bool,
	// omega-arrow-value-if-reflow - set on the write of a list ELEMENT that
	// carries a captured trailing comment (`@:fmt(arrowValueIfElemTrail)` on
	// the element's Star), so an arrow-body value-`if` chain inside that
	// element refuses the reflow. The comment sits after the chain's LAST
	// branch value, which is the one position no field of the `HxIfExpr` owns
	// - the slot belongs to the enclosing list element, out of reach of both
	// the `else`-spine walk and `_arrowValueIfBlocked`. Deliberately NOT
	// cleared by `_setExprPosition`: the signal has to cross the call-arg
	// frame AND the arrow-lambda body frame to reach the chain, and it is set
	// per element, so it never spans a sibling. Default `false`.
	_arrowValueIfElemTrailComment: Bool,

	/**
	 * Set by `HxTopLevelDecl.decl` via `@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers',
	 * 'Extern'))` when the sibling `modifiers` Star contains an `Extern` ctor. Read by
	 * `triviaBlockStarExpr`'s `addByInterMemberExpr` to suppress `interMemberBlankLines`-driven blank
	 * emission inside extern decls (the fork's `externClassEmptyLines`); also selects
	 * `externExistingBetweenFields`.
	 */
	_classExtern: Bool,

	/**
	 * Set on descent into an anonymous function body (`HxFnExpr.body`, `HxParenLambda.body`,
	 * `HxThinParenLambda.body`) via `@:fmt(propagateAnonFnContext)`. Readers: the `emptyCurlyBreak`
	 * branch in `triviaBlockStarExpr` dispatches `anonFunctionEmptyCurly` vs global `emptyCurly`;
	 * `HxExpr.BlockExpr.stmts` (`@:fmt(leftCurlyAnonFnOverride('anonFunctionLeftCurly'))`) prepends a
	 * runtime-gated hardline before `{` when the knob is `Next`, then clears the flag so nested
	 * blocks fall back to `blockLeftCurly`.
	 */
	_inAnonFnBody: Bool,

	/**
	 * Set on descent into a typedef RHS type via `@:fmt(propagateTypedefContext)` on
	 * `HxTypedefDecl.type`. Consumed by `@:fmt(forceMultiInTypedef)` on `HxType.Anon.fields`: when
	 * set AND `anonTypeLeftCurly == Next`, the writer threads a runtime `forceMode` predicate into
	 * `WrapList.emit`, bypassing the cascade and laying the anon body out `OnePerLine` even when its
	 * fields fit flat. Cleared per element so nested anons revert to the layout-driven wrap.
	 */
	_inTypedefBody: Bool,
	// ω-enumabstract-begin-end: set on the inner `HxAbstractDecl` opt when it is
	// written as the body of an `enum abstract` (via `EnumAbstractDecl(decl)`'s
	// `@:fmt(propagateEnumAbstractContext)`), so its `beginEndType` blank count
	// reads `enumAbstractBeginType` / `enumAbstractEndType`. Default `false`.
	_inEnumAbstract: Bool,

	/**
	 * `Null<WrapMode>` forcing `BinaryChainEmit.emit`'s cascade to a single mode. Set by the runtime
	 * `_setChainModeOverride(opt, mode)` helper at `@:fmt(condWrap('<knob>'))` sites before the inner
	 * cond Ref writeCall evaluates: it swaps `opBoolChainWrap` and `opAddSubChainWrap` for a fresh
	 * `{rules: [], defaultMode: mode}` cascade so the chain dispatch sees the override transparently.
	 * The mode derives from `opt.<condKnob>.defaultMode`; `NoWrap` / unmappable modes leave it `null`.
	 */
	_chainModeOverride: Null<WrapMode>,
	_callArgChainNest: Bool,
	_suppressMore: Bool,
	_parenInCondition: Bool,
	// ω-compare-operand-linewrap: set on the ternary CONDITION's opt (via
	// `_setInTernaryCond`) so `lowerInfixBranch` suppresses the `==`/`!=`
	// operand-overflow break for a compare that IS a ternary condition -- the
	// fork breaks the ternary `?`/`:`, not the compare. Default false → every
	// non-ternary compare (assignment / chain operand / statement condition)
	// still breaks on a genuine line overflow.
	_inTernaryCond: Bool,
	// omega-call-grouprestprobe-subposition: set on a `Call` subtree that is NOT
	// in statement/expression position, so the `Call` ctor skips the
	// `groupRestProbe` rest-of-line fit bias. Set-sites, all via
	// `_setSuppressCallRestProbe`:
	//  1. Case-pattern body (`HxCasePattern.expr`'s `@:fmt(suppressCallRestProbe)`):
	//     a ctor pattern (`case Nest(_, _) | Concat(_):`) must NOT wrap its args
	//     -- the fork breaks the `|` (BitOr) chain, not the ctor args.
	//  2. `??` (Coalesce) operands (`lowerInfixBranch`): `??` is right-assoc and
	//     renders via the non-chain infix path, so its outer-left operand carries
	//     the whole rest-chain; the rest-probe would over-count and wrap operand
	//     args the fork keeps glued (the fork packs left-to-right, breaking only
	//     the overflowing operand's brackets). Reverts `??` operands to pristine
	//     plain-Group (wrap-on-own-overflow), matching the self-canonical shape.
	//  3. opAddSub / opBool chain leaf operands (`lowerInfixChain`): a `Call` leaf
	//     -- especially the head -- would rest-probe the whole chain tail and split
	//     its own args though the call fits its line; the chain absorbs the overflow
	//     via its operator break / paren-open instead.
	//  4. Nested call arguments (`lowerPostfixStar`, the two `callParameterWrap`
	//     Stars = `HxExpr.Call` / `HxNewExpr`): a `Call` in argument position would
	//     count the outer call's sibling args + trailing `;`; suppressing lets the
	//     OUTER call wrap (open its paren) first while the inner call stays flat.
	// Not cleared on descent, so nested `Call`s inherit it. Default false -> every
	// statement/expression-position call keeps the rest-probe (wraps at limit+1,
	// counting the trailing `;`).
	_suppressCallRestProbe: Bool,
	// ω-complex-item-count: the subtree is a case PATTERN or a switch SUBJECT,
	// so an array literal inside it must not classify its elements for the
	// `complexItemCount >= n` cascade condition. Both positions can hold a shape
	// the classifier cannot tell from a value: an enum-constructor pattern
	// (`case [Some(a), Some(b)]:`) parses as two `Call`s, and the fork never
	// wraps a switch subject at all. Set via `_setSuppressComplexItems` from
	// `@:fmt(suppressComplexItems)` on `HxCasePattern.expr` /
	// `HxSwitchStmt(Bare).expr`; not cleared on descent, so a nested pattern
	// inherits it. Default false → every value-position array classifies.
	_suppressComplexItems: Bool,
	// ω-pattern-rest-probe: the subtree is a case PATTERN body, so NOTHING inside
	// it rest-probes the line. Distinct from `_suppressCallRestProbe`, which the
	// object-literal / array-literal element arm deliberately CLEARS so a nested
	// call in a field VALUE can still wrap, and from `_suppressComplexItems`,
	// which a switch SUBJECT also sets — a subject is a real expression and must
	// keep its rest probe (dropping it left a 141-column `switch f(…) {` header).
	// A pattern is a matching shape, not a value: it never owns the overflow of
	// the line it sits on, and charging it for the trailing `if (guard)` made a
	// 22-column object literal break so a 122-column guard could stay flat. Set
	// via `_setSuppressPatternRestProbe` from `@:fmt(suppressPatternRestProbe)` on
	// `HxCasePattern.expr`; not cleared on descent, so a collection literal and
	// the calls inside it inherit it. Default false → every value-position
	// construct keeps its rest probe.
	_suppressPatternRestProbe: Bool,
	_varKwNewline: Bool,

	/**
	 * Set on descent into a class-member `var` / `final` initializer (NOT a local statement) via
	 * `@:fmt(propagateFieldLevelVar)` on `HxClassMember.VarMember` / `FinalMember`. Consumed by the
	 * `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')` entry on `HxVarDecl.init`: when
	 * set, the knob gate is bypassed (the fork's `Indenter.isFieldLevelVar`).
	 */
	_inFieldLevelVar: Bool,
	// ω-single-stmt-braces: dangling-else suppress frame. Set (via
	// `_setSsbSuppress`) on the opt of an `if`-statement's then-body write
	// when the `if` carries an `else`, so every `dropSingleStmtBraces`
	// unwrap nested anywhere inside that then-body no-ops:
	// `if (a) while (c) { if (b) x; } else y` must keep the loop-body
	// braces — unwrapping would rebind the outer `else` to `if (b)`.
	// Never cleared on descent (over-suppression inside nested braced
	// regions is safe, merely conservative). Default `false`.
	_ssbSuppress: Bool,
	// ω-single-stmt-braces CHAIN symmetry: set (via `_setSsbChainSuppress`)
	// on the opt of an else-if continuation write when the CHAIN ROOT found
	// that some branch keeps its braces (`SingleStmtBraces.chainForcesBraces`).
	// It forces every downstream else-if branch to keep braces too, so
	// `if (a) { one; two; } else if (b) { three; }` stays fully braced
	// instead of de-bracing the `else if` half. Unlike `_ssbSuppress` this is
	// CLEARED when descending into a branch's own content (then-body /
	// terminal-else writeCall), so an independent if-chain nested inside a
	// branch still de-braces on its own merits. Default `false`.
	_ssbChainSuppress: Bool,
	// ω-keep-chain — set on the leaf-operand opt
	// when an opAddSub / opBool chain resolves to `WrapMode.Keep`. Read by the
	// `ParenExpr` (`@:fmt(expressionParenHardFlatten)`) emit to take the GLUED
	// branch UNCONDITIONALLY: a kept chain preserves the source line structure
	// verbatim (operand lines may exceed `lineWidth`), so its inner parens must
	// NOT re-open via the width-driven `IfFullLineExceeds` probe — mirror fork's
	// `keep2` `noLineEndBefore` lock on operand boundaries with no source break.
	// Default false → non-keep / Plain are byte-inert.
	_keepFlatInner: Bool,
	// ω-keep-chain — set by an enclosing
	// `ParenExpr` (`@:fmt(expressionParenHardFlatten)`) on its inner opt. A
	// `WrapMode.Keep` opAddSub / opBool chain reads it to suppress BOTH its own
	// `_headBreak` (the source return-head newline is reproduced at the
	// return-VALUE level instead) AND its continuation `Nest` (the value-level
	// break already supplies the +cols, so chain operators co-indent with the
	// head rather than compounding to +2cols). Non-keep chains ignore it (gated
	// on `isKeep`). Default false → Plain / direct-value chains byte-inert.
	// Also read by `WriterLowering.lowerTernaryBranch` as the "inside an explicit
	// expression paren" signal: a rest-aware ternary is EXCLUDED when this is set
	// (the paren owns the wrap). Keep the setter firing for ANY expression paren,
	// not only Keep chains, or that ternary gate silently breaks.
	_keepChainInParen: Bool,
	// ω-typedef-intersection-operand-break — set per-element by
	// `HxTypedefDecl.intersections`'s trivia-Star loop on the opt passed to a
	// `& Type` clause whose PRECEDING clause rendered multi-line and ended with
	// a close brace (a broke anon-struct operand: `A & {\n…\n} & B`). The clause
	// reads it via `@:fmt(typedefIntersectionBreak)` on
	// `HxIntersectionClause.type` and emits the `&`→operand whitespace as a
	// hardline + one-tab nest (`} &\n\tB`) instead of the `typedefIntersection`
	// After space (`} & B`), mirroring fork's `MarkLineEnds` `lineEndAfter` on
	// the `&` that follows a `BrClose`. Default false → single-line
	// intersections (`A & B`, `A & {x:Int} & B`) stay glued byte-identically.
	_intersectionOperandBreak: Bool,
	// ω-elseif-body-break: write-time-only signal flagging that the current
	// statement is being rendered as the direct `else` branch of an enclosing
	// `if` (i.e. an `else if`). Set by `HxIfStmt.elseBody`'s
	// `@:fmt(propagateElseIfBranch)` ONLY when the else-branch runtime ctor is
	// `IfStmt`, and cleared on the inner `if`'s then-body recursion
	// (`@:fmt(clearElseIfBranch)`) so it reaches exactly that one inner `if`'s
	// body fit-gate and dies. Read by the `fitLineIfWithElse` body gate
	// (`buildBodyFitExpr`) as an extra break trigger: mirrors haxe-formatter's
	// `MarkSameLine.isPartOfIfElse` "if inside else" clause, so a fitting
	// single-statement `else if (c) stmt;` degrades to `Next` under
	// `sameLine.ifBody:fitLine` + `fitLineIfWithElse:false`. Default false.
	_inElseIfBranch: Bool
};
