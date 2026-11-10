package anyparse.grammar.mermaid;

/** `style <nodes> <styles>`. */
@:peg
typedef MmdStyle = {
	var target: MmdIdListLit;
	var styles: MmdStylesLit;
}
