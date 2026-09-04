package anyparse.query.format.json;

/**
 * Envelope for a whole `apq lint --format json` report.
 *
 * The report on disk is a BARE top-level JSON array, and the ByName lowering
 * cannot root on one: `@:peg typedef LintReportJson = Array<LintFindingJson>`
 * fails the build with `ShapeBuilder: typedef LintReportJson does not resolve
 * to an anonymous structure` (measured 2026-08-17 against this compiler).
 * `AstRefHits` records the same constraint from the WRITER side and answers it
 * the same way — wrap the array in a one-key struct so the macro has a typedef
 * root to dispatch on.
 *
 * Here the wrap happens on the way IN: `LintDiff.parseReport` checks that the
 * snapshot text really starts with `[`, then brackets it with `{"findings":`
 * and `}` before handing it to the parser. That is also why `findings` is
 * required rather than `@:optional` — the adapter supplies the key on every
 * call, so an absent one means the wrap itself broke, not that the file was
 * missing data.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintReportJson = {

	var findings: Array<LintFindingJson>;
};
