package anyparse.grammar.mermaid;

/** A node group followed by any number of links, each to the next group: `A --> B -.-> C & D`. */
@:peg
typedef MmdChain = {
	var head: MmdNodeGroup;
	@:tryparse @:fmt(padLeading) var links: Array<MmdLink>;
}
