package anyparse.grammar.mermaid;

/** One step of a chain: the edge, then the group it points at. */
@:peg
typedef MmdLink = {
	var edge: MmdEdge;
	var target: MmdNodeGroup;
}
