package anyparse.grammar.mermaid;

/** A `subgraph` … `end` block with nothing after the keyword on its line. */
@:peg
typedef MmdAnonymousSubgraph = {
	var keyword: MmdAnonymousOpenLit;
	@:lead('') @:trail('end') var body: Array<MmdStatement>;
}
