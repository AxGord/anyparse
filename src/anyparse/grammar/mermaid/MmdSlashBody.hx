package anyparse.grammar.mermaid;

/** The label and closer after `[/`: `[/x/]` leans right, `[/x\]` is a trapezoid. */
@:peg
enum MmdSlashBody {
	@:trail('/]')
	LeanRight(text: MmdLabel);

	@:trail('\\]')
	Trapezoid(text: MmdLabel);
}
