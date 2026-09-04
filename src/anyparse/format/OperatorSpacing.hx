package anyparse.format;

/**
 * Spacing an operator token asks for, in a slot the writer emits as TEXT rather
 * than as a Doc of its own.
 *
 * Three values rather than the four of `WhitespacePolicy`, because the slot this
 * serves is a whole token run: `Keep` (the default) re-emits the run exactly as
 * authored, `None` closes the operator up (`js||flash`), `Around` opens it out
 * (`js || flash`). One-sided spacing has no meaning for a binary operator inside
 * such a run, so `Before` / `After` are deliberately absent.
 *
 * First consumer: `HxModuleWriteOptions.condDirectiveOpSpacing`, the `#if` /
 * `#elseif` condition, whose text a grammar captures verbatim as one terminal.
 * That text is NOT an expression tree, so the general operator-spacing knobs never
 * reach it; `Keep` is what every writer did with it before this knob existed.
 *
 * Format-neutral - it lives in `anyparse.format` so any grammar with a captured
 * operator run can reuse it.
 */
enum abstract OperatorSpacing(Int) from Int to Int {

	final Keep = 0;

	final None = 1;

	final Around = 2;

}
