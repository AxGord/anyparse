package anyparse.grammar.haxe;

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
};
