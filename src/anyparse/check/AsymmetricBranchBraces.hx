package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if` / `else` pair in which EXACTLY ONE branch is braced -
 * `if (a) { p(); q(); } else r();` or its mirror. `Info`: both spellings compile
 * and mean the same thing, and which one to keep is the project's taste, so the
 * finding is the report-only twin of the writer's
 * `whitespace.bracesConfig.singleStatementBraces: "symmetric"` policy, for a
 * project that wants to SEE the asymmetry rather than have `fmt` repair it.
 *
 * `DefaultOff` - opt in with `"asymmetric-branch-braces": { "enabled": true }`.
 *
 * ## What is flagged, and what is not
 *
 * Exactly one of the two branches is the grammar's block-statement kind. Two
 * braced branches are symmetric; two bare ones are symmetric too - this is not a
 * "brace everything" rule, and `if (d.length != 4) throw '...';` is never flagged.
 *
 * TWO exemptions, the same two the writer's symmetric policy applies, for the same
 * reason: an `else` whose body is another `if` (`} else if (c) ...`) or a `switch`
 * (`} else switch s { ... }`). Both are keyword-headed else bodies the writer
 * deliberately glues to the `else` line, and each closes on a `}` of its own, so
 * the pair already reads symmetric. Bracing the `if` one would rebuild the exact
 * `else { if ... }` shape `collapsible-else-if` exists to remove. The exemption is
 * on the ELSE side only: a `switch` in THEN position opposite a braced `else` is a
 * genuine asymmetry and is flagged.
 *
 * The reported span is the whole `if` statement, so the message can name both
 * branch positions - a span on one branch alone reads as if that branch were the
 * defect, and which of the two moves is the config's decision, not the check's.
 *
 * ## Grammar-agnostic
 *
 * The `if` kinds come from `RefShape.ifStatementKinds` (statement position only),
 * the block kind from `RefShape.blockStmtKind`, and the exempt else kinds from
 * `ifStatementKinds` plus `RefShape.switchStatementKinds`. Any of the first two
 * unset makes the check a no-op; an unset `switchStatementKinds` costs only the
 * `else switch` exemption, so a grammar without it reports those pairs.
 */
@:nullSafety(Strict)
final class AsymmetricBranchBraces implements Check implements DefaultOff implements NoAutofix {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'asymmetric-branch-braces';

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The then branch is the second child of an if node - `[cond, then, else]`. */
	private static inline final THEN_BRANCH_INDEX: Int = 1;

	/** The else branch is the third child of an if node - `[cond, then, else]`. */
	private static inline final ELSE_BRANCH_INDEX: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an if/else with exactly one braced branch - the other reads as an accident';
	}

	public function noAutofixReason(): String {
		return 'which branch should move is the project\'s brace policy, and the writer already owns it '
			+ '(whitespace.bracesConfig.singleStatementBraces)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) for (found in collect(tree, seams)) violations.push({
				file: entry.file,
				span: found.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: found.thenBraced
					? 'the then branch is braced and the else branch is not - brace both or neither'
					: 'the else branch is braced and the then branch is not - brace both or neither'
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Every asymmetric if/else in `root`, in document order. */
	private static function collect(root: QueryNode, seams: Seams): Array<{ span: Span, thenBraced: Bool }> {
		final out: Array<{ span: Span, thenBraced: Bool }> = [];
		walk(root, seams, out);
		return out;
	}

	private static function walk(node: QueryNode, seams: Seams, out: Array<{ span: Span, thenBraced: Bool }>): Void {
		final span: Null<Span> = node.span;
		if (span != null && seams.ifKinds.contains(node.kind) && node.children.length == IF_WITH_ELSE_CHILD_COUNT) {
			final thenBranch: QueryNode = node.children[THEN_BRANCH_INDEX];
			final elseBranch: QueryNode = node.children[ELSE_BRANCH_INDEX];
			final thenBraced: Bool = thenBranch.kind == seams.blockStmtKind;
			final elseBraced: Bool = elseBranch.kind == seams.blockStmtKind;
			if (thenBraced != elseBraced && !(thenBraced && seams.exemptElseKinds.contains(elseBranch.kind)))
				out.push({ span: span, thenBraced: thenBraced });
		}
		for (child in node.children) walk(child, seams, out);
	}

	/**
	 * The `if` kinds, the block-statement kind and the else kinds exempt from the
	 * symmetry question, or null when either of the first two is unset.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return ifKinds.length == 0 || blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			blockStmtKind: blockStmtKind,
			exemptElseKinds: ifKinds.concat(shape.switchStatementKinds ?? [])
		};
	}

}

/** The seam kinds `AsymmetricBranchBraces` reads: the statement-position `if` kinds, the block kind, and the exempt else kinds. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final blockStmtKind: String;
	final exemptElseKinds: Array<String>;
};
