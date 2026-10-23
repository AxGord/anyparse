package anyparse.grammar.mermaid;

/** A solid link with its label inline (`-- text -->`). */
@:peg
typedef MmdSolidTextEdge = {
	var open: MmdSolidOpenLit;
	var text: MmdSolidTextLit;
	var close: MmdLinkLit;
}
