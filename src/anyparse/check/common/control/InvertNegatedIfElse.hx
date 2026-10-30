package anyparse.check.common.control;

import anyparse.check.Check.ConfigAware;
import anyparse.check.common.control.NegatedCondition.InversionSeams;
import anyparse.check.common.control.NegatedCondition.InversionSite;
import anyparse.check.common.control.NegatedCondition.Swap;
import anyparse.check.scan.RegionTerminator;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberKinds;
import anyparse.query.ParenGuard;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;

/**
 * Flags a negated two-branch conditional — an `if` STATEMENT with an `else`, a value-position `if` or a ternary — whose condition's
 * TOP-LEVEL node is a logical NOT, and inverts it: drop the `!`, SWAP the branches (`if (c) B else A`, `if (c) b else a`, `c ? b :
 * a`). A pure branch swap is an EXACT complement of the negation, semantics-safe under every value including `NaN` (unlike a De Morgan
 * rewrite). `Severity.Info`; `fix` moves each branch's source slot verbatim, so braces / layout / comments travel with their branch.
 *
 * ## What is flagged
 *
 * Only a literal top-level BUILT-IN `!`, read through `NegatedCondition` — the one owner of that question here and in the
 * ternary-building rules, which emit the positive form directly. A `!=` is a different kind; `!a && b` keeps its shape; outer
 * parens around the condition are unwrapped. A branch that is the same construct bare (an else-if chain, a ternary in a ternary's
 * branch) is skipped: the swap would re-nest the chain rather than invert it. A no-`else` `if` has nothing to swap into.
 *
 * ## Comments
 *
 * The positive condition is the not's operand, a redundant paren around it unwrapped, so a comment between the
 * `!` and that operand would be dropped (one INSIDE the operand travels). A statement that would drop one is
 * left unreported. A value form is REPORT-ONLY instead, for that comment and for one in the glue between the
 * condition and the branches, which stays put while the branches move and would then describe the other one.
 *
 * ## Autofix
 *
 * Three non-overlapping edits per finding: the condition becomes the positive form, the two branches swap. In a
 * statement the `if` parentheses delimit the condition; in a value form each edit is a `ParenGuard` splice, so the
 * parse round-trip adds exactly the pairs precedence needs (`!(a = b) ? x : y` -> `(a = b) ? y : x`, `!(a && b) ? x
 * : y` -> `a && b ? y : x`). The walk STOPS at a flagged node, so a nested one surfaces on a later pass and per-pass
 * edits never overlap; a report-only node is descended into. Chains with `comparison-to-boolean` through the `--fix`
 * fixed point (`x == false` -> `!x` -> swapped away). Unset `ifStatementKinds` or `notKind` makes the check a no-op.
 *
 * ## Options (both default off)
 *
 * `keepDefaultElse` leaves a negated choice whose CURRENT else arm is a default literal (`null`, `false`, a zero, an
 * empty string) alone, so `!hasNext ? event : null` keeps the fallback last; an `if` statement counts when its else
 * is `return <default>;`. `defaultLast`, which implies it, turns the reverse: a default THEN arm before a non-literal
 * else goes last — `c ? null : v` -> `!c ? v : null`, `a != b ? null : v` -> `a == b ? v : null` — for a condition
 * that negates cleanly (`NegatedCondition.defaultLastCondition`). Both are read through `NegatedCondition.swapOf`, so
 * the four ternary builders and the swap agree and `--fix` settles.
 */
@:nullSafety(Strict)
final class InvertNegatedIfElse extends RuleBase implements ConfigAware {

	public static inline final RULE_ID: String = 'invert-negated-if-else';

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	private static inline final MSG_STATEMENT: String = 'this negated if-else can be inverted — drop the ! and swap the branches';
	private static inline final MSG_TERNARY: String = 'this negated ternary can be inverted — drop the ! and swap the branches';
	private static inline final MSG_IF_EXPRESSION: String = 'this negated if-expression can be inverted — drop the ! and swap the branches';
	private static inline final MSG_DEFAULT_STATEMENT: String =
		'this if-else returns the default first — invert the condition so the default goes last';
	private static inline final MSG_DEFAULT_TERNARY: String =
		'this ternary puts the default first — invert the condition so the default goes last';
	private static inline final MSG_DEFAULT_IF_EXPRESSION: String =
		'this if-expression puts the default first — invert the condition so the default goes last';

	/** Appended to a value-form message when a comment keeps the site report-only. */
	private static inline final COMMENT_BLOCKS: String = ' (a comment blocks the autofix)';

	/** The linter's per-file config resolver (`keepDefaultElse`), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'an if-else, if-expression or ternary with a top-level negated condition — invert the condition and swap the branches',
			RuleCategory.Control
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(
			files, plugin, resolveSeams(plugin, files, _resolveConfig),
			(entry, tree, seams, violations) -> walk(violations, scanOf(seams, entry.file, entry.source, tree, plugin), tree)
		);
	}

	/**
	 * Invert each flagged node: replace its condition with the positive form and swap the then /
	 * else branch source. The flagged node is recovered by span; a re-validation guards the
	 * independent `fix` parse. Unset seams make `fix` a no-op.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = violations[0].file;
		final resolved: Null<Seams> = resolveSeams(plugin, [{ file: file, source: source }], _resolveConfig, index);
		return RunScan.editsWith(plugin, source, resolved, (root, seams) -> {
			final scan: Scan = scanOf(seams, file, source, root, plugin);
			final byKey: Map<String, QueryNode> = [];
			MemberKinds.indexNodesByKind(root, seams.ifKinds.concat(seams.valueKinds), byKey);
			final edits: Array<{ span: Span, text: String }> = [];
			final guarded: Array<GuardedEdit> = [];
			RunScan.eachMatched(violations, byKey, (node, _) -> {
				if (seams.ifKinds.contains(node.kind))
					statementEdits(node, scan, edits)
				else
					valueEdits(node, scan, guarded);
			});
			return edits.concat(ParenGuard.guard(source, guarded, plugin));
		});
	}

	/**
	 * Walk `node`; flag an invertible `if` statement or value form, then STOP descending into it — a
	 * nested invertible conditional is found on a re-run, keeping per-pass edits non-overlapping. A
	 * report-only value form is flagged and descended into: nothing of it is rewritten.
	 */
	private static function walk(out: Array<Violation>, scan: Scan, node: QueryNode): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == IF_WITH_ELSE_CHILD_COUNT) {
			final seams: Seams = scan.seams;
			final swap: Null<Swap> = seams.ifKinds.contains(node.kind) ? statementSwap(node, scan) : null;
			if (swap != null) {
				out.push(finding(scan, span, swap.defaultLast ? MSG_DEFAULT_STATEMENT : MSG_STATEMENT));
				return;
			}
			if (seams.valueKinds.contains(node.kind)) {
				switch valueVerdict(node, scan) {
					case Fixable(swap):
						out.push(finding(scan, span, valueMessage(node, swap, seams)));
						return;
					case CommentBlocked(swap):
						out.push(finding(scan, span, valueMessage(node, swap, seams) + COMMENT_BLOCKS));
					case Skip:
				}
			}
		}
		for (c in node.children) walk(out, scan, c);
	}

	/** The finding text for the value form `node` swapped as `swap`. */
	private static function valueMessage(node: QueryNode, swap: Swap, seams: Seams): String {
		return if (node.kind == seams.ternaryKind)
			swap.defaultLast ? MSG_DEFAULT_TERNARY : MSG_TERNARY
		else if (swap.defaultLast)
			MSG_DEFAULT_IF_EXPRESSION
		else
			MSG_IF_EXPRESSION;
	}

	/** One `Info` finding of this rule at `span`. */
	private static function finding(scan: Scan, span: Span, message: String): Violation {
		return {
			file: scan.site.file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: message
		};
	}

	/**
	 * How the `if` statement `ifNode` (with an `else`) swaps, or null when it is no swap candidate: its
	 * else branch is not itself an `if`, `NegatedCondition.swapOf` reads it for that else branch (a
	 * built-in top-level not, no `keepDefaultElse` default arm; or a `defaultLast` turn) and the rebuild
	 * drops no comment.
	 */
	private static function statementSwap(ifNode: QueryNode, scan: Scan): Null<Swap> {
		final elseBranch: QueryNode = ifNode.children[2];
		if (scan.seams.ifKinds.contains(elseBranch.kind)) return null;
		final swap: Null<Swap> = NegatedCondition.swapOf(ifNode.children[0], ifNode.children[1], elseBranch, scan.site);
		return swap == null || swap.dropsComment ? null : swap;
	}

	/**
	 * What the value form `node` (a ternary or a value `if`, with both branches) is: `Skip` when
	 * `NegatedCondition.swapOf` does not swap it or a branch is the same construct (a chain the swap
	 * would restructure), `CommentBlocked` when the rebuild would drop or misplace a comment (one
	 * the positive condition drops, or one in the glue between the condition and the branches, which
	 * stays where it is while the branches move), else `Fixable`.
	 */
	private static function valueVerdict(node: QueryNode, scan: Scan): ValueVerdict {
		final cond: QueryNode = node.children[0];
		final thenBranch: QueryNode = node.children[1];
		final elseBranch: QueryNode = node.children[2];
		if (sameConstruct(thenBranch, node, scan.seams) || sameConstruct(elseBranch, node, scan.seams)) return Skip;
		final swap: Null<Swap> = NegatedCondition.swapOf(cond, thenBranch, elseBranch, scan.site);
		final condSpan: Null<Span> = tight(cond, scan);
		final thenSpan: Null<Span> = tight(thenBranch, scan);
		final elseSpan: Null<Span> = tight(elseBranch, scan);
		if (swap == null || condSpan == null || thenSpan == null || elseSpan == null) return Skip;
		final source: String = scan.site.source;
		return swap.dropsComment
			|| SourceComments.hasCommentMarker(source, condSpan.to, thenSpan.from)
			|| SourceComments.hasCommentMarker(source, thenSpan.to, elseSpan.from)
			? CommentBlocked(swap)
			: Fixable(swap);
	}

	/** Whether `branch` is the same construct as its value-form `parent` — a ternary in a ternary, a value `if` in a value `if`. */
	private static function sameConstruct(branch: QueryNode, parent: QueryNode, seams: Seams): Bool {
		return parent.kind == seams.ternaryKind ? branch.kind == seams.ternaryKind : seams.ifExpressionKinds.contains(branch.kind);
	}

	/**
	 * Push the three inversion edits for one flagged `if` statement (or nothing when it fails a
	 * re-validation or lacks the spans): condition replaced by the swapped form, then / else
	 * branch source swapped.
	 */
	private static function statementEdits(ifNode: QueryNode, scan: Scan, edits: Array<{ span: Span, text: String }>): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT) return;
		final swap: Null<Swap> = statementSwap(ifNode, scan);
		if (swap == null) return;
		final source: String = scan.site.source;
		final shape: RefShape = scan.seams.shape;
		final thenBranch: QueryNode = ifNode.children[1];
		final elseBranch: QueryNode = ifNode.children[2];
		// A region then-body closed only by the `else` after it would land in the tail slot with no
		// terminator it can be proved not to need; every branch travels with the one it owns.
		if (RegionTerminator.unterminatedRegion(thenBranch, source, shape)) return;
		final condSpan: Null<Span> = tight(ifNode.children[0], scan);
		final thenSpan: Null<Span> = RegionTerminator.ownedSpan(thenBranch, source, shape);
		final elseSpan: Null<Span> = RegionTerminator.ownedSpan(elseBranch, source, shape);
		if (condSpan == null || thenSpan == null || elseSpan == null) return;
		edits.push({ span: condSpan, text: swap.condition });
		edits.push({ span: thenSpan, text: source.substring(elseSpan.from, elseSpan.to) });
		edits.push({ span: elseSpan, text: source.substring(thenSpan.from, thenSpan.to) });
	}

	/**
	 * Push the three inversion splices for one flagged value form (or nothing when it is no longer
	 * `Fixable`): the condition replaced by the swapped form, the branches swapped. Each is a
	 * `ParenGuard` splice — the whole text is the hole — because each lands in an operator context
	 * the parser, not this rule, decides about.
	 */
	private static function valueEdits(node: QueryNode, scan: Scan, out: Array<GuardedEdit>): Void {
		if (node.children.length != IF_WITH_ELSE_CHILD_COUNT) return;
		final swap: Null<Swap> = switch valueVerdict(node, scan) {
			case Fixable(fixable): fixable;
			case CommentBlocked(_), Skip: null;
		};
		final source: String = scan.site.source;
		final condSpan: Null<Span> = tight(node.children[0], scan);
		final thenSpan: Null<Span> = tight(node.children[1], scan);
		final elseSpan: Null<Span> = tight(node.children[2], scan);
		if (swap == null || condSpan == null || thenSpan == null || elseSpan == null) return;
		out.push(write(condSpan, swap.condition));
		out.push(splice(thenSpan, elseSpan, source));
		out.push(splice(elseSpan, thenSpan, source));
	}

	/**
	 * `node`'s span without the trailing trivia a node span may run on through (a prefix `!` ends past
	 * the blank before the `?`), so a splice over it keeps the whitespace and any comment there in place.
	 */
	private static function tight(node: QueryNode, scan: Scan): Null<Span> {
		final span: Null<Span> = node.span;
		return span == null ? null : ElementSpan.trailingTrimmedSpan(scan.site.source, span, scan.regions);
	}

	/** The per-file scan state over `seams`; the lexical regions are lexed once, on first demand. */
	private static function scanOf(seams: Seams, file: String, source: String, root: QueryNode, plugin: GrammarPlugin): Scan {
		var lexed: Null<Array<LexRegion>> = null;
		return {
			regions: () -> {
				final known: Null<Array<LexRegion>> = lexed;
				if (known != null) return known;
				final fresh: Array<LexRegion> = plugin.lexicalRegions(source);
				lexed = fresh;
				return fresh;
			},
			seams: seams,
			site: NegatedCondition.site(seams.negation, file, source, root)
		};
	}

	/** Resolve the if / value-form / negation seams, or null when a required piece is unset; `config` resolves `keepDefaultElse`. */
	private static function resolveSeams(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, config: Null<(String) -> LintConfig>, ?report: SymbolIndex
	): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final negation: Null<InversionSeams> = NegatedCondition.readSeams(plugin, files, config, report);
		if (ifKinds.length == 0 || negation == null) return null;
		final ternaryKind: Null<String> = shape.ternaryKind;
		final ifExpressionKinds: Array<String> = shape.ifExpressionKinds ?? [];
		return {
			ifKinds: ifKinds,
			ternaryKind: ternaryKind,
			ifExpressionKinds: ifExpressionKinds,
			valueKinds: (ternaryKind == null ? [] : [ternaryKind]).concat(ifExpressionKinds),
			negation: negation,
			shape: shape
		};
	}

	/** The `ParenGuard` splice writing `from`'s source over `to` — the whole text is the hole. */
	private static function splice(to: Span, from: Span, source: String): GuardedEdit {
		return write(to, source.substring(from.from, from.to));
	}

	/** The `ParenGuard` splice writing `text` over `to` — the whole text is the hole. */
	private static function write(to: Span, text: String): GuardedEdit {
		return { span: to, text: text, holes: [] };
	}

}

/** The resolved seams `InvertNegatedIfElse` reads in both `run` and `fix`. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final ternaryKind: Null<String>;
	final ifExpressionKinds: Array<String>;

	/** `ternaryKind` and `ifExpressionKinds` together — every value form the rule inverts. */
	final valueKinds: Array<String>;

	/** The negation read every form shares (`NegatedCondition`), its operator table included. */
	final negation: InversionSeams;

	/** Read by `RegionTerminator` for the region kind and its terminator. */
	final shape: RefShape;
};

/** One file's scan: the run seams and that file's negation site. */
private typedef Scan = {
	final seams: Seams;
	final site: InversionSite;

	/** The file's lexical regions, lexed on first demand (`ElementSpan.trailingTrimmedSpan`). */
	final regions: () -> Array<LexRegion>;
};

/** What a value form is to this rule. */
private enum ValueVerdict {
	Skip;

	/** Rewritten as `swap` reads it. */
	Fixable(swap: Swap);

	/** Reported, not rewritten: a comment would be dropped or left describing the other branch. */
	CommentBlocked(swap: Swap);
}
