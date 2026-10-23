package anyparse.grammar.mermaid;

/** A link, with its pipe label when written (`-->|yes|`). */
@:peg
typedef MmdArrow = {
	var link: MmdLinkLit;
	@:optional @:lead('|') @:trail('|') var label: Null<MmdLabel>;
}
