package anyparse.query.format.json;

/**
 * The data of a graph page (`anyparse.query.format.GraphHtml`): every view a reader can open, the first one the page
 * opens on, and the legend, each as the Mermaid text the page renders.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef GraphPageJson = {

	var views: Array<GraphPageViewJson>;

	var legend: String;
};
