package anyparse.query.format.json;

/**
 * Declarative schema for ONE record of an `apq lint --format json` report —
 * the four keys `anyparse.query.LintDiff` compares snapshots on. Parsed by
 * the macro-generated `LintReportJsonParser` (ByName struct lowering), which
 * roots on the `LintReportJson` envelope holding an array of these.
 *
 * A real record also carries `line`, `col` and `address`. All three are
 * deliberately NOT modelled and are dropped by the `UnknownPolicy.Skip`
 * inherited from `JsonFormat`: every one of them moves when an unrelated
 * edit shifts lines, so keying on them would report a whole file as
 * removed-and-re-added after a one-line insertion above it.
 *
 * The four modelled keys are REQUIRED rather than `@:optional`. The lint
 * report writer emits all four on every record, so a record missing one is
 * a truncated snapshot or the output of some other tool, and a loud parse
 * failure is the right answer — a silently-null `rule` or `message` would
 * collapse unrelated findings onto one key and report a clean diff.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintFindingJson = {

	var file: String;

	var severity: String;

	var rule: String;

	var message: String;
};
