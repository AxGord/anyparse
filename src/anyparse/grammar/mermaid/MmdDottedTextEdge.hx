package anyparse.grammar.mermaid;

/** A dotted link with its label inline (`-. text .->`). */
@:peg
typedef MmdDottedTextEdge = {
	var open: MmdDottedOpenLit;
	var text: MmdDottedTextLit;
	var close: MmdLinkLit;
}
