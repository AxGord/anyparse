package anyparse.grammar.mermaid;

/** One node, or several joined by `&` (`A & B`), which a link connects all at once. */
@:peg
typedef MmdNodeGroup = {
	var vertex: MmdNode;
	@:tryparse @:fmt(padLeading) var also: Array<MmdAlsoNode>;
}
