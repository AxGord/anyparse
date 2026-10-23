package anyparse.grammar.mermaid;

/** A `subgraph <head>` … `end` block; the body is written one indent deeper. */
@:peg
typedef MmdSubgraph = {
	var head: MmdSubgraphHead;
	@:lead('') @:trail('end') var body: Array<MmdStatement>;
}
