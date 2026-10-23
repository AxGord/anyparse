package anyparse.grammar.mermaid;

/**
 * An edge: a link with an optional `|label|`, or a link that carries its label inline
 * (`-- text -->`, `== text ==>`, `-. text .->`), or either one named by an edge id.
 */
@:peg
enum MmdEdge {
	Identified(edge: MmdIdentifiedEdge);
	Arrow(arrow: MmdArrow);
	SolidText(edge: MmdSolidTextEdge);
	ThickText(edge: MmdThickTextEdge);
	DottedText(edge: MmdDottedTextEdge);
}
