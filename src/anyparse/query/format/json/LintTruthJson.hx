package anyparse.query.format.json;

/**
 * Declarative schema for a ground-truth file `apq lint-score` scores a lint report against: the `rule` it labels, the
 * `project` and `commit` the labels were made on, and one entry per labelled finding (`LintTruthEntryJson`). Every key
 * is required — a truth file that does not say which tree it describes cannot be told apart from a stale one.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintTruthJson = {

	var rule: String;

	var project: String;

	var commit: String;

	var entries: Array<LintTruthEntryJson>;
};
