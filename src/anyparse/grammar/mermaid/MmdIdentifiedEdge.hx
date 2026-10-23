package anyparse.grammar.mermaid;

/** `e1@-->`: an edge id, then the edge it names. */
@:peg
typedef MmdIdentifiedEdge = {
	var id: MmdEdgeIdLit;
	var edge: MmdEdge;
}
