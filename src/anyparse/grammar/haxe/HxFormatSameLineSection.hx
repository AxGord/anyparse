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
 */
@:peg typedef HxFormatSameLineSection = {

	@:optional var ifElse:HxFormatSameLinePolicy;

	@:optional var tryCatch:HxFormatSameLinePolicy;

	@:optional var doWhile:HxFormatSameLinePolicy;

	@:optional var ifBody:HxFormatBodyPolicy;

	@:optional var elseBody:HxFormatBodyPolicy;

	@:optional var forBody:HxFormatBodyPolicy;

	@:optional var whileBody:HxFormatBodyPolicy;
};
