package anyparse.grammar.mermaid;

/** What follows `subgraph`: an id with a bracketed title (`one [Title]`), or an id that is its own title. */
@:peg
enum MmdSubgraphHead {
	Titled(head: MmdTitledSubgraph);
	Named(id: MmdSubgraphIdLit);
}
