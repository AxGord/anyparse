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
};
