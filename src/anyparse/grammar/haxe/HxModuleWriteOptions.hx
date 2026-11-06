package anyparse.grammar.haxe;

import anyparse.core.Doc;
import anyparse.format.ArrayMatrixWrap;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.CommentStyle;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.LiteralReflow;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.OperatorSpacing;
import anyparse.format.OptionalSemicolon;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.SiblingPolicy;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;

/**
 * Write options of the Haxe module grammar (`HxModule`): the base `WriteOptions` knobs plus its own. A class and not
 * a struct intersection for the reason on `OptionsRecord`; it unifies with `WriteOptions` structurally, a knob's
 * initializer is its default, `new HxModuleWriteOptions(from)` is the one clone. `HaxeFormat.defaultWriteOptions` is
 * the default instance; `hxformat.json` ingest lives in `HaxeFormatConfigLoader`; the JSON path
 * each knob answers to is the schema field in `format/HxFormat*Section.hx` / `HxFormatConfig.hx`, tabulated in
 * `docs/haxe-format-config.md`. A knob's SEMANTICS — what each value does at the site — is the contract of the
 * grammar field that carries the matching `@:fmt(...)` meta, and lives in that field's doc; this class only
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
@:build(anyparse.macro.Build.buildOptionsRecord())
final class HxModuleWriteOptions {

	// The base `WriteOptions` knobs, whose contract is that typedef's field docs.
	public var indentChar: IndentChar = IndentChar.Tab;
	public var indentSize: Int = 1;
	public var tabWidth: Int = 4;
	public var lineWidth: Int = 160;
	public var lineEnd: String = '\n';
	public var finalNewline: Bool = true;
	public var keyValueSpace: Bool = false;
	public var trailingWhitespace: Bool = false;
	public var commentStyle: CommentStyle = CommentStyle.Verbatim;
	public var addLineCommentSpace: Bool = true;
	public var normalizeLineCommentIndent: Bool = false;
	public var compressSuccessiveParenthesis: Bool = true;
	public var arrayMatrixWrap: ArrayMatrixWrap = ArrayMatrixWrap.MatrixWrapWithAlign;
	public var trailingComma: TrailingCommaPolicy = TrailingCommaPolicy.Keep;
	public var conditionalPolicy: ConditionalIndentationPolicy = ConditionalIndentationPolicy.Aligned;
	public var alignInlineSwitchCaseBody: Bool = false;
	public var comprehensionCuddledOpen: Bool = false;
	public var soleItemCuddledBrackets: Bool = false;
	public var methodChainCuddledLinks: Bool = false;
	public var ternaryCuddledBraces: Bool = false;
	public var maxConsecutiveBlanks: Int = 1;
	public var blockCommentAdapter: Null<(String, WriteOptions) -> Doc> =
		anyparse.format.comment.BlockCommentNormalizer.processCapturedBlockComment;
	public var lineCommentAdapter: Null<(Array<String>, Int, WriteOptions) -> String> =
		anyparse.format.comment.LineCommentNormalizer.normalizeLineComment;
	public var betweenImportsPathDiffers: Null<(String, String, Int) -> Bool> = HxBetweenImportsLevel.pathDiffers;
	public var sameLineElse: SameLinePolicy = SameLinePolicy.Same;
	public var sameLineCatch: SameLinePolicy = SameLinePolicy.Same;
	public var sameLineDoWhile: SameLinePolicy = SameLinePolicy.Same;
	public var sameLineExpressionElse: SameLinePolicy = SameLinePolicy.Same;
	public var trailingCommaArrays: Bool = false;
	public var trailingCommaArgs: Bool = false;
	public var trailingCommaParams: Bool = false;
	public var trailingCommaObjectLits: Bool = false;
	public var trailingCommaAnonTypes: Bool = false;
	public var ifBody: BodyPolicy = BodyPolicy.Keep;
	public var elseBody: BodyPolicy = BodyPolicy.Keep;
	public var forBody: BodyPolicy = BodyPolicy.Keep;
	public var whileBody: BodyPolicy = BodyPolicy.Keep;
	public var doBody: BodyPolicy = BodyPolicy.Keep;
	public var returnBody: BodyPolicy = BodyPolicy.FitLine;
	public var returnBodySingleLine: BodyPolicy = BodyPolicy.FitLine;
	public var throwBody: BodyPolicy = BodyPolicy.Same;
	public var catchBody: BodyPolicy = BodyPolicy.Next;
	public var tryBody: BodyPolicy = BodyPolicy.Next;
	public var caseBody: BodyPolicy = BodyPolicy.Keep;
	public var caseSiblings: SiblingPolicy = SiblingPolicy.Off;
	public var expressionCase: BodyPolicy = BodyPolicy.Keep;
	public var functionBody: BodyPolicy = BodyPolicy.Next;
	public var anonFunctionBody: BodyPolicy = BodyPolicy.Same;
	public var untypedBody: BodyPolicy = BodyPolicy.Same;
	public var expressionIfBody: BodyPolicy = BodyPolicy.Same;
	public var expressionElseBody: BodyPolicy = BodyPolicy.Same;
	public var expressionForBody: BodyPolicy = BodyPolicy.Keep;
	public var expressionIfWithBlocks: Bool = false;
	public var expressionIfWithBrackets: Bool = false;
	public var leftCurly: BracePlacement = BracePlacement.Same;
	public var emptyCurly: EmptyCurly = EmptyCurly.Same;
	public var objectLiteralLeftCurly: BracePlacement = BracePlacement.Same;
	public var anonTypeLeftCurly: BracePlacement = BracePlacement.Same;
	public var anonFunctionLeftCurly: BracePlacement = BracePlacement.Same;
	public var anonFunctionEmptyCurly: EmptyCurly = EmptyCurly.Same;
	public var blockLeftCurly: BracePlacement = BracePlacement.Same;
	public var blockEmptyCurly: EmptyCurly = EmptyCurly.Same;
	public var blockRightCurly: RightCurlyPlacement = RightCurlyPlacement.Same;
	public var anonFunctionRightCurly: RightCurlyPlacement = RightCurlyPlacement.Same;
	public var anonTypeRightCurly: RightCurlyPlacement = RightCurlyPlacement.Same;
	public var objectLiteralRightCurly: RightCurlyPlacement = RightCurlyPlacement.Same;
	public var objectFieldColon: WhitespacePolicy = WhitespacePolicy.After;
	public var typeHintColon: WhitespacePolicy = WhitespacePolicy.None;
	public var typeCheckColon: WhitespacePolicy = WhitespacePolicy.Both;
	public var funcParamParens: WhitespacePolicy = WhitespacePolicy.None;
	public var callParens: WhitespacePolicy = WhitespacePolicy.None;
	public var anonFuncParens: WhitespacePolicy = WhitespacePolicy.None;

	/**
	 * When `true`, an empty anonymous-function parameter list emits a single inside space
	 * (`function ( ) body`); the loader inverts upstream `anonFuncParamParens.removeInnerWhenEmpty`.
	 * Read by `HxFnExpr.params` through `sepList`'s `keepInnerWhenEmpty` arg — orthogonal to
	 * `anonFuncParens`.
	 */
	public var anonFuncParamParensKeepInnerWhenEmpty: Bool = false;

	public var ifPolicy: WhitespacePolicy = WhitespacePolicy.After;
	public var forPolicy: WhitespacePolicy = WhitespacePolicy.After;
	public var whilePolicy: WhitespacePolicy = WhitespacePolicy.After;

	/**
	 * Trailing space after `switch`, for all four switch ctors. Caller trap: for the bare form
	 * (`switch cond { … }`) `Before` / `None` produce `switchcond` — a syntax error; keep the default
	 * there.
	 */
	public var switchPolicy: WhitespacePolicy = WhitespacePolicy.After;

	/**
	 * Leading space before the `switch` keyword — the `before` / `around`
	 * side of the fork's `whitespace.switchPolicy`, kept separate from the
	 * (conflated) `switchPolicy` field so the `conditionParens` overwrite
	 * does not erase it. Visible only when the keyword follows a tight `(`
	 * (a call argument `f( switch …)` or an expression paren `( switch …)`).
	 */
	public var switchKwLeadingSpace: Bool = false;

	public var tryPolicy: WhitespacePolicy = WhitespacePolicy.After;
	public var elseIf: KeywordPlacement = KeywordPlacement.Same;

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
	public var elseSwitch: KeywordPlacement = KeywordPlacement.Keep;

	public var fitLineIfWithElse: Bool = false;

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
	public var expressionIfArrowBodyReflow: Bool = false;

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
	public var expressionIfFit: Bool = false;

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
	public var expressionIfFitMaxBranches: Int = 0;

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
	public var elseIfCommentReflow: Bool = false;

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
	public var fitLineBodyGlue: Bool = false;

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
	public var loopBodyIfElseNext: Bool = false;

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
	public var conditionalExprFit: Bool = false;

	/**
	 * When the statement-`if` then-branch is a bare statement ending in `;` and the branch
	 * carries an `else`, put that `else` on the next line instead of gluing it after the `;`
	 * (`if (c) foo();` / `else bar();`). Trivia-mode writer only — the plain writer
	 * canonicalises `;` presence, so the question is meaningless there — and statement
	 * position only (`_inExprPosition` hands a value-`if` to `sameLineExpressionElse`). Fed by
	 * `sameLine.ifElseSemicolonNextLine`; consumed by `WriterFieldSepLowering` through the
	 * `@:fmt(semicolonNextLineElse)` flag on `HxIfStmt.elseBody`. Default `true`, unlike the
	 * other bare-`Bool` `sameLine` knobs.
	 */
	public var ifElseSemicolonNextLine: Bool = true;

	public var afterFieldsWithDocComments: CommentEmptyLinesPolicy = CommentEmptyLinesPolicy.One;

	/**
	 * `Keep` honours the source blank between class members, `Remove` strips it. A strip policy removes only the SOURCE
	 * blank: an add policy on the same slot (`afterFieldsWithDocComments = One`, the inter-member counts) still inserts
	 * one, so `Remove` + `One` yields a blank after a doc-commented member.
	 */
	public var existingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;

	/**
	 * `Keep` / `Remove` that takes over from `existingBetweenFields` on a class body while
	 * `_classExtern` is true (`emptyLines.externClassEmptyLines.existingBetweenFields`).
	 */
	public var externExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;

	public var beforeDocCommentEmptyLines: CommentEmptyLinesPolicy = CommentEmptyLinesPolicy.One;
	public var betweenVars: Int = 0;
	public var betweenFunctions: Int = 1;
	public var afterVars: Int = 1;

	/**
	 * Blanks between an instance var and a static var (either order); with `betweenStaticFunctions`,
	 * fires only where the member Star ALSO carries `@:fmt(staticVarSubdivision)` — class and abstract members opt in,
	 * interface members do not; an `extern class` and an `enum abstract` read their own between-counts there instead.
	 */
	public var afterStaticVars: Int = 1;

	public var betweenStaticFunctions: Int = 1;
	public var interfaceBetweenVars: Int = 0;
	public var interfaceBetweenFunctions: Int = 0;
	public var interfaceAfterVars: Int = 0;

	/**
	 * The between-member counts and the source-blank policy of a type body with its own `<kind>EmptyLines` section:
	 * `interface`, `abstract`, `extern class` (read while `_classExtern`), `enum abstract` (read while `_inEnumAbstract`) and
	 * `macro class` reification; the `…AfterStaticVars` / `…BetweenStaticFunctions` of `abstract` and `macro class` subdivide
	 * like the class pair. Each is named by its grammar field's `@:fmt(...)`, so no kind's config moves another kind's body.
	 */
	public var interfaceExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;

	public var externClassBetweenVars: Int = 0;
	public var externClassBetweenFunctions: Int = 0;
	public var externClassAfterVars: Int = 0;
	public var abstractExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;
	public var abstractBetweenVars: Int = 0;
	public var abstractBetweenFunctions: Int = 1;
	public var abstractAfterVars: Int = 1;
	public var abstractAfterStaticVars: Int = 1;
	public var abstractBetweenStaticFunctions: Int = 1;
	public var enumAbstractExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;
	public var enumAbstractBetweenVars: Int = 0;
	public var enumAbstractBetweenFunctions: Int = 1;
	public var enumAbstractAfterVars: Int = 1;
	public var macroClassExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;
	public var macroClassBetweenVars: Int = 0;
	public var macroClassBetweenFunctions: Int = 1;
	public var macroClassAfterVars: Int = 1;
	public var macroClassAfterStaticVars: Int = 1;
	public var macroClassBetweenStaticFunctions: Int = 1;
	public var enumExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;
	public var betweenEnumCtors: Int = 0;

	/**
	 * Blank lines between a type body's `{` and its first member (`…EndType`: between its last member and `}`), one
	 * pair per type kind — the fork's `<kind>EmptyLines.beginType` / `endType`: `beginType` / `endType` for a class,
	 * then abstract, interface, `extern class`, `macro class` reification, enum, `enum abstract`. `null` (the default)
	 * means the config did not say, and `afterLeftCurly` / `beforeRightCurly` decide from the source; any count, `0`
	 * included, is exact and wins over the source. Each pair is named by its grammar field's
	 * `@:fmt(beginEndType(...))`.
	 */
	public var beginType: Null<Int> = null;

	public var endType: Null<Int> = null;
	public var abstractBeginType: Null<Int> = null;
	public var abstractEndType: Null<Int> = null;
	public var interfaceBeginType: Null<Int> = null;
	public var interfaceEndType: Null<Int> = null;
	public var externClassBeginType: Null<Int> = null;
	public var externClassEndType: Null<Int> = null;
	public var macroClassBeginType: Null<Int> = null;
	public var macroClassEndType: Null<Int> = null;
	public var enumBeginType: Null<Int> = null;
	public var enumEndType: Null<Int> = null;
	public var enumAbstractBeginType: Null<Int> = null;
	public var enumAbstractEndType: Null<Int> = null;

	/**
	 * Blank lines between a type body's `{` and its first member (`…EndTypeIfDocComments`: between its last member and
	 * `}`) when that body holds a doc comment (`MemberGap.bodyHasDoc`) — the fork's `<kind>EmptyLines.beginTypeIfDocComments`
	 * / `endTypeIfDocComments`, for an enum, an `enum abstract` and a typedef body. `null` (the default) leaves the kind's
	 * `…BeginType` / `…EndType` in charge; a count replaces it for a body with a doc comment, `0` included. Each enum pair
	 * is named by its grammar field's `@:fmt(beginEndTypeIfDoc(...))`.
	 */
	public var enumBeginTypeIfDocComments: Null<Int> = null;

	public var enumEndTypeIfDocComments: Null<Int> = null;

	/**
	 * The blank-line policy after a doc-commented member of an enum, a typedef and an `enum abstract` body — the fork's
	 * `<kind>EmptyLines.afterFieldsWithDocComments`, each named by its grammar Star's
	 * `@:fmt(afterFieldsWithDocComments(...))`. `null` (the default) means the config did not say: an enum or typedef body
	 * then keeps the source blank (`Ignore`), an `enum abstract` body reads the global `afterFieldsWithDocComments`.
	 */
	public var enumAfterFieldsWithDocComments: Null<CommentEmptyLinesPolicy> = null;

	public var typedefAfterFieldsWithDocComments: Null<CommentEmptyLinesPolicy> = null;
	public var enumAbstractAfterFieldsWithDocComments: Null<CommentEmptyLinesPolicy> = null;
	public var enumAbstractBeginTypeIfDocComments: Null<Int> = null;
	public var enumAbstractEndTypeIfDocComments: Null<Int> = null;
	public var typedefBeginTypeIfDocComments: Null<Int> = null;
	public var typedefEndTypeIfDocComments: Null<Int> = null;
	// ω-typedef-between-fields: dedicated typedef-RHS anon-body blank-line
	// knobs (fork's `TypedefFieldsEmptyLinesConfig`), read only by the
	// `@:sep`-Star force-multi branch under `_inTypedefBody`. Kept distinct
	// from the class-scoped `beginType` / `endType` (which the typedef anon
	// path never reads) so typedef + class scopes never cross-contaminate.
	// `typedefExistingBetweenFields` governs source-blank pass-through when
	// `typedefBetweenFields == 0`; a positive `typedefBetweenFields` forces
	// that exact count regardless of the policy. `typedefBeginType` /
	// `typedefEndType` follow the type-body contract above: `null` defers to
	// the source, a count is exact.
	public var typedefBeginType: Null<Int> = null;
	public var typedefBetweenFields: Int = 0;
	public var typedefExistingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;
	public var typedefEndType: Null<Int> = null;

	/**
	 * `Keep` / `Remove` for the source blank between a `{` and its first item — a type body, a block body that opts in
	 * through `@:fmt(keepCurlyBlanks)`, an anon type's fields (`beforeRightCurly`: before the matching `}`). On a type
	 * body it is consulted only while that kind's `…BeginType` / `…EndType` is `null` — a stated count wins.
	 * Compiled default `Keep`; `HaxeFormatConfigLoader` re-baselines both to the fork's `Remove` on any JSON load.
	 */
	public var afterLeftCurly: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;

	/**
	 * `Keep` / `Remove` for the source blank between a body's last item and its `}` — the mirror of `afterLeftCurly`,
	 * same sites, same `endType` precedence, same `Remove` re-baseline on JSON load.
	 */
	public var beforeRightCurly: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep;

	/**
	 * `Keep` / `Collapse` over the blank-line gaps BETWEEN adjacent statements of one block
	 * (`@:fmt(uniformStmtBlanks)` sites — never a type member list). `Keep` (default) round-trips
	 * source blanks; `Collapse` applies "separators that separate everything separate nothing": when
	 * every interior gap is blank the blanks are uniform noise and all get stripped, while a selective
	 * mix (or any comment between statements) is left byte-exact. The head/tail `{` / `}` blanks are
	 * resolved by `afterLeftCurly` / `beforeRightCurly` instead. See `UniformStatementBlanksPolicy`.
	 */
	public var uniformStatementBlanks: UniformStatementBlanksPolicy = UniformStatementBlanksPolicy.Keep;

	/**
	 * FU12 `comments.trailingCommentOverflow: "above"`. True moves a same-line `//` comment that alone carries
	 * its line past `lineWidth` onto its own line above the statement or member it trails, at that element's
	 * indent; the code is then laid out as if the comment were not there. Only where a block Star opts in
	 * (`@:fmt(relocateTrailingComments)`: statement blocks and type member lists), only when the element alone
	 * renders as one line that fits, never for a directive (`CommentDirective`) and never for an element that
	 * already carries a leading comment. False (default) keeps every trailing comment where it was.
	 */
	public var trailingCommentAbove: Bool = false;

	public var typedefAssign: WhitespacePolicy = WhitespacePolicy.Both;
	public var typedefIntersection: WhitespacePolicy = WhitespacePolicy.After; // noqa: prefer-final-public-field
	public var typeParamDefaultEquals: WhitespacePolicy = WhitespacePolicy.Both;
	public var typeParamOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var typeParamClose: WhitespacePolicy = WhitespacePolicy.None;
	public var anonTypeBracesOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var anonTypeBracesClose: WhitespacePolicy = WhitespacePolicy.None;
	public var objectLiteralBracesOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var objectLiteralBracesClose: WhitespacePolicy = WhitespacePolicy.None;
	// ω-arrow-body-objlit-pad-keep: when `true`, the open-side
	// `objectLiteralBracesOpen` inner pad is applied EVEN when the literal
	// is an arrow-lambda body (`u -> { email: v }`). Default `false`
	// mirrors the fork's `MarkWhitespace.successiveParenthesis`
	// compress-mode `case Arrow: return;` which drops the opening-brace
	// pad after a `->` token (`u -> {email: v }`). Fed by
	// `whitespace.bracesConfig.objectLiteralBraces.arrowBodyOpenPad`.
	public var objectLiteralArrowBodyOpenPad: Bool = false;
	// ω-arrow-body-objlit-reflow: when `true`, a source-multiline object
	// literal that is an arrow-lambda body drops its source newlines and
	// the wrap cascade re-flows it by width (`u -> { a: 1 }` when it
	// fits). Default `false` keeps the source-multiline force-multi
	// shape (fork parity). Fed by `whitespace.bracesConfig.
	// objectLiteralBraces.arrowBodyReflow`.
	public var objectLiteralArrowBodyReflow: Bool = false;
	// ω-single-stmt-braces: when `true`, the writer drops the curly braces
	// around an `if` / `else` / `for` / `while` body whose block holds
	// exactly one safe single statement (`if (c) { return x; }` →
	// `if (c) return x;`). Safety gates (dangling-else, comments,
	// terminator, declaration scoping) live in
	// `anyparse.format.SingleStmtBraces.unwrapStmt` — every gate fails
	// closed (keeps braces). Trivia-mode writer only; the plain writer
	// ignores the knob. Default `false` (keep braces — byte-inert). Fed by
	// `whitespace.bracesConfig.singleStatementBraces` (`"remove"` → true).
	public var dropSingleStmtBraces: Bool = false;
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
	public var singleStmtBraceSymmetry: Bool = false;
	// omega-cond-directive-binop: spacing for the `&&` / `||` inside a `#if` /
	// `#elseif` CONDITION, which the grammar captures as one verbatim text terminal
	// rather than as an expression tree - so `whitespace.binopPolicy`, which acts on
	// operator nodes, never reaches it and the authored spelling has always survived
	// verbatim. `Keep` (the default) is that behaviour; `None` / `Around` normalise
	// it. Fed by `whitespace.conditionalCompilationBinop: true`, which takes the
	// direction from the config's own `binopPolicy` so the two cannot drift.
	// Applied in `anyparse.format.DirectiveCondition.spaceOperators` through the
	// `@:writeNormalize('condOperatorSpacing')` terminal transform.
	public var condDirectiveOpSpacing: OperatorSpacing = OperatorSpacing.Keep;
	// ω-switch-subject-parens: `true` drops the redundant parens around a
	// `switch (subject) { … }` subject (`switch v { … }`); the leading-brace
	// subject carve-out (object literal / block) still keeps them. Covers both
	// statement- and expression-position switch (shared `HxSwitchStmt`
	// grammar). Default `false` (keep parens — byte-inert). Fed by
	// `whitespace.parenConfig.switchSubjectParens` (`"remove"` → true).
	public var dropSwitchSubjectParens: Bool = false;
	// ω-optional-semicolon (E11): three-way policy for the `@:trailOpt(';')`
	// statement terminator Haxe lets a `}`-terminated statement omit.
	// `Preserve` (default) re-emits source presence — byte-inert, fork
	// parity. `Always` emits it on every slot carrying
	// `@:fmt(optionalSemicolon(...))`; `Never` drops it wherever that
	// flag's shape gate proves it optional. Trivia-mode writer only; the
	// plain writer keeps its `trailOptShapeGate` AST-shape gate. Fed by
	// `whitespace.optionalSemicolon`.
	public var optionalSemicolon: OptionalSemicolon = OptionalSemicolon.Preserve;
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
	public var semicolonBeforeElse: OptionalSemicolon = OptionalSemicolon.Preserve;
	public var accessBracketsOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var accessBracketsClose: WhitespacePolicy = WhitespacePolicy.None;
	public var arrayLiteralBracketsOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var arrayLiteralBracketsClose: WhitespacePolicy = WhitespacePolicy.None;
	public var mapLiteralBracketsOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var mapLiteralBracketsClose: WhitespacePolicy = WhitespacePolicy.None;
	public var comprehensionBracketsOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var comprehensionBracketsClose: WhitespacePolicy = WhitespacePolicy.None;
	public var callParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var callParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
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
	public var ifCondParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var ifCondParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
	public var whileCondParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var whileCondParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
	public var switchCondParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var switchCondParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
	public var catchParensGap: WhitespacePolicy = WhitespacePolicy.After;
	public var catchParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var catchParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
	public var sharpCondParensGap: WhitespacePolicy = WhitespacePolicy.After;
	public var sharpCondParensInsideOpen: WhitespacePolicy = WhitespacePolicy.None;
	public var sharpCondParensInsideClose: WhitespacePolicy = WhitespacePolicy.None;
	public var objectLiteralWrap: WrapRules = HaxeFormat.defaultObjectLiteralWrap();
	public var callParameterWrap: WrapRules = HaxeFormat.defaultCallParameterWrap();
	public var arrayLiteralWrap: WrapRules = HaxeFormat.defaultArrayLiteralWrap();
	// A MAP literal (`[k => v, …]`) reads its own cascade, the way the fork
	// splits `mapLiteralWrapping` off `arrayLiteralWrapping`. The fork's
	// `wrapping.mapWrap` DEFAULT is character-for-character its `arrayWrap`
	// default, so there is nothing to restate here — and the builder returns
	// a fresh struct per call, so the two never share mutable state.
	public var mapLiteralWrap: WrapRules = HaxeFormat.defaultArrayLiteralWrap();
	public var multiVarWrap: WrapRules = HaxeFormat.defaultMultiVarWrap();
	public var casePatternWrap: WrapRules = HaxeFormat.defaultCasePatternWrap();
	public var anonTypeWrap: WrapRules = HaxeFormat.defaultAnonTypeWrap();
	public var methodChainWrap: WrapRules = HaxeFormat.defaultMethodChainWrap();
	public var opBoolChainWrap: WrapRules = HaxeFormat.defaultOpBoolChainWrap();
	public var opAddSubChainWrap: WrapRules = HaxeFormat.defaultOpAddSubChainWrap();
	public var conditionWrap: WrapRules = HaxeFormat.defaultConditionWrap();
	public var ternaryWrap: WrapRules = HaxeFormat.defaultTernaryWrap();
	// The layout of a ternary whose branch holds a multi-line block (`cond ? macro {…} : …`): `false`
	// (the default) lets that hardline commit the ternary to its break shape, `?` and `:` on lines of their
	// own; `true` keeps `cond ? macro {` on the condition's line while it fits and leaves the wrap to
	// `ternaryWrap`. Object and array literals are not blocks, and the brace or bracket group a branch
	// opens with is skipped (`HxTernaryBranchBlocks`). Fed by
	// `wrapping.ternaryMultilineBranch` (`"inline"` → true, `"break"` → false); read through the Ternary
	// ctor's `@:fmt(multilineBranchInline)`.
	public var ternaryMultilineBranchInline: Bool = false;
	public var functionSignatureWrap: WrapRules = HaxeFormat.defaultFunctionSignatureWrap();
	public var anonFunctionSignatureWrap: WrapRules = HaxeFormat.defaultAnonFunctionSignatureWrap();
	public var metadataCallParameterWrap: WrapRules = HaxeFormat.defaultMetadataCallParameterWrap();
	public var typeParameterWrap: WrapRules = HaxeFormat.defaultTypeParameterWrap();
	public var expressionWrappingWrap: WrapRules = HaxeFormat.defaultExpressionWrappingWrap();
	public var implementsExtendsWrap: WrapRules = HaxeFormat.defaultImplementsExtendsWrap();
	public var expressionTry: SameLinePolicy = SameLinePolicy.Same;
	public var indentCaseLabels: Bool = true;
	public var indentObjectLiteral: Bool = true;
	// An object-literal body of a comprehension `for` stays glued to the header instead of taking the Allman placement.
	// Derived by the config loader from `sameLine.forBody` and `sameLine.comprehensionFor`; no config key of its own.
	public var comprehensionObjectLitGlue: Bool = false;
	public var indentComplexValueExpressions: Bool = false;
	public var indentVarTypeHintAnon: Bool = true;
	public var functionTypeHaxe4: WhitespacePolicy = WhitespacePolicy.Both;
	public var functionTypeHaxe3: WhitespacePolicy = WhitespacePolicy.None;
	public var intervalPolicy: WhitespacePolicy = WhitespacePolicy.None;
	public var arrowFunctions: WhitespacePolicy = WhitespacePolicy.Both;

	/**
	 * Blank lines forced AFTER a `package` directive by the `blankLinesAfterCtor` cascade on `HxModule.decls` — an
	 * override of the source count, like every count in that cascade (the fork's `emptyLines.afterPackage`).
	 */
	public var afterPackage: Int = 1;

	/**
	 * Blank lines forced BEFORE a leading `package` directive, read once at file head by the `blankLinesAtHeadIfCtor`
	 * cascade on `HxModule.decls` — an override of the source count. Default `0` keeps the file's leading edge tight
	 * against `package …;`, `1` starts the file with a blank line (the fork's `emptyLines.beforePackage`).
	 */
	public var beforePackage: Int = 0;

	public var beforeUsing: Int = 1;
	public var betweenImports: Int = 0;

	/**
	 * Granularity of the `betweenImports` level test: `All` (default; every same-kind boundary is a
	 * mismatch), `FirstLevelPackage` … `FifthLevelPackage` (compare the first N dot segments),
	 * `FullPackage` (the whole path). Read by the `blankLinesBetweenSameCtorByLevel` cascade on
	 * `HxModule.decls` through the grammar-wired `betweenImportsPathDiffers` adapter.
	 */
	public var betweenImportsLevel: HxBetweenImportsLevel = HxBetweenImportsLevel.All;

	public var keepSourceBlankAcrossConditional: Bool = false;
	public var beforeType: Int = 1;
	public var afterMultilineDecl: Int = 1;
	public var beforeMultilineDecl: Int = 1;
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
	public var afterConditionalBlock: Int = 0; // noqa: prefer-final-public-field

	/**
	 * Exact blanks AFTER the first top-level block-style comment of a module when fileheader semantics
	 * apply: the decl that comment LEADS is itself a `package` / `import` / `using`, OR it carries 2+
	 * leading comments at module head. Classifying from the head decl rather than a whole-module scan
	 * keeps a doc comment glued to the type it documents in a module whose `import` sits below that
	 * type. Site: `@:fmt(afterFileHeaderCommentBlanks)` on `HxModule.decls`.
	 */
	public var afterFileHeaderComment: Int = 1;

	/**
	 * Exact blanks BETWEEN two consecutive block-style comments wherever block–block boundaries occur in a
	 * `leadingComments` array or a trailing-orphan array, except the slot `afterFileHeaderComment` already claims.
	 * Site: `@:fmt(betweenMultilineCommentsBlanks)` on `HxModule.decls` and the class / interface / abstract member Stars.
	 */
	public var betweenMultilineComments: Int = 0;

	/**
	 * Blanks between two consecutive single-line top-level type decls (neither matches the `multiline`
	 * predicate). Insertion-only: the override fires ONLY when the value is `> 0`; at `0` the slot stays
	 * source-driven — this axis never strips blanks. `afterMultilineDecl` / `beforeMultilineDecl` win
	 * when either side is multi-line.
	 */
	public var betweenSingleLineTypes: Int = 0;

	/**
	 * ω-blank-around-multiline-members — blank lines forced into the gap
	 * between two adjacent TYPE MEMBERS when either of them renders across
	 * more than one line. `betweenSingleLineTypes` above is its module-level
	 * sibling, but that one resolves multi-line-ness STRUCTURALLY at macro
	 * time (a class is multi-line iff it declares members). A field cannot be
	 * classified that way — `final a = ['x'];` fits and `final a = [… 20 …];`
	 * does not, from the same shape — so this knob is answered by measuring
	 * the built Doc instead. `0` (the default) leaves every gap to the
	 * source-driven `existingBetweenFields` path.
	 */
	public var aroundMultilineFields: Int = 0;

	/**
	 * When `true` (default) the writer re-emits each `${expr}` segment by recursing into the parsed
	 * `HxExpr`, producing canonical `${a + b}` spacing; when `false` it emits the parser-captured byte
	 * slice between `${` and `}` verbatim. The slice rides `HxStringSegmentT.Block`'s positional
	 * `sourceText` arg (populated under `@:fmt(captureSource)`); plain mode does not capture, so the
	 * knob has no effect there.
	 */
	public var formatStringInterpolation: Bool = true;

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
	public var metadataFunctionLineEnd: MetadataLineEndPolicy = MetadataLineEndPolicy.None;

	/**
	 * Set when descending through an expression-position parent (`HxCaseBranch.body` /
	 * `HxDefaultBranch.stmts`, the value-switch ctors, via `@:fmt(propagateExprPosition)`). Read by
	 * the dual-flag `bodyPolicy('caseBody', 'expressionCase')` flat gate: a case nested inside
	 * another case's body inherits the flag and flattens per `expressionCase`, an outer
	 * statement-position `case X:` breaks per `caseBody`.
	 */
	public var _inExprPosition: Bool = false; // noqa: naming

	// ω-expressionif-collapse — narrow companion to `_inExprPosition`, `Here`
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
	// branch value. `HxForExpr.body`'s `@:fmt(reflowCtorOnFitLine)` sets it on a
	// literal comprehension body too, and `ThroughWrap` on a parenthesised one, which only that
	// paren's descent reads: the paren clears the frame, so a parenthesised value-if branch keeps its lines.
	public var _literalReflow: LiteralReflow = LiteralReflow.Off; // noqa: naming
	// ω-arrow-body-objlit-pad — sister to `_literalReflow`, set ONLY on the
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
	public var _inArrowLambdaBody: Bool = false; // noqa: naming
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
	public var _arrowValueIfBlocked: Bool = false; // noqa: naming
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
	public var _arrowValueIfElemTrailComment: Bool = false; // noqa: naming

	/**
	 * Set by `HxTopLevelDecl.decl` via `@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers',
	 * 'Extern'))` when the sibling `modifiers` Star contains an `Extern` ctor. Set for any extern declaration,
	 * read only where a grammar field names it: `HxClassDecl.members` switches to the `externClass*` knobs
	 * (`extern abstract` and `extern interface` keep the abstract and interface ones).
	 */
	public var _classExtern: Bool = false; // noqa: naming, prefer-final-public-field

	/**
	 * Set on descent into an anonymous function body (`HxFnExpr.body`, `HxParenLambda.body`,
	 * `HxThinParenLambda.body`) via `@:fmt(propagateAnonFnContext)`. Readers: the `emptyCurlyBreak`
	 * branch in `triviaBlockStarExpr` dispatches `anonFunctionEmptyCurly` vs global `emptyCurly`;
	 * `HxExpr.BlockExpr.stmts` (`@:fmt(leftCurlyAnonFnOverride('anonFunctionLeftCurly'))`) prepends a
	 * runtime-gated hardline before `{` when the knob is `Next`, then clears the flag so nested
	 * blocks fall back to `blockLeftCurly`.
	 */
	public var _inAnonFnBody: Bool = false; // noqa: naming

	/**
	 * Set on descent into a typedef RHS type via `@:fmt(propagateTypedefContext)` on
	 * `HxTypedefDecl.type`. Consumed by `@:fmt(forceMultiInTypedef)` on `HxType.Anon.fields`: when
	 * set AND `anonTypeLeftCurly == Next`, the writer threads a runtime `forceMode` predicate into
	 * `WrapList.emit`, bypassing the cascade and laying the anon body out `OnePerLine` even when its
	 * fields fit flat. Cleared per element so nested anons revert to the layout-driven wrap.
	 */
	public var _inTypedefBody: Bool = false; // noqa: naming

	/**
	 * Set on descent into a type nested in a type argument, parentheses or `#if` arm
	 * (`@:fmt(propagateNestedType)`) and cleared per anon-body element, whose fields start lines of
	 * their own. Read by `@:fmt(compactUnlessNested)`: a wrapped function-type signature continues
	 * one unit past its line, two while nested.
	 */
	public var _inNestedType: Bool = false; // noqa: naming

	/**
	 * ω-enumabstract-begin-end: set on the inner `HxAbstractDecl` opt when it is
	 * written as the body of an `enum abstract` (via `EnumAbstractDecl(decl)`'s
	 * `@:fmt(propagateEnumAbstractContext)`), so its `beginEndType` blank count
	 * reads `enumAbstractBeginType` / `enumAbstractEndType` instead of the
	 * `abstract` pair. Default `false`.
	 */
	public var _inEnumAbstract: Bool = false; // noqa: naming

	/**
	 * The chain mode the enclosing site set, `null` when none did. `_setChainModeOverride(opt, mode)` FORCES it — both
	 * chain cascades become that one mode — for a string-interpolation body and a `switch` subject (`NoWrap`) and an
	 * expression paren inside a condition (its `expressionWrapping` mode). `_setCondWrapChainMode(opt, mode)` only RECORDS
	 * a condition wrap's non-`NoWrap` mode, which a chain inside reads as "the condition supplies my continuation indent"
	 * while its own cascade still decides its layout.
	 */
	public var _chainModeOverride: Null<WrapMode> = null; // noqa: naming

	public var _callArgChainNest: Bool = false; // noqa: naming
	public var _suppressMore: Bool = false; // noqa: naming
	public var _parenInCondition: Bool = false; // noqa: naming
	// ω-compare-operand-linewrap: set on the ternary CONDITION's opt (via
	// `_setInTernaryCond`) so `lowerInfixBranch` suppresses the `==`/`!=`
	// operand-overflow break for a compare that IS a ternary condition -- the
	// fork breaks the ternary `?`/`:`, not the compare. Default false → every
	// non-ternary compare (assignment / chain operand / statement condition)
	// still breaks on a genuine line overflow.
	public var _inTernaryCond: Bool = false; // noqa: naming
	// omega-call-grouprestprobe-subposition: set on a `Call` subtree that is NOT
	// in statement/expression position, so the `Call` ctor skips the
	// `groupRestProbe` rest-of-line fit bias. Set-sites, all via
	// `_setSuppressCallRestProbe`:
	//  1. Case-pattern body (`HxCasePattern.expr`'s `@:fmt(suppressCallRestProbe)`):
	//     a ctor pattern (`case Nest(_, _) | Concat(_):`) must NOT wrap its args
	//     -- the fork breaks the `|` (BitOr) chain, not the ctor args.
	//  2. `??` (Coalesce) operands (`lowerInfixChain`, shared with item 3): an operand would
	//     otherwise carry the whole rest-chain; the rest-probe would over-count and wrap operand
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
	public var _suppressCallRestProbe: Bool = false; // noqa: naming
	// ω-complex-item-count: the subtree is a case PATTERN or a switch SUBJECT,
	// so an array literal inside it must not classify its elements for the
	// `complexItemCount >= n` cascade condition. Both positions can hold a shape
	// the classifier cannot tell from a value: an enum-constructor pattern
	// (`case [Some(a), Some(b)]:`) parses as two `Call`s, and the fork never
	// wraps a switch subject at all. Set via `_setSuppressComplexItems` from
	// `@:fmt(suppressComplexItems)` on `HxCasePattern.expr` /
	// `HxSwitchStmt(Bare).expr`; not cleared on descent, so a nested pattern
	// inherits it. Default false → every value-position array classifies.
	public var _suppressComplexItems: Bool = false; // noqa: naming
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
	public var _suppressPatternRestProbe: Bool = false; // noqa: naming
	public var _varKwNewline: Bool = false; // noqa: naming

	/**
	 * Set on descent into a class-member `var` / `final` initializer (NOT a local statement) via
	 * `@:fmt(propagateFieldLevelVar)` on `HxClassMember.VarMember` / `FinalMember`. Consumed by the
	 * `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')` entry on `HxVarDecl.init`: when
	 * set, the knob gate is bypassed (the fork's `Indenter.isFieldLevelVar`).
	 */
	public var _inFieldLevelVar: Bool = false; // noqa: naming

	// ω-single-stmt-braces: dangling-else suppress frame. Set (via
	// `_setSsbSuppress`) on the opt of an `if`-statement's then-body write
	// when the `if` carries an `else`, so every `dropSingleStmtBraces`
	// unwrap nested anywhere inside that then-body no-ops:
	// `if (a) while (c) { if (b) x; } else y` must keep the loop-body
	// braces — unwrapping would rebind the outer `else` to `if (b)`.
	// Never cleared on descent (over-suppression inside nested braced
	// regions is safe, merely conservative). Default `false`.
	public var _ssbSuppress: Bool = false; // noqa: naming
	// ω-single-stmt-braces CHAIN symmetry: set (via `_setSsbChainSuppress`)
	// on the opt of an else-if continuation write when the CHAIN ROOT found
	// that some branch keeps its braces (`SingleStmtBraces.chainForcesBraces`).
	// It forces every downstream else-if branch to keep braces too, so
	// `if (a) { one; two; } else if (b) { three; }` stays fully braced
	// instead of de-bracing the `else if` half. Unlike `_ssbSuppress` this is
	// CLEARED when descending into a branch's own content (then-body /
	// terminal-else writeCall), so an independent if-chain nested inside a
	// branch still de-braces on its own merits. Default `false`.
	public var _ssbChainSuppress: Bool = false; // noqa: naming
	// ω-keep-chain — set on the leaf-operand opt
	// when an opAddSub / opBool chain resolves to `WrapMode.Keep`. Read by the
	// `ParenExpr` (`@:fmt(expressionParenHardFlatten)`) emit to take the GLUED
	// branch UNCONDITIONALLY: a kept chain preserves the source line structure
	// verbatim (operand lines may exceed `lineWidth`), so its inner parens must
	// NOT re-open via the width-driven `IfFullLineExceeds` probe — mirror fork's
	// `keep2` `noLineEndBefore` lock on operand boundaries with no source break.
	// Default false → non-keep / Plain are byte-inert.
	public var _keepFlatInner: Bool = false; // noqa: naming
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
	public var _keepChainInParen: Bool = false; // noqa: naming
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
	public var _intersectionOperandBreak: Bool = false; // noqa: naming
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
	public var _inElseIfBranch: Bool = false; // noqa: naming

}
