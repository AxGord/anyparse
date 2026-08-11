package anyparse.check;

import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * The condition-NEGATION helpers the inverting checks share — `guard-continue`,
 * `guard-return`, `loop-guard` and `simplify-negated-compound` all need to turn a
 * condition's source text into its complement, and all need the same answer to
 * "is inverting this one worth flagging at all".
 *
 * Split out of `CheckScan`, on the same contract: PURE static helpers over the
 * `(node, source, seams)` a check already holds, no shared mutable state and no cache,
 * so `run` and `fix` may each parse independently.
 */
@:nullSafety(Strict)
final class NegationScan {

	/**
	 * The source text of a negation of `cond`, comment-preserving — the shared
	 * condition-inverting engine of `loop-guard`, `guard-continue` and `guard-return`.
	 *
	 * When a grammar `support` is passed AND the condition span holds no comment marker, the negation is
	 * delegated to `BooleanLogicSupport.negateCondition`: De Morgan pushed inward
	 * (`a && b` → `!a || !b`) order-safely — ordered comparisons stay wrapped `!(a < b)` unless
	 * `typeNominalOf` proves both operands totally ordered, and a `||` chain that would strand a
	 * null-safety narrowing right-nests a parenthesised group instead (the engine's own guarantee). The comment scan is
	 * STRING-LITERAL-BLIND: a `//` or `/*` inside a string operand conservatively forces the
	 * fallback (a verbatim `!(cond)` wrap — correct output, just not De-Morganed). With no `support`
	 * or a comment in the condition span, the text engine below is used, in three shapes, in
	 * order:
	 *
	 *  - a leading logical-not is STRIPPED (`!e` → `e`), unwrapping one redundant paren
	 *    (`!(a && b)` → `a && b`, `!!x` → `!x`) — the inner source verbatim;
	 *  - an `==` / `!=` is FLIPPED (`a == b` → `a != b` and back), NaN-safe (IEEE
	 *    `NaN == x` is false and `NaN != x` true) — UNLESS a comment sits in the operator
	 *    gap, which the flip would drop, so it falls through to the verbatim wrap;
	 *  - everything else (ordered comparisons `< <= > >=`, `&& || ?? ?:`, a call, …) is
	 *    wrapped `!(<cond>)` VERBATIM — the only sound negation for `<` / `>=` (they DIFFER
	 *    from their flips when an operand is a NaN or a `null`) and comment-preserving for every
	 *    shape. A bare atomic (`atomicKinds`) drops the parens (`!cond`); the wrap is always fully
	 *    parenthesised, so a low-precedence body (`a ?? b`, `c ? t : e`) negates correctly.
	 *
	 * For every standard type and normal abstract this is exactly `!(cond)`. The flip and
	 * strip assume standard boolean algebra, so they are UNSOUND only for the pathological
	 * case of a Haxe abstract that overloads `==` / `!=` non-complementarily or `!`
	 * non-involutively (`@:op`) — where `a != b` need not be `!(a == b)`; the
	 * always-parenthesised wrap is the sound form there. This edge is shared with `loop-guard`.
	 */
	public static function negateConditionText(
		cond: QueryNode, source: String, seams: NegationSeams, ?support: BooleanLogicSupport, ?typeNominalOf: (QueryNode) -> Null<String>,
		?slotKind: String
	): String {
		final cs: Null<Span> = cond.span;
		if (cs == null) return '';
		if (support != null && !CheckScan.hasCommentMarker(source, cs.from, cs.to))
			return support.negateCondition(cond, source, typeNominalOf, slotKind);
		final inner: Null<QueryNode> = notUnwrapNode(cond, seams);
		if (inner != null) {
			final innerSpan: Null<Span> = inner.span;
			// The STRIP arm is the ONE fallback shape that can bind looser than the slot it lands in
			// (`!(a || b)` hands back `a || b` verbatim); the flip and the wrap below both bind tighter
			// than `&&`. The `&&` slot is also the only one `RefShape` describes — via the same
			// `andLowerPrecedenceKinds` list `collapsible-if` merges with, which must stay in step with
			// the seam engine's own `slotPrecedence` answering this question for the De Morgan tier.
			if (innerSpan != null) {
				final text: String = source.substring(innerSpan.from, innerSpan.to);
				final loose: Bool = slotKind != null && slotKind == seams.andKind && seams.andLowerPrecedenceKinds.contains(inner.kind);
				return loose ? '($text)' : text;
			}
		}
		final flipped: Null<String> = eqFlipText(cond, source, seams);
		if (flipped != null) return flipped;
		final src: String = source.substring(cs.from, cs.to);
		return seams.atomicKinds.contains(cond.kind) ? '!$src' : '!($src)';
	}

	/**
	 * Whether inverting `cond` is worth doing at all — true unless the negation engine had to
	 * DECLINE a rewrite it knows how to perform. The three inverting checks gate on this BEFORE
	 * they flag: their purpose is to make a block read better by shedding a nesting level, and an
	 * inversion that has to keep `!(a < b)` wrapped — because the flip could not be proven free of
	 * both NaN and `null` — trades that nesting for a negation the positive form did not need.
	 *
	 * A wrap the engine could never avoid (`!(a is B)`, `!(a ?? b)`) is NOT a decline: that IS
	 * the canonical negation, and such a site still inverts. The text fallback tier (no grammar
	 * `support`, or a comment in the condition) has no flip to decline, so it keeps emitting
	 * exactly what it always did.
	 */
	public static function negationIsClean(
		cond: QueryNode, source: String, ?support: BooleanLogicSupport, ?typeNominalOf: (QueryNode) -> Null<String>
	): Bool {
		final cs: Null<Span> = cond.span;
		// Only the De Morgan tier can decline anything — the text fallback has no flip to refuse,
		// so its verbatim wrap is the shape it always emitted and the site still inverts.
		return cs != null
			&& (support == null || CheckScan.hasCommentMarker(source, cs.from, cs.to)
				|| !support.negateConditionDeclinesFlip(cond, source, typeNominalOf));
	}

	/**
	 * The `NegationSeams` `shape` exposes: the kinds `negateConditionText` strips, unwraps
	 * and flips, the atomic-expression kinds that take a bare `!` rather than `!(…)`, and the
	 * logical kinds that word `simplify-negated-compound`'s finding and drive the STRIP arm's
	 * and-slot paren decision (`andKind` + `andLowerPrecedenceKinds`). Built here rather than at
	 * each call site because the three inverting checks (`guard-return`, `guard-continue`,
	 * `loop-guard`) read exactly the same seams, and a field added to `NegationSeams` must not
	 * have to be threaded through three identical literals.
	 */
	public static function negationSeams(shape: RefShape): NegationSeams {
		return {
			notKind: shape.notKind,
			parenKind: shape.parenKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			atomicKinds: [
				for (k in [
					(shape.identKind: Null<String>),
					shape.callKind,
					shape.fieldAccessKind,
					shape.forceFieldAccessKind,
					shape.nullSafeAccessKind,
					shape.indexAccessKind,
					shape.newExprKind,
					shape.parenKind,
					shape.boolLitKind
				]) if (k != null) k
			],
			andKind: shape.logicalAndKind,
			orKind: shape.logicalOrKind,
			andLowerPrecedenceKinds: shape.andLowerPrecedenceKinds ?? []
		};
	}

	/**
	 * The `!e` -> `e` STRIP arm of `negateConditionText`: unwraps a leading logical-not
	 * (and one redundant paren under it), returning the inner NODE — the caller reads its
	 * source and asks `slotWrap` whether the slot it lands in needs a parenthesis pair.
	 * Null when `cond` is not a not-node.
	 */
	private static function notUnwrapNode(cond: QueryNode, seams: NegationSeams): Null<QueryNode> {
		final notKind: Null<String> = seams.notKind;
		if (notKind == null || cond.kind != notKind || cond.children.length < 1) return null;
		final inner: QueryNode = cond.children[0];
		final parenKind: Null<String> = seams.parenKind;
		return parenKind != null && inner.kind == parenKind && inner.children.length == 1 ? inner.children[0] : inner;
	}

	/**
	 * The `==` / `!=` FLIP arm of `negateConditionText`: rewrites a binary (in)equality
	 * to its complement operator (NaN-safe; see the caller's doc for the non-complementary
	 * `@:op` abstract caveat shared with `loop-guard`). Null when `cond` is not a binary
	 * (in)equality or a comment sits in the operator gap (the flip would drop it).
	 */
	private static function eqFlipText(cond: QueryNode, source: String, seams: NegationSeams): Null<String> {
		final eqKind: Null<String> = seams.eqKind;
		final notEqKind: Null<String> = seams.notEqKind;
		if (eqKind == null || notEqKind == null) return null;
		if ((cond.kind != eqKind && cond.kind != notEqKind) || cond.children.length != 2) return null;
		final l: Null<Span> = cond.children[0].span;
		final r: Null<Span> = cond.children[1].span;
		if (l == null || (r == null || CheckScan.hasCommentMarker(source, l.to, r.from))) return null;
		final op: String = cond.kind == eqKind ? ' != ' : ' == ';
		return source.substring(l.from, l.to) + op + source.substring(r.from, r.to);
	}

}
