package anyparse.grammar.mermaid;

/** `& <node>`; a keyword so the `&` is written with a space on both sides, as Mermaid requires. */
@:peg
typedef MmdAlsoNode = {
	@:kw('&') var vertex: MmdNode;
}
