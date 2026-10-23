package anyparse.grammar.mermaid;

/** `click <node> <action>`. */
@:peg
typedef MmdClick = {
	var target: MmdIdLit;
	var action: MmdClickAction;
}
