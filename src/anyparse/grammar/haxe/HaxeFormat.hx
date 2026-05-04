package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.CommentStyle;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
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
	 * `returnBody` (ω-return-body, see below) is the exception — it
	 * defaults to `FitLine`, not `Next`, because haxe-formatter's
	 * effective `sameLine.returnBody: @:default(Same)` semantics wrap
	 * long values via a separate `wrapping.maxLineLength` pass.
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
	 * `throwBody` (ω-throw-body) shares the `returnBody` default and
	 * shape — `throw value;` follows the same fit-or-break logic.
	 * Unlike `returnBody`, there is no upstream `sameLine.throwBody`
	 * key in haxe-formatter; the JSON loader does not parse one. The
	 * runtime knob exists for parity and for users constructing
	 * `HxModuleWriteOptions` programmatically.
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
	 * `tryBody` (ω-tryBody) defaults to `Same` — diverges from
	 * upstream haxe-formatter's `sameLine.tryBody: @:default(next)`
	 * to match the AxGord fork's project-level `hxformat.json`
	 * (`"sameLine": { "tryBody": "same" }`), which is the corpus
	 * we validate against. Drives the
	 * body-placement axis at `HxTryCatchStmt.body`. Block bodies
	 * stay inline by default — the typical `try { … }` round-trip
	 * routes through `bodyPolicyWrap`'s block-ctor path where
	 * `leftCurly` controls the `{` position. Architecturally
	 * orthogonal to `tryPolicy`: the `Same` inline gap routes
	 * through `opt.tryPolicy` (`After`/`Both` → space, `None`/
	 * `Before` → empty) via the `kwOwnsInlineSpace` mode in
	 * `bodyPolicyWrap`, so `tryPolicy=None` + `tryBody=Same` still
	 * collapses to `try{…}` while default `tryPolicy=After` +
	 * `tryBody=Same` keeps `try {…}`. Opting into `Next`/`FitLine`/
	 * `Keep` requires an explicit `hxformat.json` override
	 * (`"sameLine": { "tryBody": "next" | "fitLine" | "keep" }`).
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
	 * `functionTypeHaxe4` default (ω-arrow-fn-type) is `Both` — the `->`
	 * separator inside a new-form arrow function type
	 * (`HxArrowFnType.ret`) emits `(args) -> ret` with surrounding
	 * spaces, matching haxe-formatter's
	 * `whitespace.functionTypeHaxe4Policy: @:default(Around)`. Setting
	 * to `None` produces the tight `(args)->ret` form and requires
	 * `"whitespace": { "functionTypeHaxe4Policy": "none" }` in
	 * `hxformat.json`. The old-form curried arrow `Int->Bool` is on a
	 * separate axis (`@:fmt(tight)` on `HxType.Arrow`, mirroring upstream's
	 * `functionTypeHaxe3Policy: @:default(None)`) and is unaffected.
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
		commentStyle: CommentStyle.Verbatim,
		sameLineElse: SameLinePolicy.Same,
		sameLineCatch: SameLinePolicy.Same,
		sameLineDoWhile: SameLinePolicy.Same,
		trailingCommaArrays: false,
		trailingCommaArgs: false,
		trailingCommaParams: false,
		trailingCommaObjectLits: false,
		ifBody: BodyPolicy.Next,
		elseBody: BodyPolicy.Next,
		forBody: BodyPolicy.Next,
		whileBody: BodyPolicy.Next,
		doBody: BodyPolicy.Next,
		returnBody: BodyPolicy.FitLine,
		throwBody: BodyPolicy.FitLine,
		catchBody: BodyPolicy.Next,
		tryBody: BodyPolicy.Same,
		caseBody: BodyPolicy.Next,
		expressionCase: BodyPolicy.Keep,
		functionBody: BodyPolicy.Next,
		untypedBody: BodyPolicy.Same,
		expressionIfBody: BodyPolicy.Keep,
		expressionElseBody: BodyPolicy.Keep,
		expressionForBody: BodyPolicy.Keep,
		leftCurly: BracePlacement.Same,
		objectLiteralLeftCurly: BracePlacement.Same,
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
		afterFieldsWithDocComments: CommentEmptyLinesPolicy.One,
		existingBetweenFields: KeepEmptyLinesPolicy.Keep,
		beforeDocCommentEmptyLines: CommentEmptyLinesPolicy.One,
		betweenVars: 0,
		betweenFunctions: 1,
		afterVars: 1,
		interfaceBetweenVars: 0,
		interfaceBetweenFunctions: 0,
		interfaceAfterVars: 0,
		typedefAssign: WhitespacePolicy.Both,
		typeParamDefaultEquals: WhitespacePolicy.Both,
		typeParamOpen: WhitespacePolicy.None,
		typeParamClose: WhitespacePolicy.None,
		anonTypeBracesOpen: WhitespacePolicy.None,
		anonTypeBracesClose: WhitespacePolicy.None,
		objectLiteralBracesOpen: WhitespacePolicy.None,
		objectLiteralBracesClose: WhitespacePolicy.None,
		objectLiteralWrap: HaxeFormat.defaultObjectLiteralWrap(),
		callParameterWrap: HaxeFormat.defaultCallParameterWrap(),
		arrayLiteralWrap: HaxeFormat.defaultArrayLiteralWrap(),
		anonTypeWrap: HaxeFormat.defaultAnonTypeWrap(),
		methodChainWrap: HaxeFormat.defaultMethodChainWrap(),
		opBoolChainWrap: HaxeFormat.defaultOpBoolChainWrap(),
		opAddSubChainWrap: HaxeFormat.defaultOpAddSubChainWrap(),
		addLineCommentSpace: true,
		expressionTry: SameLinePolicy.Same,
		indentCaseLabels: true,
		indentObjectLiteral: true,
		functionTypeHaxe4: WhitespacePolicy.Both,
		arrowFunctions: WhitespacePolicy.Both,
		afterPackage: 1,
		beforeUsing: 1,
		afterMultilineDecl: 1,
		beforeMultilineDecl: 1,
		formatStringInterpolation: true,
		blockCommentAdapter: anyparse.format.comment.BlockCommentNormalizer.processCapturedBlockComment,
		lineCommentAdapter: anyparse.format.comment.LineCommentNormalizer.normalizeLineComment,
		endsWithCloseBrace: HxExprUtil.endsWithCloseBrace,
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
	 * in `resources/default-hxformat.json` (AxGord fork). Returned as a
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
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxExpr.ArrayExpr.elems` — ported
	 * from haxe-formatter's `wrapping.arrayWrap` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). Conditions
	 * unsupported by the current `WrapConditionType` set
	 * (`hasMultilineItems`, `equalItemLengths`) and the
	 * `fillLineWithLeadingBreak` rules they gate are skipped — for the
	 * `hasMultilineItems` case the `WrapList.emit` runtime already routes
	 * `anyHardline=true` items through the `exceeds=true` cascade run
	 * with `maxLen` / `total` set to `HARDLINE_LEN`, which fails the
	 * `total<80` rule and triggers `OnePerLine` via the
	 * `anyItemLength>=30` rule. Returned as a fresh struct on each call
	 * so test code that mutates the `defaultWriteOptions.arrayLiteralWrap`
	 * substruct doesn't corrupt the singleton.
	 */
	public static function defaultArrayLiteralWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [{cond: WrapConditionType.TotalItemLengthLessThan, value: 80}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.AnyItemLengthLargerThan, value: 30}],
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
	 * `resources/default-hxformat.json` (AxGord fork). The leading
	 * `lineLength >= 160` rule from upstream is skipped because
	 * `WrapConditionType` does not yet model raw current-line length —
	 * same skip-precedent
	 * as `defaultArrayLiteralWrap`'s `hasMultilineItems` /
	 * `equalItemLengths` omissions. The remaining cascade still covers
	 * the common cases: short chains stay flat (`itemCount<=3` +
	 * `exceedsMaxLineLength==0`, or `totalItemLength<=80` +
	 * `exceedsMaxLineLength==0`); `anyItemLength>=30` + `itemCount>=4`
	 * or `itemCount>=7` or `exceedsMaxLineLength==1` cascades to
	 * `OnePerLineAfterFirst`.
	 *
	 * NOTE: this cascade is currently unused by the writer pipeline —
	 * the slice ω-methodchain-wraprules-capability ships the knob and
	 * JSON loader only, so a follow-up slice can wire the writer-time
	 * chain extractor against `HxExpr.Call` / `HxExpr.FieldAccess`. See
	 * `HxModuleWriteOptions.methodChainWrap` for the rationale.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.methodChainWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultMethodChainWrap():WrapRules {
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
	 * Default `WrapRules` cascade for `||` / `&&` chains (haxe-formatter
	 * `opBoolChain` class). Single rule: when the chain in flat layout
	 * would exceed `WriteOptions.lineWidth`, fall through to
	 * `OnePerLineAfterFirst` with explicit `location: BeforeLast` (`op`
	 * prefixes each continuation line). `defaultMode: NoWrap` keeps short
	 * chains inline.
	 *
	 * The explicit `BeforeLast` matches haxe-formatter's per-rule setting
	 * for the analogous final rule in `wrapping.opBoolChain` and shields
	 * the rule from the cascade-level `defaultLocation: AfterLast`
	 * fallback (mirroring fork's typedef-level default).
	 *
	 * The upstream WrapConfig has 5 additional rules with `lineLength >= 140`
	 * + `anyItemLength >= 40` predicates that `WrapConditionType` does
	 * not yet model — same skip-precedent as `defaultMethodChainWrap`'s
	 * `lineLength >= 160` omission. For default-config fixtures the
	 * single `ExceedsMaxLineLength` cond fires identically to upstream's
	 * 6-rule cascade.
	 */
	public static function defaultOpBoolChainWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
	}

	/**
	 * Default `WrapRules` cascade for `+` / `-` chains (haxe-formatter
	 * `opAddSubChain` class). Single rule
	 * `ExceedsMaxLineLength → FillLine` over `defaultMode: NoWrap`.
	 *
	 * Diverges from `defaultOpBoolChainWrap` (which uses
	 * `OnePerLineAfterFirst`): haxe-formatter's `opAddSubChain` cascade
	 * routes the wide-but-short-item case (the most common one for
	 * string concat — long total length, lots of short items) through
	 * `FillLine`, packing as many operands per line as fit. Drives
	 * issue_179's long throw expression — `throw "a" + b + "c" + ... +
	 * ") in atlas " + name + " with max size ("\n\t+ rest` — where the
	 * first ~10 items pack inline and the break lands on the soft-line
	 * before the overflowing operand. `WrapConditionType` doesn't yet
	 * model the upstream `lineLength >= 160` predicate so the simpler
	 * `ExceedsMaxLineLength` cond fires identically for default-config
	 * fixtures.
	 *
	 * Explicit `location: BeforeLast` on the rule preserves the existing
	 * op-before-operand emission and shields it from the cascade-level
	 * `defaultLocation: AfterLast` fallback (mirroring fork's typedef
	 * default).
	 */
	public static function defaultOpAddSubChainWrap():WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					location: WrappingLocation.BeforeLast,
					conditions: [{cond: WrapConditionType.ExceedsMaxLineLength, value: 1}],
				},
			],
			defaultMode: WrapMode.NoWrap,
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
			case _: throw new haxe.Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}
}
