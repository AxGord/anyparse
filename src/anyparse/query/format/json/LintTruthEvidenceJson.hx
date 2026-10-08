package anyparse.query.format.json;

/**
 * What a `LintTruthEntryJson` verdict rests on: `kind` is `measured`, `test` or `code` (`LintScore.EVIDENCE_KINDS`),
 * `ref` points at it (a ledger line, a test name, a file:line), and `ms` is a measured stall.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintTruthEvidenceJson = {

	var kind: String;

	@:optional var ref: Null<String>;

	@:optional var ms: Null<Float>;
};
