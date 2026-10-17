package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.NegatedCondition.InversionSeams;
import anyparse.check.NegatedCondition.InversionSite;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberKinds;
import anyparse.query.ParenGuard;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

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
 * ## Option `keepDefaultElse` (default off)
 *
 * With `"keepDefaultElse": true` a negated choice whose CURRENT else arm is a default literal (`null`, `false`, a
 * numeric zero, an empty string; parenthesised too) is left alone: `!hasNext ? event : null` keeps the fallback
 * last, where the inversion would bury the value (`hasNext ? null : event`). Likewise a value `if`, and an `if`
 * statement whose else branch is `return <default>;` (bare or alone in a block). A non-default else still inverts.
 * The gate is `NegatedCondition`'s, so the four ternary builders read this same option.
 */
@:nullSafety(Strict)
final class InvertNegatedIfElse implements Check implements ConfigAware {

	public static inline final RULE_ID: String = 'invert-negated-if-else';

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	private static inline final MSG_STATEMENT: String = 'this negated if-else can be inverted — drop the ! and swap the branches';
	private static inline final MSG_TERNARY: String = 'this negated ternary can be inverted — drop the ! and swap the branches';
	private static inline final MSG_IF_EXPRESSION: String = 'this negated if-expression can be inverted — drop the ! and swap the branches';

	/** Appended to a value-form message when a comment keeps the site report-only. */
	private static inline final COMMENT_BLOCKS: String = ' (a comment blocks the autofix)';

	/** The linter's per-file config resolver (`keepDefaultElse`), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an if-else, if-expression or ternary with a top-level negated condition — invert the condition and swap the branches';
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
			if (seams.ifKinds.contains(node.kind) && statementInvertible(node, scan)) {
				out.push(finding(scan, span, MSG_STATEMENT));
				return;
			}
			if (seams.valueKinds.contains(node.kind)) {
				final message: String = node.kind == seams.ternaryKind ? MSG_TERNARY : MSG_IF_EXPRESSION;
				switch valueVerdict(node, scan) {
					case Fixable:
						out.push(finding(scan, span, message));
						return;
					case CommentBlocked:
						out.push(finding(scan, span, message + COMMENT_BLOCKS));
					case Skip:
				}
			}
		}
		for (c in node.children) walk(out, scan, c);
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
	 * Whether the `if` statement `ifNode` (with an `else`) is a swap candidate: its condition reads
	 * positive through `NegatedCondition.positive` for its `else` branch (a built-in top-level not whose
	 * rebuild drops no comment, and no `keepDefaultElse` default arm) and that branch is not itself an `if`.
	 */
	private static function statementInvertible(ifNode: QueryNode, scan: Scan): Bool {
		final elseBranch: QueryNode = ifNode.children[2];
		return
			!scan.seams.ifKinds.contains(elseBranch.kind) && NegatedCondition.positive(ifNode.children[0], elseBranch, scan.site) != null;
	}

	/**
	 * What the value form `node` (a ternary or a value `if`, with both branches) is: `Skip` when its
	 * condition is no built-in top-level not or a branch is the same construct (a chain the swap
	 * would restructure), `CommentBlocked` when the rebuild would drop or misplace a comment (one
	 * the positive condition drops, or one in the glue between the condition and the branches, which
	 * stays where it is while the branches move), else `Fixable`.
	 */
	private static function valueVerdict(node: QueryNode, scan: Scan): ValueVerdict {
		final cond: QueryNode = node.children[0];
		final thenBranch: QueryNode = node.children[1];
		final elseBranch: QueryNode = node.children[2];
		if (sameConstruct(thenBranch, node, scan.seams) || sameConstruct(elseBranch, node, scan.seams)) return Skip;
		final kept: Null<QueryNode> = NegatedCondition.invertibleOperand(cond, elseBranch, scan.site);
		final condSpan: Null<Span> = tight(cond, scan);
		final thenSpan: Null<Span> = tight(thenBranch, scan);
		final elseSpan: Null<Span> = tight(elseBranch, scan);
		if (kept == null || condSpan == null || thenSpan == null || elseSpan == null) return Skip;
		final source: String = scan.site.source;
		return NegatedCondition.dropsComment(cond, kept, source) || SourceComments.hasCommentMarker(source, condSpan.to, thenSpan.from)
			|| SourceComments.hasCommentMarker(source, thenSpan.to, elseSpan.from)
			? CommentBlocked
			: Fixable;
	}

	/** Whether `branch` is the same construct as its value-form `parent` — a ternary in a ternary, a value `if` in a value `if`. */
	private static function sameConstruct(branch: QueryNode, parent: QueryNode, seams: Seams): Bool {
		return parent.kind == seams.ternaryKind ? branch.kind == seams.ternaryKind : seams.ifExpressionKinds.contains(branch.kind);
	}

	/**
	 * Push the three inversion edits for one flagged `if` statement (or nothing when it fails a
	 * re-validation or lacks the spans): condition replaced by the positive form, then / else
	 * branch source swapped.
	 */
	private static function statementEdits(ifNode: QueryNode, scan: Scan, edits: Array<{ span: Span, text: String }>): Void {
		if (ifNode.children.length < IF_WITH_ELSE_CHILD_COUNT || !statementInvertible(ifNode, scan)) return;
		final source: String = scan.site.source;
		final shape: RefShape = scan.seams.shape;
		final cond: QueryNode = ifNode.children[0];
		final thenBranch: QueryNode = ifNode.children[1];
		final elseBranch: QueryNode = ifNode.children[2];
		// A region then-body closed only by the `else` after it would land in the tail slot with no
		// terminator it can be proved not to need; every branch travels with the one it owns.
		if (RegionTerminator.unterminatedRegion(thenBranch, source, shape)) return;
		final condSpan: Null<Span> = tight(cond, scan);
		final thenSpan: Null<Span> = RegionTerminator.ownedSpan(thenBranch, source, shape);
		final elseSpan: Null<Span> = RegionTerminator.ownedSpan(elseBranch, source, shape);
		final keptSpan: Null<Span> = NegatedCondition.positive(cond, elseBranch, scan.site)?.span;
		if (condSpan == null || thenSpan == null || elseSpan == null || keptSpan == null) return;
		edits.push({ span: condSpan, text: source.substring(keptSpan.from, keptSpan.to) });
		edits.push({ span: thenSpan, text: source.substring(elseSpan.from, elseSpan.to) });
		edits.push({ span: elseSpan, text: source.substring(thenSpan.from, thenSpan.to) });
	}

	/**
	 * Push the three inversion splices for one flagged value form (or nothing when it is no longer
	 * `Fixable`): the condition replaced by the positive form, the branches swapped. Each is a
	 * `ParenGuard` splice — the whole text is the hole — because each lands in an operator context
	 * the parser, not this rule, decides about.
	 */
	private static function valueEdits(node: QueryNode, scan: Scan, out: Array<GuardedEdit>): Void {
		if (node.children.length != IF_WITH_ELSE_CHILD_COUNT || !valueVerdict(node, scan).match(Fixable)) return;
		final source: String = scan.site.source;
		final cond: QueryNode = node.children[0];
		final condSpan: Null<Span> = tight(cond, scan);
		final thenSpan: Null<Span> = tight(node.children[1], scan);
		final elseSpan: Null<Span> = tight(node.children[2], scan);
		final keptSpan: Null<Span> = NegatedCondition.invertibleOperand(cond, node.children[2], scan.site)?.span;
		if (condSpan == null || thenSpan == null || elseSpan == null || keptSpan == null) return;
		out.push(splice(condSpan, keptSpan, source));
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
		return { span: to, text: source.substring(from.from, from.to), holes: [] };
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
	Fixable;

	/** Reported, not rewritten: a comment would be dropped or left describing the other branch. */
	CommentBlocked;
}
