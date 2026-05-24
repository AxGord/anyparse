package unit.miniblock;

/**
 * Minimal grammar driving the `blockEnded` Star primitive pilot test
 * for the BlockBody Star tail-relax refactor ([[project-blockbody-star-tail-relax-debt]]).
 *
 * `Atom(s)` — bare identifier.
 * `Block(items)` — `{` ... `}` with `;` separator between elements;
 *   trailing `;` tolerated (tail-relax); between two elements `;` may
 *   be omitted when the prior element ends with `}` OR when the format
 *   instance's `endsImplicitly` predicate accepts the prior element's
 *   AST shape (Session 7 option b2 — AST-shape adapter). The
 *   `@:sep(';', tailRelax, blockEnded('endsImplicitly'))` annotation
 *   wires both byte-check and predicate paths.
 *
 * Schema is `MiniBlockFormat`, a dedicated pilot format — see its file
 * for the `endsImplicitly` predicate semantics and the rationale for
 * not reusing `JsonFormat` here (the predicate API forced a dedicated
 * format class).
 */
@:peg
@:schema(unit.miniblock.MiniBlockFormat)
@:ws
enum MiniBlock {

	Atom(s:MiniAtomLit);

	@:lead('{') @:trail('}') @:sep(';', tailRelax, blockEnded('endsImplicitly'))
	Block(items:Array<MiniBlock>);
}
