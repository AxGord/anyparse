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
	 *
	 * `typeNominalOf` is the same operand-type probe `negateCondition` takes, and it
	 * governs the same one thing: whether negating the condition may FLIP an ordered
	 * comparison (`!(a < b)` -> `a >= b`) or must keep it wrapped. Omit it — or return
	 * null — and every ordered comparison in the condition keeps the verbatim wrap,
	 * which is the sound form for an operand that may be a NaN or a `null`. It never
	 * changes WHETHER a ternary reduces, only the text of the reduction, so a caller
	 * that only needs the yes/no answer (a check's `run` pass) can skip building it.
	 */
	public function simplifyBooleanTernary(ternary: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): Null<String>;

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
	 *
	 * `typeNominalOf` is the same operand-type probe `negateCondition` takes: it licenses
	 * the ordered-comparison FLIP (`!(a < b)` -> `a >= b`) inside a negated condition, and
	 * without it every ordered comparison keeps the sound verbatim wrap. Like
	 * `simplifyBooleanTernary`'s, it never changes WHETHER the chain reduces — only the
	 * text — so a caller that only needs the yes/no answer can skip building it.
	 */
	public function reduceBooleanGuardChain(
		conds: Array<QueryNode>, lits: Array<QueryNode>, finalLit: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>
	): Null<String>;

	/**
	 * The order-safe logical negation of condition `cond`, pushed inward by De
	 * Morgan: `!` stripped, `&&` / `||` distributed, `==` / `!=` flipped; an
	 * ordered comparison (`<` `<=` `>` `>=`) is wrapped `!(…)` verbatim rather than
	 * flipped — `!(a < b)` and `a >= b` differ whenever an operand is a NaN or a
	 * `null`. Operands carry precedence-safe parentheses. Comments in the operator
	 * glue between operands are dropped, so the caller must gate:
	 * `CheckScan.negateConditionText` falls back to a verbatim wrap when the
	 * condition span holds a comment marker.
	 *
	 * `typeNominalOf` lifts that wrap where the comparison is provably total: it answers
	 * an operand node's declared type nominal (null = unknown), and an ordered
	 * comparison whose BOTH operands are provably drawn from a value set the
	 * comparison orders TOTALLY flips like `==` / `!=` does. Which nominals qualify is
	 * the grammar engine's call — for Haxe it is `Int` / `UInt`, and notably NOT
	 * `String`, since Haxe has no non-nullable string type. Omit the probe — or return null —
	 * and every ordered comparison keeps the verbatim wrap.
	 *
	 * `slotKind` names the node kind of the operator slot the negation is about to land in, so
	 * the result carries a parenthesis pair exactly when it binds LOOSER than that slot — the
	 * kind-addressed twin of `simplifyNegatedCompound`'s `parent`, for a caller whose slot is
	 * SYNTHETIC and therefore has no node (`loop-guard` merging a lifted guard into a header
	 * `if` emits `c && INV`, and a De Morgan `||` result must not re-associate there). Null —
	 * or a slot kind that constrains nothing — emits the bare form, which is what every caller
	 * dropping the negation into a whole condition slot wants.
	 *
	 * The contract on `slotKind` is therefore the caller's to keep: it must be a kind the GRAMMAR
	 * names for that operator (read off its own `RefShape`, never a literal). An unrecognised kind
	 * is indistinguishable from null here and yields the bare form — the UNSAFE direction, and one
	 * the fix pipeline's re-parse gate cannot catch, since a re-associated condition still parses.
	 * A caller that cannot supply the kind must therefore refuse the site, not pass null.
	 */
	public function negateCondition(
		cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>, ?slotKind: String
	): String;

	/**
	 * Whether `negateCondition` had to DECLINE a rewrite it knows how to perform — in the Haxe
	 * engine, an ordered comparison `typeNominalOf` could not prove totally ordered (free of both
	 * NaN and `null`), so it stayed `!(a < b)` instead of flipping. A caller that inverts a
	 * condition purely so a block reads better asks this FIRST and refuses the site when it answers
	 * true: the wrapped negation is sound, but it reads worse than the positive condition it would
	 * replace. A wrap the engine could never avoid (`!(a is B)`) is NOT a decline — that IS the
	 * canonical negation.
	 */
	public function negateConditionDeclinesFlip(cond: QueryNode, source: String, ?typeNominalOf: (QueryNode) -> Null<String>): Bool;

	/**
	 * The operand a logical-not negates — parentheses unwrapped — whenever `simplifyNegatedCompound`
	 * would consider `not` at all; null when `not` is not a logical-not, or wraps a shape this
	 * simplification never touches.
	 *
	 * This is THE single shape test for the rule. The consuming check asks this instead of
	 * re-deriving the kind set from `RefShape`, so the two can never disagree about the rule's
	 * input — before this seam the predicate existed as two copies, one in the check over
	 * `RefShape` kinds and one private in the Haxe engine, that had to be widened in lockstep.
	 *
	 * A non-null answer does NOT promise a rewrite: the worth gate inside `simplifyNegatedCompound`
	 * still decides, and refuses whatever would not pay. The NODE is returned rather than a `Bool`
	 * so the caller can run its own operand-level gates on it (`CheckScan.narrowingStranded`).
	 */
	public function negatedOperandOf(not: QueryNode): Null<QueryNode>;

	/**
	 * The simplification of `not` — a logical-not over one of the two shapes `negatedOperandOf`
	 * accepts — as source replacing the whole not node, or null when `not` is neither shape or the
	 * rewrite would not PAY. Both arms are produced by the same order-safe engine as
	 * `negateCondition`:
	 *
	 *  - a `&&` / `||` COMPOUND, which De Morgan distributes (`!(!a || b)` → `a && !b`);
	 *  - a SINGLE comparison, whose operator simply flips (`!(x < 0)` → `x >= 0` when the order gate
	 *    licenses it, `!(a == b)` → `a != b` always).
	 *
	 * ONE worth gate serves both: the result is offered only when it carries strictly fewer unary
	 * `!` operators than the input (`!(a || b)` → `!a && !b` does not, and answers null). Inside a
	 * compound, a term the order gate refuses to flip stays wrapped, so a PARTIAL simplification is
	 * still offered whenever the count still falls. For the single-comparison arm that same gate IS
	 * the order licence: a flip is `notDelta` 0 (offered — the outer `!` is shed), a declined flip is
	 * `notDelta` +1 (refused — the wrap IS the input).
	 *
	 * The method NAME keeps "Compound" because the rule id it serves, `simplify-negated-compound`,
	 * is user- and config-visible; the mismatch with the widened contract is deliberate.
	 *
	 * `parent` is the not node's parent — the slot the replacement lands in — so the result can be
	 * parenthesised exactly when the slot needs it (`x && !(a && b)` → `x && (a != … || …)`); pass
	 * null for a slot that accepts any expression. A slot whose own operator is non-associative
	 * needs the pair even when the result binds at the SAME rank — `c == !(x < 0)` must emit
	 * `c == (x >= 0)`, since bare `c == x >= 0` re-associates to `(c == x) >= 0`.
	 * `typeNominalOf` is the same operand-type probe `negateCondition` takes.
	 */
	public function simplifyNegatedCompound(
		not: QueryNode, parent: Null<QueryNode>, source: String, ?typeNominalOf: (QueryNode) -> Null<String>
	): Null<String>;

}
