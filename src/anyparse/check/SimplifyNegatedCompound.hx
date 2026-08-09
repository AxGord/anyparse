package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a logical-not that simplifies to a form carrying strictly fewer `!` operators.
 * `Severity.Info` with an autofix. Two shapes reach the rule:
 *
 *  - a boolean COMPOUND — `!(!a || b)` → `a && !b`, `!(a == b && !c)` → `a != b || c` — which
 *    De Morgan distributes;
 *  - a SINGLE comparison — `!(x < 0)` → `x >= 0`, `!(a == b)` → `a != b` — whose operator
 *    simply flips.
 *
 * The shape is not only hand-written: it is what the guard family's inverter EMITS when its
 * order gate cannot prove an ordered comparison free of NaN and `null` — it then wraps the
 * whole condition `!( … )` rather than flipping `<` to `>=`. Once the gate learns the type
 * (see `RefactorSupport.expressionTypeNominal`), the leftover wraps are exactly this rule's
 * input, so the two compose across `--fix` passes.
 *
 * ## The worth gate — a strict reduction, not a distribution
 *
 * De Morgan applied blindly makes code WORSE: `!(a || b)` → `!a && !b` trades one negation
 * for two. The rewrite is offered only when the unary-`!` count strictly falls, which
 * `BooleanLogicSupport.simplifyNegatedCompound` decides by counting inside the negation
 * engine itself (`Operand.notDelta`) rather than by a second, drift-prone model here. ONE gate
 * serves both arms, producing every wanted case and refusing every unwanted one:
 *
 *  - `!(!a || b)` → `a && !b` — one `!` fewer, offered;
 *  - `!(a == b && c != d)` → `a != b || c == d` — the outer `!` is gone, offered;
 *  - `!(a || b)` → `!a && !b` — one `!` more, refused;
 *  - `!(!a || f < 0.5)` with `f:Float` → `a && !(f < 0.5)` — a PARTIAL simplification (the
 *    order gate keeps the comparison wrapped) that still sheds one `!`, so it is offered.
 *
 * For the single-comparison arm that same gate is EXACTLY the order licence. An ordered
 * comparison the type resolver cannot prove totally ordered declines the flip, and that costs
 * `+1` `!` — the only text it could emit is the input verbatim — so the site is refused:
 * `!(f < 0.5)` with `f:Float` — and `!(s < t)` with `s:String`, which Haxe can never prove
 * non-null — stays put, while `!(n < 0)` with `n:Int` becomes `n >= 0`. `!(a ==
 * b)` → `a != b` needs no type proof at all: IEEE makes `NaN == x` false and `NaN != x` true,
 * and a `null` operand answers the same both ways, so the flip and the wrap agree for every
 * operand — neither breaker reaches equality. There is no partial form on this arm — with
 * one term there is nothing left to keep wrapped.
 *
 * `!(!x)` is `double-negation`'s node and never this rule's: the seam's operand whitelist
 * excludes the not-kind, even though its `notDelta` of `-1` would pass the worth gate.
 *
 * Parentheses never enter the count: the input already carries a pair around the operand,
 * and the output carries at most one — the seam re-adds it only where the surrounding slot
 * needs it. A comparison slot needs one around a FLIPPED comparison — `c == !(x < 0)` emits
 * `c == (x >= 0)`, since that tier is a single left-associative rank and the bare form would
 * re-associate — and elsewhere the pair appears exactly where the surrounding
 * operator binds tighter than the result.
 *
 * ## Short-circuit and single evaluation
 *
 * De Morgan preserves both. `!(A || B)` evaluates A, then B only if A was false; `!A && !B`
 * evaluates A, then B only if `!A` was true — the same condition. Each term keeps its
 * position and is evaluated at most once, so a call operand's count and order are unchanged.
 * Haxe's null narrowing survives the same way (`!(x == null || f(x))` → `x != null && f(x)`
 * narrows `x` for `f` exactly as the `||` chain did), except in one shape the shared
 * `CheckScan.narrowingStranded` gate rejects: a chain whose third-or-later operand depends on
 * a narrowing introduced by a non-first operand, which the compiler does not carry across the
 * flipped connective.
 *
 * ## Gates
 *
 * A comment anywhere in the negated span refuses the site — the engine rebuilds the operator
 * glue and would drop it. A `#if` region inside refuses too: the branches project as flat
 * siblings, so a rebuilt chain would splice both arms together. A macro-reification subtree
 * (`RefShape.opaqueKinds`) is never entered. Only the OUTERMOST candidate of a nest is
 * flagged; a `!( … )` inside it becomes reachable on the next `--fix` pass, so two edits can
 * never overlap. The single-comparison arm inherits every one of them unchanged — including
 * `narrowingStranded`, which answers false for a lone comparison and so cannot reject it.
 *
 * ## Grammar-agnostic
 *
 * The shape test itself is `BooleanLogicSupport.negatedOperandOf`, and every rewrite decision
 * — negation, precedence, parenthesisation, the worth count — lives behind the same seam, so
 * a grammar without it makes the check a no-op. `RefShape` is read only for the opaque kinds
 * and for the and / or kinds that word the finding and drive the shared narrowing gate. `!!x`
 * and `!(!x)` are NOT this rule's shape: a single-term double negation belongs to
 * `double-negation`, which reads through parentheses for exactly that reason.
 */
@:nullSafety(Strict)
final class SimplifyNegatedCompound implements Check {

	public function new() {}

	public function id(): String {
		return 'simplify-negated-compound';
	}

	public function description(): String {
		return 'a negated boolean compound or comparison that simplifies to fewer negations';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			// The type resolver walks the whole resolution scope, so it is built only for a file
			// that actually holds the shape — most files skip it entirely.
			if (tree == null || !hasShape(tree, s)) continue;
			for (c in candidates(
				tree, null, entry.source, s, CheckScan.typeNominalResolver(entry.source, plugin, tree, entry.file), []
			)) violations.push({
				file: entry.file,
				span: c.span,
				rule: 'simplify-negated-compound',
				severity: Severity.Info,
				message: c.message
			});
		}
		return violations;
	}

	/**
	 * Replace each flagged `!( … )` with the seam's simplified form — De Morgan for a compound,
	 * the flipped operator for a single comparison. The candidate set is
	 * recomputed from `source` under the same gates `run` applied, so a finding whose site no
	 * longer qualifies (an earlier check's edit in the same batch changed it) yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final s: Seams = seams;
		final types: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, violations[0].file, index);
		final bySpan: Map<String, Candidate> = [];
		for (c in candidates(tree, null, source, s, types, [])) bySpan['${c.span.from}:${c.span.to}'] = c;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final c: Null<Candidate> = bySpan['${span.from}:${span.to}'];
			if (c != null) edits.push({ span: c.span, text: c.text });
		}
		return edits;
	}

	/**
	 * Whether any `!( … )` this rule could CONSIDER exists at all — the cheap pre-gate before the
	 * type resolver is built. The single-comparison arm makes it true for more files than the
	 * compound arm alone did, which is inherent: that arm's licence IS the type resolver, so the
	 * resolver has to run before the site can be accepted or refused.
	 */
	private static function hasShape(node: QueryNode, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (s.support.negatedOperandOf(node) != null) return true;
		for (c in node.children) if (hasShape(c, s)) return true;
		return false;
	}

	/**
	 * Every accepted rewrite in `node`'s subtree, outermost-first: a `!( … )` whose operand
	 * passes the comment / `#if` / narrowing gates and whose seam rewrite pays. Descent STOPS at
	 * an accepted node, so a nested candidate is left for the next `--fix` pass and no two edits
	 * can overlap; a REJECTED node is descended into normally, since nothing will consume it.
	 */
	private static function candidates(
		node: QueryNode, parent: Null<QueryNode>, source: String, s: Seams, types: Null<(QueryNode) -> Null<String>>, out: Array<Candidate>
	): Array<Candidate> {
		if (s.opaqueKinds.contains(node.kind)) return out;
		final accepted: Null<Candidate> = candidateAt(node, parent, source, s, types);
		if (accepted != null) {
			out.push(accepted);
			return out;
		}
		for (c in node.children) candidates(c, node, source, s, types, out);
		return out;
	}

	/** The accepted rewrite AT `node`, or null when it is not the shape or any gate refuses it. */
	private static function candidateAt(
		node: QueryNode, parent: Null<QueryNode>, source: String, s: Seams, types: Null<(QueryNode) -> Null<String>>
	): Null<Candidate> {
		final operand: Null<QueryNode> = s.support.negatedOperandOf(node);
		final span: Null<Span> = node.span;
		if (operand == null || span == null) return null;
		// The engine rebuilds the operator glue between operands, so a comment inside the span
		// would be dropped; a `#if` region projects as flat siblings, so a rebuilt chain would
		// splice both arms together. Both refuse rather than emit a lossy rewrite.
		if (CheckScan.hasCommentMarker(source, span.from, span.to) || hasConditionalRegion(node)) return null;
		// Verified no-op for a single comparison: `narrowingStranded` returns false immediately for
		// any kind that is neither the and-kind nor the or-kind. The gate is inherited unchanged by
		// the new arm rather than being N/A by omission.
		if (CheckScan.narrowingStranded(operand, s.negation)) return null;
		final text: Null<String> = s.support.simplifyNegatedCompound(node, parent, source, types);
		return text == null ? null : { span: span, text: text, message: messageFor(operand, s) };
	}

	/** Which arm accepted the site, as the finding's wording — the compound text is pinned by a test. */
	private static function messageFor(operand: QueryNode, s: Seams): String {
		return operand.kind == s.negation.andKind || operand.kind == s.negation.orKind
			? 'this negated compound simplifies by De Morgan'
			: 'this negated comparison simplifies to the flipped operator';
	}

	/** Whether a `#if … #end` region sits anywhere in `node` — block, expression or mid-expression splice alike. */
	private static function hasConditionalRegion(node: QueryNode): Bool {
		if (RefactorSupport.isConditionalKind(node.kind)) return true;
		for (c in node.children) if (hasConditionalRegion(c)) return true;
		return false;
	}

	/**
	 * Bundle the opaque-kind list + the boolean-logic seam. The shape test now lives entirely
	 * behind that seam (`negatedOperandOf`), so a missing `booleanLogicSupport` is the ONLY thing
	 * that makes the check a no-op; the and / or kinds still come from `RefShape`, but only to
	 * word the finding and to run the shared narrowing gate.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		return support == null ? null : {
			opaqueKinds: shape.opaqueKinds ?? [],
			negation: CheckScan.negationSeams(shape),
			support: support
		};
	}

}

/** One accepted rewrite: the `!( … )` node's span, the source replacing it, and the arm that accepted it. */
private typedef Candidate = {
	final span: Span;
	final text: String;
	final message: String;
};

/** The resolved seams `SimplifyNegatedCompound` reads in both `run` and `fix`. */
private typedef Seams = {
	final opaqueKinds: Array<String>;
	final negation: NegationSeams;
	final support: BooleanLogicSupport;
};
