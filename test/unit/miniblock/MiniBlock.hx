package unit.miniblock;

/**
 * Minimal grammar driving the `blockEnded` Star primitive pilot test
 * for the BlockBody Star tail-relax refactor ([[project-blockbody-star-tail-relax-debt]]).
 *
 * `Atom(s)` — bare identifier.
 * `Block(items)` — `{` ... `}` with `;` separator between elements;
 *   trailing `;` tolerated (tail-relax); between two elements `;` may
 *   be omitted when the prior element ends with `}` (block-ended
 *   exemption). The `@:sep(';', tailRelax, blockEnded)` annotation
 *   drives both relaxations.
 *
 * Reuses `anyparse.format.text.JsonFormat` purely as a whitespace
 * carrier — none of JSON's literal escape / number policy applies to
 * `MiniBlock`. A dedicated `MiniBlockFormat` is overkill for a pilot.
 */
@:peg
@:schema(anyparse.format.text.JsonFormat)
@:ws
enum MiniBlock {

	Atom(s:MiniAtomLit);

	@:lead('{') @:trail('}') @:sep(';', tailRelax, blockEnded)
	Block(items:Array<MiniBlock>);
}
