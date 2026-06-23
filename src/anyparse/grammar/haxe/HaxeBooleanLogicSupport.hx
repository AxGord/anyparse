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
 * `cond ? X : X` with the same literal both sides is left alone: collapsing it
 * would drop `cond`, discarding any side effect of evaluating it.
 */
@:nullSafety(Strict)
final class HaxeBooleanLogicSupport implements BooleanLogicSupport {

	private static inline final PREC_ATOM: Int = 100;
	private static inline final PREC_NOT: Int = 90;
	private static inline final PREC_CMP: Int = 50;
	private static inline final PREC_AND: Int = 40;
	private static inline final PREC_OR: Int = 30;
	private static inline final PREC_COALESCE: Int = 20;
	private static inline final PREC_TERNARY: Int = 10;
	private static inline final PREC_ASSIGN: Int = 5;

	private static final BOOL_OP_KINDS: Array<String> = ['Or', 'And', 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq', 'Not'];

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
			return thenBool && !elseBool ? plain(cond, source).src : !thenBool && elseBool ? negate(cond, source).src : null;
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
				? thenBool ? joinOr(plain(cond, source), plain(elseNode, source)) : joinAnd(negate(cond, source), plain(elseNode, source))
				: elseBool == true
					? joinOr(negate(cond, source), plain(thenNode, source))
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
		var accPrec: Int = PREC_ATOM;
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
					accSrc = joinOr(plain(cond, source), { src: accSrc, prec: accPrec });
					accPrec = PREC_OR;
				}
			} else {
				if (accLit == false) return null; // !cond && false -> false : drops cond's evaluation
				final n: Operand = negate(cond, source);
				if (accLit == true) { // !cond && true -> !cond
					accSrc = n.src;
					accPrec = n.prec;
				} else {
					accSrc = joinAnd(n, { src: accSrc, prec: accPrec });
					accPrec = PREC_AND;
				}
			}
			accLit = null;
			i--;
		}
		return accSrc;
	}

	/** `node`'s boolean-literal value, or null when it is not a `true` / `false` literal. */
	private static function boolValue(node: QueryNode, source: String): Null<Bool> {
		if (node.kind != 'BoolLit') return null;
		final s: String = src(node, source);
		return s == 'true' || (s != 'false' && null);
	}

	/** `a && b`, each operand parenthesised iff it binds strictly looser than `&&`. */
	private static function joinAnd(a: Operand, b: Operand): String {
		return wrap(a, PREC_AND) + ' && ' + wrap(b, PREC_AND);
	}

	/** `a || b`, each operand parenthesised iff it binds strictly looser than `||`. */
	private static function joinOr(a: Operand, b: Operand): String {
		return wrap(a, PREC_OR) + ' || ' + wrap(b, PREC_OR);
	}

	/** A node carried verbatim: its source plus its precedence. */
	private static function plain(node: QueryNode, source: String): Operand {
		return { src: src(node, source), prec: precedence(node.kind) };
	}

	/** Parenthesise `o`'s source iff it binds strictly looser than `targetPrec`. */
	private static function wrap(o: Operand, targetPrec: Int): String {
		return o.prec < targetPrec ? '(' + o.src + ')' : o.src;
	}

	/**
	 * The logical negation of `node`, pushed inward by De Morgan: `!(a || b)` ->
	 * `!a && !b`, `!(a && b)` -> `!a || !b`, `!(a == b)` -> `a != b`, `!!a` -> `a`.
	 * A non-decomposable operand becomes `!x` (`!(x)` when not atomic).
	 */
	private static function negate(node: QueryNode, source: String): Operand {
		switch node.kind {
			case 'Or':
				final l: Operand = negate(node.children[0], source);
				final r: Operand = negate(node.children[1], source);
				return { src: wrap(l, PREC_AND) + ' && ' + wrap(r, PREC_AND), prec: PREC_AND };
			case 'And':
				final l: Operand = negate(node.children[0], source);
				final r: Operand = negate(node.children[1], source);
				return { src: wrap(l, PREC_OR) + ' || ' + wrap(r, PREC_OR), prec: PREC_OR };
			case 'Eq':
				return flip(node, source, '!=');
			case 'NotEq':
				return flip(node, source, '==');
			case 'Lt':
				return flip(node, source, '>=');
			case 'LtEq':
				return flip(node, source, '>');
			case 'Gt':
				return flip(node, source, '<=');
			case 'GtEq':
				return flip(node, source, '<');
			case 'Not':
				// !!x -> x : strip the existing negation.
				final inner: QueryNode = node.children[0];
				return { src: src(inner, source), prec: precedence(inner.kind) };
			case 'BoolLit':
				return { src: boolValue(node, source) == false ? 'true' : 'false', prec: PREC_ATOM };
			case 'ParenExpr':
				// Drop the parens, negate the inner; wrap() re-adds parens where needed.
				return node.children.length == 1 ? negate(node.children[0], source) : wrapNot(node, source);
			case _:
				return wrapNot(node, source);
		}
	}

	/** Negate an opaque operand: `!x` for an atom, `!(x)` otherwise. */
	private static function wrapNot(node: QueryNode, source: String): Operand {
		final s: String = src(node, source);
		return { src: precedence(node.kind) >= PREC_ATOM ? '!' + s : '!(' + s + ')', prec: PREC_NOT };
	}

	/** A comparison `a <op> b` rewritten with `newOp`, its boolean negation. */
	private static function flip(node: QueryNode, source: String, newOp: String): Operand {
		return node.children.length == 2
			? {
				src: src(node.children[0], source) + ' ' + newOp + ' ' + src(node.children[1], source),
				prec: PREC_CMP
			}
			: wrapNot(node, source);
	}

	/** Operator-precedence rank of a node kind — higher binds tighter. */
	private static function precedence(kind: String): Int {
		return switch kind {
			case 'Or': PREC_OR;
			case 'And': PREC_AND;
			case 'NullCoal': PREC_COALESCE;
			case 'Ternary': PREC_TERNARY;
			case 'Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq': PREC_CMP;
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
	var prec: Int;
};
