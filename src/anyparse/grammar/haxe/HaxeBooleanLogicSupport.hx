package anyparse.grammar.haxe;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Haxe `BooleanLogicSupport`: reduces a ternary with a boolean-literal branch to
 * an equivalent boolean expression. The four mixed forms collapse via
 * short-circuit `&&` / `||` (`cond ? true : x` -> `cond || x`, `cond ? false : x`
 * -> `!cond && x`, `cond ? x : true` -> `!cond || x`, `cond ? x : false` ->
 * `cond && x`), and the two pure-literal forms collapse to `cond` / `!cond`. A mixed form reduces only when its non-literal branch is a provably non-null `Bool` (a boolean-operator result); a `null` literal, bare identifier or call/field branch is left alone.
 *
 * Any negation is pushed inward by De Morgan — `!(a == null || b == null)`
 * becomes `a != null && b != null`, not `!(a == null || b == null)` — so the
 * result reads as plain boolean logic. Each operand is parenthesised only when it
 * binds strictly looser than the joining operator, so precedence (and meaning) is
 * preserved; the re-parse gate in the fix pipeline rejects anything malformed.
 *
 * `negateCondition` exposes that same engine to `guard-continue` / `loop-guard`,
 * but ORDER-SAFE: an ordered comparison (`< <= > >=`) is kept wrapped `!(a < b)`
 * rather than flipped to `a >= b`, since the two differ whenever an operand is a
 * NaN or a `null` — UNLESS the caller passes a type resolver that proves BOTH
 * operands drawn from a value set `<` orders totally (`TOTAL_ORDER_TYPES`), which
 * removes both cases they differ in and lets the flip through. `==` / `!=` flip
 * either way (equivalent under NaN and null alike).
 *
 * `simplifyNegatedCompound` runs that same engine over a `!( … )` node and offers the
 * result only when the unary-`!` count strictly falls. Two operand shapes reach it —
 * `negatedOperandOf` is the single test for both: a `&&` / `||` compound, which De Morgan
 * distributes (`!(!a || b)` -> `a && !b`), and a lone comparison, whose operator flips
 * (`!(x < 0)` -> `x >= 0` where the order gate licenses it, `!(a == b)` -> `a != b` always).
 * The one worth gate is what implements the order licence for the second arm: a flip costs no
 * `!`, a declined flip costs one, and the wrap it would emit is the input verbatim.
 *
 * The ternary / guard-chain reductions above flip ordered comparisons
 * unconditionally, as before; their only other visible effect is that a
 * `!(compound)` condition sheds redundant parens (the `Not` case unwraps a single
 * `ParenExpr`), a meaning-preserving change since `wrap` re-adds every
 * precedence-required paren.
 *
 * `cond ? X : X` with the same literal both sides is left alone: collapsing it
 * would drop `cond`, discarding any side effect of evaluating it.
 */
@:nullSafety(Strict)
final class HaxeBooleanLogicSupport implements BooleanLogicSupport {

	private static final BOOL_OP_KINDS: Array<String> = ['Or', 'And', 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq', 'Not'];

	/**
	 * Literal kinds `<` orders TOTALLY: neither a NaN nor a `null` can reach a comparison
	 * through one, so an operand of one of these kinds can never break `!(a < b)` <=> `a >= b`.
	 * A `FloatLit` is deliberately absent: `1e3` is a `Float`, and comparing against one is
	 * exactly the case the wrap protects. The two STRING literal kinds ARE here even though the
	 * `String` nominal is not — a literal is non-null BY CONSTRUCTION, which is precisely the
	 * proof a declaration cannot give (see `TOTAL_ORDER_TYPES`).
	 */
	private static final TOTAL_ORDER_LITERAL_KINDS: Array<String> = ['IntLit', 'HexLit', 'SingleStringExpr', 'DoubleStringExpr'];

	/**
	 * Declared type nominals whose value set `<` orders TOTALLY, so `!(a < b)` and `a >= b`
	 * agree for them. The criterion is the NAME, not a value blacklist: `<` must BE the built-in
	 * total order on the type. Among the built-in scalar comparisons two values break it — a NaN,
	 * which inhabits `Float` alone, and a `null`: with a null operand `!(a < b)` is true where
	 * `a >= b` is false, for all four ordered operators (measured on `--interp`, `js` and `neko`,
	 * Haxe 4.3.7). Ruling those two out is NOT sufficient on its own, so do not admit a nominal on
	 * that test alone: a Haxe abstract may define `@:op(A < B)` and `@:op(A >= B)` independently,
	 * and a non-complementary pair disagrees with no NaN and no null in sight.
	 *
	 * `String` is deliberately NOT here, and its absence is what the list's name now guards. A
	 * `String` carries no NaN, which is why it once WAS here — but Haxe has no non-nullable
	 * string type, so `s:String`, `?s:String` and an unannotated `s` alike prove nothing about
	 * null, and the flip is unsound for every one of them. The compiler draws the same line: it
	 * folds `!(a < b)` into `a >= b` ITSELF for `Int`, and emits `!(a < b)` verbatim for `String`
	 * and for `Float` (read off generated JS). Re-adding the nominal needs a NON-NULL proof this
	 * seam does not carry — the one non-null string shape, a literal, is licensed by
	 * `TOTAL_ORDER_LITERAL_KINDS` instead.
	 *
	 * `Null<Int>` resolves to the nominal `Null` and is likewise absent — one conservative step
	 * beyond the compiler, which folds that flip too.
	 */
	private static final TOTAL_ORDER_TYPES: Array<String> = ['Int', 'UInt'];

	/**
	 * The operand families `simplifyNegatedCompound` PAYS for: the `&&` / `||` compounds De Morgan
	 * distributes, and the six comparisons whose operator flips. A POSITIVE list, deliberately not
	 * "anything the worth gate accepts". TWO kinds the worth gate would let through are excluded
	 * here by name: `Not`, because `!(!x)` (`notDelta` -1) is `double-negation`'s shape and the two
	 * rules must stay disjoint, and `BoolLit`, because `!(true)` negates to `false` at `notDelta` 0
	 * and is `constant-condition`'s territory, not a De Morgan simplification. Everything else (a
	 * call, `is`, `??`, a bitwise operator, a bare identifier) the worth gate refuses too, so the
	 * list buys the guarantee that a FUTURE kind cannot leak in the day its `notDelta` happens to
	 * reach zero.
	 */
	private static final NEGATABLE_OPERAND_KINDS: Array<String> = ['Or', 'And', 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq'];

	public function new() {}

	public function simplifyBooleanTernary(ternary: QueryNode, source: String): Null<String> {
		if (ternary.kind != 'Ternary' || ternary.children.length != 3) return null;
		final cond: QueryNode = ternary.children[0];
		final thenNode: QueryNode = ternary.children[1];
		final elseNode: QueryNode = ternary.children[2];
		final thenBool: Null<Bool> = boolValue(thenNode, source);
		final elseBool: Null<Bool> = boolValue(elseNode, source);
		if (thenBool == null && elseBool == null) return null;
		if (thenBool != null && elseBool != null)
			return thenBool && !elseBool ? plain(cond, source).src : !thenBool && elseBool ? negate(cond, source, true).src : null;
		// Exactly one branch is a boolean literal; the other becomes an operand of
		// `&&` / `||`. That reduction is sound only when the non-literal branch is a
		// non-null `Bool` — a boolean-operator result. A `null` literal, a bare
		// identifier (possibly a `Null<Bool>` local) or a call / field access would
		// change meaning AND fail `@:nullSafety(Strict)` (`cond || null`), so the
		// ternary is left alone — mirroring `ComparisonToBoolean`'s `provablyBool` gate.
		final other: QueryNode = thenBool != null ? elseNode : thenNode;
		return !provablyBool(other)
			? null
			: thenBool != null
				? thenBool
					? joinOr(plain(cond, source), plain(elseNode, source))
					: joinAnd(negate(cond, source, true), plain(elseNode, source))
				: elseBool == true
					? joinOr(negate(cond, source, true), plain(thenNode, source))
					: joinAnd(plain(cond, source), plain(thenNode, source));
	}

	public function reduceBooleanGuardChain(
		conds: Array<QueryNode>, lits: Array<QueryNode>, finalLit: QueryNode, source: String
	): Null<String> {
		if (conds.length == 0 || conds.length != lits.length) return null;
		final finalVal: Null<Bool> = boolValue(finalLit, source);
		if (finalVal == null) return null;
		// Fold right-to-left from the trailing literal. `accLit` holds the accumulator's
		// boolean value while it is still a literal — used to simplify and to refuse a
		// fold that would absorb (drop) a condition's evaluation.
		var accSrc: String = finalVal ? 'true' : 'false';
		var accPrec: Precedence = PREC_ATOM;
		var accLit: Null<Bool> = finalVal;
		var i: Int = conds.length - 1;
		while (i >= 0) {
			final litVal: Null<Bool> = boolValue(lits[i], source);
			if (litVal == null) return null;
			final cond: QueryNode = conds[i];
			if (litVal == true) {
				if (accLit == true) return null; // cond || true -> true : drops cond's evaluation
				if (accLit == false) {
					final p: Operand = plain(cond, source); // cond || false -> cond
					accSrc = p.src;
					accPrec = p.prec;
				} else {
					accSrc = joinOr(plain(cond, source), {
						src: accSrc,
						prec: accPrec,
						declined: false,
						notDelta: 0
					});
					accPrec = PREC_OR;
				}
			} else {
				if (accLit == false) return null; // !cond && false -> false : drops cond's evaluation
				final n: Operand = negate(cond, source, true);
				if (accLit == true) { // !cond && true -> !cond
					accSrc = n.src;
					accPrec = n.prec;
				} else {
					accSrc = joinAnd(n, {
						src: accSrc,
						prec: accPrec,
						declined: false,
						notDelta: 0
					});
					accPrec = PREC_AND;
				}
			}
			accLit = null;
			i--;
		}
		return accSrc;
	}

	/**
	 * The order-safe De Morgan negation of `cond` — the seam `guard-continue` /
	 * `loop-guard` use to invert a lifted condition. `!` stripped, `&&` / `||`
	 * distributed, `==` / `!=` flipped, but an ordered comparison (`< <= > >=`)
	 * wrapped `!(…)` verbatim (flipped only where `typeNominalOf` proves both operands
	 * totally ordered — `!(a < b)` and `a >= b` differ whenever either side is a NaN or
	 * a `null`). Operands carry precedence-safe parentheses; a comment in the operator
	 * glue between operands is dropped, so the caller gates on a comment-free span.
	 */
	public function negateCondition(cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): String {
		return negate(cond, source, false, typeNominalOf).src;
	}

	/**
	 * Whether `negateCondition` had to DECLINE a rewrite it knows how to perform — an ordered
	 * comparison `typeNominalOf` could not prove totally ordered (NaN- AND null-free), kept as
	 * `!(a < b)` instead of flipped. A caller that inverts a condition purely so a block reads
	 * better refuses such a site: the negation buys nothing over the positive form it would
	 * replace. A wrap the engine could never avoid (`!(a is B)`, `!(a ?? b)`) is NOT a decline —
	 * that IS the canonical negation.
	 */
	public function negateConditionDeclinesFlip(cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): Bool {
		return negate(cond, source, false, typeNominalOf).declined;
	}

	/**
	 * The simplification of `!( … )` over either arm `negatedOperandOf` accepts — a `&&` / `||`
	 * compound De Morgan distributes (`!(!a || b)` → `a && !b`), or a single comparison whose
	 * operator flips (`!(x < 0)` → `x >= 0`, `!(a == b)` → `a != b`) — or null when `not` is
	 * neither shape, or when the rewrite would not PAY. The text is `negate`'s — the same
	 * order-safe engine `negateCondition` exposes, so an ordered comparison that `typeNominalOf`
	 * cannot prove totally ordered stays wrapped `!(a < b)` rather than flipping.
	 *
	 * The worth gate is `Operand.notDelta <= 0`: the rewrite drops the one outer `!` and buys
	 * `notDelta` further ones, so it is offered exactly when the unary-`!` count strictly falls.
	 * That admits the PARTIAL compounds (`!(!a || f < 0.5)` → `a && !(f < 0.5)`, one `!` fewer) and
	 * refuses the pure distributions (`!(a || b)` → `!a && !b`, one more) with no separate rule.
	 * For the single-comparison arm it IS the order licence with no extra code: a flip is `notDelta`
	 * 0 and is offered, a `declinedFlip` is `notDelta` +1 and is refused — the wrap it would emit
	 * is byte-for-byte the input. Parentheses are never a cost: the input already carried a pair
	 * around the operand, and the output carries at most one.
	 *
	 * `parent` picks the parenthesisation: `slotPrecedence` answers what the surrounding slot
	 * requires, and `wrap` adds a pair only when the result binds looser than that. A null
	 * `parent` — or a slot that constrains nothing (a condition, an argument, a statement) —
	 * emits the bare form.
	 */
	public function simplifyNegatedCompound(
		not: QueryNode, parent: Null<QueryNode>, source: String, ?typeNominalOf: (QueryNode) -> Null<String>
	): Null<String> {
		final inner: Null<QueryNode> = negatedOperandOf(not);
		if (inner == null) return null;
		final negated: Operand = negate(inner, source, false, typeNominalOf);
		if (negated.notDelta > 0) return null;
		final slot: Null<Precedence> = parent == null ? null : slotPrecedence(parent.kind);
		return slot == null ? negated.src : wrap(negated, slot);
	}

	/**
	 * The operand a `!( … )` node negates — parentheses unwrapped — when it is one of the families
	 * `NEGATABLE_OPERAND_KINDS` lists, or null when `not` is not a logical-not or its operand is
	 * anything else (a call, `is`, `??`, a bitwise operator, another not: `!!x` and `!(!x)` belong
	 * to `double-negation`, not here). Shape only — whether the rewrite pays is
	 * `simplifyNegatedCompound`'s worth gate.
	 */
	public function negatedOperandOf(not: QueryNode): Null<QueryNode> {
		if (not.kind != 'Not' || not.children.length != 1) return null;
		var inner: QueryNode = not.children[0];
		while (inner.kind == 'ParenExpr' && inner.children.length == 1) inner = inner.children[0];
		return NEGATABLE_OPERAND_KINDS.contains(inner.kind) ? inner : null;
	}

	/**
	 * The precedence an expression must bind at to sit UNPARENTHESISED in a `parentKind` child
	 * slot, or null when the slot constrains nothing — a statement, a condition, a call
	 * argument, an array element, an already-parenthesised expression: any expression is
	 * grammatical there.
	 *
	 * A POSITIVE list of the operator kinds, deliberately NOT `precedence` itself: that function
	 * answers `PREC_ATOM` for every kind it does not list, which is the right default for an
	 * OPERAND (an unlisted kind is an atom) and exactly the wrong one for a SLOT (an unlisted
	 * kind imposes nothing, and `PREC_ATOM` would parenthesise every condition and argument).
	 * The assignment family is absent for the same reason as a statement slot — its right-hand
	 * side takes a whole expression.
	 *
	 * Nor is the answer always the parent's OWN precedence. `wrap` parenthesises on
	 * `result.prec < slot`, which admits a result of exactly the slot's rank — sound only where
	 * the parent operator is associative (`&&` / `||`), and wrong for the comparison tier, whose
	 * members share one left-associative rank while meaning nothing like each other. Those slots
	 * therefore answer one tier up; see the case itself.
	 */
	private static function slotPrecedence(parentKind: String): Null<Precedence> {
		return switch parentKind {
			case 'Not', 'Neg':
				PREC_ATOM;
			// The comparison tier is left-associative but NOT associative in meaning, so a result at
			// PREC_CMP may not sit bare in either of its slots: `c == (n >= 0)` de-parenthesised is
			// `(c == n) >= 0`. Demanding the next tier up parenthesises exactly the PREC_CMP results
			// and nothing else — anything binding tighter already sits at PREC_BINARY or above.
			case 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq': PREC_BINARY;
			case 'Or', 'And', 'NullCoal', 'Ternary', 'Is', 'In', 'BitOr', 'BitXor', 'BitAnd', 'Shl', 'Shr', 'UShr', 'Add', 'Sub', 'Mul',
				'Div', 'Mod', 'Interval', 'CastExpr':
				precedence(parentKind);
			case _: null;
		};
	}

	/** `node`'s boolean-literal value, or null when it is not a `true` / `false` literal. */
	private static function boolValue(node: QueryNode, source: String): Null<Bool> {
		if (node.kind != 'BoolLit') return null;
		final s: String = src(node, source);
		return s == 'true' || (s != 'false' && null);
	}

	/** `a && b`, each operand parenthesised iff it binds strictly looser than `&&`. */
	private static function joinAnd(a: Operand, b: Operand): String {
		return '${wrap(a, PREC_AND)} && ${wrap(b, PREC_AND)}';
	}

	/** `a || b`, each operand parenthesised iff it binds strictly looser than `||`. */
	private static function joinOr(a: Operand, b: Operand): String {
		return '${wrap(a, PREC_OR)} || ${wrap(b, PREC_OR)}';
	}

	/** A node carried verbatim: its source plus its precedence. */
	private static function plain(node: QueryNode, source: String): Operand {
		return {
			src: src(node, source),
			prec: precedence(node.kind),
			declined: false,
			notDelta: 0
		};
	}

	/** Parenthesise `o`'s source iff it binds strictly looser than `targetPrec`. */
	private static function wrap(o: Operand, targetPrec: Precedence): String {
		return o.prec < targetPrec ? '(${o.src})' : o.src;
	}

	/**
	 * The logical negation of `node`, pushed inward by De Morgan: `!(a || b)` ->
	 * `!a && !b`, `!(a && b)` -> `!a || !b`, `!(a == b)` -> `a != b`, `!!a` -> `a`.
	 * A non-decomposable operand becomes `!x` (`!(x)` when not atomic).
	 *
	 * `flipOrdered` governs the ordered comparisons `< <= > >=`: `true` flips them
	 * (`!(a < b)` -> `a >= b`) UNCONDITIONALLY — sound over the reals, but not over a NaN or a
	 * `null` operand; it is the behaviour the ternary / guard-chain callers keep, and they pass no
	 * `types`; `false` wraps them `!(a < b)` verbatim UNLESS `types`
	 * proves both operands totally ordered by `<` (`totallyOrdered`) — the wrap is the
	 * only sound negation for an operand that may be a NaN or a `null`, since
	 * `!(a < b)` and `a >= b` differ for both. `==` / `!=` flip either way (a flip is
	 * NaN- and null-equivalent to the wrap for them).
	 */
	private static function negate(node: QueryNode, source: String, flipOrdered: Bool, ?types: (QueryNode) -> Null<String>): Operand {
		switch node.kind {
			case 'Or':
				final l: Operand = negate(node.children[0], source, flipOrdered, types);
				final r: Operand = negate(node.children[1], source, flipOrdered, types);
				return {
					src: '${wrap(l, PREC_AND)} && ${wrap(r, PREC_AND)}',
					prec: PREC_AND,
					declined: l.declined || r.declined,
					notDelta: l.notDelta + r.notDelta
				};
			case 'And':
				final l: Operand = negate(node.children[0], source, flipOrdered, types);
				final r: Operand = negate(node.children[1], source, flipOrdered, types);
				return {
					src: '${wrap(l, PREC_OR)} || ${wrap(r, PREC_OR)}',
					prec: PREC_OR,
					declined: l.declined || r.declined,
					notDelta: l.notDelta + r.notDelta
				};
			case 'Eq':
				return flip(node, source, '!=');
			case 'NotEq':
				return flip(node, source, '==');
			case 'Lt':
				return flipOrdered || totallyOrdered(node, types) ? flip(node, source, '>=') : declinedFlip(node, source);
			case 'LtEq':
				return flipOrdered || totallyOrdered(node, types) ? flip(node, source, '>') : declinedFlip(node, source);
			case 'Gt':
				return flipOrdered || totallyOrdered(node, types) ? flip(node, source, '<=') : declinedFlip(node, source);
			case 'GtEq':
				return flipOrdered || totallyOrdered(node, types) ? flip(node, source, '<') : declinedFlip(node, source);
			case 'Not':
				// !!x -> x : strip the existing negation, unwrapping one redundant paren
				// (`!(a && b)` -> `a && b`); wrap() re-adds parens where precedence demands.
				var inner: QueryNode = node.children[0];
				if (inner.kind == 'ParenExpr' && inner.children.length == 1) inner = inner.children[0];
				return {
					src: src(inner, source),
					prec: precedence(inner.kind),
					declined: false,
					notDelta: -1
				};
			case 'BoolLit':
				return {
					src: boolValue(node, source) == false ? 'true' : 'false',
					prec: PREC_ATOM,
					declined: false,
					notDelta: 0
				};
			case 'ParenExpr':
				// Drop the parens, negate the inner; wrap() re-adds parens where needed.
				return node.children.length == 1 ? negate(node.children[0], source, flipOrdered, types) : wrapNot(node, source);
			case _:
				return wrapNot(node, source);
		}
	}

	/** Negate an opaque operand: `!x` for an atom, `!(x)` otherwise. */
	private static function wrapNot(node: QueryNode, source: String): Operand {
		final s: String = src(node, source);
		return {
			src: precedence(node.kind) >= PREC_ATOM ? '!$s' : '!($s)',
			prec: PREC_NOT,
			declined: false,
			notDelta: 1
		};
	}

	/**
	 * The wrap an ordered comparison falls back to when its flip is not licensed — identical
	 * source to `wrapNot`, but marked `declined` so a caller inverting for readability can tell
	 * this apart from an operand the engine simply cannot decompose (`a is B`, `a ?? b`), whose
	 * wrap IS its canonical negation.
	 */
	private static function declinedFlip(node: QueryNode, source: String): Operand {
		final wrapped: Operand = wrapNot(node, source);
		return {
			src: wrapped.src,
			prec: wrapped.prec,
			declined: true,
			notDelta: wrapped.notDelta
		};
	}

	/** A comparison `a <op> b` rewritten with `newOp`, its boolean negation. */
	private static function flip(node: QueryNode, source: String, newOp: String): Operand {
		return node.children.length == 2 ? {
			src: '${src(node.children[0], source)} $newOp ${src(node.children[1], source)}',
			prec: PREC_CMP,
			declined: false,
			notDelta: 0
		} : wrapNot(node, source);
	}

	/**
	 * Whether an ordered comparison's operands are BOTH provably drawn from a value set `<`
	 * orders TOTALLY, so flipping its operator preserves meaning. The proof is a nominal from
	 * `TOTAL_ORDER_TYPES` (or a literal kind), never an ad-hoc "has no NaN and no null" test —
	 * see that list for why the weaker test is not sufficient. One unresolved operand is enough
	 * to refuse: unproven means keep the wrap.
	 */
	private static function totallyOrdered(node: QueryNode, types: Null<(QueryNode) -> Null<String>>): Bool {
		if (node.children.length != 2) return false;
		return totallyOrderedOperand(node.children[0], types) && totallyOrderedOperand(node.children[1], types);
	}

	/**
	 * Whether one comparison operand provably holds neither a NaN nor a `null`: a literal of a
	 * totally-ordered kind, or a value whose declared type `types` resolves to a nominal in
	 * `TOTAL_ORDER_TYPES`. Parentheses and a unary minus are transparent — `-(x)` is a `Float`
	 * exactly when `x` is, and cannot introduce a `null` that `x` did not already carry (the only
	 * direction the licence relies on).
	 */
	private static function totallyOrderedOperand(node: QueryNode, types: Null<(QueryNode) -> Null<String>>): Bool {
		var n: QueryNode = node;
		while ((n.kind == 'ParenExpr' || n.kind == 'Neg') && n.children.length == 1) n = n.children[0];
		if (TOTAL_ORDER_LITERAL_KINDS.contains(n.kind)) return true;
		if (types == null) return false;
		final nominal: Null<String> = types(n);
		return nominal != null && TOTAL_ORDER_TYPES.contains(nominal);
	}

	/** Operator-precedence rank of a node kind — higher binds tighter. */
	private static function precedence(kind: String): Precedence {
		return switch kind {
			case 'Or': PREC_OR;
			case 'And': PREC_AND;
			case 'NullCoal': PREC_COALESCE;
			case 'Ternary': PREC_TERNARY;
			case 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq': PREC_CMP;
			case 'Is', 'In', 'BitOr', 'BitXor', 'BitAnd', 'Shl', 'Shr', 'UShr', 'Add', 'Sub', 'Mul', 'Div', 'Mod', 'Interval', 'CastExpr':
				PREC_BINARY;
			case 'Assign', 'AddAssign', 'SubAssign', 'MulAssign', 'DivAssign', 'ModAssign', 'ShlAssign', 'ShrAssign', 'UShrAssign',
				'BitOrAssign', 'BitAndAssign', 'BitXorAssign', 'NullCoalAssign', 'BoolAndAssign', 'BoolOrAssign':
				PREC_ASSIGN;
			case _: PREC_ATOM;
		};
	}

	/** Verbatim source of `node` (empty when unspanned — the re-parse gate then rejects the fix). */
	private static inline function src(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : StringTools.trim(source.substring(span.from, span.to));
	}

	/**
	 * Whether `node` is a provably non-null `Bool`: a boolean-operator result
	 * (`&&` / `||` / `!` / a comparison), parentheses unwrapped. Such a node can
	 * never be `Null<Bool>`, so joining it with `&&` / `||` is sound under strict
	 * null-safety. A boolean literal, a bare identifier, a field access or a call is
	 * not provable without types and is left alone.
	 */
	private static function provablyBool(node: QueryNode): Bool {
		var n: QueryNode = node;
		while (n.kind == 'ParenExpr' && n.children.length == 1) n = n.children[0];
		return BOOL_OP_KINDS.contains(n.kind);
	}

}

private typedef Operand = {
	var src: String;
	var prec: Precedence;

	/**
	 * Whether this operand — or anything folded into it — is a rewrite the engine KNOWS how to
	 * perform but declined (an ordered comparison whose flip is not licensed, see `declinedFlip`).
	 * Read by `negateConditionDeclinesFlip`, so a caller inverting a condition only to make it
	 * read better can refuse the site. A wrap the engine could never avoid does not set it.
	 */
	var declined: Bool;

	/**
	 * How many unary `!` operators this operand's emitted form ADDS relative to the verbatim
	 * source it replaces: `+1` for every `!(…)` wrap the negation had to introduce, `-1` for
	 * every existing `!` it stripped, `0` for a flip (`==` ↔ `!=`, an ordered comparison) and
	 * for anything carried verbatim. Nested `!` inside a verbatim operand are NOT counted —
	 * they survive the rewrite unchanged and cancel on both sides.
	 *
	 * Read by `simplifyNegatedCompound` as its WORTH gate: rewriting `!(cond)` into
	 * `negate(cond)` trades the one outer `!` for `notDelta` further ones, so it pays exactly
	 * when `notDelta <= 0`. A cost model, not a second inverter — the emitted text always
	 * comes from `negate` itself, and the counter rides along with it so the two can never
	 * disagree about which branch was taken.
	 */
	var notDelta: Int;
};

/**
 * Operator-precedence rank — a higher value binds tighter. A distinct type rather
 * than a bare `Int` so a precedence can never be confused with an unrelated count;
 * the two `@:op` forwards give it the `<` / `>=` ordering that `wrap` / `wrapNot`
 * need (Haxe otherwise forbids ordered comparison on an abstract).
 */
private enum abstract Precedence(Int) {
	final PREC_ATOM = 100;
	final PREC_NOT = 90;
	// Any binary / type-check operator (is, in, bitwise, shift, arithmetic, ...) — binds
	// looser than unary `!`, so `negate` must wrap it `!(...)`, yet tighter than `&&` / `||`,
	// so a join needs no extra parens. Kinds not listed in `precedence` default to PREC_ATOM;
	// omitting one here would let `wrapNot` emit a bare `!` that captures only its left operand.
	final PREC_BINARY = 60;
	final PREC_CMP = 50;
	final PREC_AND = 40;
	final PREC_OR = 30;
	final PREC_COALESCE = 20;
	final PREC_TERNARY = 10;
	final PREC_ASSIGN = 5;

	@:op(A < B) static function lt(a: Precedence, b: Precedence): Bool;

	@:op(A >= B) static function gte(a: Precedence, b: Precedence): Bool;
}
