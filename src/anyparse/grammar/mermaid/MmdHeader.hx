package anyparse.grammar.mermaid;

/** The `flowchart` / `graph` keyword: alone on its line, or with the direction that follows it there. */
@:peg
enum MmdHeader {
	Undirected(keyword: MmdUndirectedLit);

	@:kw('flowchart')
	Flowchart(direction: MmdDirection);

	@:kw('graph')
	Graph(direction: MmdDirection);
}
