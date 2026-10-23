package anyparse.grammar.mermaid;

/** `linkStyle <links> interpolate <curve>`. */
@:peg
typedef MmdLinkCurve = {
	var links: MmdLinkTargetsLit;
	@:kw('interpolate') var curve: MmdCurveLit;
}
