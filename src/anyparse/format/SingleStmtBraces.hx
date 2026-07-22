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
 *  6. `hasTrailingSemi` — a redundant trailing `;` on the enclosing
 *     statement (the `@:trailOpt(';')` slot, e.g. `for (c) { x; };`).
 *     De-bracing would emit `for (c) x;;`, which anyparse parses but
 *     the Haxe compiler rejects ("Expected }"), so the braces stay.
 *  7. `siblingKeepsBraces` - if/else brace symmetry: an if/else must
 *     de-brace BOTH branches or NEITHER. Each splice probes the OTHER
 *     branch (via `keepsBraces`) and passes `true` here when that
 *     sibling keeps its braces, so `if (b) { one; } else { a; b; }`
 *     stays fully braced instead of the asymmetric
 *     `if (b) one; else { a; b; }`. Loop bodies (for / while / do) have
 *     no sibling - they always pass `false`. The gate runs in BOTH
 *     directions: a braced branch keeps its braces (fail closed), and a
 *     branch that arrives BARE opposite a brace-keeping sibling GAINS
 *     them through `wrapInBlock` - the same repair direction gate 8
 *     uses - so `if (a) { p(); q(); } else r();` canonicalises to a
 *     fully braced if/else instead of staying asymmetric. The wrap
 *     direction has ONE exemption of its own - an `IfStmt` in ELSE
 *     position, an `else if` chain link whose wrapping would rebuild
 *     the `else { if … }` shape the `collapsible-else-if` rule exists
 *     to remove - and otherwise defers to gate 3's
 *     `innerSelfTerminates`, which excludes both a `;`-less statement
 *     (it would not re-parse inside braces) and an already
 *     brace-bearing body (it would nest a redundant level).
 */
class SingleStmtBraces {

	public static function unwrapStmt(
		body: Dynamic, drop: Bool, suppress: Bool, elseFollows: Bool, hasTrailingSemi: Bool, siblingKeepsBraces: Bool, isIfThenBody: Bool
	): Dynamic {
		if (!drop || body == null) return body;
		if (!Reflect.isEnumValue(body)) return body;
		final block: EnumValue = cast body;
		// Gate 8 repair direction (omega-ssb-wrap): a BARE `if` in then-position gains a
		// synthesized brace block - `if (a) if (b) ... else ...` reads as a dangling-else
		// puzzle, so braces are REQUIRED there and fmt self-heals previously unwrapped
		// sources. Runs even under `suppress` (adding braces is always semantics-safe:
		// the parse tree already fixed the else binding).
		if (isIfThenBody && Type.enumConstructor(block) == 'IfStmt') return wrapInBlock(block);
		// Gate 7 repair direction (omega-ssb-symmetry-wrap) - see `needsSymmetryWrap`.
		if (needsSymmetryWrap(block, siblingKeepsBraces)) return wrapInBlock(block);
		if (suppress) return body;
		if (Type.enumConstructor(block) == 'BlockBody') return unwrapDoBody(block);
		if (Type.enumConstructor(block) != 'BlockStmt') return body;
		// Gate 7 - if/else brace symmetry: when the SIBLING branch keeps its braces, this
		// branch keeps its own too. De-bracing one half of an if/else while the other stays
		// braced (`if (b) return true; else { ... }`) is an asymmetry violation, so fail closed.
		if (siblingKeepsBraces) return body;
		// Gate 6 — a redundant trailing `;` on the enclosing statement (`for (…) { x; };`,
		// the `@:trailOpt(';')` slot): de-bracing would emit `for (…) x;;`, which anyparse
		// parses but the Haxe compiler rejects ("Expected }"). Keep the braces (fail closed).
		if (hasTrailingSemi) return body;
		final inner: Null<Dynamic> = singleCleanInner(Type.enumParameters(block));
		// Gate 8 - then-branch readability: when the sole inner statement is itself an
		// `if`, the braces stay even though every removal gate passes. Loop bodies and
		// else-bodies are exempt (`for (...) if (...)` guard headers and `else if`
		// chains are the preferred style).
		return inner == null
			? body
			: isIfThenBody && Type.enumConstructor(cast inner) == 'IfStmt'
				? body
				: !innerSelfTerminates(cast inner) ? body : elseFollows && containsIf(inner) ? body : inner;
	}

	/**
	 * Would this branch RENDER with braces? True only when `body` is a
	 * brace-bearing `BlockStmt` that `unwrapStmt` would NOT de-brace. A branch
	 * that carries no braces to begin with - a bare statement, or an
	 * `else if` (`IfStmt`) - returns false: there is nothing to stay
	 * asymmetric against. The if/else splices call this to probe the OTHER
	 * branch, feeding gate 7 so `if (b) { one; } else { a; b; }` keeps both
	 * braced while `if (a) x(); else if (b) y(); else z();` still de-braces.
	 *
	 * It stays consistent with gate 7's repair direction WITHOUT recursing:
	 * the probe calls `unwrapStmt` with symmetry forced OFF, and the repair arm
	 * fires only when symmetry is ON - so a probe can never reach it (it also
	 * calls in only for a `BlockStmt`, which `innerSelfTerminates` excludes
	 * from the arm anyway). That is what keeps a chain from oscillating: no
	 * branch's answer depends on an answer that depends on it. The one wrap a
	 * probe MUST account for is gate 8's (then-position bare `if`), which is
	 * unconditional and handled by the `IfStmt` arm below.
	 */
	public static function keepsBraces(
		body: Dynamic, drop: Bool, suppress: Bool, elseFollows: Bool, hasTrailingSemi: Bool, isIfThenBody: Bool
	): Bool {
		if (body == null || !Reflect.isEnumValue(body)) return false;
		// omega-ssb-wrap: a bare `if` in then-position RENDERS braced (the wrap
		// direction synthesizes its block), so sibling-symmetry probes must see it
		// as brace-keeping.
		// `unwrapStmt` (symmetry forced off) returns the body UNCHANGED only when it would NOT
		// de-brace it on its own merits (gates 1-6, 8) - i.e. the block renders WITH its braces.
		return isIfThenBody && Type.enumConstructor(cast body) == 'IfStmt'
			? drop
			: Type.enumConstructor(cast body) == 'BlockStmt'
				&& unwrapStmt(body, drop, suppress, elseFollows, hasTrailingSemi, false, isIfThenBody) == body;
	}

	/**
	 * ω-single-stmt-braces CHAIN symmetry: does ANY branch of an if / else-if /
	 * else chain keep its braces? OR of `keepsBraces` over the outer then, every
	 * else-if then, and the terminal else block, walking the nested `elseBody`
	 * spine. `IfStmt(stmt)` wraps a single `HxIfStmt` struct, reached via
	 * `Type.enumParameters(v)[0]`; its `thenBody` / `elseBody` are portable field
	 * accesses. When true the caller forces braces on EVERY branch (symmetric-
	 * braced); only a chain whose every branch is de-braceable de-braces them all.
	 * A null `elseBody` (a lone `if`) or a non-`if` terminal are handled by the
	 * walk. Each branch's `elseFollows` is derived from the spine so gate 4
	 * (dangling-else) matches its real splice exactly, and `hasTrailingSemi` is
	 * read from each else-if then-body's own `TrailPresent` slot: only the
	 * TERMINAL branch (no further `else`) can carry a redundant trailing `;`
	 * (gate 6) — missing it would leave that branch braced while earlier branches
	 * de-brace. Byte-inert when `drop` is off. `suppress` is THREADED into every
	 * `keepsBraces` probe rather than short-circuiting the scan: inside a suppress
	 * frame a `BlockStmt` renders braced whatever its own merits say, and the
	 * immediate-pair probe at each splice already reads it that way — a scan that
	 * ignored it would answer `false` for a chain whose links visibly keep their
	 * braces, leaving the head branch bare while its siblings gained braces from the
	 * pair probe. That mixed state is the one thing the chain gate exists to prevent.
	 * Suppress can only ever ADD braces here: `unwrapStmt` returns on its own
	 * `suppress` guard before gate 7's de-brace arm is reached, so the widened
	 * answer feeds the wrap direction alone.
	 */
	public static function chainForcesBraces(thenBody: Dynamic, elseBody: Dynamic, drop: Bool, suppress: Bool): Bool {
		if (!drop) return false;
		if (keepsBraces(thenBody, drop, suppress, elseBody != null, false, true)) return true;
		var cur: Dynamic = elseBody;
		while (cur != null && Reflect.isEnumValue(cur) && Type.enumConstructor(cast cur) == 'IfStmt') {
			final ps: Array<Dynamic> = Type.enumParameters(cast cur);
			final stmt: Null<Dynamic> = ps.length == 0 ? null : ps[0];
			if (stmt == null) break;
			final innerThen: Dynamic = stmt.thenBody;
			final innerElse: Dynamic = stmt.elseBody;
			// The terminal else-if then-body (no further `else`) can carry the
			// enclosing statement's trailing `;`; gate 6 keeps its braces at the real
			// splice, so the scan must see it too. Non-terminal then-bodies are always
			// false — a `;` never sits between a then-block and `else`.
			final innerTrail: Bool = stmt.thenBodyTrailPresent == true;
			if (keepsBraces(innerThen, drop, suppress, innerElse != null, innerTrail, true)) return true;
			cur = innerElse;
		}
		return cur != null && keepsBraces(cur, drop, suppress, false, false, false);
	}

	/**
	 * Gate 7's repair direction (omega-ssb-symmetry-wrap): should this body gain the
	 * braces its brace-keeping sibling has? Runs under `suppress` for the same reason
	 * the gate-8 wrap does - adding braces never changes semantics. `!= 'IfStmt'` is
	 * the ELSE-position exemption: `unwrapStmt` returns the then-position bare `if`
	 * before this is reached, so any `IfStmt` still here is an `else if` chain link,
	 * and wrapping it would rebuild the `else { if … }` shape `collapsible-else-if`
	 * exists to remove. `innerSelfTerminates` is gate 3 read in reverse and carries
	 * TWO exclusions: a statement with no terminator of its own (`else r()` with no
	 * `;`) would not re-parse inside braces, and a brace-bearing `BlockStmt` /
	 * `BlockBody` is already braced - wrapping it again would nest a redundant level.
	 */
	private static inline function needsSymmetryWrap(block: EnumValue, siblingKeepsBraces: Bool): Bool {
		return siblingKeepsBraces && Type.enumConstructor(block) != 'IfStmt' && innerSelfTerminates(block);
	}

	/**
	 * Does this statement carry its own terminator when it stands alone outside a
	 * block? Gate 3 asks it about HOISTING a statement OUT of braces; the gate-7
	 * repair arm asks the reverse question (may this statement be put INSIDE braces).
	 * The two differ only on inputs that are already invalid Haxe - e.g. a
	 * `WhileStmt` whose own body is a bare unterminated statement answers `true`
	 * here, but both that input and its wrapped form are rejected by the compiler, so
	 * no valid program is affected.
	 */
	private static function innerSelfTerminates(inner: EnumValue): Bool {
		return switch Type.enumConstructor(inner) {
			case 'ReturnStmt' | 'ExprStmt': Type.enumParameters(inner)[1] == true;
			case 'VoidReturnStmt' | 'ThrowStmt' | 'BreakStmt' | 'ContinueStmt' | 'DoWhileStmt': true;
			case 'IfStmt' | 'WhileStmt' | 'ForStmt' | 'SwitchStmt' | 'SwitchStmtBare' | 'TryCatchStmt':
				true;
			// Brace-bearing already - it self-terminates on `}`, but neither caller wants it:
			// gate 3 would unwrap `{ { x; } }` one level (that is `unnecessary-block`'s job) and
			// the gate-7 repair arm would wrap an ALREADY braced branch a second time. This arm
			// is the only thing keeping either from happening, so do not move it to the `true`
			// side without giving both callers their own guard.
			case 'BlockStmt' | 'BlockBody': false;
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


	/**
	 * omega-ssb-wrap - the repair direction of gate 8: a bare `if` in
	 * then-position is wrapped in a synthesized brace block so
	 * `if (a) if (b) ... else ...` self-heals to `if (a) { if (b) ... }` on
	 * the next write. The synthesized `BlockStmt` slots mirror
	 * `singleCleanInner`'s locked layout (stmts, closeTrailing, openTrailing,
	 * trailingBlankBefore, trailingLeading, trailPresent); the sole element
	 * carries empty trivia with `newlineBefore=true` so the wrapped statement
	 * lands on its own line inside the braces.
	 */
	private static function wrapInBlock(stmt: EnumValue): Dynamic {
		final en: Null<Enum<Dynamic>> = Type.getEnum(cast stmt);
		if (en == null) return stmt;
		final elem: Dynamic = {
			blankBefore: false,
			blankAfterLeadingComments: false,
			newlineBefore: true,
			leadingComments: [],
			trailingComment: null,
			trailingBeforeSep: false,
			sepAfter: true,
			node: stmt
		};
		final args: Array<Dynamic> = [[elem], null, null, false, [], false];
		return Type.createEnum(en, 'BlockStmt', args);
	}

}
