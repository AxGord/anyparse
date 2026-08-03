package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a logical-not over a boolean COMPOUND — `!(!a || b)`, `!(a == b && !c)` — that De
 * Morgan simplifies to a form carrying strictly fewer `!` operators (`a && !b`,
 * `a != b || c`). `Severity.Info` with an autofix.
 *
 * The shape is not only hand-written: it is what the guard family's inverter EMITS when its
 * NaN gate cannot prove an ordered comparison float-free — `negateCondition` then wraps the
 * whole condition `!( … )` rather than flipping `<` to `>=`. Once the gate learns the type
 * (see `RefactorSupport.expressionTypeNominal`), the leftover wraps are exactly this rule's
 * input, so the two compose across `--fix` passes.
 *
 * ## The worth gate — a strict reduction, not a distribution
 *
 * De Morgan applied blindly makes code WORSE: `!(a || b)` → `!a && !b` trades one negation
 * for two. The rewrite is offered only when the unary-`!` count strictly falls, which
 * `BooleanLogicSupport.simplifyNegatedCompound` decides by counting inside the negation
 * engine itself (`Operand.notDelta`) rather than by a second, drift-prone model here. That
 * one gate produces every wanted case and refuses every unwanted one:
 *
 *  - `!(!a || b)` → `a && !b` — one `!` fewer, offered;
 *  - `!(a == b && c != d)` → `a != b || c == d` — the outer `!` is gone, offered;
 *  - `!(a || b)` → `!a && !b` — one `!` more, refused;
 *  - `!(!a || f < 0.5)` with `f:Float` → `a && !(f < 0.5)` — a PARTIAL simplification (the
 *    NaN gate keeps the comparison wrapped) that still sheds one `!`, so it is offered.
 *
 * Parentheses never enter the count: the input already carries a pair around the compound,
 * and the output carries at most one — the seam re-adds it only where the surrounding
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
 * never overlap.
 *
 * ## Grammar-agnostic
 *
 * The not / paren / `&&` / `||` kinds come from `RefShape`, and every rewrite decision —
 * negation, precedence, parenthesisation, the worth count — lives behind
 * `BooleanLogicSupport`. A grammar missing either seam makes the check a no-op. `!!x` and
 * `!(!x)` are NOT this rule's shape: a single-term double negation belongs to
 * `double-negation`, which reads through parentheses for exactly that reason.
 */
@:nullSafety(Strict)
final class SimplifyNegatedCompound implements Check {

	public function new() {}

	public function id(): String {
		return 'simplify-negated-compound';
	}

	public function description(): String {
		return 'a negated boolean compound that De Morgan simplifies to fewer negations';
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
				message: 'this negated compound simplifies by De Morgan'
			});
		}
		return violations;
	}

	/**
	 * Replace each flagged `!( … )` with the seam's De Morgan form. The candidate set is
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

	/** Whether any `!( … )` over a `&&` / `||` compound exists at all — the cheap pre-gate before the type resolver is built. */
	private static function hasShape(node: QueryNode, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (compoundOf(node, s) != null) return true;
		for (c in node.children) if (hasShape(c, s)) return true;
		return false;
	}

	/**
	 * Every accepted rewrite in `node`'s subtree, outermost-first: a `!( … )` whose compound
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
		final compound: Null<QueryNode> = compoundOf(node, s);
		final span: Null<Span> = node.span;
		if (compound == null || span == null) return null;
		// The engine rebuilds the operator glue between operands, so a comment inside the span
		// would be dropped; a `#if` region projects as flat siblings, so a rebuilt chain would
		// splice both arms together. Both refuse rather than emit a lossy rewrite.
		if (CheckScan.hasCommentMarker(source, span.from, span.to) || hasConditionalRegion(node)) return null;
		if (CheckScan.narrowingStranded(compound, s.negation)) return null;
		final text: Null<String> = s.support.simplifyNegatedCompound(node, parent, source, types);
		return text == null ? null : { span: span, text: text };
	}

	/** Whether a `#if … #end` region sits anywhere in `node` — block, expression or mid-expression splice alike. */
	private static function hasConditionalRegion(node: QueryNode): Bool {
		if (RefactorSupport.isConditionalKind(node.kind)) return true;
		for (c in node.children) if (hasConditionalRegion(c)) return true;
		return false;
	}

	/**
	 * The `&&` / `||` compound `node` negates — parentheses unwrapped — or null when `node` is
	 * not a logical-not or its operand is anything else. Structural only: the rewrite itself is
	 * the seam's, this just recognises the shape the seam accepts.
	 */
	private static function compoundOf(node: QueryNode, s: Seams): Null<QueryNode> {
		if (node.kind != s.notKind || node.children.length != 1) return null;
		var inner: QueryNode = node.children[0];
		while (inner.kind == s.parenKind && inner.children.length == 1) inner = inner.children[0];
		return inner.kind == s.andKind || inner.kind == s.orKind ? inner : null;
	}

	/** Bundle the `RefShape` kinds + the boolean-logic seam, or null when the grammar lacks one (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final notKind: Null<String> = shape.notKind;
		final parenKind: Null<String> = shape.parenKind;
		final andKind: Null<String> = shape.logicalAndKind;
		final orKind: Null<String> = shape.logicalOrKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		return notKind == null || parenKind == null || andKind == null || orKind == null || support == null ? null : {
			notKind: notKind,
			parenKind: parenKind,
			andKind: andKind,
			orKind: orKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			negation: CheckScan.negationSeams(shape),
			support: support
		};
	}

}

/** One accepted rewrite: the `!( … )` node's span and the source replacing it. */
private typedef Candidate = {
	final span: Span;
	final text: String;
};

/** The resolved seams `SimplifyNegatedCompound` reads in both `run` and `fix`. */
private typedef Seams = {
	final notKind: String;
	final parenKind: String;
	final andKind: String;
	final orKind: String;
	final opaqueKinds: Array<String>;
	final negation: NegationSeams;
	final support: BooleanLogicSupport;
};
