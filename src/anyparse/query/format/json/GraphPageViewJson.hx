package anyparse.query.format.json;

/**
 * One view of a `GraphPageJson`: the `id` of the node it opens (empty for the view the page opens on), its `title`,
 * the view a reader goes back `up` to (absent for the first view), and the `mermaid` text drawing it.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef GraphPageViewJson = {

	var id: String;

	var title: String;

	@:optional var up: Null<String>;

	var mermaid: String;
};
