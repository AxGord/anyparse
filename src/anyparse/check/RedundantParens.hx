package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags redundant parentheses in three shapes. A parenthesized expression wrapped
 * directly in another (`((e))`) — the outer pair adds nothing wherever it sits. And a
 * LONE `(e)` sitting in a DELIMITED position: one where the surrounding construct
 * supplies its own boundaries on both sides, so no operator can bind across the
 * parens. `Info` severity (a cosmetic cleanup); `fix` unwraps the chain to a single
 * pair (`((e))` / `(((e)))` → `(e)`) outside a delimited position and to nothing
 * inside it (`final m = (-1);` → `final m = -1;`, `((e))` → `e`).
 *
 * The third shape is PRECEDENCE-GATED: a lone `(e)` wrapping the CONDITION of a
 * ternary (`(a < b) ? 1 : -1` → `a < b ? 1 : -1`). That position is an operand, not a
 * delimited slot, so the drop is proven per-content — it fires only when the bare
 * inner binds strictly tighter than `?:` (`RefShape.ternaryConditionUnwrapKinds`),
 * never for a loose / right-greedy inner (assignment, a nested ternary, an arrow, an
 * `untyped` / `macro` / metadata wrapper) that would absorb the `? … : …` on unwrap.
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
 *   right-associative prec-0 operator would make it provably safe. The lone exception
 *   is a ternary CONDITION, which the precedence-gated third shape above handles.
 *
 * The three arms compose without overlapping: the check flags the OUTERMOST paren of a
 * chain and does not descend into it, so a site yields one finding and one edit, and
 * in a delimited position `((e))` collapses to `e` outright.
 *
 * ## The two OPERAND arms (opt-in, off by default)
 *
 * Both reach the operand positions the arms above refuse, and both replace a
 * precedence MODEL with a per-site proof. Each is a separate `apqlint.json` option on
 * this rule, default false, so a project that declares neither sees byte-identical
 * behaviour:
 *
 * - `"atoms"` — the pair wraps an ATOM: a SELF-DELIMITING expression
 *   (`RefShape.atomExprKinds` — an identifier, `this`, a literal) or a chain of
 *   TRANSPARENT LINKS bottoming out in one (`RefShape.atomChainKinds` — a call-free
 *   dotted access). Nothing outside can bind into an atom, so the pair is inert in
 *   EVERY position — `(a) + c`, `-(a)`, `arr[(i)]`, `(g)(1)`, `c ? (a) : (b)`. This is
 *   the arm that reaches the common defensive divisor, `(x - y) / (r.width)`.
 * - `"sameOperatorLeft"` — the pair is the LEFT operand of a binary operator and its
 *   content is a binary operator in the SAME left-associative precedence family
 *   (`RefShape.leftAssociativeBinaryFamilies`). Left-associativity already groups that
 *   way, so `(a * b) / c` re-parses to the tree it already had. The RIGHT operand is
 *   never a candidate (`a / (b * c)` is a different computation), families never mix
 *   (`(a + b) * c` stays), and Haxe's `%` is in no family at all — the language binds
 *   it tighter than `*` and `/` while this parser does not, so its own tree cannot
 *   prove the re-association either way.
 *
 * Readability parens on a MIXED-operator expression are a human choice, so
 * `sameOperatorLeft` is restricted to the same-family left operand and nothing else —
 * and it declines even that when the RIGHT operand carries a pair of its own
 * (`Math.abs((px - x) + (py - y - h))`). Both pairs are one symmetry the author wrote,
 * only the left is ever removable, and firing there leaves the expression lopsided:
 * worse to read than either keeping or dropping both. Measured on a 798-file corpus,
 * that veto is what separates the clean drops from the disfiguring ones.
 *
 * Both arms are additionally suppressed inside `RefShape.parenOpaqueSubtreeKinds` (a
 * `macro` quotation, where a pair reifies as data; a case pattern, matched
 * structurally) and at a direct child of `RefShape.parenRequiredHostKinds` (a `case`
 * guard, a `switch` subject, metadata).
 *
 * ## Trivia
 *
 * Every arm refuses a pair whose parentheses do not sit flush against their content:
 * the fix reproduces the content's source and drops everything else, so a comment
 * between `(` and the expression would be deleted. The test walks each layer of the
 * chain, since the intermediate `(` `)` of `((e))` are not trivia.
 */
@:nullSafety(Strict)
final class RedundantParens implements Check implements ConfigAware {

	/** The rule id — also the `apqlint.json` key its two opt-in options hang off. */
	private static final ID: String = 'redundant-parens';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return ID;
	}

	public function description(): String {
		return
			'parentheses that cannot affect the parse — ((e)), a lone (e) in a delimited position, or (opt-in) one around an inert operand';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if (shape.parenKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final slots: ParenSlots = slotsOf(shape, entry.file);
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, slots, SlotKind.Plain, false);
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
		if (violations.length == 0) return [];
		final shape: RefShape = plugin.refShape();
		if (shape.parenKind == null) return [];
		final slots: ParenSlots = slotsOf(shape, violations[0].file);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final siteByKey: Map<String, ParenSite> = [];
		indexParens(tree, slots, SlotKind.Plain, false, siteByKey);

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
			// A parenthesis can be the ONLY thing separating its content from a
			// neighbouring word token — `return(a);` before it, `(s)is String` after —
			// and dropping it bare would weld the two into one identifier, which still
			// PARSES and so survives the caller's re-parse. Re-separate either side.
			final lead: String = isWordCharAt(source, span.from - 1) ? ' ' : '';
			final trail: String = isWordCharAt(source, span.to) ? ' ' : '';
			edits.push({ span: span, text: '$lead$text$trail' });
		}
		return edits;
	}

	/**
	 * The grammar's paren kind plus its delimited-slot vocabulary and this project's
	 * operand-arm opt-ins. `shape.parenKind` must be non-null — the caller bails on a
	 * grammar that declares none, once per run rather than once per file.
	 *
	 * EVERY vocabulary the operand arms read is emptied when neither arm is on, the
	 * suppression lists (`requiredHost` / `opaqueSubtree`) included: those two answer
	 * only for the operand arms, and leaving them populated would let a future grammar
	 * that lists a host BOTH as required and as delimited change the shipped arms'
	 * answer with nothing opted in.
	 */
	private function slotsOf(shape: RefShape, file: String): ParenSlots {
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
		final atomArm: Bool = config.boolOption(ID, 'atoms') == true;
		final familyArm: Bool = config.boolOption(ID, 'sameOperatorLeft') == true;
		final operandArm: Bool = atomArm || familyArm;
		return {
			parenKind: shape.parenKind ?? '',
			ternaryKind: shape.ternaryKind,
			ternaryUnwrap: shape.ternaryConditionUnwrapKinds ?? [],
			allChild: shape.delimitedAllChildKinds ?? [],
			tailChild: shape.delimitedTailChildKinds ?? [],
			condFirstChild: shape.conditionFirstChildKinds ?? [],
			condLastChild: shape.conditionLastChildKinds ?? [],
			greedy: shape.separatorGreedyExprKinds ?? [],
			splice: shape.spliceSensitiveExprKinds ?? [],
			spliceHost: [for (k in [shape.callKind, shape.arrayLiteralKind, shape.newExprKind]) if (k != null) k],
			atoms: armVocabulary(shape.atomExprKinds, atomArm),
			atomChains: armVocabulary(shape.atomChainKinds, atomArm),
			families: armVocabulary(shape.leftAssociativeBinaryFamilies, familyArm),
			requiredHost: armVocabulary(shape.parenRequiredHostKinds, operandArm),
			opaqueSubtree: armVocabulary(shape.parenOpaqueSubtreeKinds, operandArm)
		};
	}

	/** A grammar vocabulary an arm reads, or an EMPTY list when the arm is off or the grammar declares none. */
	private static function armVocabulary<T>(declared: Null<Array<T>>, on: Bool): Array<T> {
		return on ? declared ?? [] : [];
	}

	/**
	 * Whether `source` holds an identifier / number character at `at` — a neighbour the
	 * unwrapped content could lex into one token with, once the parenthesis between them
	 * is gone. Out of range answers false: nothing there to weld with.
	 */
	private static function isWordCharAt(source: String, at: Int): Bool {
		if (at < 0 || at >= source.length) return false;
		final c: Int = source.charCodeAt(at) ?? 0;
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Walk `node`; flag a paren that directly wraps another paren, or one whose `slot`
	 * lets the pair drop, and STOP — the inner redundant layers are subsumed by the
	 * single fix, and not descending keeps every edit disjoint. Otherwise descend,
	 * classifying each child's own slot and carrying whether the walk is inside a
	 * subtree where a paren is not merely grouping.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool
	): Void {
		// `children.length == 1` is defensive: a grammar's paren wraps exactly one
		// expression, so no fixture can reach the else side in Haxe (`()` does not
		// parse). It guards a grammar whose paren kind is shaped differently.
		if (
			node.kind == slots.parenKind && node.children.length == 1
			&& (dropsParens(node.children[0], slots, slot, opaque) || node.children[0].kind == slots.parenKind)
			&& !triviaInsideParens(source, node, slots)
		) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: ID,
					severity: Severity.Info,
					message: 'redundant parentheses'
				});
				return;
			}
		}
		final inner: Bool = opaque || slots.opaqueSubtree.contains(node.kind);
		for (i => c in node.children) walk(out, file, source, c, slots, slotOf(node, i, slots), inner);
	}

	/**
	 * Whether the paren chain around `inner` can be dropped ENTIRELY: its slot is
	 * delimited, the content left bare is not separator-greedy, and dropping the parens
	 * would not turn a splice-sensitive reification loose in a splicing host — or, under
	 * the opt-in operand arms, the content is provably inert wherever it sits.
	 */
	private static function dropsParens(inner: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool): Bool {
		// The fix drops the WHOLE chain, so every test reads the content that would be
		// left bare, not the next paren layer down.
		final bare: QueryNode = RefactorSupport.unwrapParens(inner, slots.parenKind);
		if (slot == SlotKind.Required) return false;
		// The operand arms answer per CONTENT, so they apply in any slot the shipped arms
		// leave alone — but never inside a subtree where a paren carries meaning.
		if (!opaque && (isAtom(bare, slots) || slot == SlotKind.SameFamilyLeft)) return true;
		if (slot == SlotKind.Plain || slot == SlotKind.SameFamilyLeft) return false;
		// A ternary condition drops its parens only when the bare content binds strictly
		// tighter than `?:` — otherwise unwrapping lets it absorb the `? … : …` branches.
		if (slot == SlotKind.TernaryCondition) return slots.ternaryUnwrap.contains(bare.kind);
		return (slot != SlotKind.DelimitedSplice || !slots.splice.contains(bare.kind)) && !separatorGreedy(bare, slots);
	}

	/**
	 * Whether nothing outside `node` can bind into it: either it is SELF-DELIMITING
	 * (`atoms` — an identifier or a literal, whose children are internal structure
	 * sealed inside its own delimiters) or a TRANSPARENT LINK whose every child is
	 * itself an atom (`atomChains` — what makes `a.b.c` one atom and `f().b` none).
	 * Empty vocabularies — the default, and any grammar that declares none — answer
	 * uniformly false.
	 */
	private static function isAtom(node: QueryNode, slots: ParenSlots): Bool {
		if (slots.atoms.contains(node.kind)) return true;
		if (!slots.atomChains.contains(node.kind)) return false;
		for (c in node.children) if (!isAtom(c, slots)) return false;
		return true;
	}

	/**
	 * Whether anything but whitespace sits between a parenthesis and the expression it
	 * wraps, at ANY layer of the chain — a comment the fix would delete, since it
	 * reproduces the content's source and nothing else. Walked layer by layer because
	 * the intermediate `(` `)` of `((e))` are the chain, not trivia. An unmeasurable
	 * span answers true, which keeps the parentheses.
	 */
	private static function triviaInsideParens(source: String, node: QueryNode, slots: ParenSlots): Bool {
		var n: QueryNode = node;
		while (n.kind == slots.parenKind && n.children.length == 1) {
			final outer: Null<Span> = n.span;
			final child: QueryNode = n.children[0];
			final inner: Null<Span> = child.span;
			if (outer == null || inner == null) return true;
			if (!isBlank(source, outer.from + 1, inner.from) || !isBlank(source, inner.to, outer.to - 1)) return true;
			n = child;
		}
		return false;
	}

	/** Whether `[from, to)` of `source` is empty or whitespace only. */
	private static function isBlank(source: String, from: Int, to: Int): Bool {
		return StringTools.trim(source.substring(from, to)) == '';
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

	/** How `parent`'s child at `i` is bounded — see `SlotKind`. */
	private static function slotOf(parent: QueryNode, i: Int, slots: ParenSlots): SlotKind {
		if (slots.requiredHost.contains(parent.kind)) return SlotKind.Required;
		if (parent.kind == slots.ternaryKind && i == 0) return SlotKind.TernaryCondition;
		// `i == 0` is defensive, in the manner of the `children.length == 1` guards
		// below: the symmetry veto in `sameFamilyLeftOperand` already refuses a
		// parenthesized child 1, and a child that is not a paren never reaches
		// `dropsParens`. It pins the slot as the LEFT operand's for a reader.
		if (i == 0 && sameFamilyLeftOperand(parent, slots)) return SlotKind.SameFamilyLeft;
		return !childDelimited(parent, i, slots)
			? SlotKind.Plain
			: slots.spliceHost.contains(parent.kind) ? SlotKind.DelimitedSplice : SlotKind.Delimited;
	}

	/**
	 * Whether `parent` is a member of a left-associative precedence family and its FIRST
	 * child is a parenthesized member of the SAME family — the shape left-associativity
	 * already groups, so the pair re-parses away. Only child 0 is asked; the right
	 * operand of the same operators is a different computation.
	 *
	 * A parenthesized RIGHT operand vetoes it. Both pairs together are a SYMMETRY the
	 * author wrote deliberately (`Math.abs((px - x) + (py - y - h))`), and only the left
	 * one is ever removable — so firing would leave the expression lopsided, which reads
	 * worse than either keeping or dropping both. Measured on a 798-file corpus: the
	 * veto is what separates the clean drops from the disfiguring ones.
	 */
	private static function sameFamilyLeftOperand(parent: QueryNode, slots: ParenSlots): Bool {
		if (parent.children.length != 2 || parent.children[0].kind != slots.parenKind) return false;
		if (parent.children[1].kind == slots.parenKind) return false;
		final bare: String = RefactorSupport.unwrapParens(parent.children[0], slots.parenKind).kind;
		for (family in slots.families) if (family.contains(parent.kind) && family.contains(bare)) return true;
		return false;
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
	private static function indexParens(
		node: QueryNode, slots: ParenSlots, slot: SlotKind, opaque: Bool, out: Map<String, ParenSite>
	): Void {
		// Same defensive `children.length == 1` as `walk` — see the note there.
		if (node.kind == slots.parenKind && node.children.length == 1) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = {
				node: node,
				dropsParens: dropsParens(node.children[0], slots, slot, opaque)
			};
		}
		final inner: Bool = opaque || slots.opaqueSubtree.contains(node.kind);
		for (i => c in node.children) indexParens(c, slots, slotOf(node, i, slots), inner, out);
	}

}

/**
 * The grammar's parenthesis kind, the four host-kind lists that pin a DELIMITED slot
 * — `allChild` (every child), `tailChild` (every child but the first),
 * `condFirstChild` / `condLastChild` (the bracketed condition of a conditional) — and
 * `greedy`, the interior kinds whose parens stay even in a delimited slot.
 *
 * `atoms` (self-delimiting kinds), `atomChains` (transparent links, atomic only when
 * every child is) and `families` carry the two OPERAND arms, with `requiredHost` /
 * `opaqueSubtree` bounding them. Each holds the grammar's vocabulary when this project
 * opted the owning arm in and an EMPTY array otherwise, so a default run answers every
 * operand question uniformly false with no second flag to read. Resolved once per file
 * so the walk never re-reads the shape or the config.
 */
private typedef ParenSlots = {
	var parenKind: String;
	var ternaryKind: Null<String>;
	var ternaryUnwrap: Array<String>;
	var allChild: Array<String>;
	var tailChild: Array<String>;
	var condFirstChild: Array<String>;
	var condLastChild: Array<String>;
	var greedy: Array<String>;
	var splice: Array<String>;
	var spliceHost: Array<String>;
	var atoms: Array<String>;
	var atomChains: Array<String>;
	var families: Array<Array<String>>;
	var requiredHost: Array<String>;
	var opaqueSubtree: Array<String>;
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
 * `TernaryCondition` — a ternary's condition child, a precedence-gated slot where the
 * paren drops only when the bare inner binds strictly tighter than `?:`
 * (`RefShape.ternaryConditionUnwrapKinds`). `SameFamilyLeft` — the LEFT operand of a
 * binary operator whose parenthesized content is another member of the same
 * left-associative precedence family, which the opt-in `sameOperatorLeft` arm drops.
 * `Required` — a direct child of a `RefShape.parenRequiredHostKinds` host, where the
 * pair is grammar syntax or an idiom this check declines to own.
 */
private enum abstract SlotKind(Int) {

	final Plain = 0;

	final Delimited = 1;

	final DelimitedSplice = 2;

	final TernaryCondition = 3;

	final SameFamilyLeft = 4;

	final Required = 5;

}
