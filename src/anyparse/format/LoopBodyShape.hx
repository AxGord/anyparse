package anyparse.format;

/**
 * Runtime shape probe for the `loopBodyIfElseNext` writer knob (slice
 * omega-loop-body-if-else-next; JSON key `sameLine.loopBodyIfElseNext`).
 *
 * `isIfWithElse` is spliced by `WriterLowering` around the body value of
 * `HxForStmt.body` / `HxWhileStmt.body` / `HxDoWhileStmt.body` (the fields
 * carrying `@:fmt(loopBodyIfElseNext(...))`). It answers ONE question no body
 * PLACEMENT can ask for itself: is the statement about to be glued to the loop
 * header an `if` that carries an `else`? Its answer substitutes
 * `BodyPolicy.Next` for the placement in `WriterBodyPolicyLowering.`
 * `buildBodyCoreWrap`, upstream of every layout, so `same` and `keep` obey it
 * exactly as `fitLine` does.
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
	 *
	 * `wrapperCtor`, when given, is ONE enum ctor to unwrap before the probe:
	 * `HxDoWhileStmt.body` is an `HxDoWhileBody`, so its `if` arrives as
	 * `ExprBody(IfExpr(head))` where the `for` / `while` twin has the bare
	 * `IfStmt(head)`. The unwrap is a single level and answers `false` when the
	 * body carries a different ctor, so the two-name form is as narrow as the
	 * one-name one.
	 */
	public static function isIfWithElse(body: Dynamic, ifCtor: String, elseField: String, ?wrapperCtor: String): Bool {
		if (body == null || !Reflect.isEnumValue(body)) return false;
		if (wrapperCtor != null)
			return Type.enumConstructor(body) == wrapperCtor && isIfWithElse(Type.enumParameters(body)[0], ifCtor, elseField);
		if (Type.enumConstructor(body) != ifCtor) return false;
		final head: Dynamic = Type.enumParameters(body)[0];
		if (head == null || Reflect.isEnumValue(head) || !Reflect.hasField(head, elseField)) return false;
		return Reflect.field(head, elseField) != null;
	}

}
