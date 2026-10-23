package anyparse.grammar.mermaid;

/** `subgraph <id>[<title>]`; the field is `name` so the query projection names the node by the id. */
@:peg
typedef MmdTitledSubgraph = {
	var name: MmdSubgraphIdLit;
	@:lead('[') @:trail(']') var title: MmdTextLit;
}
