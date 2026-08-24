package anyparse.format;

using Lambda;
using StringTools;

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
 *  2. No comment in a brace-owned slot the bare statement cannot carry: block `closeTrailing` / `trailingLeading` slots, element `leadingComments`. TWO slots are exceptions, and both travel with the de-braced statement through `hoistTrailingComment`: a same-line element `trailingComment`, and the block's `openTrailing` comment - the one written on the `{` line (`} else { // Call error handlers`), which folds after the bare statement's `;` (`else\n\ttokenError(); // Call error handlers`). The fold site is ONE slot, so the two exceptions are mutually exclusive: a block carrying both keeps its braces. Folding after the statement rather than onto the header line is deliberate - a de-braced body may GLUE to its header (`if (c) f();`), and a comment placed there would comment the statement out.
 *  3. The inner statement must self-terminate when written standalone:
 *     `ReturnStmt` / `ExprStmt` (and the other `@:trailOpt(';')`
 *     kinds) qualify only when their own `trailPresent` is true —
 *     `{ return x }` (no `;`) keeps braces because the braceless form
 *     would not re-parse before a `}`. Declaration statements
 *     (`var` / `final` / local functions) are excluded outright: the
 *     braces scope the binding, dropping them would widen it.
 *  4. Dangling else: when the enclosing construct has a trailing
 *     `else` (`elseFollows`), the candidate keeps its braces iff its
 *     de-braced rendering would END on an `if` that can still absorb
 *     that `else`. The test is the TRAILING SPINE (`tailDanglingIf`),
 *     not a whole-subtree scan: an inner `if` is dangerous only when
 *     nothing seals it before the statement ends — a closing `)` /
 *     `]` / `}` of an enclosing call, index, array, block, switch or
 *     brace-bearing body makes it harmless, while the statement's own
 *     trailing `;` does NOT (Haxe absorbs a `;` before `else`).
 *     A trailing `if` that HAS its own `else` consumes the following
 *     `else` itself, so the spine walk continues into that `else`
 *     branch — for an `else if` chain the question is whether the
 *     FINAL arm lacks an `else`. `Cond*` raw conditional-compilation
 *     regions are opaque: dangerous whenever they sit on the spine.
 *     Every ctor the spine walk does not model falls back to the
 *     whole-subtree `containsIf` scan, i.e. to the pre-slice
 *     over-approximation — unknown shapes fail closed.
 *  5. `suppress` (`opt._ssbSuppress`) — set for the then-body write of
 *     an `if` that has an `else` whose then-body does NOT render with
 *     braces — blocks a nested unwrap under the SAME trailing-spine
 *     test as gate 4: `if (a) while (c) { if (b) x; } else y` must
 *     keep the loop-body braces even though the loop itself carries no
 *     `elseFollows` signal, while `if (a) while (c) { g(); } else y`
 *     de-braces (the loop body ends on a sealed call). Position inside
 *     the then-body is over-approximated to "on the spine"; a
 *     brace-bearing then-body is sealed by its own `}` and so never
 *     arms the frame at all (`WriterLowering.deBraceBodyAccess`).
 *  6. `hasTrailingSemi` — a redundant trailing `;` on the enclosing
 *     statement (the `@:trailOpt(';')` slot, e.g. `for (c) { x; };`).
 *     UNREACHABLE since omega-ssb-trailopt-drop: the writer no longer re-emits
 *     that slot on a brace-droppable field, so every splice passes `false`.
 *     It survives as a fail-closed guard for a future field that both drops
 *     braces and emits a trail. It once mattered because de-bracing would
 *     emit `for (c) x;;`, which anyparse parses but
 *     the Haxe compiler rejects ("Expected }"), so the braces stay.
 *  7. `siblingKeepsBraces` - if/else brace symmetry: an if/else must
 *     de-brace BOTH branches or NEITHER. The probe answers THROUGH
 *     `unwrapStmt`, so it inherits gate 4's trailing-spine precision
 *     verbatim - there is no second copy of the dangling-else test that
 *     could drift from it. Each splice probes the OTHER
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
		if (isIfThenBody && Type.enumConstructor(block) == 'IfStmt') return wrapInBlock(block, 'BlockStmt');
		// Gate 7 repair direction (omega-ssb-symmetry-wrap) - see `needsSymmetryWrap`.
		if (needsSymmetryWrap(block, siblingKeepsBraces)) return wrapInBlock(block, 'BlockStmt');
		// The do-body is the ONE brace-droppable field a suppress frame cannot reach: its
		// rendering is always followed by the `while (...)` keyword+paren, so no de-braced
		// do-body can ever sit on the trailing spine of an enclosing then-body. Gate 5's
		// span-precision therefore lets it through unconditionally.
		if (Type.enumConstructor(block) == 'BlockBody') return unwrapDoBody(block);
		if (Type.enumConstructor(block) != 'BlockStmt') return body;
		// Gate 7 - if/else brace symmetry: when the SIBLING branch keeps its braces, this
		// branch keeps its own too. De-bracing one half of an if/else while the other stays
		// braced (`if (b) return true; else { ... }`) is an asymmetry violation, so fail closed.
		if (siblingKeepsBraces) return body;
		// Gate 6 — UNREACHABLE for the fields spliced today, kept as a fail-closed guard.
		// A redundant trailing `;` on the enclosing statement (`for (…) { x; };`) once
		// forced the braces to stay, because de-bracing would have emitted `for (…) x;;` -
		// parsed by anyparse, rejected by the Haxe compiler ("Expected }"). Since
		// omega-ssb-trailopt-drop the writer no longer RE-EMITS that slot on a
		// brace-droppable field (`WriterLowering.emitMandatoryRefTrail`), so every splice
		// passes `false` here and the hazard is gone at the root. The gate survives for a
		// future field that both drops braces and does emit a trail.
		if (hasTrailingSemi) return body;
		// The de-brace decision (gates 1-8) lives in `deBracedElem`, shared with
		// `hoistTrailingComment` so a same-line trailing comment on the single statement
		// travels with the bare statement (the writer folds it after the statement's own
		// `;`); every standalone-comment / dangling-else / symmetry gate still fails closed there.
		final elem: Null<Dynamic> = deBracedElem(body, drop, suppress, elseFollows, hasTrailingSemi, siblingKeepsBraces, isIfThenBody);
		return elem == null ? body : elem.node;
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
		// Gate 4's trailing-spine test is reached through that call, so this probe and the real
		// splice can never disagree about a dangling `else`.
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
	 * `keepsBraces` probe rather than short-circuiting the scan: a suppressed frame
	 * holds braces on exactly the branches whose de-braced tail could capture the
	 * enclosing `else` (gate 5), and the immediate-pair probe at each splice already
	 * reads it that way - a scan that ignored it would answer `false` for a chain
	 * whose links visibly keep their braces, leaving the head branch bare while its
	 * siblings gained braces from the pair probe. That mixed state is the one thing
	 * the chain gate exists to prevent. Suppress can only ever ADD braces here: it
	 * is a keep-arm of `deBracedElem`, never a de-brace one.
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
			// omega-ssb-trailopt-drop: always `false`. The terminal else-if then-body
			// CAN carry the enclosing statement's redundant trailing `;`, but the writer
			// no longer re-emits that slot, so gate 6 cannot fire at the real splice -
			// and a scan that still read the slot would hold the whole chain braced over
			// a `;` that never reaches the output.
			if (keepsBraces(innerThen, drop, suppress, innerElse != null, false, true)) return true;
			cur = innerElse;
		}
		return cur != null && keepsBraces(cur, drop, suppress, false, false, false);
	}

	/**
	 * The same-line trailing comment (verbatim, delimiters intact) that must
	 * travel with the de-braced single statement, or `null` when `unwrapStmt`
	 * does not de-brace `body` to a plain inner statement OR the statement
	 * carries no trailing comment. The writer folds the returned comment in
	 * after the bare statement's own `;` (`foldTrailingIntoBodyGroup`). Same
	 * gate arguments as `unwrapStmt` so the two stay in lock-step.
	 */
	public static function hoistTrailingComment(
		body: Dynamic, drop: Bool, suppress: Bool, elseFollows: Bool, hasTrailingSemi: Bool, siblingKeepsBraces: Bool, isIfThenBody: Bool
	): Null<String> {
		final elem: Null<Dynamic> = deBracedElem(body, drop, suppress, elseFollows, hasTrailingSemi, siblingKeepsBraces, isIfThenBody);
		if (elem == null) return null;
		final own: Null<String> = elem.trailingComment;
		return own ?? openTrailingOf(body);
	}

	/**
	 * `value` inside a synthesized single-element block of ITS OWN enum — `blockCtor` names the block
	 * constructor there, and `lift` raises the value into the block's element type when the two differ.
	 *
	 * One constructor for both symmetry directions. The STATEMENT side (gates 7 and 8) wraps a statement
	 * into a block of statements: same enum, no lift. The VALUE side wraps a branch EXPRESSION into a
	 * block expression, whose elements are STATEMENTS — so it passes a lift that builds the
	 * expression-statement, typed, from the writer's generated code. What is shared is the part that
	 * would otherwise drift: the Star element wrapper and the block ctor's positional slot vector.
	 */
	public static function wrapInBlock(value: EnumValue, blockCtor: String, ?lift: (EnumValue) -> Dynamic): Dynamic {
		final en: Null<Enum<Dynamic>> = Type.getEnum(cast value);
		if (en == null) return value;
		final raise: Null<(EnumValue) -> Dynamic> = lift;
		final elem: Dynamic = {
			blankBefore: false,
			blankAfterLeadingComments: false,
			newlineBefore: true,
			leadingComments: [],
			trailingComment: null,
			trailingBeforeSep: false,
			sepAfter: true,
			node: raise == null ? value : raise(value)
		};
		final args: Array<Dynamic> = [[elem], null, null, false, [], false];
		return Type.createEnum(en, blockCtor, args);
	}

	/**
	 * omega-value-brace-symmetry: does a VALUE-position branch need a synthesized block so its `if` /
	 * `else` pair is braced on both sides or neither?
	 *
	 * The value twin of gate 7's question, asked differently because the two sides differ in what
	 * "braced" means. A statement body may be DE-braced, so gate 7 has to probe what its sibling would
	 * RENDER as (`keepsBraces`); a value branch is never de-braced, so being braced is simply being
	 * `blockCtor`. Sharing one predicate would mean one function answering two questions.
	 *
	 * `skipCtors` carries the shapes a wrap would break: the chain ctor (`else if`, where a block would
	 * bury the chain) and any brace-LED value such as an object literal, which a block would re-open in
	 * statement position where `{` reads as a block.
	 */
	public static function symmetryNeedsValueWrap(
		value: Dynamic, sibling: Dynamic, drop: Bool, blockCtor: String, skipCtors: Array<String>
	): Bool {
		if (!drop || value == null || sibling == null) return false;
		if (!Reflect.isEnumValue(value) || !Reflect.isEnumValue(sibling)) return false;
		if (Type.enumConstructor(cast sibling) != blockCtor) return false;
		final own: String = Type.enumConstructor(cast value);
		return own != blockCtor && !skipCtors.contains(own);
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

	/** Is `o` a trivia typedef struct that declares `name`? Enum values and `null` are not. */
	private static inline function hasStructField(o: Dynamic, name: String): Bool {
		return o != null && !Reflect.isEnumValue(o) && Reflect.hasField(o, name);
	}

	/** The `i`-th enum parameter, or `null` when the ctor carries fewer. */
	private static inline function paramAt(e: EnumValue, i: Int): Dynamic {
		final ps: Array<Dynamic> = Type.enumParameters(e);
		return i < ps.length ? ps[i] : null;
	}

	/**
	 * The payload of an `anyparse.runtime.Trivial` element wrapper, or the value
	 * itself when it is not wrapped. Star-field elements arrive wrapped; a plain
	 * Ref field does not, and no grammar typedef declares a field named `node`.
	 */
	private static inline function triviaNode(v: Dynamic): Dynamic {
		return hasStructField(v, 'node') ? Reflect.field(v, 'node') : v;
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
			case 'ReturnStmt', 'ExprStmt': Type.enumParameters(inner)[1] == true;
			case 'VoidReturnStmt', 'ThrowStmt', 'BreakStmt', 'ContinueStmt', 'DoWhileStmt', 'IfStmt', 'WhileStmt', 'ForStmt',
				'SwitchStmt', 'SwitchStmtBare', 'TryCatchStmt', 'TryCatchStmtBare':
				true;
			// Brace-bearing already - it self-terminates on `}`, but neither caller wants it:
			// gate 3 would unwrap `{ { x; } }` one level (that is `unnecessary-block`'s job) and
			// the gate-7 repair arm would wrap an ALREADY braced branch a second time. This arm
			// is the only thing keeping either from happening, so do not move it to the `true`
			// side without giving both callers their own guard.
			case 'BlockStmt', 'BlockBody': false;
			case _: false;
		};
	}

	/**
	 * Gates 4 and 5: would a bare `else` written directly after `v`'s rendering
	 * (modulo the statement's own trailing `;` and trivia) bind INSIDE `v`
	 * instead of to the `if` that owns it?
	 *
	 * The walk follows the TRAILING SPINE - at each node, only the child whose
	 * rendering ends the node's own rendering. Everything else is unreachable by
	 * a following `else`, so `f(x -> if (c) y)` is safe (the call's `)` seals the
	 * arrow body) while `x = () -> if (c) y` is not (nothing follows the arrow
	 * body). An `if` on the spine is dangerous only when it has NO `else` of its
	 * own; when it has one, that `else` is already taken and the walk continues
	 * into its branch, which is what makes `while (c) if (b) p(); else q();`
	 * safe in front of an outer `else` (verified against the Haxe compiler).
	 *
	 * Three-way classification, all of it fail-closed:
	 *  - `Cond*` (raw conditional-compilation regions) are opaque - the `#end`
	 *    marker is not a token the parser sees, so anything can be at the tail:
	 *    dangerous whenever reached.
	 *  - `tailSealed` ctors end on `)` / `]` / `}` / an operator / an identifier,
	 *    so nothing inside them can reach the `else`: safe without recursing.
	 *  - `tailOperandIndex` ctors end on one designated child: recurse into it.
	 * Any ctor in NONE of those falls back to `containsIf`, the whole-subtree
	 * over-approximation this gate used before the spine walk existed - an
	 * unmodelled shape can only over-KEEP braces, never over-remove them.
	 *
	 * MAINTENANCE: adding a grammar ctor needs an entry here only to gain
	 * precision. A WRONG entry is the one hazard - a ctor listed as sealed that
	 * actually ends on a child, or a tail index pointing at a child that is not
	 * rendered last, silently drops a brace pair that carries meaning.
	 */
	private static function tailDanglingIf(v: Dynamic): Bool {
		if (v == null) return false;
		if (!Reflect.isEnumValue(v)) return containsIf(v);
		final e: EnumValue = cast v;
		final ctor: String = Type.enumConstructor(e);
		if (ctor.startsWith('Cond')) return true;
		if (tailSealed(ctor)) return false;
		final operand: Int = tailOperandIndex(ctor);
		if (operand >= 0) return tailDanglingIf(paramAt(e, operand));
		final head: Dynamic = paramAt(e, 0);
		return switch ctor {
			case 'IfStmt': elseTailDanglingIf(head, 'elseBody');
			case 'IfExpr':
				elseTailDanglingIf(head, 'elseBranch');
			// Loop / lambda / function typedefs whose LAST field is the body.
			case 'WhileStmt', 'WhileExpr', 'ForStmt', 'ForExpr', 'ForReifExpr', 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'FnExpr',
				'NamedFnExpr', 'LocalFnStmt', 'LocalInlineFnStmt':
				fieldTailDanglingIf(head, 'body');
			case 'TryCatchStmt', 'TryCatchStmtBare', 'TryExpr': tailCatchDanglingIf(head);
			case 'MetaExpr': fieldTailDanglingIf(head, 'expr');
			case 'MetaStmt': fieldTailDanglingIf(head, 'stmt');
			case _: containsIf(e);
		};
	}

	/**
	 * The `if` / `if`-expression arm of `tailDanglingIf`: an else-less `if` at the
	 * tail captures the following `else`, so it is dangerous whatever its then-body
	 * looks like (a braced then-body seals nothing - the `if` itself is still open).
	 * With an `else` present that `else` is already bound, and the spine continues
	 * into its branch, so an `else if` chain is decided by its FINAL arm.
	 */
	private static function elseTailDanglingIf(head: Dynamic, elseField: String): Bool {
		if (!hasStructField(head, elseField)) return true;
		final elseBody: Dynamic = Reflect.field(head, elseField);
		return elseBody == null || tailDanglingIf(elseBody);
	}

	/**
	 * The try/catch arm: the rendering ends on the LAST catch clause's body, or on
	 * the try body when there are no catches. Covers the block-bodied `TryCatchStmt`
	 * too, whose last catch body may itself be bare.
	 */
	private static function tailCatchDanglingIf(head: Dynamic): Bool {
		if (!hasStructField(head, 'catches')) return true;
		final catches: Null<Array<Dynamic>> = Reflect.field(head, 'catches');
		return catches == null || catches.length == 0
			? fieldTailDanglingIf(head, 'body')
			: fieldTailDanglingIf(triviaNode(catches[catches.length - 1]), 'body');
	}

	/**
	 * The trailing spine through a NAMED field of a trivia typedef struct. A field the
	 * struct does not declare at all answers DANGEROUS: that is what a grammar rename
	 * looks like from a name-keyed walk, and reading it as "absent, therefore nothing
	 * is rendered, therefore safe" would silently start dropping braces the walk can no
	 * longer reason about. A DECLARED field holding `null` stays safe - an omitted
	 * `@:optional` body (a body-less `catch (e:T)`, a signature-only `function()`)
	 * renders nothing after the token that precedes it.
	 */
	private static function fieldTailDanglingIf(head: Dynamic, name: String): Bool {
		return !hasStructField(head, name) || tailDanglingIf(Reflect.field(head, name));
	}

	/**
	 * Ctors whose rendering ends on a token no `else` can attach to: a closing
	 * `)` / `]` / `}`, a postfix operator, or an identifier. Nothing inside them
	 * is on the trailing spine, so `tailDanglingIf` stops without recursing.
	 * `BlockBody` / `ExprBody` are shared ctor names across `HxDoWhileBody`,
	 * `HxFnBody` and `HxFnExprBody`; all three `BlockBody` variants are
	 * brace-bearing and all three `ExprBody` variants are single-operand, so the
	 * name-keyed classification is unambiguous for both.
	 */
	private static function tailSealed(ctor: String): Bool {
		return switch ctor {
			// Statements closed by `}` (block / switch / untyped block).
			case 'BlockStmt', 'SwitchStmt', 'SwitchStmtBare', 'UntypedBlockStmt':
				true;
			// Keyword statements closed by their own `;` or by the do-while `)`.
			case 'DoWhileStmt', 'BreakStmt', 'ContinueStmt', 'VoidReturnStmt', 'EmptyStmt', 'EllipsisStmt', 'ErrorStmt':
				true;
			// Function / do-while body wrappers that carry their own braces or `;`.
			case 'BlockBody', 'UntypedBlockBody', 'NoBody':
				true;
			// Expressions closed by a brace or a paren.
			case 'ArrayExpr', 'ObjectLit', 'BlockExpr', 'ParenExpr', 'ECheckTypeExpr', 'NewExpr', 'TypedCastExpr', 'SwitchExpr',
				'SwitchExprBare', 'DollarBlockExpr', 'DollarReifExpr':
				true;
			// Postfix operators and member access - the last token is a bracket, an
			// operator or a name.
			case 'IndexAccess', 'Call', 'FieldAccess', 'SafeFieldAccess', 'ForceFieldAccess', 'PostIncr', 'PostDecr':
				true;
			case _: false;
		};
	}

	/**
	 * The positional child that ends this ctor's rendering, or `-1` when the ctor
	 * is not modelled that way (sealed, struct-shaped, or unknown). Trivia
	 * synthesis APPENDS its slots after the grammar parameters - verified against
	 * the live parser (`Add` is `[left, right, Bool, null, null]`,
	 * `Ternary` is `[cond, then, else]`, `ExprStmt` is `[expr, Bool]`) - so the
	 * grammar-order indices below are stable in trivia mode.
	 */
	private static function tailOperandIndex(ctor: String): Int {
		return switch ctor {
			case 'Ternary':
				2;
			// Every binary infix operator, incl. the arrows: the right operand is last.
			// `Is` / `HxType.Arrow` put a type there, which the walk treats conservatively.
			case 'Mul', 'Div', 'Mod', 'Add', 'Sub', 'Shl', 'UShr', 'Shr', 'BitOr', 'BitAnd', 'BitXor', 'Eq', 'NotEq', 'LtEq', 'GtEq',
				'Lt', 'Gt', 'Interval', 'Is', 'And', 'Or', 'NullCoal', 'In', 'Assign', 'AddAssign', 'SubAssign', 'MulAssign', 'DivAssign',
				'ModAssign', 'ShlAssign', 'UShrAssign', 'ShrAssign', 'BitOrAssign', 'BitAndAssign', 'BitXorAssign', 'NullCoalAssign',
				'BoolAndAssign', 'BoolOrAssign', 'ThinArrow', 'Arrow':
				1;
			// Single-operand statements, prefix operators and keyword-atom expressions.
			case 'ReturnStmt', 'ExprStmt', 'ThrowStmt', 'ExprBody', 'ReturnExpr', 'ThrowExpr', 'UntypedExpr', 'CastExpr', 'InlineExpr',
				'MacroExpr', 'Neg', 'Not', 'BitNot', 'PreIncr', 'PreDecr', 'Spread':
				0;
			case _: -1;
		};
	}

	private static function containsIf(v: Dynamic): Bool {
		if (v == null) return false;
		if (Std.isOfType(v, String) || Std.isOfType(v, Bool) || Std.isOfType(v, Float) || Std.isOfType(v, Int)) return false;
		if (Reflect.isEnumValue(v)) {
			final e: EnumValue = cast v;
			final ctor: String = Type.enumConstructor(e);
			if (ctor == 'IfStmt' || ctor == 'IfExpr' || ctor.startsWith('Cond')) return true;
			for (p in Type.enumParameters(e)) if (containsIf(p)) return true;
			return false;
		}
		if (Std.isOfType(v, Array)) {
			final arr: Array<Dynamic> = v;
			return arr.exists(x -> containsIf(x));
		}
		return Reflect.isObject(v) && Reflect.fields(v).exists(f -> containsIf(Reflect.field(v, f)));
	}

	/**
	 * Gates 1-2: the trivia `BlockStmt` param list must hold exactly one
	 * element and no comment in any brace-owned slot (block `openTrailing`
	 * / `closeTrailing` / `trailingLeading`, element `leadingComments`).
	 * Returns the single inner ELEMENT (the `Trivial` wrapper) when every
	 * gate passes, `null` otherwise. `allowTrailingComment` relaxes the
	 * element `trailingComment` gate: a same-line trailing comment on the
	 * single statement is permitted (it travels with the de-braced
	 * statement, hoisted by `hoistTrailingComment`), while every OTHER
	 * comment slot still fails closed.
	 */
	private static function singleCleanElem(ps: Array<Dynamic>, allowTrailingComment: Bool): Null<Dynamic> {
		if (ps.length < 6) return null; // plain-mode arity - not supported
		final stmts: Null<Array<Dynamic>> = ps[0];
		if (stmts == null || stmts.length != 1) return null;
		if (ps[1] != null) return null; // closeTrailing comment before `}`
		final trailingLeading: Null<Array<Dynamic>> = ps[4];
		if (trailingLeading != null && trailingLeading.length > 0) return null; // own-line comments before `}`
		if (ps[5] == true) return null; // stray trailing `;` owned by the Star
		final elem: Dynamic = stmts[0];
		if (elem == null) return null;
		final leading: Null<Array<Dynamic>> = elem.leadingComments;
		// openTrailing (a comment on the `{` line) travels with the statement the same way a
		// same-line trailing comment does — but only into an EMPTY trailing slot: the fold
		// site is one slot, so two comments cannot both land there.
		return if (leading != null && leading.length > 0)
			null
		else if (!allowTrailingComment && elem.trailingComment != null)
			null
		else if (ps[2] != null && !(allowTrailingComment && elem.trailingComment == null))
			null
		else
			elem;
	}

	/**
	 * Strict single-inner-statement gate (no trailing comment) returning the
	 * inner statement node - the do-body path, which has no channel to hoist
	 * a comment and so keeps its braces when one is present.
	 */
	private static function singleCleanInner(ps: Array<Dynamic>): Null<Dynamic> {
		final elem: Null<Dynamic> = singleCleanElem(ps, false);
		if (elem == null) return null;
		final inner: Dynamic = elem.node;
		return inner == null || !Reflect.isEnumValue(inner) ? null : inner;
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
	 * The single inner ELEMENT (`Trivial` wrapper) IFF `unwrapStmt` de-braces
	 * `body` to a plain inner statement - the ONLY case where a same-line
	 * trailing comment must be hoisted onto the de-braced statement. Every
	 * keep / wrap / do-body / non-BlockStmt case returns `null`. Shared by
	 * `unwrapStmt` (reads `.node`) and `hoistTrailingComment` (reads
	 * `.trailingComment`) so the two never disagree on whether de-bracing happened.
	 * The block's `openTrailing` comment — the one written on the `{` line
	 * (`} else { // Call error handlers`) — or null when the slot is empty.
	 *
	 * Only ever read AFTER `deBracedElem` returned an element, i.e. after
	 * `singleCleanElem` already accepted this slot, so the shape is known to be a
	 * `BlockStmt` in trivia mode. The slot index is the one `singleCleanElem`
	 * documents; keeping the read here rather than threading a second return value
	 * out of `deBracedElem` keeps every other caller's signature untouched.
	 */
	private static function openTrailingOf(body: Dynamic): Null<String> {
		if (body == null || !Reflect.isEnumValue(body)) return null;
		final ps: Array<Dynamic> = Type.enumParameters(cast body);
		return ps.length < 6 ? null : ps[2];
	}

	private static function deBracedElem(
		body: Dynamic, drop: Bool, suppress: Bool, elseFollows: Bool, hasTrailingSemi: Bool, siblingKeepsBraces: Bool, isIfThenBody: Bool
	): Null<Dynamic> {
		if (!drop || body == null || !Reflect.isEnumValue(body)) return null;
		final block: EnumValue = cast body;
		if (isIfThenBody && Type.enumConstructor(block) == 'IfStmt') return null; // gate 8 wrap - no de-brace
		if (needsSymmetryWrap(block, siblingKeepsBraces)) return null; // gate 7 wrap - no de-brace
		if (Type.enumConstructor(block) != 'BlockStmt') return null; // do-body / non-block - no plain de-brace
		if (siblingKeepsBraces) return null; // gate 7 keep
		if (hasTrailingSemi) return null; // gate 6 keep
		final elem: Null<Dynamic> = singleCleanElem(Type.enumParameters(block), true);
		if (elem == null) return null; // gates 1-2
		final inner: Dynamic = elem.node;
		// Gates 4 + 5 share ONE test. `elseFollows` means an `else` is written directly
		// after this body; `suppress` means one is written after the enclosing then-body,
		// with this candidate's position inside it over-approximated to "on the spine".
		// Either way the question is the same: would that `else` bind inside the de-braced
		// statement instead of to its own `if`?
		return if (inner == null || !Reflect.isEnumValue(inner))
			null
		else if (isIfThenBody && Type.enumConstructor(cast inner) == 'IfStmt')
			null // gate 8 keep
		else if (!innerSelfTerminates(cast inner))
			null // gate 3 terminator
		else if ((elseFollows || suppress) && tailDanglingIf(inner))
			null
		else
			elem;
	}

}
