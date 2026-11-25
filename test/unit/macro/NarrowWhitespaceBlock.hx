package unit.macro;

/** Words between braces, separated only by the characters the format declares as whitespace. */
@:peg
@:schema(unit.macro.NarrowWhitespaceFormat)
@:ws
enum NarrowWhitespaceBlock {

	@:lead('{')
	@:trail('}')
	Block(items: Array<NarrowWhitespaceAtom>);

}
