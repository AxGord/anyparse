package anyparse.format;

using Lambda;

/**
 * Runtime shape probes over a BODY VALUE, for the writer knobs whose placement depends on what the body IS rather than
 * on how wide it renders (`loopBodyIfElseNext`, JSON key `sameLine.loopBodyIfElseNext`; `@:fmt(strictFitLineBody(...))`).
 *
 * `isIfWithElse` is spliced by `WriterLowering` around the body value of
 * `HxForStmt.body` / `HxWhileStmt.body` / `HxDoWhileStmt.body` (the fields
 * carrying `@:fmt(loopBodyIfElseNext(...))`). It answers ONE question no body
 * PLACEMENT can ask for itself: is the statement about to be glued to the loop
 * header an `if` that carries an `else`? `@:fmt(statementIfBody(...))` asks it of a
 * function body, to mark that `if` a statement. Its answer substitutes
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

	/**
	 * Is `body` one of the `ctors`?
	 *
	 * The question `@:fmt(strictFitLineBody(...))` asks before it lets a non-flat body
	 * keep its glue: only a body that is ITSELF a keyword-led construct carries its
	 * continuation inside what its own head opened. A value — a lambda, a map entry, a
	 * nested comprehension — stacks its closers under the container instead, which is
	 * the shape that flag refuses.
	 *
	 * `false` for a null body and for a non-enum one, as in `isIfWithElse`.
	 */
	public static function isOneOfCtors(body: Any, ctors: Array<String>): Bool {
		return body != null && Reflect.isEnumValue(body) && ctors.contains(Type.enumConstructor(body));
	}

	/**
	 * Does the `ifCtor` chain `body` hold a branch that is none of the `bracedCtors` (a block, a brace-led `switch`)?
	 *
	 * Every `thenField` of the chain and its final `elseField` are read; an `elseField` holding another `ifCtor` is the
	 * next link. `@:fmt(statementIfBody(...))` asks it before it moves a function body to its own line: a chain whose
	 * every branch is braced keeps its glue (`function f() if (c) {`, `if (c) switch x {`), only a brace-less branch
	 * ladders. `wrapperCtor`
	 * unwraps one level as in `isIfWithElse`; any unmodelled shape answers `false`.
	 */
	public static function hasBareBranch(
		body: Null<Any>, ifCtor: String, thenField: String, elseField: String, bracedCtors: Array<String>, ?wrapperCtor: String
	): Bool {
		if (!Reflect.isEnumValue(body)) return false;
		final value: EnumValue = cast body;
		return wrapperCtor != null
			? Type.enumConstructor(value) == wrapperCtor
				&& hasBareBranch(Type.enumParameters(value)[0], ifCtor, thenField, elseField, bracedCtors)
			: Type.enumConstructor(value) == ifCtor
				&& headHasBareBranch(Type.enumParameters(value)[0], ifCtor, thenField, elseField, bracedCtors);
	}

	/**
	 * `hasBareBranch` asked of an `if` HEAD (the struct holding `thenField` and `elseField`) rather than of the `ifCtor`
	 * value around it: a branch body's writer holds the head of its own `if`, and `@:fmt(ifElseLadder(...))` asks it
	 * whether a glued `switch` branch must ladder after all.
	 */
	public static function headHasBareBranch(
		head: Null<Any>, ifCtor: String, thenField: String, elseField: String, bracedCtors: Array<String>
	): Bool {
		if (head == null || Reflect.isEnumValue(head)) return false;
		if (isBareBranch(Reflect.field(head, thenField), bracedCtors)) return true;
		final elseBranch: Null<Any> = Reflect.field(head, elseField);
		return isBareBranch(elseBranch, [ifCtor])
			? isBareBranch(elseBranch, bracedCtors)
			: hasBareBranch(elseBranch, ifCtor, thenField, elseField, bracedCtors);
	}

	/**
	 * The one answer to "is this `if` / `else` chain a simple value": every branch of the chain `head` (an `<ifCtor>`'s
	 * struct) owns an `else`, and each branch is a `<wrapperCtor>` around a plain value, a node of `plainCtors` whose
	 * enum-valued children are plain values too (a literal, a name, a field read; never a call). An `else if` link is
	 * asked the same of its own chain.
	 */
	public static function isPlainValueChain(
		head: Null<Any>, ifCtor: String, thenField: String, elseField: String, wrapperCtor: String, plainCtors: Array<String>
	): Bool {
		if (head == null || Reflect.isEnumValue(head)) return false;

		final elseBranch: Null<Any> = Reflect.field(head, elseField);
		if (!Reflect.isEnumValue(elseBranch) || !isPlainBranch(Reflect.field(head, thenField), wrapperCtor, plainCtors)) return false;
		final elseValue: EnumValue = cast elseBranch;
		return Type.enumConstructor(elseValue) == ifCtor
			? isPlainValueChain(Type.enumParameters(elseValue)[0], ifCtor, thenField, elseField, wrapperCtor, plainCtors)
			: isPlainBranch(elseValue, wrapperCtor, plainCtors);
	}

	/**
	 * The statement a function body stands for: `body` with `wrapperCtor` unwrapped, then every loop of `loopCtors`
	 * (`Ctor.field`: the field of the ctor's struct that holds the loop body) looked through down to its body. `null` when
	 * the wrapper is missing; with no loop in the way it is the unwrap `isIfWithElse` does itself.
	 */
	public static function statementTail(body: Null<Any>, wrapperCtor: Null<String>, loopCtors: Array<String>): Null<Any> {
		var value: Null<Any> = body;
		if (wrapperCtor != null) {
			if (!Reflect.isEnumValue(value) || Type.enumConstructor(cast value) != wrapperCtor) return null;
			value = Type.enumParameters(cast value)[0];
		}
		while (Reflect.isEnumValue(value)) {
			final selector: Null<String> = peelSelector(cast value, loopCtors);
			if (selector == null) break;
			value = peeled(cast value, selector);
		}
		return value;
	}

	/**
	 * A present branch value that is an enum value none of `bracedCtors` names. A block wrapped in metadata or
	 * parentheses is none of them: the `if` writes it on its own line like a brace-less branch, so the chain ladders.
	 */
	private static function isBareBranch(branch: Null<Any>, bracedCtors: Array<String>): Bool {
		return Reflect.isEnumValue(branch) && !bracedCtors.contains(Type.enumConstructor(cast branch));
	}

	private static function isPlainBranch(branch: Null<Any>, wrapperCtor: String, plainCtors: Array<String>): Bool {
		if (!Reflect.isEnumValue(branch)) return false;
		final value: EnumValue = cast branch;
		return Type.enumConstructor(value) == wrapperCtor && isPlainValue(Type.enumParameters(value)[0], plainCtors);
	}

	private static function isPlainValue(node: Null<Any>, plainCtors: Array<String>): Bool {
		if (!Reflect.isEnumValue(node)) return false;
		final value: EnumValue = cast node;
		return plainCtors.contains(Type.enumConstructor(value))
			&& Type.enumParameters(value).foreach(param -> !Reflect.isEnumValue(param) || isPlainValue(param, plainCtors));
	}

	/** The entry of `selectors` (`Ctor.field`) naming the ctor of `value`, `null` when none does. */
	private static function peelSelector(value: EnumValue, selectors: Array<String>): Null<String> {
		final ctor: String = Type.enumConstructor(value);
		return selectors.find(selector -> selector.split('.')[0] == ctor);
	}

	/**
	 * What `selector` (`Ctor.field`) reaches inside `value`: the field of its first parameter, `null` when the parameter
	 * is absent or has no such field.
	 */
	private static function peeled(value: EnumValue, selector: String): Null<Any> {
		final param: Null<Any> = Type.enumParameters(value)[0];
		return param == null || Reflect.isEnumValue(param) ? null : Reflect.field(param, selector.substr(selector.indexOf('.') + 1));
	}

}
