package anyparse.grammar.mermaid;

/** `linkStyle <links> [interpolate <curve>] <styles>`. */
@:peg
typedef MmdLinkStyle = {
	var links: MmdLinkTargetsLit;
	@:optional @:kw('interpolate') var curve: Null<MmdIdLit>;
	var styles: MmdStylesLit;
}
