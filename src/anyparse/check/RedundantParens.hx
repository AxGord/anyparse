package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags redundant parentheses in two shapes. A parenthesized expression wrapped
 * directly in another (`((e))`) — the outer pair adds nothing wherever it sits. And a
 * LONE `(e)` sitting in a DELIMITED position: one where the surrounding construct
 * supplies its own boundaries on both sides, so no operator can bind across the
 * parens. `Info` severity (a cosmetic cleanup); `fix` unwraps the chain to a single
 * pair (`((e))` / `(((e)))` → `(e)`) outside a delimited position and to nothing
 * inside it (`final m = (-1);` → `final m = -1;`, `((e))` → `e`).
 *
 * In a delimited position the content's PRECEDENCE is irrelevant — `f((a + b))`
 * unwraps as safely as `f((x))` — but its SYNTAX is not: two content shapes keep
 * their parens even there, and both are declared by the grammar. See
 * `separatorGreedyExprKinds` and `spliceSensitiveExprKinds` below.
 *
 * ## Grammar-agnostic
 *
 * The parenthesized-expression kind comes from `RefShape.parenKind` (unset → no-op).
 * The delimited positions come from two NEW optional lists —
 * `RefShape.delimitedAllChildKinds` (every child of the host: var / final
 * initializer, `return` value, array-literal element, object-literal field value,
 * `new T(args)` argument) and `delimitedTailChildKinds` (every child but the head:
 * call ARGUMENT, not the callee; assignment RIGHT-hand side, not the target) — plus
 * the PRE-EXISTING condition seams `conditionFirstChildKinds` /
 * `conditionLastChildKinds` (`if` / `while` / `do … while`, whose own `(` `)` are
 * grammar syntax rather than a node).
 *
 * Those last two state a grammar FACT — "this kind's condition is child 0" — and
 * were introduced for `assignment-in-condition`, so a grammar that already declares
 * them gets the CONDITION arm of this check with no further opt-in. The two new
 * lists are what the other positions need; declaring neither leaves only the
 * conditions and the double-paren arm.
 *
 * Two content shapes keep their parens in any delimited position:
 *
 * - `separatorGreedyExprKinds` — a construct whose own syntax can consume the
 *   separator that ends the slot. In Haxe a `macro`-quoted declaration:
 *   `f((macro final w = 1), x)` unwrapped becomes `f(macro final w = 1, x)`, where
 *   the compiler reads `x` as a second declarator. The hazard is positional, so the
 *   test walks the interior's LAST child while it ends where its parent ends —
 *   reaching through `@:m macro final w = 1`, a ternary or `if`-`else` whose last
 *   branch is one, and a trailing operand, and stopping at a bracket-closed host
 *   (`q(macro final w = 1)`), whose own closing token already bounds it.
 * - `spliceSensitiveExprKinds` — a reification whose ARITY depends on being directly
 *   an argument. In Haxe `$a{args}`: `macro g(($a{args}))` builds a ONE-argument call
 *   and `macro g($a{args})` a two-argument one, with no syntax error either way. The
 *   test reads the paren's direct content and applies only in a splicing host — the
 *   `callKind` / `arrayLiteralKind` / `newExprKind` seams.
 *
 * Both tests read the content that would be left BARE (paren layers unwrapped
 * first), so `((macro final w = 1))` still collapses to one pair rather than none.
 *
 * Deliberately NOT delimited:
 *
 * - The `switch` SUBJECT — excluded by project decision, not by a safety argument.
 *   The Haxe grammar keeps a parenthesized `SwitchStmt` (carrying its own `(` `)`,
 *   like `if` / `while`) apart from a bare `SwitchStmtBare`, so a `parenKind` child
 *   there IS a redundant second pair and unwrapping it would yield `switch (x)`,
 *   never `switch x`. Whether a switch is written with or without its parens is an
 *   idiom the project's own style rules own; this check stays out of it.
 * - A `case` PATTERN, and with it the case GUARD — the guard's mandatory `(` `)`
 *   project as a bare paren node (`case X if (g):`), so treating a `CaseBranch` child
 *   as delimited would strip syntax the language requires.
 * - Every operand position of a unary or binary operator: an operand is parsed above
 *   the loosest precedence, so its interior re-associates outward — `(a + b) * c` ≢
 *   `a + b * c`, and a map-literal key `[(a ? b : c) => d]` ≢ `[a ? b : c => d]`.
 *   That is why a call's CALLEE and an assignment's TARGET are excluded while their
 *   tails are not, and why the map-literal `=>` VALUE is left alone even though its
 *   right-associative prec-0 operator would make it provably safe.
 *
 * The two arms compose without overlapping: the check flags the OUTERMOST paren of a
 * chain and does not descend into it, so a site yields one finding and one edit, and
 * in a delimited position `((e))` collapses to `e` outright.
 */
@:nullSafety(Strict)
final class RedundantParens implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-parens';
	}

	public function description(): String {
		return 'parentheses that cannot affect the parse — ((e)), or a lone (e) in a delimited position';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final slots: Null<ParenSlots> = slotsOf(plugin);
		if (slots == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, slots, SlotKind.Plain);
		}
		return violations;
	}

	/**
	 * Unwrap each flagged paren chain: to nothing in a delimited position, to a
	 * single pair anywhere else.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final slots: Null<ParenSlots> = slotsOf(plugin);
		if (slots == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final siteByKey: Map<String, ParenSite> = [];
		indexParens(tree, slots, SlotKind.Plain, siteByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final site: Null<ParenSite> = siteByKey['${span.from}:${span.to}'];
			if (site == null) continue;
			final inner: Null<Span> = RefactorSupport.unwrapParens(site.node, slots.parenKind).span;
			if (inner == null) continue;
			final text: String = source.substring(inner.from, inner.to);
			if (!site.dropsParens) {
				edits.push({ span: span, text: '($text)' });
				continue;
			}
			// The `(` was the only thing separating the content from a preceding
			// keyword (`return(a);`) — dropping it bare would weld them into one
			// identifier, which still PARSES and so survives the caller's re-parse.
			edits.push({ span: span, text: weldsWithPreviousToken(source, span.from) ? ' $text' : text });
		}
		return edits;
	}

	/** The grammar's paren kind plus its delimited-slot vocabulary, or null when it declares no paren kind. */
	private static function slotsOf(plugin: GrammarPlugin): Null<ParenSlots> {
		final shape: RefShape = plugin.refShape();
		final parenKind: Null<String> = shape.parenKind;
		return parenKind == null ? null : {
			parenKind: parenKind,
			allChild: shape.delimitedAllChildKinds ?? [],
			tailChild: shape.delimitedTailChildKinds ?? [],
			condFirstChild: shape.conditionFirstChildKinds ?? [],
			condLastChild: shape.conditionLastChildKinds ?? [],
			greedy: shape.separatorGreedyExprKinds ?? [],
			splice: shape.spliceSensitiveExprKinds ?? [],
			spliceHost: [for (k in [shape.callKind, shape.arrayLiteralKind, shape.newExprKind]) if (k != null) k]
		};
	}

	/** Whether the character before `from` would merge with the unwrapped content into one token. */
	private static function weldsWithPreviousToken(source: String, from: Int): Bool {
		if (from == 0) return false;
		final c: Int = source.charCodeAt(from - 1) ?? 0;
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Walk `node`; flag a paren that directly wraps another paren, or one whose `slot`
	 * lets the pair drop, and STOP — the inner redundant layers are subsumed by the
	 * single fix, and not descending keeps every edit disjoint. Otherwise descend,
	 * classifying each child's own slot.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, slots: ParenSlots, slot: SlotKind): Void {
		// `children.length == 1` is defensive: a grammar's paren wraps exactly one
		// expression, so no fixture can reach the else side in Haxe (`()` does not
		// parse). It guards a grammar whose paren kind is shaped differently.
		if (
			node.kind == slots.parenKind && node.children.length == 1
			&& (dropsParens(node.children[0], slots, slot) || node.children[0].kind == slots.parenKind)
		) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'redundant-parens',
					severity: Severity.Info,
					message: 'redundant parentheses'
				});
				return;
			}
		}
		for (i => c in node.children) walk(out, file, c, slots, slotOf(node, i, slots));
	}

	/**
	 * Whether the paren chain around `inner` can be dropped ENTIRELY: its slot is
	 * delimited, the content left bare is not separator-greedy, and dropping the parens
	 * would not turn a splice-sensitive reification loose in a splicing host.
	 */
	private static function dropsParens(inner: QueryNode, slots: ParenSlots, slot: SlotKind): Bool {
		if (slot == SlotKind.Plain) return false;
		// The fix drops the WHOLE chain, so both tests read the content that would be
		// left bare, not the next paren layer down.
		final bare: QueryNode = RefactorSupport.unwrapParens(inner, slots.parenKind);
		return (slot != SlotKind.DelimitedSplice || !slots.splice.contains(bare.kind)) && !separatorGreedy(bare, slots);
	}

	/**
	 * Whether a construct that can consume the separator ending this slot sits at the
	 * RIGHT EDGE of `inner`, which makes the parentheses around it load-bearing. The
	 * walk follows the last child while that child ends where its parent ends, so it
	 * reaches through a metadata wrapper / trailing ternary branch / trailing operand
	 * and stops at a bracket-closed host, whose own closing token already bounds the
	 * construct.
	 */
	private static function separatorGreedy(inner: QueryNode, slots: ParenSlots): Bool {
		var n: QueryNode = inner;
		while (!slots.greedy.contains(n.kind)) {
			if (n.children.length == 0) return false;
			final last: QueryNode = n.children[n.children.length - 1];
			if (!endsTogether(n, last)) return false;
			n = last;
		}
		return true;
	}

	/** Whether `child` is the last thing inside `parent` — nothing of `parent`'s own closes after it. */
	private static function endsTogether(parent: QueryNode, child: QueryNode): Bool {
		// A grammar that leaves spans unset cannot be measured; keep descending, which
		// errs towards KEEPING the parentheses.
		final p: Null<Span> = parent.span;
		if (p == null) return true;
		final c: Null<Span> = child.span;
		return c == null || p.to == c.to;
	}

	/** How `parent`'s child at `i` is bounded: not delimited, delimited, or delimited by a SPLICING host. */
	private static function slotOf(parent: QueryNode, i: Int, slots: ParenSlots): SlotKind {
		return !childDelimited(parent, i, slots)
			? SlotKind.Plain
			: slots.spliceHost.contains(parent.kind) ? SlotKind.DelimitedSplice : SlotKind.Delimited;
	}

	/**
	 * Whether `parent`'s child at `i` sits in a slot the surrounding construct delimits
	 * itself.
	 *
	 * The `condLastChild` index test is defensive: Haxe's only such host is
	 * `DoWhileStmt`, whose children are `[body, cond]`, and a body never projects as a
	 * bare paren — so no fixture can reach its false side. It pins the slot for a grammar
	 * whose do-while carries more children.
	 */
	private static function childDelimited(parent: QueryNode, i: Int, slots: ParenSlots): Bool {
		if (slots.allChild.contains(parent.kind)) return true;
		return slots.tailChild.contains(parent.kind)
			? i > 0
			: slots.condFirstChild.contains(parent.kind)
				? i == 0
				: slots.condLastChild.contains(parent.kind) && i == parent.children.length - 1;
	}

	/** Index every paren node by its `from:to` span key, recording whether its own pair can be dropped entirely. */
	private static function indexParens(node: QueryNode, slots: ParenSlots, slot: SlotKind, out: Map<String, ParenSite>): Void {
		// Same defensive `children.length == 1` as `walk` — see the note there.
		if (node.kind == slots.parenKind && node.children.length == 1) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = {
				node: node,
				dropsParens: dropsParens(node.children[0], slots, slot)
			};
		}
		for (i => c in node.children) indexParens(c, slots, slotOf(node, i, slots), out);
	}

}

/**
 * The grammar's parenthesis kind, the four host-kind lists that pin a DELIMITED slot
 * — `allChild` (every child), `tailChild` (every child but the first),
 * `condFirstChild` / `condLastChild` (the bracketed condition of a conditional) — and
 * `greedy`, the interior kinds whose parens stay even in a delimited slot. Resolved
 * once per run so the walk never re-reads the shape.
 */
private typedef ParenSlots = {
	var parenKind: String;
	var allChild: Array<String>;
	var tailChild: Array<String>;
	var condFirstChild: Array<String>;
	var condLastChild: Array<String>;
	var greedy: Array<String>;
	var splice: Array<String>;
	var spliceHost: Array<String>;
}

/**
 * An indexed paren node plus whether its own pair can be dropped entirely (rather
 * than collapsed to one pair) — the `fix` lookup's payload.
 */
private typedef ParenSite = {
	var node: QueryNode;
	var dropsParens: Bool;
}

/**
 * How a child slot is bounded. `Plain` — nothing delimits it, so a paren there may be
 * load-bearing for precedence. `Delimited` — the construct supplies its own boundaries.
 * `DelimitedSplice` — delimited AND the host expands a splicing reification argument
 * (`RefShape.spliceSensitiveExprKinds`), where a paren changes ARITY, not syntax.
 */
private enum abstract SlotKind(Int) {

	final Plain = 0;

	final Delimited = 1;

	final DelimitedSplice = 2;

}
