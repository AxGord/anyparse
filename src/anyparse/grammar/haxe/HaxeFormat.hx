package anyparse.grammar.haxe;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.CommentStyle;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TextFormat.BlockCommentDelims;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;

/**
 * Text-format descriptor for the Haxe programming language.
 *
 * **Known debt**: the `TextFormat` interface was designed for structured-
 * text formats in the JSON family (mapping open/close, sequence open/close,
 * quote characters, key/value separator, trailing-separator policy, …).
 * These concepts do not apply cleanly to a programming language — `{}` in
 * Haxe delimits a class body, not a JSON mapping, and the literal
 * vocabulary of the language is far richer than anything a `TextFormat`
 * can express.
 *
 * `FormatReader.resolve` in the Phase 2 macro pipeline currently extracts
 * **only the `whitespace` field** from the resolved format class (see
 * `src/anyparse/macro/FormatReader.hx`), so implementing the interface
 * with placeholder values for the rest is enough to drive the existing
 * pipeline. A dedicated `LanguageFormat` interface will appear once the
 * Pratt / Indent strategies demand format-provided data that cannot be
 * expressed as a `TextFormat` shape; until then this class lives in the
 * grammar package rather than polluting `anyparse.format.text.*`.
 *
 * Singleton for the same reason as `JsonFormat`: the fields are pure
 * configuration with no per-parse state.
 */
@:nullSafety(Strict)
final class HaxeFormat implements TextFormat {

	public static final instance:HaxeFormat = new HaxeFormat();

	public var name(default, null):String = 'Haxe';
	public var version(default, null):String = '4';
	public var encoding(default, null):Encoding = Encoding.UTF8;

	public var mappingOpen(default, null):String = '{';
	public var mappingClose(default, null):String = '}';
	public var sequenceOpen(default, null):Null<String> = null;
	public var sequenceClose(default, null):Null<String> = null;
	public var keyValueSep(default, null):String = ':';
	public var entrySep(default, null):String = ',';

	public var whitespace(default, null):String = ' \t\n\r';
	public var lineComment(default, null):Null<String> = '//';
	public var blockComment(default, null):Null<BlockCommentDelims> = {open: '/*', close: '*/'};

	public var keySyntax(default, null):KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null):Array<String> = ['"', "'"];

	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByName;

	public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Error;

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. For Haxe only `{` block-opens do — `(` and
	 * `[` stay tight against the previous identifier, yielding
	 * `function main()` / `a[0]` / `new Foo(x)` rather than
	 * `function main ()` / `a [0]` / `new Foo (x)`.
	 */
	public var spacedLeads(default, null):Array<String> = ['{'];

	/**
	 * Optional `@:lead(...)` strings that emit tight — no leading
	 * separator, no trailing space. For Haxe the type-annotation colon
	 * is the canonical tight lead, so `function f():Int` and
	 * `var x:Type` keep their compact native layout instead of the
	 * spaced ` : ` that would be applied to keyword-like leads
	 * (`else`, `catch`).
	 */
	public var tightLeads(default, null):Array<String> = [':'];

	public var intLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null):Null<BoolLiterals> = {trueLit: 'true', falseLit: 'false'};
	public var nullLiteral(default, null):Null<String> = 'null';

	/**
	 * Default `WriteOptions` for Haxe output: tab indent, 4-column tab
	 * width, terminal newline. Generated Haxe writers use this struct
	 * when the caller omits the `options` argument to `write()`.
	 *
	 * Declared as `HxModuleWriteOptions` (not the base `WriteOptions`)
	 * so Haxe-specific knobs (`sameLine*` from τ₁, `trailingComma*`
	 * from τ₂, …) are present in the defaulted struct — generated
	 * writers cast this value to `HxModuleWriteOptions` at entry.
	 *
	 * Same-line defaults match haxe-formatter's `sameLine` defaults
	 * (`ifElse`/`tryCatch`/`doWhile` are all same-line by default).
	 *
	 * Trailing-comma defaults mirror haxe-formatter's `trailingComma`
	 * defaults — all groups are `false` by default; the trailing `,`
	 * only appears when the user opts in per group.
	 *
	 * Body-placement defaults (ψ₄ + ψ₁₀a) are `Next` for the five
	 * statement-form `*Body` knobs (`ifBody`, `elseBody`, `forBody`,
	 * `whileBody`, `doBody`) — non-block bodies of `if` / `else` /
	 * `for` / `while` / `do` sit on the next line, matching
	 * haxe-formatter's
	 * `sameLine.{ifBody,elseBody,forBody,whileBody,doWhileBody}:
	 * @:default(Next)`. Opting into `Same` (same-line body) or
	 * `FitLine` requires an explicit `hxformat.json` override.
	 * `returnBody` and `throwBody` are the exceptions — `returnBody`
	 * (ω-return-body, see below) defaults to `FitLine` because
	 * haxe-formatter's effective `sameLine.returnBody: @:default(Same)`
	 * semantics wrap long values via a separate
	 * `wrapping.maxLineLength` pass; `throwBody` (slice
	 * ω-throw-body-same-default) defaults to `Same` because
	 * haxe-formatter has no `throwBody` knob and leaves
	 * `throw <expr>` inline regardless of length, deferring any wrap
	 * to the value's own chain/fill rules.
	 *
	 * `returnBody` (ω-return-body) defaults to `FitLine` — `return
	 * value;` stays on one line when the value fits within
	 * `lineWidth`, otherwise the value breaks to the next line at one
	 * indent level deeper. This mirrors haxe-formatter's effective
	 * `sameLine.returnBody: @:default(Same)` semantics: their `Same`
	 * wraps long values via a separate `wrapping.maxLineLength` pass,
	 * which corresponds to our `FitLine` rather than strict `Same`.
	 * Opting into strict `Same` (no wrap) or `Next` (always-break) /
	 * `Keep` (preserve source) requires a `sameLine.returnBody`
	 * override in `hxformat.json`.
	 *
	 * `throwBody` (ω-throw-body) shares the `returnBody` shape but
	 * defaults to `Same`, not `FitLine` — `throw value;` always stays
	 * flat at the kw-side. haxe-formatter has no `throwBody` knob and
	 * leaves the `throw <expr>` separator inline regardless of length;
	 * any wrap happens inside the value via its own chain/fill rules
	 * (slice ω-throw-body-same-default, supersedes the original
	 * FitLine-mirror-returnBody default). `Next` / `FitLine` / `Keep`
	 * remain available for users constructing `HxModuleWriteOptions`
	 * programmatically; the JSON loader still does not parse a
	 * `sameLine.throwBody` key.
	 *
	 * `catchBody` (ω-catch-body) defaults to `Next`, matching haxe-
	 * formatter's `sameLine.catchBody: @:default(Next)` and the
	 * sibling `ifBody`/`forBody`/`whileBody`/`doBody` defaults. Drives
	 * the `)`→body separator at `HxCatchClause.body`. Block bodies
	 * stay inline regardless via `bodyPolicyWrap`'s block-ctor
	 * detection, so the typical `} catch (e:T) { … }` round-trip is
	 * unaffected; only non-block catch bodies (`} catch (e:T)
	 * trace(e);`) see a hardline by default. Opting into `Same`,
	 * `FitLine` or `Keep` requires an explicit `hxformat.json`
	 * override (`"sameLine": { "catchBody": "same" | "fitLine" |
	 * "keep" }`).
	 *
	 * `functionBody` (ω-functionBody-policy) defaults to `Next` —
	 * `function f() expr;` pushes the body onto a fresh line at one
	 * indent level deeper, matching upstream haxe-formatter's
	 * `sameLine.functionBody: @:default(Next)`. Setting `"sameLine":
	 * { "functionBody": "same" }` keeps the body inline with a single
	 * space between the `()` and the body expression. The knob lives
	 * on `HxFnBody.ExprBody`; `BlockBody` (`function f() { … }`) is
	 * unaffected — its layout is owned by `leftCurly`. `NoBody`
	 * (`function f();` interface stub) is unaffected.
	 *
	 * `untypedBody` (ω-untyped-body-policy) defaults to `Same` —
	 * `function f():T untyped { … }` cuddles `untyped` after the
	 * function header by default, matching haxe-formatter's
	 * `sameLine.untypedBody: @:default(Same)`. Setting `"sameLine":
	 * { "untypedBody": "next" }` pushes `untyped` onto its own line
	 * at one indent level deeper. The knob is consumed at
	 * `HxFnBody.UntypedBlockBody` (fn-decl modifier form). Stmt-level
	 * `HxStatement.UntypedBlockStmt` (incl. `try untyped { … }` and
	 * block-stmt `{ untyped { … } }`) is deferred to a follow-up
	 * slice — a duplicate inner wrap would stack with the parent
	 * body-policy / block-stmt separators and produce double spaces
	 * / spurious blank lines. Inline-expression variants
	 * (`HxExpr.UntypedExpr`, single-expr `untyped expr`) ride a
	 * different path and stay unaffected.
	 *
	 * `caseBody` defaults to `Next` — single-stmt switch case bodies
	 * stay on a fresh line below `case X:` for non-expression statement
	 * bodies (block, var, if-stmt, …). `expressionCase` defaults to
	 * `Keep` (slice ω-expression-case-keep-default 2026-05-03) — when
	 * the body's first element had no preceding source newline, the
	 * `case X: foo();` shape is preserved; otherwise the body keeps the
	 * source's multiline layout. Setting either to `Same` flattens
	 * single-stmt bodies unconditionally. `caseBody` corresponds to
	 * haxe-formatter's `sameLine.caseBody: @:default(Next)`;
	 * `expressionCase` to `sameLine.expressionCase: @:default(Same)`.
	 * We pick `Keep` over upstream's `Same` to avoid the `;`-cascade
	 * regression documented in `feedback_case_body_default_flip_regresses.md`
	 * — Keep gates on source same-line-ness so multi-line source bodies
	 * keep their VarStmt `@:trailOpt(';')` cascade behaviour.
	 *
	 * `tryBody` (ω-tryBody) defaults to `Next` — matches upstream
	 * haxe-formatter's `sameLine.tryBody: @:default(next)`. Drives
	 * the body-placement axis at `HxTryCatchStmt.body`. Block bodies
	 * stay inline regardless — the typical `try { … }` round-trip
	 * routes through `bodyPolicyWrap`'s block-ctor path where
	 * `leftCurly` controls the `{` position. Non-block bodies
	 * (`ExprStmt`, etc.) get pushed to the next line at one indent
	 * level deeper (`try\n\tBARE;`). Architecturally orthogonal to
	 * `tryPolicy`: when `tryBody=Same` is opted into via JSON, the
	 * inline gap routes through `opt.tryPolicy` (`After`/`Both` →
	 * space, `None`/`Before` → empty) via the `kwOwnsInlineSpace`
	 * mode in `bodyPolicyWrap`, so `tryPolicy=None` + `tryBody=Same`
	 * still collapses to `try{…}` while default `tryPolicy=After` +
	 * `tryBody=Same` keeps `try {…}`. Opting into `Same`/`FitLine`/
	 * `Keep` requires an explicit `hxformat.json` override
	 * (`"sameLine": { "tryBody": "same" | "fitLine" | "keep" }`).
	 *
	 * `elseIf` (ψ₈) defaults to `Same` — the nested `if` inside an
	 * `else` clause stays on the same line as `else`, matching
	 * haxe-formatter's `sameLine.elseIf: @:default(Same)`. This knob
	 * overrides `elseBody` specifically when the else branch's
	 * statement is an `IfStmt` — keeping the `else if (...)` idiom
	 * inline even though `elseBody=Next` would otherwise push the
	 * nested if to the next line.
	 *
	 * Left-curly default (ψ₆) is `Same` — `{` stays on the same line
	 * as the preceding token (`class F {` / `function f() {`). This
	 * mirrors haxe-formatter's `lineEnds.leftCurly: @:default(After)`
	 * and keeps pre-ψ₆ byte-identical output. Flipping to `Next`
	 * requires an explicit `hxformat.json` override
	 * (`"lineEnds": { "leftCurly": "before" }` or `"both"`).
	 *
	 * Object-literal left-curly default (ω-objectlit-leftCurly) is
	 * `Same` — object-literal braces stay cuddled on the previous line
	 * (`var x = {…}`, `f({…})`). Global `lineEnds.leftCurly` cascades
	 * into this knob (slice ω-objectlit-leftCurly-cascade), mirroring
	 * haxe-formatter's `MarkLineEnds.getCurlyPolicy(ObjectDecl)`
	 * precedence — `lineEnds.leftCurly: "both"` flips both
	 * `opt.leftCurly` AND `opt.objectLiteralLeftCurly` to `Next`. Per-
	 * construct override `"lineEnds": { "objectLiteralCurly": { "leftCurly":
	 * "<value>" } }` wins. Short literals chosen flat by the wrap
	 * cascade stay cuddled even under `Next` — the wrap engine wires
	 * `WrapList.emit`'s `(leadFlat, leadBreak)` so `Group(IfBreak)`
	 * picks cuddled vs Allman per literal's own flat/break decision.
	 *
	 * Empty-curly default (ω-empty-curly-break) is `Same` — empty
	 * bodies stay flat (`class C {}`, `function f() {}`). `Break`
	 * emits empty bodies across two lines with `}` on its own line at
	 * the parent's indent (`class C {\n}`). Mirrors haxe-formatter's
	 * `lineEnds.emptyCurly: @:default(Same)`. Driven via
	 * `@:fmt(emptyCurlyBreak)` on body Stars (`HxClassDecl.members`,
	 * `HxFnBlock.stmts`, etc.).
	 *
	 * Object-field colon default (ψ₇) is `After` — `{a: 0}`, matching
	 * haxe-formatter's `whitespace.objectFieldColonPolicy:
	 * @:default(After)`. This diverges from the pre-ψ₇ output
	 * (`{a:0}`, i.e. `None`) because the corpus reference expects the
	 * spaced form. Callers who want byte-identical pre-ψ₇ layout must
	 * pass `objectFieldColon: WhitespacePolicy.None` explicitly.
	 *
	 * Type-hint colon default (ω-E-whitespace) is `None` — `x:Int`,
	 * `f():Void`. Matches the pre-slice layout and haxe-formatter's
	 * `whitespace.typeHintColonPolicy: @:default(None)`. Callers who
	 * want `x : Int` around the colon must pass `typeHintColon:
	 * WhitespacePolicy.Both` explicitly (or set
	 * `whitespace.typeHintColonPolicy: "around"` in `hxformat.json`).
	 *
	 * Type-check colon default (ω-check-type) is `Both` — `("" : String)`
	 * with surrounding spaces. Matches haxe-formatter's
	 * `whitespace.typeCheckColonPolicy: @:default(Around)`. Diverges
	 * from `typeHintColon`'s `None` default because the type-check `:`
	 * (inside `(expr : Type)`) follows the opposite upstream convention
	 * from the type-annotation `:` (`x:Int`). Callers who want the
	 * tight `("":String)` form must pass `typeCheckColon:
	 * WhitespacePolicy.None` explicitly.
	 *
	 * Func-param-parens default (ω-E-whitespace) is `None` — no space
	 * before the opening `(` of `HxFnDecl.params`. Matches the pre-
	 * slice layout and haxe-formatter's
	 * `whitespace.parenConfig.funcParamParens.openingPolicy:
	 * @:default(None)`.
	 *
	 * Call-parens default (ω-call-parens) is `None` — no space before
	 * the opening `(` of `HxExpr.Call.args`. Matches the pre-slice
	 * layout and haxe-formatter's
	 * `whitespace.parenConfig.callParens.openingPolicy:
	 * @:default(None)`.
	 *
	 * Anon-func-parens default (ω-anon-fn-paren-policy) is `None` — no
	 * space between `function` and the opening `(` of an
	 * `HxExpr.FnExpr(fn:HxFnExpr)` anonymous function (tight
	 * `function(args)…`). The pre-slice writer hardcoded a trailing
	 * space on the `function` kw (yielding `function (args)…`); the
	 * `None` default flips to the upstream haxe-formatter shape so the
	 * common idiom `function() {…}` round-trips byte-identically.
	 * Callers who want `function (args)…` must pass
	 * `anonFuncParens: WhitespacePolicy.Before` (or `Both`)
	 * explicitly, or set
	 * `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
	 * "before"` in `hxformat.json`.
	 *
	 * `anonFuncParamParensKeepInnerWhenEmpty` default
	 * (ω-anon-fn-empty-paren-inner-space) is `false` — an empty
	 * anonymous-function parameter list emits the tight `function()`.
	 * Setting `whitespace.parenConfig.anonFuncParamParens.removeInnerWhenEmpty:
	 * false` in `hxformat.json` flips the runtime knob to `true`,
	 * yielding `function ( ) body` (haxe-formatter parity).
	 *
	 * `fitLineIfWithElse` default (ψ₁₂) is `false` — when an `if` has
	 * an `else` and the body policies are `FitLine`, the bodies fall
	 * back to the `Next` layout instead of flat-or-break. Matches
	 * haxe-formatter's `sameLine.fitLineIfWithElse: @:default(false)`.
	 * Flipping to `true` requires an explicit `hxformat.json` override
	 * (`"sameLine": { "fitLineIfWithElse": true }`).
	 *
	 * `afterFieldsWithDocComments` default (ω-C-empty-lines-doc) is
	 * `One` — one blank line after any class member whose leading
	 * trivia carries a doc comment. Matches haxe-formatter's
	 * `emptyLines.afterFieldsWithDocComments: @:default(One)`. Opting
	 * into `Ignore` (respect source blank-line count) or `None` (strip
	 * the blank line) requires an explicit `hxformat.json` override
	 * (`"emptyLines": { "afterFieldsWithDocComments": "ignore" | "none" }`).
	 *
	 * `existingBetweenFields` default (ω-C-empty-lines-between-fields)
	 * is `Keep` — source blank lines between class members survive
	 * round-trip, matching haxe-formatter's
	 * `emptyLines.classEmptyLines.existingBetweenFields:
	 * @:default(Keep)`. Opting into `Remove` (strip every blank line
	 * between siblings regardless of source) requires an explicit
	 * `hxformat.json` override (`"emptyLines": { "classEmptyLines":
	 * { "existingBetweenFields": "remove" } }`).
	 *
	 * `beforeDocCommentEmptyLines` default (ω-C-empty-lines-before-doc)
	 * is `One` — one blank line before any class member whose leading
	 * trivia carries a doc comment. Matches haxe-formatter's
	 * `emptyLines.beforeDocCommentEmptyLines: @:default(One)`. Opting
	 * into `Ignore` (respect source blank-line count) or `None` (strip
	 * the blank line) requires an explicit `hxformat.json` override
	 * (`"emptyLines": { "beforeDocCommentEmptyLines": "ignore" | "none" }`).
	 *
	 * Inter-member blank-line defaults (ω-interblank-defaults) match
	 * haxe-formatter's `emptyLines.classEmptyLines`:
	 * `betweenFunctions: 1`, `afterVars: 1`, `betweenVars: 0`. One
	 * blank line is inserted between two sibling functions, and at a
	 * `var` → `function` or `function` → `var` transition.
	 * Consecutive vars stay tight. Opting out of these blank-line
	 * gates requires an explicit `hxformat.json` override
	 * (`"emptyLines": { "classEmptyLines": { "betweenFunctions": 0,
	 * "afterVars": 0 } }`). The defaults were kept at `0` for the
	 * initial ω-interblank plumbing slice to land the infrastructure
	 * and audit unit/corpus deltas independently; this slice flips
	 * them to the upstream values.
	 *
	 * Interface inter-member blank-line defaults (ω-iface-interblank)
	 * are all 0: consecutive interface members stay tight regardless of
	 * kind, matching haxe-formatter InterfaceFieldsEmptyLinesConfig
	 * defaults (betweenVars: 0, betweenFunctions: 0, afterVars: 0).
	 * Opting in requires an explicit hxformat.json override:
	 * "emptyLines": { "interfaceEmptyLines": { "betweenFunctions": 1 } }.
	 * The interface knobs are independent of the class/abstract
	 * betweenVars / betweenFunctions / afterVars fields so the two
	 * member-bodies can be tuned separately.
	 *
	 * Typedef-rhs `=` spacing default (ω-typedef-assign) is `Both` —
	 * `typedef Foo = Bar;`, matching haxe-formatter's
	 * `whitespace.binopPolicy: @:default(Around)` for the typedef-rhs
	 * site. Callers who want the pre-slice tight `typedef Foo=Bar;`
	 * layout must pass `typedefAssign: WhitespacePolicy.None` explicitly.
	 *
	 * Type-param default `=` spacing default (ω-typeparam-default-equals)
	 * is `Both` — `<T = Int>` / `<T:Foo = Bar>`, matching haxe-formatter's
	 * `whitespace.binopPolicy: @:default(Around)` for the type-param-
	 * default site. Callers who want the tight `<T=Int>` layout (the
	 * `_none` corpus variant) must pass
	 * `typeParamDefaultEquals: WhitespacePolicy.None` explicitly, or
	 * load `whitespace.binopPolicy: "none"` via the JSON config.
	 *
	 * Type-param `<>` spacing defaults (ω-typeparam-spacing) are both
	 * `None` — `Array<Int>` and `class Foo<T>` stay tight, matching
	 * haxe-formatter's `whitespace.typeParamOpenPolicy: @:default(None)`
	 * and `whitespace.typeParamClosePolicy: @:default(None)`. Opting
	 * into the spaced form requires explicit `hxformat.json` overrides:
	 * `"whitespace": { "typeParamOpenPolicy": "after",
	 * "typeParamClosePolicy": "before" }` produces `Array< Int >`.
	 *
	 * Anon-type `{}` interior spacing defaults (ω-anontype-braces) are
	 * both `None` — `{x:Int}` stays tight. haxe-formatter's
	 * `bracesConfig.anonTypeBraces` defaults to `{openingPolicy: Before,
	 * closingPolicy: OnlyAfter}` whose effective inside-spaces are also
	 * none, so the tight form matches upstream's default output for the
	 * inside-of-braces axis. Opting into the spaced form requires:
	 * `"whitespace": { "bracesConfig": { "anonTypeBraces":
	 * { "openingPolicy": "around", "closingPolicy": "around" } } }`
	 * which produces `{ x:Int }`.
	 *
	 * Object-literal `{}` interior spacing defaults (ω-objectlit-braces)
	 * are both `None` — `{a: 1}` stays tight. haxe-formatter's
	 * `bracesConfig.objectLiteralBraces` defaults to `{openingPolicy:
	 * Before, closingPolicy: OnlyAfter}` whose effective inside-spaces
	 * are also none. Opting into the spaced form requires:
	 * `"whitespace": { "bracesConfig": { "objectLiteralBraces":
	 * { "openingPolicy": "around", "closingPolicy": "around" } } }`
	 * which produces `{ a: 1 }`.
	 *
	 * `addLineCommentSpace` default (ω-line-comment-space) is `true` —
	 * captured `//foo` line comments are re-emitted as `// foo` when
	 * the body's first non-decoration character is alphanumeric or
	 * other non-`[/\*\-\s]` content. Decoration runs (`//*******`,
	 * `//---------`, `////////////`) survive tight. Matches haxe-
	 * formatter's `whitespace.addLineCommentSpace: @:default(true)`.
	 * Setting to `false` requires
	 * `"whitespace": { "addLineCommentSpace": false }` in
	 * `hxformat.json`.
	 *
	 * `expressionTry` default (ω-expression-try) is `Same` — the
	 * expression-position `try ... catch ...` form stays on one line,
	 * matching haxe-formatter's `sameLine.expressionTry:
	 * @:default(Same)`. Independent of `sameLineCatch` (statement-
	 * form). Setting to `Next` requires
	 * `"sameLine": { "expressionTry": "next" }` in `hxformat.json`.
	 *
	 * `indentCaseLabels` default (ω-indent-case-labels) is `true` — the
	 * `case` / `default` labels of a `switch` body are indented one
	 * level inside the surrounding `{ ... }` (matching haxe-formatter's
	 * `indentation.indentCaseLabels: @:default(true)`). Setting to
	 * `false` keeps the labels flush with the `switch` keyword and
	 * requires `"indentation": { "indentCaseLabels": false }` in
	 * `hxformat.json`.
	 *
	 * `indentObjectLiteral` default (ω-indent-objectliteral) is `true` —
	 * an `ObjectLit` value placed on the right-hand side of `=`/`:`/`(`
	 * /`[`/keyword picks up one extra indent step in front of `{` when
	 * `objectLiteralLeftCurly` is `Next` / `both` (Allman), matching
	 * haxe-formatter's `indentation.indentObjectLiteral: @:default(true)`
	 * rule which only fires for own-line `{`. Setting to `false`
	 * requires `"indentation": { "indentObjectLiteral": false }` in
	 * `hxformat.json` and disables the extra indent. Under `Same`
	 * (cuddled) leftCurly the knob is inert in both directions. The
	 * gate fires only at sites tagged with `@:fmt(indentValueIfCtor(
	 * 'ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'))` in
	 * the grammar (currently `HxVarDecl.init` and `HxObjectField.value`).
	 *
	 * `indentComplexValueExpressions` default (ω-indent-complex-value-expr)
	 * is `false` — an `IfExpr` value on `=`/`:`/`(`/`[`/keyword RHS
	 * renders without an extra indent step (matching haxe-formatter's
	 * `indentation.indentComplexValueExpressions: @:default(false)`).
	 * Setting to `true` requires
	 * `"indentation": { "indentComplexValueExpressions": true }` in
	 * `hxformat.json` and adds one indent step to the value's hardlines
	 * (the `{ … } else { … }` block bodies of `var x = if (cond) … else …;`
	 * shift one tab right). The gate fires only at sites tagged with
	 * `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
	 * in the grammar (currently `HxVarDecl.init`).
	 *
	 * `functionTypeHaxe4` default (ω-arrow-fn-type) is `Both` — the `->`
	 * separator inside a new-form arrow function type
	 * (`HxArrowFnType.ret`) emits `(args) -> ret` with surrounding
	 * spaces, matching haxe-formatter's
	 * `whitespace.functionTypeHaxe4Policy: @:default(Around)`. Setting
	 * to `None` produces the tight `(args)->ret` form and requires
	 * `"whitespace": { "functionTypeHaxe4Policy": "none" }` in
	 * `hxformat.json`. The old-form curried arrow `Int->Bool` is on a
	 * separate axis (`@:fmt(functionTypeHaxe3)` on `HxType.Arrow` →
	 * `opt.functionTypeHaxe3`, default `None` — see field doc below).
	 *
	 * `functionTypeHaxe3` default (Writer Slice 6) is `None` — the `->`
	 * separator inside an old-form curried arrow type (`HxType.Arrow`)
	 * emits `Int->Bool` tight, matching haxe-formatter's
	 * `whitespace.functionTypeHaxe3Policy: @:default(None)`. Setting to
	 * `Both` (via `"whitespace": { "functionTypeHaxe3Policy": "around" }`)
	 * flips to spaced `Int -> Bool`. Independent of `functionTypeHaxe4`,
	 * so a config can space one arrow form while keeping the other
	 * tight.
	 *
	 * `arrowFunctions` default (ω-arrow-fn-expr) is `Both` — the `->`
	 * separator inside a parenthesised arrow lambda expression
	 * (`HxThinParenLambda.body`) emits `(params) -> body` with
	 * surrounding spaces, matching haxe-formatter's
	 * `whitespace.arrowFunctionsPolicy: @:default(Around)`. Setting to
	 * `None` produces the tight `(params)->body` form and requires
	 * `"whitespace": { "arrowFunctionsPolicy": "none" }` in
	 * `hxformat.json`. Independent of `functionTypeHaxe4` (the type-
	 * position knob); the single-ident infix form `arg -> body`
	 * (`HxExpr.ThinArrow`) is on the Pratt infix path which already
	 * adds surrounding spaces by default and is unaffected.
	 *
	 * `ifPolicy` default (ω-if-policy) is `After` — the gap between the
	 * `if` keyword and the opening `(` of its condition is a single
	 * space, producing `if (cond)` for both `HxStatement.IfStmt` and
	 * `HxExpr.IfExpr`. Matches the pre-slice fixed trailing space on
	 * the `if` keyword and haxe-formatter's effective default. Setting
	 * to `None` (or the JSON-side `"onlyBefore"`) collapses the gap to
	 * `if(cond)` and requires `"whitespace": { "ifPolicy": "onlyBefore" }`
	 * (or `"none"`) in `hxformat.json`.
	 *
	 * `forPolicy` / `whilePolicy` / `switchPolicy` defaults
	 * (ω-control-flow-policies) are `After` — same shape as `ifPolicy`,
	 * driven by `@:fmt(forPolicy)` on `HxStatement.ForStmt` /
	 * `HxExpr.ForExpr`, `@:fmt(whilePolicy)` on `HxStatement.WhileStmt`
	 * / `HxExpr.WhileExpr`, and `@:fmt(switchPolicy)` on all four switch
	 * ctors (parens / bare × stmt / expr). Matches haxe-formatter's
	 * `whitespace.{forPolicy,whilePolicy,switchPolicy}: @:default(After)`.
	 *
	 * `tryPolicy` default (ω-try-policy) is `After` — same shape as
	 * `ifPolicy`, driven by `@:fmt(tryPolicy)` on
	 * `HxStatement.TryCatchStmt` (block-body form only; the bare-body
	 * sibling's `bareBodyBreaks` predicate gates the slot to `null`).
	 * Matches haxe-formatter's `whitespace.tryPolicy: @:default(After)`.
	 *
	 * `afterPackage` default (ω-after-package) is `1` — exact number of
	 * blank lines between the top-level `package …;` directive and the
	 * next decl. Override semantics: the source-captured blank-line
	 * count is replaced with this value, so `0` strips an existing
	 * blank line and `2` doubles one regardless of source. Matches
	 * haxe-formatter's `emptyLines.afterPackage: @:default(1)`. Driven
	 * by
	 * `@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))`
	 * on `HxModule.decls` and consumed by the trivia-mode EOF Star path
	 * in `WriterLowering.triviaEofStarExpr`.
	 *
	 * `beforePackage` default (ω-before-package) is `0` — exact number of
	 * blank lines emitted at file head BEFORE the leading `package …;`
	 * directive. Override semantics, head-of-Star only: the source-
	 * captured blank-line count is replaced once at the start of the
	 * module. `0` (default) keeps the file leading edge tight against
	 * `package …;` even when the source had blank lines before it; `1`
	 * inserts one blank line so the file starts with a leading newline.
	 * Matches haxe-formatter's `emptyLines.beforePackage: @:default(0)`.
	 * Driven by
	 * `@:fmt(blankLinesAtHeadIfCtor('decl', 'PackageDecl', 'PackageEmpty', 'beforePackage'))`
	 * on `HxModule.decls` and consumed by the head-emit splice in
	 * `WriterLowering.triviaEofStarExpr` (head-of-Star override fires
	 * once before the per-element loop).
	 *
	 * `beforeUsing` default (ω-imports-using-blank) is `1` — exact number
	 * of blank lines between an `import` (or any non-`using`) decl and
	 * the following `using` decl at module top level. Override
	 * semantics: the source-captured blank-line count is replaced with
	 * this value at the `import → using` transition, so `0` strips an
	 * existing blank line and `2` doubles one regardless of source.
	 * Consecutive `using` decls fall through to the source-driven
	 * binary `blankBefore` flag. Matches haxe-formatter's
	 * `emptyLines.importAndUsing.beforeUsing: @:default(1)`. Driven by
	 * `@:fmt(blankLinesBeforeCtor('decl', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))`
	 * on `HxModule.decls` and consumed by the trivia-mode EOF Star path
	 * in `WriterLowering.triviaEofStarExpr`.
	 *
	 * `betweenImports` default (ω-imports-using-between) is `0` — exact
	 * number of blank lines between two consecutive same-kind imports
	 * (or two consecutive same-kind usings) whose dotted-ident paths
	 * fall into different groups at `betweenImportsLevel`. Override
	 * semantics: the source-captured blank-line count is replaced on a
	 * level-mismatch boundary. Same-level pairs fall through to the
	 * source-driven `blankBefore` flag. Matches haxe-formatter's
	 * `emptyLines.importAndUsing.betweenImports: @:default(0)`.
	 *
	 * `betweenImportsLevel` default (ω-imports-using-between) is `All` —
	 * granularity of the level test for `betweenImports`. `All` treats
	 * every same-kind boundary as a level mismatch (one blank between
	 * every pair); `FirstLevelPackage` … `FifthLevelPackage` compare
	 * the first N dot-separated segments; `FullPackage` compares the
	 * full path. Matches haxe-formatter's
	 * `BetweenImportsEmptyLinesLevel: @:default(All)`. Driven together
	 * with `betweenImports` by
	 * `@:fmt(blankLinesBetweenSameCtorByLevel('decl', Ctor1, [Ctor2, …],
	 * 'betweenImportsLevel', 'betweenImports',
	 * 'betweenImportsPathDiffers'))` on `HxModule.decls` and consumed
	 * by the trivia-mode EOF Star path in
	 * `WriterLowering.triviaEofStarExpr`. The path-comparison helper
	 * is wired through the format-neutral
	 * `WriteOptions.betweenImportsPathDiffers` adapter slot, defaulted
	 * to `HxBetweenImportsLevel.pathDiffers`.
	 *
	 * `beforeType` default (ω-imports-using-before-type) is `1` — exact
	 * number of blank lines the writer emits at the import/using →
	 * type-decl transition (current decl is `ClassDecl` /
	 * `InterfaceDecl` / `AbstractDecl` / `EnumDecl` / `TypedefDecl` /
	 * `FnDecl`, previous decl is an import or using directive).
	 * Override semantics: the source-captured blank-line count is
	 * replaced with this value at the transition, so `0` strips an
	 * existing blank line and `2` doubles one regardless of source.
	 * Matches haxe-formatter's `emptyLines.importAndUsing.beforeType:
	 * @:default(1)`. Driven by
	 * `@:fmt(blankLinesOnTransitionAcross('decl', 'ImportDecl',
	 * 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl',
	 * 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'TypedefDecl',
	 * 'FnDecl', 'beforeType'))` on `HxModule.decls`,
	 * `HxConditionalDecl.body` / `elseBody`, and `HxElseifDecl.body`
	 * (mirrored cluster), consumed by the trivia-mode EOF Star path in
	 * `WriterLowering.triviaEofStarExpr`. Conditional transparency
	 * from the existing `betweenImportsTailLeafClassify` /
	 * `betweenImportsHeadLeafClassify` adapters extends to this
	 * transition automatically — both share the `'decl'` classifier.
	 *
	 * `afterMultilineDecl` / `beforeMultilineDecl` defaults
	 * (ω-after-multiline) are both `1` — exact number of blank lines the
	 * writer emits around a multi-line top-level type/function decl
	 * (Class/Interface/Abstract/Enum with non-empty members, or FnDecl
	 * with non-empty BlockBody). Override semantics. Matches
	 * haxe-formatter's `emptyLines.betweenTypes: @:default(1)` and
	 * `emptyLines.betweenSingleLineTypes: @:default(0)` discrimination —
	 * the predicate-gated variant fires only on multi-line shapes, so
	 * runs of single-line type decls fall through to the source-driven
	 * blank-line slot (no override). Driven by
	 * `@:fmt(blankLinesAfterCtorIf('decl', 'multiline', 'ClassDecl', …, 'afterMultilineDecl'))`
	 * and the symmetric `BeforeCtorIf` on `HxModule.decls`. The
	 * predicate `'multiline'` is grammar-derived at compile time —
	 * `WriterLowering.buildMultilinePredicate` walks each ctor's arg
	 * type, reading typedef-level
	 * `@:fmt(multilineWhenFieldNonEmpty(<arrayField>))` /
	 * `@:fmt(multilineWhenFieldShape(<refField>))` and ctor-level
	 * `@:fmt(multilineCtor)` annotations on the relevant grammar types
	 * (`HxClassDecl` / `HxInterfaceDecl` / `HxAbstractDecl` / `HxEnumDecl` /
	 * `HxFnDecl` / `HxFnBlock` / `HxFnBody.BlockBody`). Zero runtime
	 * reflection — the macro emits direct field access + `length > 0`
	 * comparison.
	 */
	public var defaultWriteOptions(default, null):HxModuleWriteOptions = {
		indentChar: Tab,
		indentSize: 1,
		tabWidth: 4,
		lineWidth: 160,
		lineEnd: '\n',
		finalNewline: true,
		trailingWhitespace: false,
		maxConsecutiveBlanks: 1,
		commentStyle: CommentStyle.Verbatim,
		sameLineElse: SameLinePolicy.Same,
		sameLineCatch: SameLinePolicy.Same,
		sameLineDoWhile: SameLinePolicy.Same,
		sameLineExpressionElse: SameLinePolicy.Same,
		trailingCommaArrays: false,
		trailingCommaArgs: false,
		trailingCommaParams: false,
		trailingCommaObjectLits: false,
		ifBody: BodyPolicy.Keep,
		elseBody: BodyPolicy.Keep,
		forBody: BodyPolicy.Keep,
		whileBody: BodyPolicy.Keep,
		doBody: BodyPolicy.Keep,
		returnBody: BodyPolicy.FitLine,
		returnBodySingleLine: BodyPolicy.FitLine,
		throwBody: BodyPolicy.Same,
		catchBody: BodyPolicy.Next,
		tryBody: BodyPolicy.Next,
		caseBody: BodyPolicy.Keep,
		expressionCase: BodyPolicy.Keep,
		functionBody: BodyPolicy.Next,
		anonFunctionBody: BodyPolicy.Same,
		untypedBody: BodyPolicy.Same,
		expressionIfBody: BodyPolicy.Keep,
		expressionElseBody: BodyPolicy.Keep,
		expressionForBody: BodyPolicy.Keep,
		expressionIfWithBlocks: false,
		leftCurly: BracePlacement.Same,
		emptyCurly: EmptyCurly.Same,
		objectLiteralLeftCurly: BracePlacement.Same,
		anonTypeLeftCurly: BracePlacement.Same,
		anonFunctionLeftCurly: BracePlacement.Same,
		anonFunctionEmptyCurly: EmptyCurly.Same,
		blockLeftCurly: BracePlacement.Same,
		blockEmptyCurly: EmptyCurly.Same,
		blockRightCurly: RightCurlyPlacement.Same,
		anonFunctionRightCurly: RightCurlyPlacement.Same,
		anonTypeRightCurly: RightCurlyPlacement.Same,
		objectLiteralRightCurly: RightCurlyPlacement.Same,
		objectFieldColon: WhitespacePolicy.After,
		typeHintColon: WhitespacePolicy.None,
		typeCheckColon: WhitespacePolicy.Both,
		funcParamParens: WhitespacePolicy.None,
		callParens: WhitespacePolicy.None,
		anonFuncParens: WhitespacePolicy.None,
		anonFuncParamParensKeepInnerWhenEmpty: false,
		ifPolicy: WhitespacePolicy.After,
		forPolicy: WhitespacePolicy.After,
		whilePolicy: WhitespacePolicy.After,
		switchPolicy: WhitespacePolicy.After,
		tryPolicy: WhitespacePolicy.After,
		elseIf: KeywordPlacement.Same,
		fitLineIfWithElse: false,
		ifElseSemicolonNextLine: true,
		afterFieldsWithDocComments: CommentEmptyLinesPolicy.One,
		existingBetweenFields: KeepEmptyLinesPolicy.Keep,
		externExistingBetweenFields: KeepEmptyLinesPolicy.Keep,
		beforeDocCommentEmptyLines: CommentEmptyLinesPolicy.One,
		betweenVars: 0,
		betweenFunctions: 1,
		afterVars: 1,
		afterStaticVars: 1,
		betweenStaticFunctions: 1,
		interfaceBetweenVars: 0,
		interfaceBetweenFunctions: 0,
		interfaceAfterVars: 0,
		betweenEnumCtors: 0,
		beginType: 0,
		endType: 0,
		typedefBeginType: 0,
		typedefBetweenFields: 0,
		typedefExistingBetweenFields: KeepEmptyLinesPolicy.Keep,
		typedefEndType: 0,
		afterLeftCurly: KeepEmptyLinesPolicy.Keep,
		beforeRightCurly: KeepEmptyLinesPolicy.Keep,
		typedefAssign: WhitespacePolicy.Both,
		typedefIntersection: WhitespacePolicy.After,
		typeParamDefaultEquals: WhitespacePolicy.Both,
		typeParamOpen: WhitespacePolicy.None,
		typeParamClose: WhitespacePolicy.None,
		anonTypeBracesOpen: WhitespacePolicy.None,
		anonTypeBracesClose: WhitespacePolicy.None,
		objectLiteralBracesOpen: WhitespacePolicy.None,
		objectLiteralBracesClose: WhitespacePolicy.None,
		accessBracketsOpen: WhitespacePolicy.None,
		accessBracketsClose: WhitespacePolicy.None,
		arrayLiteralBracketsOpen: WhitespacePolicy.None,
		arrayLiteralBracketsClose: WhitespacePolicy.None,
		mapLiteralBracketsOpen: WhitespacePolicy.None,
		mapLiteralBracketsClose: WhitespacePolicy.None,
		comprehensionBracketsOpen: WhitespacePolicy.None,
		comprehensionBracketsClose: WhitespacePolicy.None,
		callParensInsideOpen: WhitespacePolicy.None,
		callParensInsideClose: WhitespacePolicy.None,
		ifCondParensInsideOpen: WhitespacePolicy.None,
		ifCondParensInsideClose: WhitespacePolicy.None,
		whileCondParensInsideOpen: WhitespacePolicy.None,
		whileCondParensInsideClose: WhitespacePolicy.None,
		switchCondParensInsideOpen: WhitespacePolicy.None,
		switchCondParensInsideClose: WhitespacePolicy.None,
		catchParensGap: WhitespacePolicy.After,
		catchParensInsideOpen: WhitespacePolicy.None,
		catchParensInsideClose: WhitespacePolicy.None,
		sharpCondParensGap: WhitespacePolicy.After,
		sharpCondParensInsideOpen: WhitespacePolicy.None,
		sharpCondParensInsideClose: WhitespacePolicy.None,
		objectLiteralWrap: HaxeFormat.defaultObjectLiteralWrap(),
		callParameterWrap: HaxeFormat.defaultCallParameterWrap(),
		arrayLiteralWrap: HaxeFormat.defaultArrayLiteralWrap(),
		multiVarWrap: HaxeFormat.defaultMultiVarWrap(),
		casePatternWrap: HaxeFormat.defaultCasePatternWrap(),
		anonTypeWrap: HaxeFormat.defaultAnonTypeWrap(),
		methodChainWrap: HaxeFormat.defaultMethodChainWrap(),
		opBoolChainWrap: HaxeFormat.defaultOpBoolChainWrap(),
		opAddSubChainWrap: HaxeFormat.defaultOpAddSubChainWrap(),
		conditionWrap: HaxeFormat.defaultConditionWrap(),
		ternaryWrap: HaxeFormat.defaultTernaryWrap(),
		functionSignatureWrap: HaxeFormat.defaultFunctionSignatureWrap(),
		anonFunctionSignatureWrap: HaxeFormat.defaultAnonFunctionSignatureWrap(),
		metadataCallParameterWrap: HaxeFormat.defaultMetadataCallParameterWrap(),
		typeParameterWrap: HaxeFormat.defaultTypeParameterWrap(),
		expressionWrappingWrap: HaxeFormat.defaultExpressionWrappingWrap(),
		implementsExtendsWrap: HaxeFormat.defaultImplementsExtendsWrap(),
		arrayMatrixWrap: ArrayMatrixWrap.MatrixWrapWithAlign,
		conditionalPolicy: ConditionalIndentationPolicy.Aligned,
		alignInlineSwitchCaseBody: false,
		addLineCommentSpace: true,
		compressSuccessiveParenthesis: true,
		expressionTry: SameLinePolicy.Same,
		indentCaseLabels: true,
		indentObjectLiteral: true,
		indentComplexValueExpressions: false,
		indentVarTypeHintAnon: true,
		functionTypeHaxe4: WhitespacePolicy.Both,
		functionTypeHaxe3: WhitespacePolicy.None,
		arrowFunctions: WhitespacePolicy.Both,
		afterPackage: 1,
		beforePackage: 0,
		beforeUsing: 1,
		betweenImports: 0,
		betweenImportsLevel: HxBetweenImportsLevel.All,
		keepSourceBlankAcrossConditional: false,
		beforeType: 1,
		afterMultilineDecl: 1,
		beforeMultilineDecl: 1,
		afterConditionalBlock: 0,
		afterFileHeaderComment: 1,
		betweenMultilineComments: 0,
		betweenSingleLineTypes: 0,
		formatStringInterpolation: true,
		metadataFunctionLineEnd: MetadataLineEndPolicy.None,
		_inExprPosition: false,
		_classExtern: false,
		_inAnonFnBody: false,
		_inTypedefBody: false,
		_fnSigBodyEmpty: false,
		_chainModeOverride: null,
		_callArgChainNest: false,
		_suppressMore: false,
		_parenInCondition: false,
		_varKwNewline: false,
		_inFieldLevelVar: false,
		_keepFlatInner: false,
		_keepChainInParen: false,
		_intersectionOperandBreak: false,
		blockCommentAdapter: anyparse.format.comment.BlockCommentNormalizer.processCapturedBlockComment,
		lineCommentAdapter: anyparse.format.comment.LineCommentNormalizer.normalizeLineComment,
		endsWithCloseBrace: HxExprUtil.endsWithCloseBrace,
		caseBodyRefusesFlat: HxExprUtil.refusesCaseFlat,
		arrayBracketKind: HxExprUtil.arrayBracketKind,
		betweenImportsPathDiffers: HxBetweenImportsLevel.pathDiffers,
		betweenImportsTailLeafClassify: HxExprUtil.tailLeafClassifyImports,
		betweenImportsHeadLeafClassify: HxExprUtil.headLeafClassifyImports,
		tailLeafKeepsBlankAfterConditional: HxExprUtil.tailLeafKeepsBlankAfterConditional,
		elementIsConditional: HxExprUtil.elementIsConditional,
	};

	private function new() {}

	/**
	 * Default `WrapRules` cascade for `HxObjectLit.fields` — ported
	 * verbatim from haxe-formatter's `wrapping.objectLiteral` rule set
	 * in `resources/default-hxformat.json` (AxGord fork). Returned as a
	 * fresh struct on each call so test code that mutates the
	 * `defaultWriteOptions.objectLiteralWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultObjectLiteralWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.ItemCountLessThan, value: 3},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 30}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 60}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxExpr.Call.args` — ported
	 * verbatim from haxe-formatter's `wrapping.callParameter` rule set
	 * in `resources/default-hxformat.json` (AxGord fork). Five rules in
	 * source order: `itemCount>=7`, `totalItemLength>=140`,
	 * `anyItemLength>=80`, `lineLength>=160`, `exceedsMaxLineLength==1`
	 * — all `FillLine`, defaultMode `NoWrap`. The `lineLength>=160`
	 * rule (slice ω-callparam-linelen-160) is functionally subsumed by
	 * `totalItemLength>=140` at this default — `LineLengthLargerThan`
	 * evaluates to `totalItemLen >= n` like its sibling — but is kept
	 * present for byte-exact alignment with upstream and so user-side
	 * `hxformat.json` tweaks that lower `totalItemLength` without
	 * touching `lineLength` keep the threshold intact. Returned as a
	 * fresh struct on each call so test code that mutates the
	 * `defaultWriteOptions.callParameterWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultCallParameterWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 7}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 140}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 80}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.LineLengthLargerThan, value: 160}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxExpr.ArrayExpr.elems` — ported
	 * from haxe-formatter's `wrapping.arrayWrap` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). Now matches the
	 * upstream first rule `hasMultilineItems → OnePerLine` directly,
	 * after `WrapList.emit` decoupled item-multiline detection from
	 * width measurement (slice ω-flatlength-decouple-tokenwidth) — items
	 * with hardlines anywhere (incl. `BodyGroup`-deferred bodies) feed
	 * `total`/`maxLen` as clean `flatTokenWidth` while `hasMultilineItems`
	 * triggers via the new `HasMultilineItems` cascade condition. The
	 * `equalItemLengths` condition and its `fillLineWithLeadingBreak`
	 * rule remain skipped — none of the current corpus fixtures depends
	 * on it. Returned as a fresh struct on each call so test code that
	 * mutates the `defaultWriteOptions.arrayLiteralWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultArrayLiteralWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.HasMultilineItems, value: 1}],
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [{cond: WrapConditionType.TotalItemLengthLessThan, value: 80}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 30}],
				},
				{
					mode: WrapMode.FillLineWithLeadingBreak,
					conditions: [
						{cond: WrapConditionType.AllItemLengthsLessThan, value: 10},
						{cond: WrapConditionType.ItemCountLargerThan, value: 10},
					],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxVarDecl.more` — the binding list
	 * of a multi-variable declaration (`var a = 1, b = 2, c = 3;`).
	 * Ported from haxe-formatter's `wrapping.multiVar` rule set in
	 * `resources/default-hxformat.json` (AxGord fork): short items pack
	 * via `FillLine`, wide bindings break one-per-line-after-first once
	 * the column or the configured `maxLineLength` is exceeded.
	 *
	 * Divergence note: the fork's rule 1 condition is `anyItemLength <= n`
	 * (MIN item length ≤ n — "at least one short binding"); anyparse has
	 * no min≤n `WrapConditionType`, so `AllItemLengthsLessThan` (MAX ≤ n —
	 * "every binding short") is used instead. The two coincide on every
	 * corpus target (issue_355 bindings ~30 > 15 → both miss; issue_430
	 * bindings ≤ 3 → both fire); they diverge only on mixed-width wide
	 * decls, which fail regardless. Returned as a fresh struct on each
	 * call so test code that mutates the
	 * `defaultWriteOptions.multiVarWrap` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultMultiVarWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.AllItemLengthsLessThan, value: 15}],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{cond: WrapConditionType.LineLengthLargerThan, value: 80}],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxCaseBranch.patterns` — the
	 * comma-separated pattern list of a multi-value `case` label
	 * (`case A, B, C:`). Ported verbatim from haxe-formatter's
	 * `wrapping.casePattern` rule set in `config/WrapConfig.hx` (AxGord
	 * fork): single/double patterns stay flat (`NoWrap` default), lists
	 * of three or more pack Wadler-style via `FillLine`, and any list
	 * that overflows `maxLineLength` also fills. Consumed at the fork's
	 * `markSingleCasePatternChain`. Returned as a fresh struct on each
	 * call so test code that mutates the
	 * `defaultWriteOptions.casePattern` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultCasePatternWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 2}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxType.Anon.fields` — ported
	 * from haxe-formatter's `wrapping.anonType` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). The full rule
	 * set encodes cleanly against the current `WrapConditionType`
	 * surface: short anon types stay flat via the AND-conjunction of
	 * `itemCount<=3` and `exceedsMaxLineLength==0`, with three
	 * cascading `OnePerLine` triggers (`anyItemLength>=30`,
	 * `totalItemLength>=60`, `itemCount>=4`) and `FillLine` as the
	 * `exceedsMaxLineLength==1` fallback. Returned as a fresh struct on
	 * each call so test code that mutates the
	 * `defaultWriteOptions.anonTypeWrap` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultAnonTypeWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.ItemCountLessThan, value: 3},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 30}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 60}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for postfix `.method(args)` chains —
	 * ported from haxe-formatter's `wrapping.methodChain` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). Slice
	 * ω-linelen-static added the runtime infra for `lineLength >= n`
	 * (initially evaluated statically against `totalItemFlatLength`).
	 * Slice ω-linelen-methodchain-baseline first tried to adopt upstream's
	 * leading `lineLength >= 160` rule and reverted: static eval used
	 * `MethodChainEmit.chainItemLength` which descended into `BodyGroup`
	 * content, while the renderer's `fitsFlat` defers BG content
	 * (Departure 2). Multi-line lambda / block / struct-lit bodies
	 * inflated `total` and the rule fired for chains the renderer would
	 * (and the corpus expected to) keep flat — `issue_576_switch_indentation`
	 * regressed. Slice ω-chain-itemlen-bg-defer aligned `chainItemLength`
	 * with `fitsFlat`'s BG-defer and re-adopted the leading rule (full
	 * 6-rule cascade now matches upstream). Slice
	 * ω-methodchain-threshold-aware migrated `MethodChainEmit.emit` off
	 * the legacy column-blind `decide` evaluator onto
	 * `decideWithLineLengthState` + `IfWidthExceeds` — at default
	 * `lineWidth=160` the leading `LineLengthLargerThan: 160` collapses
	 * cleanly to the existing `exceeds` semantic via the standard
	 * `IfBreak` pivot; user-modified `lineWidth` now routes the answer
	 * through the renderer's column-aware probe. The cascade also covers
	 * the common cases via `IfBreak`-split between `NoWrap` and
	 * `OnePerLineAfterFirst`, picked at render time by the parent `Group`.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.methodChainWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultMethodChainWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{cond: WrapConditionType.LineLengthLargerThan, value: 160}],
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.ItemCountLessThan, value: 3},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.TotalItemLengthLessThan, value: 80},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [
						{cond: WrapConditionType.AnyItemLengthLargerThan, value: 30},
						{cond: WrapConditionType.ItemCountLargerThan, value: 4},
					],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 7}],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `||` / `&&` chains.
	 *
	 * **Pivot (slice ω-drop-soft-thresholds):** anyparse-core defaults
	 * adopt **one hard limit** (`lineWidth`) and drop fork's two leading
	 * soft-threshold rules (`lineLength >= 140 → OnePerLineAfterFirst`
	 * and `lineLength >= 140 → FillLine`). Soft thresholds are a
	 * Haxe-formatter author's stylistic choice ("wrap proactively at
	 * 87% of hard limit"), not universal truth — JSON / AS3 / future
	 * grammars inherit anyparse-core defaults and should not pay the
	 * per-cascade `IfWidthExceeds(140, …)` render-probe cost or carry a
	 * Haxe-specific aesthetic. Users who want fork-style aesthetic for
	 * Haxe load a custom `hxformat.json` that re-introduces the
	 * `wrapping.opBoolChain.lineLength` rules.
	 *
	 * Rules (first-match):
	 *  1. `itemCount <= 3` + `!exceeds` → NoWrap
	 *  2. `totalItemLength <= 120` + `!exceeds` → NoWrap
	 *  3. `itemCount >= 4` → OnePerLineAfterFirst
	 *  4. `exceeds` → FillLine
	 *
	 * `defaultMode: NoWrap` preserves the cascade-level fallback for
	 * the rare case where no rule matches (only possible when the
	 * chain is exactly 0/1 items, which the engine short-circuits).
	 *
	 * Rule 4 mode is `FillLine` so a chain that exceeds the hard limit
	 * but has < 4 items packs Wadler-style rather than collapsing to
	 * one-per-line. Rule 3 fires first for ≥ 4 items.
	 *
	 * `location: BeforeLast` on every wrapping rule mirrors fork's
	 * per-rule setting and shields each rule from the cascade-level
	 * `defaultLocation: AfterLast` fallback.
	 *
	 * Divergence from upstream `default-hxformat.json wrapping.opBoolChain`:
	 * rules 1, 2 (`lineLength >= 140`) intentionally absent. Slice
	 * ω-drop-soft-thresholds confirmed Δ pass = 0 across all 3 corpus
	 * buckets (ws / sl / idn) on the AxGord fork fixtures — the dropped
	 * rules were redundant with rules 3 / 4 on the existing corpus and
	 * carried real per-cascade `IfWidthExceeds(140, …)` probe overhead.
	 */
	public static function defaultOpBoolChainWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.ItemCountLessThan, value: 3},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.TotalItemLengthLessThan, value: 120},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [
						{cond: WrapConditionType.ItemCountLargerThan, value: 4},
					],
				},
				{
					mode: WrapMode.FillLine,
					location: WrappingLocation.BeforeLast,
					conditions: [
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 1},
					],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `+` / `-` chains.
	 *
	 * **Pivot (slice ω-drop-soft-thresholds):** sister of
	 * `defaultOpBoolChainWrap` — anyparse-core defaults adopt **one
	 * hard limit** and drop fork's two leading soft-threshold rules
	 * (`lineLength >= 160 → OnePerLineAfterFirst` and `lineLength >= 160
	 * → FillLine`). Rationale identical: soft thresholds bias plugin
	 * grammars toward Haxe-formatter aesthetic; users opt in via
	 * custom `hxformat.json`.
	 *
	 * Rules (first-match):
	 *  1. `itemCount <= 3` + `!exceeds` → NoWrap
	 *  2. `totalItemLength <= 120` + `!exceeds` → NoWrap
	 *  3. `itemCount >= 4` → OnePerLineAfterFirst
	 *  4. `exceeds` → OnePerLineAfterFirst
	 *
	 * `defaultMode: NoWrap` preserves the cascade-level fallback.
	 *
	 * Diverges from `defaultOpBoolChainWrap` only in rule 4 mode
	 * (`OnePerLineAfterFirst` vs `FillLine`) — matches fork's
	 * per-cascade choice and anyparse's pre-cascade behaviour for
	 * `+` / `-`.
	 *
	 * `location: BeforeLast` on every wrapping rule mirrors fork's
	 * per-rule setting and shields each rule from the cascade-level
	 * `defaultLocation: AfterLast` fallback.
	 *
	 * Divergence from upstream `default-hxformat.json wrapping.opAddSubChain`:
	 * rules 1, 2 (`lineLength >= 160`) intentionally absent. The dropped
	 * rule 2 (`exceeds → FillLine`) was the sole source of Wadler-style
	 * packing for `+` / `-` chains — long string-concat throws (e.g.
	 * issue_179) now apply rule 3 / 4 (one operand per line) when they
	 * exceed the hard limit. Slice ω-drop-soft-thresholds confirmed
	 * Δ pass = 0 across all 3 corpus buckets; issue_179 stays in the
	 * existing fail bucket as fork-divergence-by-design with a shifted
	 * byte-diff signature (see project memory).
	 */
	public static function defaultOpAddSubChainWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.ItemCountLessThan, value: 3},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{cond: WrapConditionType.TotalItemLengthLessThan, value: 120},
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 0},
					],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [
						{cond: WrapConditionType.ItemCountLargerThan, value: 4},
					],
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 1},
					],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for statement-condition parens
	 * (`if (cond)`, `for (item in coll)`, `while (cond)`, `switch
	 * (expr)`). Slice ω-condition-wrap-ingest foundational scaffold —
	 * the writer does not consume this field yet, so the default is
	 * deliberately minimal: empty rules + `defaultMode: NoWrap`, which
	 * preserves pre-slice byte output. Engine + grammar wiring lands in
	 * a follow-up slice; user `hxformat.json` `wrapping.conditionWrapping`
	 * configs are still ingested by the loader so the cascade is
	 * available when the wiring slice ships.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.conditionWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultConditionWrap():WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for the `? :` ternary
	 * (haxe-formatter `ternaryExpression` class). Slice ω-ternary-wrap
	 * wires `WriterLowering`'s `@:ternary` branch into
	 * `BinaryChainEmit.emit` (items=[cond, then, else], ops=['?', ':']).
	 *
	 * Rule: `exceedsMaxLineLength=1 → OnePerLineAfterFirst, BeforeLast`
	 * mirrors fork's `resources/default-hxformat.json` ternary cascade
	 * verbatim — when the flat `cond ? then : else` line overflows the
	 * `wrapping.maxLineLength` budget, the condition stays inline with
	 * the parent and the `? then` / `: else` pair each take their own
	 * continuation line. Slice ω-ternary-default-rule.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.ternaryWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultTernaryWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [
						{cond: WrapConditionType.ExceedsMaxLineLength, value: 1},
					],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for parenthesised expressions
	 * (`(expr)` — haxe-formatter `expressionWrapping` class). Slice
	 * ω-expressionwrapping-cascade-ingest foundational scaffold —
	 * the writer does not consume this field yet, so the default is
	 * deliberately minimal: empty rules + `defaultMode: NoWrap`, which
	 * preserves pre-slice byte output. Engine + grammar wiring lands
	 * in a follow-up slice; user `hxformat.json`
	 * `wrapping.expressionWrapping` configs are still ingested by the
	 * loader so the cascade is available when the wiring slice ships.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.expressionWrappingWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultExpressionWrappingWrap():WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for named function parameter lists
	 * (haxe-formatter `functionSignature` class).
	 *
	 * Mirrors haxe-formatter's `default-hxformat.json`:
	 * `{rules: [], defaultWrap: fillLine, defaultAdditionalIndent: 1}` —
	 * empty rule set, `FillLine` mode, +1 indent unit on continuation
	 * lines. The `defaultAdditionalIndent: 1` keeps wrapped function
	 * parameters one indent level deeper than the function body so they
	 * remain visually distinct (matches the legacy `@:fmt(fill,
	 * fillDoubleIndent)` Wadler-fillSep emission this cascade replaces).
	 *
	 * Slice ω-functionsignature-wrap-ingest landed the foundational
	 * scaffold (field, default, JSON loader). Slice
	 * ω-wraplist-additional-indent extended `WrapList.emit` with the
	 * `defaultAdditionalIndent` knob, and the follow-up slice swapped
	 * `HxFnDecl.params` over to `@:fmt(wrapRules('functionSignatureWrap'))`.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.functionSignatureWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultFunctionSignatureWrap():WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.FillLine,
			defaultAdditionalIndent: 1,
		};
	}

	/**
	 * Default `WrapRules` cascade for anonymous-function parameter
	 * lists — `HxFnExpr.params` (`function(...)`),
	 * `HxParenLambda.params` (`(...) => body`), and
	 * `HxThinParenLambda.params` (`(...) -> body`). Ported from
	 * haxe-formatter's `wrapping.anonFunctionSignature` rule set in
	 * `resources/default-hxformat.json` (AxGord fork): short anon-fn
	 * signatures stay flat (`defaultMode: NoWrap`) and break only when
	 * one of three cascade triggers fires — `itemCount >= 7`,
	 * `totalItemLength >= 80`, or `exceedsMaxLineLength`, all routing
	 * to `FillLine` with `+1 tab` continuation indent.
	 *
	 * Per-rule `additionalIndent` from fork's JSON is not modelled —
	 * the cascade-level `defaultAdditionalIndent: 1` is byte-equivalent
	 * because every rule in the fork's default carries the same `1`.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.anonFunctionSignatureWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultAnonFunctionSignatureWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 7}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 80}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
			defaultAdditionalIndent: 1,
		};
	}

	/**
	 * Default `WrapRules` cascade for metadata-call argument lists —
	 * `HxMetaCallArgs.args` (`@:overload(args)`, `@:keep(args)`, …).
	 * Ported from haxe-formatter's `wrapping.metadataCallParameter` rule
	 * set in `resources/default-hxformat.json` (AxGord fork): meta args
	 * stay flat (`defaultMode: NoWrap`) and only break when one of three
	 * cascade triggers fires — `totalItemLength >= 140`, `lineLength >= 160`,
	 * or `exceedsMaxLineLength`, all routing to `FillLine`.
	 *
	 * The `lineLength >= 160` rule is functionally subsumed by
	 * `totalItemLength >= 140` at this default — `LineLengthLargerThan`
	 * evaluates as `totalItemLen >= n` like its sibling — but is kept
	 * present for byte-exact alignment with upstream and so user-side
	 * `hxformat.json` tweaks that lower `totalItemLength` without
	 * touching `lineLength` keep the threshold intact.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.metadataCallParameterWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultMetadataCallParameterWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 140}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.LineLengthLargerThan, value: 160}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for type-parameter lists — declare-site
	 * (`HxClassDecl.typeParams`, `HxTypedefDecl.typeParams`,
	 * `HxFnDecl.typeParams`, `HxFnExpr.typeParams`,
	 * `HxEnumDecl.typeParams`, `HxAbstractDecl.typeParams`,
	 * `HxInterfaceDecl.typeParams`) and use-site (`HxTypeRef.params`).
	 * Ported from haxe-formatter's `wrapping.typeParameter` rule set in
	 * `resources/default-hxformat.json`: short `<T>` / `<K, V>` lists stay
	 * flat (`defaultMode: NoWrap`); a list breaks to Wadler-style FillLine
	 * packing when either soft threshold fires — `anyItemLength >= 50`
	 * (one very long type-param name) or `totalItemLength >= 70`
	 * (aggregate width across all entries).
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.typeParameterWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultTypeParameterWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 50}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.TotalItemLengthLargerThan, value: 70}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * B4 ω-implements-extends-wrap: default `wrapping.implementsExtends`
	 * cascade for class/interface heritage clauses, ported from the fork's
	 * `WrapConfig.implementsExtends` `@:default`. FillLine once the glued
	 * decl line exceeds 140 (or >4 clauses, or exceeds maxLineLength), at
	 * a continuation indent of 2 (8 spaces). anyparse `WrapRule` carries no
	 * per-rule `additionalIndent`, so the fork's per-rule `additionalIndent:
	 * 2` is modelled as `defaultAdditionalIndent: 2` (every break-mode
	 * shape in this cascade shares the same indent, so the per-rule vs
	 * default distinction is byte-equivalent here). Consumed by the
	 * dedicated heritage emit in `WriterLowering.triviaTryparseStarExpr`.
	 *
	 * Fresh struct per call (mutation safety) — same convention as the
	 * other `default*Wrap` helpers.
	 */
	public static function defaultImplementsExtendsWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.LineLengthLargerThan, value: 140}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
			defaultAdditionalIndent: 2,
		};
	}

	public function escapeChar(c:Int):String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < 0x20) '\\x' + StringTools.hex(c, 2);
				else String.fromCharCode(c);
		};
	}

	/**
	 * Escape a single character for emission inside a SINGLE-quoted Haxe
	 * string segment (`'...'`).
	 *
	 * Asymmetry with `escapeChar` (which targets double-quoted strings):
	 *  - `'` is the delimiter → escape as `\'`
	 *  - `"` is a literal character inside single-quoted strings → bare
	 *  - `$` triggers interpolation → escape as `\$` so a literal dollar
	 *    in the parsed segment doesn't accidentally start interpolation
	 *    on re-parse. (Currently the segment parser regex excludes `$`
	 *    from `HxStringLitSegment`, but the writer guards defensively.)
	 *  - `\` and control chars (`\n`, `\r`, `\t`, `\xNN`) — same as
	 *    `escapeChar`.
	 *
	 * Used by `HxStringLitSegment`'s writer (`@:unescape("singleQuoteRaw")`
	 * mode) to round-trip Haxe single-quoted strings whose literal body
	 * may contain bare `"` (very common in code that builds SQL / HTML
	 * snippets in single-quoted strings).
	 */
	public function escapeSingleQuoteChar(c:Int):String {
		return switch c {
			case '\''.code: '\\\'';
			case '\\'.code: '\\\\';
			case '$'.code: '\\$';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < 0x20) '\\x' + StringTools.hex(c, 2);
				else String.fromCharCode(c);
		};
	}

	public function unescapeChar(input:String, pos:Int):UnescapeResult {
		final esc:Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new haxe.Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: {char: '"'.code, consumed: 1};
			case '\\'.code: {char: '\\'.code, consumed: 1};
			case 'n'.code: {char: '\n'.code, consumed: 1};
			case 'r'.code: {char: '\r'.code, consumed: 1};
			case 't'.code: {char: '\t'.code, consumed: 1};
			case '\''.code: {char: '\''.code, consumed: 1};
			case '$'.code: {char: '$'.code, consumed: 1};
			case _: throw new haxe.Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}

	/**
	 * Parser-side statement-terminator gate for
	 * `@:fmt(trailOptParseGate('stmtExprNoSemi'))` on
	 * `HxStatement.ExprStmt`. Reached from the generated parser via
	 * `schema.instance.stmtExprNoSemi(_raw)` (the same channel as
	 * `unescapeChar`); delegates to the AST predicate in `HxExprUtil`
	 * so the grammar-AST logic stays beside `endsWithCloseBrace`.
	 */
	public inline function stmtExprNoSemi(raw:Null<Dynamic>):Bool return HxExprUtil.stmtExprNoSemi(raw);

	/**
	 * HxStatement-level sister of `stmtExprNoSemi`. Wired through
	 * `@:sep(';', tailRelax, blockEnded('stmtNoSemi'))` on BlockBody
	 * Star containers (Session 6 option b2 — AST-shape adapter). The
	 * generated parser calls
	 * `schema.instance.stmtNoSemi(_arr[_arr.length - 1])` after each
	 * pushed element to decide whether the next-element gate may skip
	 * the `;` separator. Delegates to the AST predicate in `HxExprUtil`
	 * so all the per-ctor logic (including recursive `ExprStmt(expr)` →
	 * `stmtExprNoSemi(expr)`) stays beside `endsWithCloseBrace`.
	 */
	public inline function stmtNoSemi(raw:Null<Dynamic>):Bool return HxExprUtil.stmtNoSemi(raw);
}
