package anyparse.check.common.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.control.BranchChain;
import anyparse.check.common.control.CollapsibleIf;
import anyparse.check.scan.PurityScan;
import anyparse.query.CanonicalEdit;
import anyparse.query.MemberKinds;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;

/** The `RefShape` kinds `RedundantIfBeforeWhile` reads. */
private typedef Seams = { var ifKinds: Array<String>; var whileKind: String; var blockKind: Null<String>; }

/** The per-file scan state: the source, its comment tokens, the seams and a LAZY purity scan. */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var purity: () -> Null<PurityCtx>;
}

/** A flagged `if`: its span, the text replacing it (null = report-only) and why it is report-only. */
private typedef Match = { var span: Span; var edit: Null<FixEdit>; var note: String; }

/**
 * Flags an `if (C)` with no `else` whose only then-statement, braced or bare, is `while (C)` with
 * a structurally equal condition: the `if` repeats the loop's own test and decides nothing, so
 * `if (C) while (C) body` is `while (C) body`.
 *
 * Only `while`: a `for` has no condition to compare, and a `do … while` runs its body once
 * without the test, so its `if` is not redundant. `if (C && D) while (C)` is a different
 * condition and is left alone.
 *
 * `fix` removes the repeated evaluation of `C`, so it applies only when `C` is pure
 * (`PurityScan.isPure`); a condition it cannot clear (an unresolved call) is reported with a
 * note and no edit. A comment inside the `if` but outside the `while` would be lost, so it
 * makes the finding report-only too.
 *
 * ## Grammar-agnostic
 *
 * Kinds come from `RefShape.ifStatementKinds`, `whileStmtKind` and `blockStmtKind`; with the
 * first two unset the check is a no-op.
 */
@:nullSafety(Strict)
final class RedundantIfBeforeWhile extends RuleBase {

	private static final MESSAGE: String = 'this if repeats the condition of the while it holds and decides nothing';
	private static final COMMENT_NOTE: String = ' (comment inside the if - merge by hand)';
	private static final IMPURE_NOTE: String = ' (condition not proven pure - merge by hand)';

	public function new() {
		super(
			'redundant-if-before-while',
			'an if (C) whose only statement is while (C) with the same condition — the if repeats the loop test and decides nothing',
			RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in scan(tree, entry.source, plugin, entry.file, seams, symbols)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'redundant-if-before-while',
				severity: Severity.Warning,
				message: MESSAGE + m.note
			});
		});
	}

	/** Replace each flagged `if` with the `while` it holds, source text unchanged. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.editsWith(plugin, source, readSeams(plugin), (tree, seams) -> {
			final file: String = violations.length == 0 ? '' : violations[0].file;
			final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
			final byKey: Map<String, Match> = [];
			for (m in scan(tree, source, plugin, file, seams, symbols)) byKey['${m.span.from}:${m.span.to}'] = m;
			final edits: Array<FixEdit> = [];
			RunScan.eachMatched(violations, byKey, (m, span) -> {
				final edit: Null<FixEdit> = m.edit;
				if (edit != null) edits.push(edit);
			});
			return CanonicalEdit.dropContainedEdits(edits);
		});
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileKind: Null<String> = shape.whileStmtKind;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		return whileKind == null || ifKinds.length == 0 ? null : { ifKinds: ifKinds, whileKind: whileKind, blockKind: shape.blockStmtKind };
	}

	private static function scan(
		tree: QueryNode, source: String, plugin: GrammarPlugin, file: String, seams: Seams, symbols: () -> Null<SymbolIndex>
	): Array<Match> {
		final out: Array<Match> = [];
		walk(tree, {
			source: source,
			seams: seams,
			comments: SourceComments.collectCommentTokens(plugin.lexicalRegions(source)),
			purity: PurityScan.lazyContextOf(plugin, source, tree, symbols, file)
		}, out);
		return out;
	}

	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.ifKinds.contains(node.kind) && BranchChain.hasThen(node) && !BranchChain.hasElse(node)) {
			final m: Null<Match> = matchIf(node, ctx);
			if (m != null) out.push(m);
		}
		for (c in node.children) walk(c, ctx, out);
	}

	private static function matchIf(ifNode: QueryNode, ctx: Ctx): Null<Match> {
		final loop: QueryNode = CollapsibleIf.unwrapBlock(BranchChain.thenOf(ifNode), ctx.seams.blockKind);
		if (loop.kind != ctx.seams.whileKind || !LoopScan.hasWhileShape(loop)) return null;
		final cond: QueryNode = BranchChain.condOf(ifNode);
		if (!MemberKinds.structurallyEqual(cond, LoopScan.whileCondition(loop))) return null;
		final span: Null<Span> = ifNode.span;
		final loopSpan: Null<Span> = loop.span;
		if (span == null || loopSpan == null) return null;
		final note: String = refusal(cond, span, loopSpan, ctx);
		final replacement: String = ctx.source.substring(loopSpan.from, loopSpan.to);
		return { span: span, edit: note == '' ? { span: span, text: replacement } : null, note: note };
	}

	/** Why the fix is refused, or the empty string when `if` → `while` is safe. */
	private static function refusal(cond: QueryNode, span: Span, loopSpan: Span, ctx: Ctx): String {
		for (c in ctx.comments) {
			final inside: Bool = c.to > span.from && c.from < span.to;
			if (inside && !(c.from >= loopSpan.from && c.to <= loopSpan.to)) return COMMENT_NOTE;
		}
		final purity: Null<PurityCtx> = ctx.purity();
		return purity != null && PurityScan.isPure(cond, purity) ? '' : IMPURE_NOTE;
	}

}
