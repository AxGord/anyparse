package anyparse.grammar.mermaid;

/** A click callback, then its tooltip when written. */
@:peg
typedef MmdClickCall = {
	var callback: MmdCallbackLit;
	@:tryparse @:fmt(padLeading) var extras: Array<MmdClickExtra>;
}
