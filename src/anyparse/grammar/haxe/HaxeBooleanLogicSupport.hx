package anyparse.grammar.haxe;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Haxe `BooleanLogicSupport`: reduces a ternary with a boolean-literal branch to
 * an equivalent boolean expression. The four mixed forms collapse via
 * short-circuit `&&` / `||` (`cond ? true : x` -> `cond || x`, `cond ? false : x`
 * -> `!cond && x`, `cond ? x : true` -> `!cond || x`, `cond ? x : false` ->
 * `cond && x`), and the two pure-literal forms collapse to `cond` / `!cond`.
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

	static inline final PREC_ATOM: Int = 100;
	static inline final PREC_NOT: Int = 90;
	static inline final PREC_CMP: Int = 50;
	static inline final PREC_AND: Int = 40;
	static inline final PREC_OR: Int = 30;
	static inline final PREC_COALESCE: Int = 20;
	static inline final PREC_TERNARY: Int = 10;
	static inline final PREC_ASSIGN: Int = 5;

	public function new() {}

	public function simplifyBooleanTernary(ternary: QueryNode, source: String): Null<String> {
		if (ternary.kind != 'Ternary' || ternary.children.length != 3) return null;
		final cond: QueryNode = ternary.children[0];
		final thenNode: QueryNode = ternary.children[1];
		final elseNode: QueryNode = ternary.children[2];
		final thenBool: Null<Bool> = boolValue(thenNode, source);
		final elseBool: Null<Bool> = boolValue(elseNode, source);
		if (thenBool == null && elseBool == null) return null;

		if (thenBool != null && elseBool != null) {
			// cond ? true : false -> cond ; cond ? false : true -> !cond.
			// Same literal both sides drops cond's evaluation — left alone.
			if (thenBool && !elseBool) return plain(cond, source).src;
			if (!thenBool && elseBool) return negate(cond, source).src;
			return null;
		}

		if (thenBool != null) {
			// cond ? true : x -> cond || x   ;   cond ? false : x -> !cond && x
			return thenBool ? joinOr(plain(cond, source), plain(elseNode, source)) : joinAnd(negate(cond, source), plain(elseNode, source));
		}
		// cond ? x : true -> !cond || x   ;   cond ? x : false -> cond && x  (elseBool is non-null here)
		return elseBool == true
			? joinOr(negate(cond, source), plain(thenNode, source))
			: joinAnd(plain(cond, source), plain(thenNode, source));
	}

	/** `node`'s boolean-literal value, or null when it is not a `true` / `false` literal. */
	private static function boolValue(node: QueryNode, source: String): Null<Bool> {
		if (node.kind != 'BoolLit') return null;
		final s: String = src(node, source);
		return s == 'true' ? true : (s == 'false' ? false : null);
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

}

private typedef Operand = {
	var src: String;
	var prec: Int;
};
