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
 * site at runtime (the writer ORs them together — any `Same` value
 * triggers single-stmt flatten; `FitLine` and `Keep` degrade to `Next`
 * until those policies are wired for case bodies in a follow-up slice).
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
 */
@:peg typedef HxFormatSameLineSection = {

	@:optional var ifElse:HxFormatSameLinePolicy;

	@:optional var tryCatch:HxFormatSameLinePolicy;

	@:optional var doWhile:HxFormatSameLinePolicy;

	@:optional var ifBody:HxFormatBodyPolicy;

	@:optional var elseBody:HxFormatBodyPolicy;

	@:optional var forBody:HxFormatBodyPolicy;

	@:optional var whileBody:HxFormatBodyPolicy;

	@:optional var doWhileBody:HxFormatBodyPolicy;

	@:optional var elseIf:HxFormatKeywordPlacement;

	@:optional var fitLineIfWithElse:Bool;

	@:optional var expressionTry:HxFormatSameLinePolicy;

	@:optional var returnBody:HxFormatBodyPolicy;

	@:optional var returnBodySingleLine:HxFormatBodyPolicy;

	@:optional var catchBody:HxFormatBodyPolicy;

	@:optional var tryBody:HxFormatBodyPolicy;

	@:optional var caseBody:HxFormatBodyPolicy;

	@:optional var expressionCase:HxFormatBodyPolicy;

	@:optional var functionBody:HxFormatBodyPolicy;

	@:optional var untypedBody:HxFormatBodyPolicy;

	@:optional var expressionIf:HxFormatBodyPolicy;
};
