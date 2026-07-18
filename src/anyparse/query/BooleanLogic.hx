package anyparse.query;

/**
 * A grammar's boolean-expression simplification capability, consumed by the
 * `simplify-boolean-ternary` check — the seam that keeps the check
 * grammar-agnostic (mirrors `ControlFlow.ControlFlowSupport` /
 * `StringFold.StringFoldSupport`). A grammar with no boolean-ternary concept
 * returns null from `GrammarPlugin.booleanLogicSupport` and the check no-ops.
 *
 * The language-specific work — operator negation by De Morgan, operator
 * precedence, and the parenthesisation that keeps the rewrite meaning-preserving
 * — lives behind this seam, so the check itself only locates ternary nodes and
 * replaces their spans with the returned source.
 */
@:nullSafety(Strict)
interface BooleanLogicSupport {

	/**
	 * If `ternary` (a `cond ? then : else`) has a boolean-literal branch, the
	 * equivalent boolean-expression source — `cond ? true : x` -> `cond || x`,
	 * `cond ? false : x` -> `!cond && x` (with the negation pushed inward by De
	 * Morgan so there is no leading `!( … )` over a compound), and the mirror
	 * forms — with precedence-safe parentheses. Null when neither branch is a
	 * boolean literal (nothing to simplify), when both branches are the SAME
	 * literal (collapsing would drop `cond`'s evaluation), or when the node is not
	 * a well-formed ternary. `source` is the file text the node's spans index into.
	 */
	public function simplifyBooleanTernary(ternary: QueryNode, source: String): Null<String>;

	/**
	 * The flat boolean expression equivalent to a boolean guard chain
	 * `if (cond_i) return <bool>; … return <bool>;` (every return a boolean literal),
	 * or null when it cannot be built without dropping a condition's evaluation
	 * (a degenerate chain whose conditions are all absorbed by a literal). `conds[i]`
	 * are the guard condition nodes, `lits[i]` their return's boolean literal node
	 * (parallel to `conds`), `finalLit` the trailing return's literal; `source` indexes
	 * the node spans. Each `cond_i` is an `if` condition — non-null `Bool` under strict
	 * null-safety, since the source compiles — so joining them with `&&` / `||` is
	 * sound; conditions are kept verbatim, preserving any `== true` null-safety idiom.
	 */
	public function reduceBooleanGuardChain(
		conds: Array<QueryNode>, lits: Array<QueryNode>, finalLit: QueryNode, source: String
	): Null<String>;

	/**
	 * The NaN-safe logical negation of condition `cond`, pushed inward by De
	 * Morgan: `!` stripped, `&&` / `||` distributed, `==` / `!=` flipped; an
	 * ordered comparison (`<` `<=` `>` `>=`) is wrapped `!(…)` verbatim, never
	 * flipped — `!(a < b)` and `a >= b` differ under NaN. Operands carry
	 * precedence-safe parentheses. Comments in the operator glue between
	 * operands are dropped, so the caller must gate: `CheckScan.negateConditionText`
	 * falls back to a verbatim wrap when the condition span holds a comment marker.
	 */
	public function negateCondition(cond: QueryNode, source: String): String;

}
