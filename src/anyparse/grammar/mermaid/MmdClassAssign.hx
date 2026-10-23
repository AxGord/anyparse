package anyparse.grammar.mermaid;

/** `class <nodes> <className>`. */
@:peg
typedef MmdClassAssign = {
	var nodes: MmdIdListLit;
	var className: MmdIdLit;
}
