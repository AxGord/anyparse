package anyparse.format;

/**
 * Runtime shape probe for the `loopBodyIfElseNext` writer knob (slice
 * omega-loop-body-if-else-next; JSON key `sameLine.loopBodyIfElseNext`).
 *
 * `isIfWithElse` is spliced by `WriterLowering` around the body value of
 * `HxForStmt.body` / `HxWhileStmt.body` (fields carrying
 * `@:fmt(loopBodyIfElseNext(...))`). It answers ONE question the `FitLine`
 * placement cannot ask for itself: is the statement about to be glued to the
 * loop header an `if` that carries an `else`?
 *
 * That distinction is the whole slice. A bare guard `if` glued to its header
 * (`for (x in xs) if (c) f(x);`) reads correctly and is a deliberate project
 * idiom. The same glue on an `if`/`else` pair leaves the `else` at the LOOP's
 * indent, where it reads as a branch of the loop rather than of the `if` - so
 * that shape, and only that shape, moves the whole body one line down and one
 * indent step in.
 *
 * The values are trivia-synthesised enums (`HxStatementT`), reached here as
 * `Dynamic` + enum reflection so this module never references a
 * `Context.defineModule`-synthesised type - the same access discipline
 * `SingleStmtBraces` uses next door. The ctor and field names arrive from the
 * grammar flag rather than being hard-coded, so the macro and this module both
 * stay format-neutral.
 *
 * Every unmodelled shape answers `false`, i.e. KEEPS the pre-slice glue.
 */
@:nullSafety(Strict)
final class LoopBodyShape {

	/**
	 * Is `body` an `ifCtor` statement whose head struct carries a non-null
	 * `elseField`?
	 *
	 * `false` for a null body, a non-enum body, any other ctor, a head that is
	 * not a struct, a head that does not declare the field at all (what a
	 * grammar rename looks like from a name-keyed probe), and a declared field
	 * holding `null` (an `if` with no `else`).
	 */
	public static function isIfWithElse(body: Dynamic, ifCtor: String, elseField: String): Bool {
		if (body == null || !Reflect.isEnumValue(body) || Type.enumConstructor(body) != ifCtor) return false;
		final head: Dynamic = Type.enumParameters(body)[0];
		if (head == null || Reflect.isEnumValue(head) || !Reflect.hasField(head, elseField)) return false;
		return Reflect.field(head, elseField) != null;
	}

}
