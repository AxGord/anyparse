package anyparse.grammar.mermaid;

/** The `flowchart` / `graph` keyword, with its direction when one is written. */
@:peg
enum MmdHeader {
	@:kw('flowchart')
	Flowchart(direction: MmdDirection);

	@:kw('flowchart')
	FlowchartDefault;

	@:kw('graph')
	Graph(direction: MmdDirection);

	@:kw('graph')
	GraphDefault;
}
