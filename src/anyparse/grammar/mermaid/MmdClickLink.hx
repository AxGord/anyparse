package anyparse.grammar.mermaid;

/** A click URL, then its tooltip and window target when written. */
@:peg
typedef MmdClickLink = {
	var url: MmdStringLit;
	@:tryparse @:fmt(padLeading) var extras: Array<MmdClickExtra>;
}
