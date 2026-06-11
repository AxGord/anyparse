package unit.miniblockstrict;

/**
 * Strict-sep pilot for the BlockBody Star Session 9 `sepStartsElement`
 * mechanism ([[project-blockbody-star-tail-relax-debt]]).
 *
 * Mirrors `unit.miniblock.MiniBlock` but adds:
 *  - `EmptyAtom` — a `;`-bodied element (`@:lit(';')`). Models Haxe
 *    `HxStatement.EmptyStmt` whose body IS the separator character.
 *  - `Block` carries `@:sep(';', tailRelax, blockEnded('endsImplicitly',
 *    sepStartsElement))` instead of `blockEnded('endsImplicitly')`.
 *
 * Under `sepStartsElement` the parser's blockEnded branch flips
 * byte-ambiguity policy: when block-ended is TRUE, the sep byte at pos
 * ALWAYS belongs to the next element, NEVER a separator. So `{;;}`
 * parses as `Block([EmptyAtom, EmptyAtom])`, not as a single EmptyAtom
 * followed by a consumed sep.
 *
 * Companion to `unit.miniblock.MiniBlock` (permissive-sep pilot, kept
 * unchanged). The two pilots together pin both halves of the
 * `blockEnded` API surface.
 */
@:peg
@:schema(unit.miniblockstrict.MiniBlockStrictFormat)
@:ws
enum MiniBlockStrict {

	Atom(s: MiniAtomLitStrict);

	@:lit(';') EmptyAtom;

	@:lead('{') @:trail('}') @:sep(';', tailRelax, blockEnded('endsImplicitly', sepStartsElement))
	Block(items: Array<MiniBlockStrict>);

}
