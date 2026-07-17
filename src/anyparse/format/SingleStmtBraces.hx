package anyparse.format;

/**
 * Runtime support for the `dropSingleStmtBraces` writer knob (slice
 * ω-single-stmt-braces; JSON key
 * `whitespace.bracesConfig.singleStatementBraces: "remove"`).
 *
 * `unwrapStmt` is spliced by `WriterLowering` around the body value of
 * `HxIfStmt.thenBody` / `HxIfStmt.elseBody` / `HxForStmt.body` / `HxWhileStmt.body` / `HxDoWhileStmt.body` (fields carrying `@:fmt(dropSingleStmtBraces)`, trivia mode only). When every safety gate passes it returns the
 * block's single inner statement so the writer emits
 * `if (cond) return x;` instead of `if (cond) { return x; }`; in every
 * other case it returns the original body unchanged (byte-inert).
 *
 * The values are trivia-synthesised enums (`HxStatementT`), reached
 * here as `Dynamic` + enum reflection so this module never references
 * `Context.defineModule`-synthesised types. Positional-parameter
 * layout it relies on (locked by unit tests):
 *  - `BlockStmt(stmts, closeTrailing, openTrailing,
 *    trailingBlankBefore, trailingLeading, trailPresent)`
 *  - `ReturnStmt(value, trailPresent, …)` / `ExprStmt(expr,
 *    trailPresent)` — the trailing-`;` slot sits at index 1.
 * Elements of `stmts` are `anyparse.runtime.Trivial` wrappers (anon
 * structs, field access is portable).
 *
 * SAFETY GATES (a wrong drop changes semantics — every gate fails
 * CLOSED, i.e. keeps the braces):
 *  1. Exactly one statement in the block.
 *  2. No comment anywhere the braces own: block `openTrailing` /
 *     `closeTrailing` / `trailingLeading` slots, element
 *     `leadingComments` / `trailingComment`.
 *  3. The inner statement must self-terminate when written standalone:
 *     `ReturnStmt` / `ExprStmt` (and the other `@:trailOpt(';')`
 *     kinds) qualify only when their own `trailPresent` is true —
 *     `{ return x }` (no `;`) keeps braces because the braceless form
 *     would not re-parse before a `}`. Declaration statements
 *     (`var` / `final` / local functions) are excluded outright: the
 *     braces scope the binding, dropping them would widen it.
 *  4. Dangling else: when the enclosing construct has a trailing
 *     `else` (`elseFollows`), any `if` anywhere inside the candidate
 *     statement (`IfStmt` / `IfExpr`, plus `Cond*` raw
 *     conditional-compilation regions treated opaquely) keeps the
 *     braces — a braceless trailing `if` without its own `else` would
 *     capture the outer `else` (Haxe absorbs even a `;` before
 *     `else`). The whole-subtree scan over-approximates the trailing
 *     spine; over-keeping is always safe.
 *  5. `suppress` (`opt._ssbSuppress`) — set for the whole then-body
 *     write of an `if` that has an `else` — blocks every nested
 *     unwrap: `if (a) while (c) { if (b) x; } else y` must keep the
 *     loop-body braces even though the loop itself carries no
 *     `elseFollows` signal.
 */
class SingleStmtBraces {

	public static function unwrapStmt(body: Dynamic, drop: Bool, suppress: Bool, elseFollows: Bool): Dynamic {
		if (!drop || suppress || body == null) return body;
		if (!Reflect.isEnumValue(body)) return body;
		final block: EnumValue = cast body;
		if (Type.enumConstructor(block) == 'BlockBody') return unwrapDoBody(block);
		if (Type.enumConstructor(block) != 'BlockStmt') return body;
		final inner: Null<Dynamic> = singleCleanInner(Type.enumParameters(block));
		return inner == null ? body : !innerSelfTerminates(cast inner) ? body : elseFollows && containsIf(inner) ? body : inner;
	}

	private static function innerSelfTerminates(inner: EnumValue): Bool {
		return switch Type.enumConstructor(inner) {
			case 'ReturnStmt' | 'ExprStmt': Type.enumParameters(inner)[1] == true;
			case 'VoidReturnStmt' | 'ThrowStmt' | 'BreakStmt' | 'ContinueStmt' | 'DoWhileStmt': true;
			case 'IfStmt' | 'WhileStmt' | 'ForStmt' | 'SwitchStmt' | 'SwitchStmtBare' | 'TryCatchStmt': true;
			case _: false;
		};
	}

	private static function containsIf(v: Dynamic): Bool {
		if (v == null) return false;
		if (Std.isOfType(v, String) || Std.isOfType(v, Bool) || Std.isOfType(v, Float) || Std.isOfType(v, Int)) return false;
		if (Reflect.isEnumValue(v)) {
			final e: EnumValue = cast v;
			final ctor: String = Type.enumConstructor(e);
			if (ctor == 'IfStmt' || ctor == 'IfExpr' || StringTools.startsWith(ctor, 'Cond')) return true;
			for (p in Type.enumParameters(e)) if (containsIf(p)) return true;
			return false;
		}
		if (Std.isOfType(v, Array)) {
			final arr: Array<Dynamic> = v;
			for (x in arr) if (containsIf(x)) return true;
			return false;
		}
		if (Reflect.isObject(v)) {
			for (f in Reflect.fields(v)) if (containsIf(Reflect.field(v, f))) return true;
			return false;
		}
		return false;
	}


	/**
	 * Gates 1–2: the trivia `BlockStmt` param list must hold exactly one
	 * element and no comment in any brace-owned slot (block
	 * `openTrailing` / `closeTrailing` / `trailingLeading`, element
	 * `leadingComments` / `trailingComment`) nor a stray Star-owned
	 * trailing `;`. Returns the single inner statement (an enum value)
	 * when every gate passes, `null` otherwise.
	 */
	private static function singleCleanInner(ps: Array<Dynamic>): Null<Dynamic> {
		if (ps.length < 6) return null; // plain-mode arity — not supported
		final stmts: Null<Array<Dynamic>> = ps[0];
		if (stmts == null || stmts.length != 1) return null;
		if (ps[1] != null) return null; // closeTrailing comment before `}`
		if (ps[2] != null) return null; // openTrailing comment after `{`
		final trailingLeading: Null<Array<Dynamic>> = ps[4];
		if (trailingLeading != null && trailingLeading.length > 0) return null; // own-line comments before `}`
		if (ps[5] == true) return null; // stray trailing `;` owned by the Star
		final elem: Dynamic = stmts[0];
		if (elem == null) return null;
		final leading: Null<Array<Dynamic>> = elem.leadingComments;
		if (leading != null && leading.length > 0) return null;
		if (elem.trailingComment != null) return null;
		final inner: Dynamic = elem.node;
		if (inner == null || !Reflect.isEnumValue(inner)) return null;
		return inner;
	}


	/**
	 * Do-while body unwrap — `HxDoWhileBody.BlockBody` → `ExprBody`
	 * ctor mapping (`do { x(); } while (c);` → `do x() while (c);`).
	 * Only an `ExprStmt` inner maps (the other statement kinds have no
	 * `HxDoWhileBody` counterpart — braces kept). The mapped `ExprBody`
	 * carries `trailPresent=false`: modern Haxe REJECTS a `;` between a
	 * bare do-body and `while` (`do x(); while (c);` fails with
	 * "Expected while"), so the braceless canonical form drops it — the
	 * `while` keyword itself seals the statement boundary. The trivia
	 * `BlockBody` slot layout is identical to `BlockStmt`, so
	 * `singleCleanInner` is shared; dangling-else cannot arise (the body
	 * is always followed by `while`).
	 */
	private static function unwrapDoBody(block: EnumValue): Dynamic {
		final inner: Null<Dynamic> = singleCleanInner(Type.enumParameters(block));
		if (inner == null) return block;
		final innerE: EnumValue = cast inner;
		if (Type.enumConstructor(innerE) != 'ExprStmt') return block;
		final en: Null<Enum<Dynamic>> = Type.getEnum(cast block);
		return en == null ? block : Type.createEnum(en, 'ExprBody', [Type.enumParameters(innerE)[0], false]);
	}

}
