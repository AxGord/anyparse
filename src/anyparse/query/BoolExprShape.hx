package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

using StringTools;
using Lambda;

/**
 * Whether an expression is a provably non-null `Bool`, and whether a condition NARROWS one.
 * The shared gate under the boolean-simplification family (`comparison-to-boolean`,
 * `prefer-ternary-return`, `simplify-boolean-ternary`, `prefer-if-expression-return`): each of
 * those rewrites replaces a branch with the condition itself, which is sound only when the
 * operand can never be `null` under strict null-safety.
 *
 * Two independent proofs, because neither subsumes the other. `provablyBoolOperand` reads the
 * SHAPE — a comparison or a logical operator can only produce a `Bool`. `declaresNonNullBool`
 * reads the function's written RETURN TYPE, which is the proof an identifier or a call can
 * give and shape analysis cannot. `hasNullNarrowingGuard` is the refusal side: a condition that
 * null-narrows a binding cannot be collapsed away, because the narrowing is what makes the
 * branch type-check.
 */
@:nullSafety(Strict)
final class BoolExprShape {

	/**
	 * Whether the condition subtree `cond` contains a null-narrowing guard: an
	 * identifier compared against null (`x == null` / `x != null`) that is then
	 * REUSED elsewhere in the same condition (`x.f`, `x[i]`, `x()`, `g(x)`, a bare
	 * `x`, …). Haxe narrows such an `x` only inside a condition, so a check that
	 * flattens the condition into a bare boolean `||` chain loses the narrowing and
	 * the result fails to compile under `@:nullSafety(Strict)` —
	 * `simplify-boolean-ternary` must always skip a guarded finding. A ternary
	 * `cond ? a : b` KEEPS the narrowing (it types like if/else), so the ternary
	 * checks consult this only through `refusesNullNarrowingBoolCollapse` (refusing
	 * just the bool-literal collapse that would hand off to the flattening
	 * `simplify-boolean-ternary`). Conservative: a reuse in ANY position counts (it
	 * over-skips a comparison-only reuse like `x != null && x == y`, which is
	 * actually safe to flatten — never a compile break), and a grammar without the
	 * null/equality kinds yields false.
	 */
	public static function hasNullNarrowingGuard(cond: QueryNode, shape: RefShape): Bool {
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return false;
		final identCount: Map<String, Int> = [];
		final checkCount: Map<String, Int> = [];
		tallyGuardIdents(cond, shape.identKind, nullKind, shape.eqKind, shape.notEqKind, identCount, checkCount);
		for (name => total in identCount) {
			// Null-checked (`checks != null`) AND reused beyond its own null-comparison
			// operand(s) (`total > checks`): the reuse relies on the in-condition narrowing.
			final checks: Null<Int> = checkCount[name];
			if (checks != null && total > checks) return true;
		}
		return false;
	}

	/**
	 * Whether collapsing an `if`/branch pair with condition `cond` and branch
	 * values `a` / `b` into a ternary must be REFUSED: `cond` carries a
	 * null-narrowing guard (`hasNullNarrowingGuard`) AND a branch value is a bool
	 * literal (`boolLitKind`; an unset kind never refuses). A VALUE ternary keeps
	 * the in-condition narrowing (`cond ? a : b` types exactly like if/else), so a
	 * guarded condition alone is fine — but a bool-literal pair hands off to
	 * `simplify-boolean-ternary`, whose boolean flattening loses the narrowing
	 * (and whose own guard then strands a stuck ternary uglier than the original).
	 * The shared gate of `prefer-ternary-return` / `prefer-ternary-assignment`.
	 */
	public static function refusesNullNarrowingBoolCollapse(a: QueryNode, b: QueryNode, cond: QueryNode, shape: RefShape): Bool {
		final boolLitKind: Null<String> = shape.boolLitKind;
		return boolLitKind != null && (a.kind == boolLitKind || b.kind == boolLitKind) && hasNullNarrowingGuard(cond, shape);
	}

	/**
	 * Whether `operand` (parentheses unwrapped) is a provably non-null `Bool` — a node
	 * whose kind is in `boolOpKinds` (a comparison / `&&` / `||` / `!` result). Such a
	 * node can never be `Null<Bool>`, so combining it with boolean logic is sound under
	 * strict null-safety; an identifier, call, field access or literal is not provable
	 * without types. Shared by `comparison-to-boolean` and `prefer-ternary-return`.
	 */
	public static function provablyBoolOperand(operand: QueryNode, boolOpKinds: Array<String>, parenKind: Null<String>): Bool {
		return boolOpKinds.contains(unwrapParens(operand, parenKind).kind);
	}

	/**
	 * Whether `returnTypeSource` — the verbatim source of a function's EXPLICIT return type,
	 * as `TypeResolver.functionReturnTypeSource` returns it — is the non-nullable boolean
	 * nominal (`RefShape.nonNullBoolTypeName`). The SECOND proof that a `return`ed expression
	 * is a non-null `Bool`, and the one `provablyBoolOperand` structurally cannot give: it
	 * reads the node's KIND, and a `Call` / field access / identifier has no kind that says
	 * `Bool`. This one reads the CONTRACT the enclosing function states instead.
	 *
	 * ★ What it actually proves, because the obvious reading is wrong. Haxe does NOT reject
	 * `function f():Bool return someNullBool;` — `Null<Bool>` unifies with `Bool` silently on
	 * every target (measured: `--interp` -> `null`, `js` -> `undefined`, `--jvm` -> `false`,
	 * all exit 0). So a declared `:Bool` is not, by itself, a runtime non-null guarantee.
	 *
	 * It does not need to be. The hazard the boolean-collapse gates guard is COMPILE
	 * ACCEPTANCE under `@:nullSafety(Strict)`, not meaning: `cond ? false : <tail>` and
	 * `!cond && <tail>` are observationally identical for a null `<tail>` too (18/18 cells on
	 * `--interp` / `js` / `--jvm`, both guard polarities). And under Strict a `:Bool` function
	 * CANNOT host a `return <nullable>;` ("Null safety: Cannot return nullable value of
	 * Null<Bool> as Bool") — so if the pre-rewrite source compiles, the tail is a non-null
	 * `Bool` and the post-rewrite source compiles too. Both readings of the world are covered,
	 * which is why the trimmed WHOLE-type match is the right strictness: `Null<Bool>` refuses.
	 */
	public static function declaresNonNullBool(returnTypeSource: Null<String>, shape: RefShape): Bool {
		final boolName: Null<String> = shape.nonNullBoolTypeName;
		return boolName != null && returnTypeSource != null && returnTypeSource.trim() == boolName;
	}

	/**
	 * Whether `operand` is a ternary MID-REDUCTION — one with exactly one boolean-literal
	 * branch, i.e. exactly what `simplify-boolean-ternary` is about to flatten into `&&` /
	 * `||`. Collapsing an outer pair onto such a tail strands it: the inner ternary stops
	 * being the function's DIRECT returned value, loses its licence for good, and the result
	 * is a hybrid uglier than either endpoint —
	 *
	 *     return isSimpleOperand(node)
	 *         || (!CONST_OP_KINDS.contains(node.kind) ? false : node.children.foreach(…));
	 *
	 * measured on `anyparse/check/PreferInline.hx` and `anyparse/check/TrivialGetter.hx`
	 * during the first apply-and-compile run of this slice. Refusing for ONE `--fix` pass
	 * fixes it: the inner ternary flattens first, becomes a provably-`Bool` `&&` / `||`, and
	 * the outer pair then collapses through the ORIGINAL kind-only proof. Purely structural —
	 * it never asks whether the sibling rule will in fact reduce, so a tail that can never
	 * reduce simply keeps its guard, which is the right answer for it too.
	 */
	public static function pendingBooleanTernaryTail(operand: QueryNode, shape: RefShape): Bool {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (ternaryKind == null || boolLitKind == null) return false;
		final n: QueryNode = unwrapParens(operand, shape.parenKind);
		return
			n.kind == ternaryKind && n.children.length == 3 && (n.children[1].kind == boolLitKind) != (n.children[2].kind == boolLitKind);
	}

	/**
	 * Whether `operand` is a tail the declared-return-type proof must NOT license, even inside a
	 * function declaring the non-null boolean nominal. `statementLikeValue` plus one more kind:
	 * the `null` LITERAL. `!cond && null` is behaviour-preserving (the null propagates through
	 * `&&` exactly as it did through the guard's fall-through) but degenerate, and under
	 * `@:nullSafety(Strict)` a `return null;` in a `:Bool` function does not compile, so the site
	 * can only exist where nothing is checking. Emitting `&& null` there trades a readable guard
	 * for an expression that reads like a bug. Parentheses are unwrapped first.
	 */
	public static function statementLikeOrNullTail(operand: QueryNode, shape: RefShape): Bool {
		return unwrapParens(operand, shape.parenKind).kind == shape.nullLiteralKind || statementLikeValue(operand, shape);
	}

	/**
	 * Whether `operand` is a STATEMENT-LIKE expression: an `if` used as a value, a `switch`, a
	 * `try`, a `throw`, a block. Parentheses unwrapped. The shared half of
	 * `statementLikeOrNullTail`, and a gate in its own right on `prefer-ternary-return`'s VALUE
	 * arm: `cond ? <a four-line if-expression chain> : x` is not more readable than the two
	 * statements it replaced, which is the same judgement the boolean arm already makes. Measured
	 * on anyparse's own `PurityScan.isPure`, whose collapse produced a three-level nest around an
	 * `if` / `else if` / `else` value.
	 */
	public static function statementLikeValue(operand: QueryNode, shape: RefShape): Bool {
		final kind: String = unwrapParens(operand, shape.parenKind).kind;
		return kind == shape.blockStmtKind || [
			shape.ifExpressionKinds,
			shape.tryExpressionKinds,
			shape.switchKinds,
			shape.throwKinds
		].exists(kinds -> kinds != null && kinds.contains(kind));
	}

	/**
	 * `node` with every enclosing parenthesis layer peeled off — `((e))` yields `e`.
	 * The grammar-agnostic paren seam: an UNSET `parenKind` (the grammar declares no
	 * parenthesized-expression kind) returns `node` unchanged, so a caller degrades to
	 * its un-unwrapped behaviour rather than guessing a kind. A paren node that does not
	 * hold exactly one child stops the walk — only a plain single-child wrap is
	 * semantically transparent.
	 */
	public static function unwrapParens(node: QueryNode, parenKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/** Increment the integer counter for `key`. */
	private static inline function bumpCount(map: Map<String, Int>, key: String): Void {
		final cur: Null<Int> = map[key];
		map[key] = (cur ?? 0) + 1;
	}

	/** Tally, over `node`, every IdentExpr occurrence and every null-comparison ident operand. */
	private static function tallyGuardIdents(
		node: QueryNode, identKind: String, nullKind: String, eqKind: Null<String>, notEqKind: Null<String>, identCount: Map<String, Int>,
		checkCount: Map<String, Int>
	): Void {
		if (node.kind == identKind) {
			final name: Null<String> = node.name;
			if (name != null) bumpCount(identCount, name);
		}
		if ((eqKind != null && node.kind == eqKind) || (notEqKind != null && node.kind == notEqKind)) {
			final ident: Null<String> = nullComparedIdent(node, identKind, nullKind);
			if (ident != null) bumpCount(checkCount, ident);
		}
		for (c in node.children) tallyGuardIdents(c, identKind, nullKind, eqKind, notEqKind, identCount, checkCount);
	}

	/** The identifier compared against null in `node` (one operand an ident, the other null), or null. */
	private static function nullComparedIdent(node: QueryNode, identKind: String, nullKind: String): Null<String> {
		if (node.children.length != 2) return null;
		final a: QueryNode = node.children[0];
		final b: QueryNode = node.children[1];
		return if (a.kind == identKind && b.kind == nullKind)
			a.name
		else if (b.kind == identKind && a.kind == nullKind)
			b.name
		else
			null;
	}

}
