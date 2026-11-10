package anyparse.grammar.mermaid;

/** `classDef <names> <styles>`. */
@:peg
typedef MmdClassDef = {
	var names: MmdIdListLit;
	var styles: MmdStylesLit;
}
