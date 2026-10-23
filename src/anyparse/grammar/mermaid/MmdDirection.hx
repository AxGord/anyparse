package anyparse.grammar.mermaid;

/** A layout direction: `TB` / `TD`, `BT`, `RL`, `LR`, or the arrow forms `<`, `>`, `^`, `v`. */
@:peg
enum MmdDirection {
	@:kw('TB')
	TB;

	@:kw('TD')
	TD;

	@:kw('BT')
	BT;

	@:kw('RL')
	RL;

	@:kw('LR')
	LR;

	@:lit('<')
	Left;

	@:lit('>')
	Right;

	@:lit('^')
	Up;

	@:kw('v')
	Down;
}
