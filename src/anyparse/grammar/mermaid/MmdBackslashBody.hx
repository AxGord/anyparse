package anyparse.grammar.mermaid;

/** The label and closer after `[\`: `[\x\]` leans left, `[\x/]` is an inverted trapezoid. */
@:peg
enum MmdBackslashBody {
	@:trail('\\]')
	LeanLeft(text: MmdLabel);

	@:trail('/]')
	InvTrapezoid(text: MmdLabel);
}
