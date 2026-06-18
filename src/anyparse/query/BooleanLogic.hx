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

}
