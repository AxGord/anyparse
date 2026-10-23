package anyparse.grammar.mermaid;

/** The label and closer after `[/`: `[/x/]` leans right, `[/x\]` is a trapezoid. */
@:peg
enum MmdSlashBody {
	@:trail('/]')
	LeanRight(text: MmdTextLit);

	@:trail('\\]')
	Trapezoid(text: MmdTextLit);
}
