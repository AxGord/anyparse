package anyparse.query.format.json;

/**
 * One node of a `CodeGraphJson`: its stable `id` (a valid Mermaid node id, derived from `level` and
 * `name`), its level (`package`, `type`, `member`, `group`), the qualified `name`, the `label` a reader
 * sees, the `parent` holding it (absent at the top level), and whether it lies outside the scanned
 * scope (`external`) or is one the query asked about (`focus`).
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CodeGraphNodeJson = {

	var id: String;

	var level: String;

	var name: String;

	var label: String;

	@:optional var parent: Null<String>;

	var external: Bool;

	var focus: Bool;
};
