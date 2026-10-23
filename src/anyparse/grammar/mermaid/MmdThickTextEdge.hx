package anyparse.grammar.mermaid;

/** A thick link with its label inline (`== text ==>`). */
@:peg
typedef MmdThickTextEdge = {
	var open: MmdThickOpenLit;
	var text: MmdThickTextLit;
	var close: MmdLinkLit;
}
