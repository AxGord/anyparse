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
	 * ordered comparison (`<` `<=` `>` `>=`) is wrapped `!(…)` verbatim rather than
	 * flipped — `!(a < b)` and `a >= b` differ under NaN. Operands carry
	 * precedence-safe parentheses. Comments in the operator glue between
	 * operands are dropped, so the caller must gate: `CheckScan.negateConditionText`
	 * falls back to a verbatim wrap when the condition span holds a comment marker.
	 *
	 * `typeNominalOf` lifts that wrap where NaN cannot arise: it answers an operand
	 * node's declared type nominal (null = unknown), and an ordered comparison whose
	 * BOTH operands are provably not floating-point flips like `==` / `!=` does. Omit
	 * it — or return null — and every ordered comparison keeps the verbatim wrap.
	 */
	public function negateCondition(cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): String;

	/**
	 * Whether `negateCondition` had to DECLINE a rewrite it knows how to perform — in the Haxe
	 * engine, an ordered comparison `typeNominalOf` could not prove NaN-free, so it stayed
	 * `!(a < b)` instead of flipping. A caller that inverts a condition purely so a block reads
	 * better asks this FIRST and refuses the site when it answers true: the wrapped negation is
	 * sound, but it reads worse than the positive condition it would replace. A wrap the engine
	 * could never avoid (`!(a is B)`) is NOT a decline — that IS the canonical negation.
	 */
	public function negateConditionDeclinesFlip(cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): Bool;

	/**
	 * The De Morgan simplification of `not` — a logical-not over a `&&` / `||` COMPOUND — as
	 * source replacing the whole not node, or null when `not` is not that shape or the rewrite
	 * would not PAY: the same NaN-safe engine as `negateCondition` produces the text, and the
	 * result is offered only when it carries strictly fewer unary `!` operators than the input
	 * (`!(!a || b)` → `a && !b` pays; `!(a || b)` → `!a && !b` does not, and answers null).
	 * A term the NaN gate refuses to flip stays wrapped inside the result, so a PARTIAL
	 * simplification is still offered whenever the count still falls.
	 *
	 * `parent` is the not node's parent — the slot the replacement lands in — so the result can
	 * be parenthesised exactly when the surrounding operator binds tighter than it (`x && !(a
	 * && b)` → `x && (a != … || …)`); pass null for a slot that accepts any expression.
	 * `typeNominalOf` is the same operand-type probe `negateCondition` takes.
	 */
	public function simplifyNegatedCompound(
		not: QueryNode, parent: Null<QueryNode>, source: String, ?typeNominalOf: (QueryNode) -> Null<String>
	): Null<String>;

}
