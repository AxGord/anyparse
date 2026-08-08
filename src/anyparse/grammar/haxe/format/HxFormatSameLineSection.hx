package anyparse.grammar.haxe.format;

/**
 * `sameLine` section of `hxformat.json`.
 *
 * `ifElse` / `tryCatch` / `doWhile` are two-way same-line knobs
 * (τ₁) driving whether `else` / `catch` / `while` sit on the same
 * line as their preceding block.
 *
 * `ifBody` / `elseBody` / `forBody` / `whileBody` are three-way
 * body-placement knobs (ψ₄) driving whether a non-block body sits
 * on the same line as its `if (…)` / `for (…)` / `while (…)` header,
 * always moves to the next line, or lays out on a fit-or-break basis.
 *
 * `doWhileBody` (ψ₅) is the same three-way body-placement knob for
 * the body of `do body while (…);`. The JSON key matches haxe-
 * formatter's `sameLine.doWhileBody` field; the loader maps it onto
 * the runtime `doBody` option on `HxModuleWriteOptions`.
 *
 * `elseIf` (ψ₈) is a two-value keyword-placement knob for the nested
 * `if` inside an `else` clause. `"same"` (default) keeps `else if`
 * inline; `"next"` moves the nested `if` onto its own line at one
 * indent level deeper. The loader maps this onto the runtime
 * `elseIf` option on `HxModuleWriteOptions`.
 *
 * `fitLineIfWithElse` (ψ₁₂) is a boolean gate on the `FitLine` body
 * policy for `if`-statement bodies (both then- and else-branch) when
 * the enclosing `if` carries an `else`. When `false` (default) an
 * `ifBody=fitLine` / `elseBody=fitLine` degrades to `Next` for such
 * `if`s; `true` keeps `FitLine` active regardless of the else clause.
 * The loader maps this onto the runtime `fitLineIfWithElse` option on
 * `HxModuleWriteOptions`.
 *
 * `expressionTry` (ω-expression-try) is a two-way same-line knob for
 * the separator between the body of an expression-position `try` and
 * its `catch` clauses (`var x = try foo() catch (_:Any) null;`). It
 * is independent of `tryCatch` (statement-form), matching haxe-
 * formatter's `sameLine.expressionTry` field. Default `same`. The
 * loader maps it onto the runtime `expressionTry` option on
 * `HxModuleWriteOptions`.
 *
 * `returnBody` (ω-return-body) is the same three-way body-placement
 * knob shape as `ifBody`, gating the separator between `return` and
 * its value expression. The loader maps it onto the runtime
 * `returnBody` option on `HxModuleWriteOptions`. The sibling
 * `returnBodySingleLine` knob (refining the policy for returns whose
 * value is single-line) is parsed and silently dropped — the
 * single-line refinement axis is not yet wired through the runtime.
 *
 * `catchBody` (ω-catch-body) is the same three-way body-placement
 * knob shape as `ifBody`, gating the separator between the `)` of
 * a catch clause's `(name:Type)` header and its body. The loader
 * maps it onto the runtime `catchBody` option on
 * `HxModuleWriteOptions`. Default `Next` mirrors haxe-formatter's
 * `sameLine.catchBody: @:default(Next)`.
 *
 * `caseBody` (ω-case-body-policy) is the same three-way body-placement
 * knob shape as `ifBody`, gating whether a single-stmt switch case body
 * sits on the same line as `case X:` or moves to a fresh line at one
 * indent level deeper. The loader maps it onto the runtime `caseBody`
 * option on `HxModuleWriteOptions`. Default `Next` matches haxe-
 * formatter's `sameLine.caseBody: @:default(Next)`. `expressionCase`
 * is the sibling knob for switches used in expression position
 * (`var x = switch ... { case Y: 1; }`); the loader maps it onto the
 * runtime `expressionCase` option. Both knobs feed the same Star body
 * site at runtime, dispatched on `opt._inExprPosition` (ω-issue-423-
 * mech-a) rather than OR-ed: `Same` flattens a single-stmt body
 * unconditionally, `Keep` flattens only when the source had it on the
 * case line, and `FitLine` (ω-case-body-fitline) defers the choice to
 * the renderer — a body that can render on one line stays inline while
 * `case <patterns>: <body>` fits `maxLineLength` and moves one indent
 * deeper past it, while a body that cannot render on one line at all
 * (block, refusing wrap cascade, kept multi-line literal) glues to the
 * label as `same` does. See `anyparse.format.BodyFit`.
 *
 * `functionBody` (ω-functionBody-policy) is the same three-way body-
 * placement knob shape as `ifBody`, gating the separator between the
 * `()` of a function declaration's parameter list and its body when
 * the body is a single expression (`function f() trace("hi");`).
 * The loader maps it onto the runtime `functionBody` option on
 * `HxModuleWriteOptions`. Default `Next` matches upstream haxe-
 * formatter's `sameLine.functionBody: @:default(Next)`; opting into
 * `Same` keeps the body inline. `BlockBody` (`function f() { … }`)
 * and `NoBody` (`function f();`) are unaffected — the knob lives on
 * `HxFnBody.ExprBody` only.
 *
 * `untypedBody` (ω-untyped-body-policy) is the same three-way body-
 * placement knob shape as `ifBody`, gating the parent→`untyped`
 * separator at `HxFnBody.UntypedBlockBody` (`function f():T untyped {
 * … }`). The loader maps it onto the runtime `untypedBody` option on
 * `HxModuleWriteOptions`. Default `Same` matches haxe-formatter's
 * `sameLine.untypedBody: @:default(Same)`. Setting `"next"` pushes
 * `untyped` onto its own line at one indent level deeper; `"keep"`
 * preserves source (degrades to `Same` in plain mode); `"fitLine"`
 * fits-or-breaks. Stmt-level form `HxStatement.UntypedBlockStmt`
 * (incl. `try untyped { … }`) is deferred to a follow-up slice —
 * duplicating the wrap would stack with parent body-policy / block-
 * stmt separators producing double spaces / spurious blank lines.
 *
 * `tryBody` (ω-tryBody) is the same three-way body-placement knob
 * shape as `catchBody`, gating the separator between the `try`
 * keyword and its body at `HxTryCatchStmt.body`. The loader maps
 * it onto the runtime `tryBody` option on `HxModuleWriteOptions`.
 * Default `Same` diverges from upstream haxe-formatter's
 * `sameLine.tryBody: @:default(next)` to match the AxGord fork's
 * project-level `hxformat.json` (`"sameLine": { "tryBody": "same" }`)
 * — the corpus we validate against. Co-exists with the
 * `whitespace.tryPolicy` knob via the `kwOwnsInlineSpace` mode in
 * `WriterLowering.bodyPolicyWrap` — `tryBody=Same` + `tryPolicy=None`
 * still collapses to `try{…}`, decoupling the two semantic axes
 * (body inline-vs-break vs kw-trail-space).
 *
 * `expressionIf` (ω-expr-body-keep) is the body-placement knob for
 * the expression-position counterparts of `if`/`for` (the typedefs
 * driving array comprehensions and any value-position `if`/`for`).
 * The loader fans this single JSON key out into three runtime knobs
 * — `expressionIfBody` / `expressionElseBody` / `expressionForBody` —
 * because haxe-formatter exposes only one config key for the trio.
 * Default `Keep` (in `HaxeFormat.defaultWriteOptions`) preserves the
 * source layout, matching haxe-formatter's
 * `sameLine.expressionIf: @:default(Keep)`. Statement-level
 * counterparts (`ifBody` / `elseBody` / `forBody`) keep their own
 * defaults — the divergence is intentional.
 *
 * `expressionIfWithBlocks` (ω-expression-if-with-blocks) is an
 * orthogonal `Bool` knob (default `false`) that collapses
 * `BlockExpr` bodies on `HxIfExpr.thenBranch` / `elseBranch` to a
 * single line when set. Mirrors haxe-formatter's
 * `sameLine.expressionIfWithBlocks: false` — the body's brace pair
 * survives but its contents flatten regardless of width. Wired via
 * `@:fmt(inlineBlockBodyIfFlag('expressionIfWithBlocks'))` on both
 * branches; non-block bodies fall through to the `expressionIf*`
 * cascade unchanged.
 *
 * omega-arrow-value-if-reflow: `expressionIfArrowBodyReflow` (default
 * `false`, absent = fork parity) is a `Bool` knob for the ONE context
 * the `expressionIf` cascade cannot canonicalise - a value-`if`/`else`
 * chain in an arrow-lambda body. When set, the chain
 * becomes a width-decided unit: it renders flat
 * (`(a, b) -> if (c) -1 else 0`) when it fits, and one arm per line with
 * each branch value glued to its own condition when it does not. Off,
 * the `expressionIf` policy decides each branch on its own and even a
 * flat-fitting chain still explodes. Wired via
 * `@:fmt(arrowValueIfReflow('expressionIfArrowBodyReflow'))` on the
 * `HxIfExpr` typedef plus `@:fmt(arrowValueIfReflowSite)` on both
 * branches. A chain carrying a comment anywhere on its `else`-spine
 * refuses the reflow as a WHOLE and keeps the policy-driven shape; the
 * reach is `_inArrowLambdaBody`, which also covers a `cast` operand, an
 * `untyped` / `@:meta` prefix and an enclosing value-`if`'s condition.
 *
 * omega-elseif-comment-reflow: `elseIfCommentReflow` (default `false`,
 * absent = fork parity) is a `Bool` knob for the ONE comment position the
 * `elseIf` glue cannot canonicalise - a single `//` line comment written
 * between `else` and its nested `if`. Off, that comment forces the
 * three-line fork layout (`else` alone on its line, the comment one indent
 * deeper, the nested `if` back at the outer indent). On, the link glues
 * (`} else if (b) {`) and the comment becomes a trailing comment at the end
 * of the nested `if`'s head line - after the then-body's `{` when it is
 * braced, after the condition's `)` when the body policy already puts a bare
 * body on the next line. Wired via `@:fmt(elseIfCommentReflow)` on
 * `HxIfStmt.elseBody`; statement position only. A block comment, more than
 * one comment, a comment cuddled to the `else` itself, a nested `if` head
 * that already carries its own trailing `//`, an empty then-body, and a body
 * that offers no provable head-line anchor all refuse and keep the knob-off
 * layout - as
 * does `elseBody: "keep"`, whose `Keep` layout path the knob does not reach.
 */
@:peg typedef HxFormatSameLineSection = {

	@:optional var ifElse: HxFormatSameLinePolicy;

	@:optional var tryCatch: HxFormatSameLinePolicy;

	@:optional var doWhile: HxFormatSameLinePolicy;

	@:optional var ifBody: HxFormatBodyPolicy;

	@:optional var elseBody: HxFormatBodyPolicy;

	@:optional var forBody: HxFormatBodyPolicy;

	@:optional var whileBody: HxFormatBodyPolicy;

	@:optional var doWhileBody: HxFormatBodyPolicy;

	@:optional var elseIf: HxFormatKeywordPlacement;

	@:optional var fitLineIfWithElse: Bool;

	@:optional var fitLineBodyGlue: Bool;

	@:optional var ifElseSemicolonNextLine: Bool;

	@:optional var expressionTry: HxFormatSameLinePolicy;

	@:optional var returnBody: HxFormatBodyPolicy;

	@:optional var returnBodySingleLine: HxFormatBodyPolicy;

	@:optional var catchBody: HxFormatBodyPolicy;

	@:optional var tryBody: HxFormatBodyPolicy;

	@:optional var caseBody: HxFormatBodyPolicy;

	@:optional var expressionCase: HxFormatBodyPolicy;

	@:optional var functionBody: HxFormatBodyPolicy;

	@:optional var anonFunctionBody: HxFormatBodyPolicy;

	@:optional var untypedBody: HxFormatBodyPolicy;

	@:optional var expressionIf: HxFormatBodyPolicy;

	@:optional var expressionIfWithBlocks: Bool;

	@:optional var expressionIfArrowBodyReflow: Bool;

	@:optional var elseIfCommentReflow: Bool;

	@:optional var comprehensionFor: HxFormatBodyPolicy;
};
