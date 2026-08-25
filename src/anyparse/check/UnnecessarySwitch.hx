package anyparse.check;

import anyparse.check.CasePatternScan.CaseSeams;
import anyparse.check.Check.Violation;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags — and UNWRAPS — a switch whose only arm is an unconditional catch-all: `switch x {
 * case _: close(); }` decides nothing, so it is `close();` with a subject evaluated for no
 * reason. `Info`, with a `--fix` that puts the arm's body in the switch's place.
 *
 * ## Why the rule exists where it does
 *
 * It is the TERMINATOR of a cascade the other case-arm rules stop one step short of.
 * `unused-case-binder` rewrites a binder nothing reads to `_`, `redundant-case-body` deletes an
 * arm a catch-all already covers, and `empty-case-arm` peels trailing empty arms — each of them
 * can leave a switch holding exactly one catch-all, and each deliberately refuses to go further:
 * `empty-case-arm`'s second gate says so outright ("deleting the sole arm leaves a degenerate
 * `switch x {}`"). Nothing then removed the husk. A hand-written one is rare; one PRODUCED by a
 * `--fix` pass is not, and it is the shape a reader is most likely to mistake for a decision the
 * code makes.
 *
 * ## What is flagged
 *
 * A `switchKinds` node with exactly TWO children — its subject and ONE arm — whose arm
 * `CasePatternScan.isCatchAll` accepts (a `default:`, or a single unguarded `_`; a guard RUNS and
 * may reject, so a guarded arm is never unconditional). A BINDER instead of the wildcard
 * (`case action:`) is refused: unwrapping one means introducing `final action = subject;`, a
 * different rewrite with a different name-collision question — and `shadowing-case-binder` has
 * something to say about that shape first.
 *
 * The two-child requirement carries the conditional-compilation gate for free: an `#if` among the
 * arms projects as a SIBLING of them, so a switch holding one has three children or an arm this
 * scan does not recognise, and is refused either way. Reification subtrees (`opaqueKinds`) are
 * skipped wholesale.
 *
 * ## The subject must be DROPPABLE, which is not the same as hoistable
 *
 * `switch next() { case _: f(); }` cannot lose its subject — the call runs. Purity is asked
 * through `PurityScan`, which reads a field access as pure only when it can prove the member is
 * not a property getter. A collection LITERAL (`switch [m, args] { case _: … }`) is accepted on
 * top of that, and deliberately NOT by adding it to `PurityScan`'s shared whitelist: dropping an
 * allocation is unobservable, but HOISTING one is not — two evaluations of `[a, b]` yield
 * distinct references and `extract-repeated-expression` would collapse them into one. The safe
 * direction differs per caller, so the widening stays local to this rule.
 *
 * ## The statement fix splices a BLOCK, and that is not laziness
 *
 * A statement switch is replaced by `{ <arm body> }`, never by the bare statements. The braces
 * answer three questions at once that a bare splice answers wrongly: a block is self-TERMINATING
 * (no `;` to reason about), it is a legal brace-less BODY (`if (c) switch x { case _: a(); b(); }`
 * would otherwise leave only `a()` guarded), and it preserves the arm's SCOPE (an arm body
 * declaring a local must not widen that local into the enclosing block). Everything left is
 * `unnecessary-block`'s existing job — it unwraps a binding-free block whose parent is a statement
 * list, and refuses exactly the cases that must keep their braces. Two rules, each proving its own
 * half, instead of one rule re-deriving the other's gates.
 *
 * An EMPTY arm body has no block worth leaving, so it is deleted outright
 * (`RefactorSupport.lineDeletionSpan`) — and only when the switch is itself a statement in a list,
 * since deleting the body of `if (c)` would leave the `if` with none.
 *
 * ## The expression fix owes a terminator
 *
 * In expression position the arm must yield exactly one value — one `exprStatementKind` statement
 * — and its VALUE is spliced, not the statement, so the arm's own `;` does not ride along into
 * `final v = <here>;`. But the switch's closing brace may itself have been the enclosing
 * statement's terminator: `return switch x { case _: 42; }` is legal Haxe, and `return 42` is not
 * (`Missing ;`, verified against the compiler). So when only whitespace separates the switch's end
 * from its statement's end, the spliced value carries a `;`. A multi-statement expression arm is
 * refused: it would need a block-expression wrapper, which is a rewrite rather than an unwrap.
 *
 * A comment anywhere in the region the unwrap DISTURBS — between the `switch` keyword and the
 * body, or between the body and the closing brace — refuses the finding, the same gate
 * `empty-case-arm` and `redundant-case-body` carry. A comment INSIDE the body travels with it.
 *
 * ## One behaviour this deliberately changes
 *
 * On hxcpp a `switch` over a null enum crashes, so deleting one removes a latent crash rather than
 * preserving it. That is a change in the good direction and it is the only one: whether a wildcard
 * is reached for `null` at all is the target-dependent question `nullable-switch-missing-null`
 * owns.
 *
 * ## Seams and idempotence
 *
 * Everything arrives through `CasePatternScan.seamsOf` plus `switchStatementKinds` /
 * `exprStatementKind`; a required one unset makes the check a no-op, report and fix alike. `fix`
 * re-derives its candidates from the re-parsed tree, so a reported span that no longer names a
 * degenerate switch produces no edit. After the fix there is no switch left at that position, so a
 * second pass finds nothing.
 */
@:nullSafety(Strict)
final class UnnecessarySwitch implements Check {

	/** A degenerate switch holds exactly its subject and ONE arm. */
	private static inline final SUBJECT_AND_ONE_ARM: Int = 2;

	private static inline final MESSAGE: String =
		'this switch has a single unconditional catch-all arm — it decides nothing; use the arm\'s body directly';
	private static final RULE_ID: String = 'unnecessary-switch';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a switch whose only arm is an unconditional catch-all — it decides nothing and unwraps to the arm body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		return [
			for (entry in files) for (candidate in candidates(resolved, plugin, entry.source, index))
				{
					file: entry.file,
					span: candidate.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: MESSAGE
				}
		];
	}

	/**
	 * Unwrap each flagged switch. The candidate set is re-derived from the re-parsed tree — with
	 * the caller's report-scoped index when it supplied one, else one built over this file alone —
	 * so a reported span that no longer names a degenerate switch produces no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final resolved: Seams = seams;
		final files: Array<{ file: String, source: String }> = [{ file: violations[0].file, source: source }];
		final resolvedIndex: SymbolIndex = index ?? SymbolIndex.build(files, plugin);
		final byKey: Map<String, Candidate> = [];
		for (candidate in candidates(resolved, plugin, source, resolvedIndex))
			byKey['${candidate.span.from}:${candidate.span.to}'] = candidate;
		return CheckScan.collectSpanEdits(violations, byKey, (candidate, _) -> candidate.edit);
	}

	/** Every degenerate switch in `source`, in document order, each with the edit that unwraps it. */
	private static function candidates(seams: Seams, plugin: GrammarPlugin, source: String, index: SymbolIndex): Array<Candidate> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final purity: Null<PurityCtx> = PurityScan.contextOf(plugin, source, root, index);
		if (purity == null) return [];
		final out: Array<Candidate> = [];
		walk(seams, purity, root, source, false, null, out);
		return out;
	}

	/**
	 * Walk the whole tree so a switch nested in another switch's arm is reached too, carrying
	 * whether the current node sits directly in a statement list — the position an unwrap of
	 * anything other than a single statement needs.
	 */
	private static function walk(
		seams: Seams, purity: PurityCtx, node: QueryNode, source: String, inList: Bool, statementEnd: Null<Int>, out: Array<Candidate>
	): Void {
		if (seams.cases.opaqueKinds.contains(node.kind)) return;
		if (seams.cases.switchKinds.contains(node.kind)) {
			final candidate: Null<Candidate> = candidateOf(seams, purity, node, source, inList, statementEnd);
			if (candidate != null) out.push(candidate);
		}
		final container: Bool = seams.containerKinds.contains(node.kind);
		for (child in node.children) walk(seams, purity, child, source, container, container ? child.span?.to : statementEnd, out);
	}

	/** `node` as a degenerate switch plus the edit that unwraps it, or null when any gate refuses. */
	private static function candidateOf(
		seams: Seams, purity: PurityCtx, node: QueryNode, source: String, inList: Bool, statementEnd: Null<Int>
	): Null<Candidate> {
		final span: Null<Span> = node.span;
		if (span == null || node.children.length != SUBJECT_AND_ONE_ARM) return null;
		final at: Span = span;
		final branch: QueryNode = node.children[1];
		if (!CasePatternScan.isCatchAll(seams.cases, branch) || !droppable(seams, purity, node.children[0])) return null;
		final body: Array<QueryNode> = bodyOf(seams.cases, branch);
		final statement: Bool = seams.statementKinds.contains(node.kind);
		if (body.length == 0)
			return !statement || !inList || CheckScan.hasCommentMarker(source, at.from, at.to)
				? null
				: { span: at, edit: { span: RefactorSupport.lineDeletionSpan(source, at), text: '' } };
		final first: Null<Span> = body[0].span;
		final last: Null<Span> = body[body.length - 1].span;
		if (first == null || last == null) return null;
		final open: Span = first;
		final close: Span = last;
		if (CheckScan.hasCommentMarker(source, at.from, open.from) || CheckScan.hasCommentMarker(source, close.to, at.to)) return null;
		if (statement) return { span: at, edit: { span: at, text: '{ ${source.substring(open.from, close.to).trim()} }' } };
		final valueSpan: Null<Span> = soleValueSpan(seams, body);
		if (valueSpan == null) return null;
		final value: String = source.substring(valueSpan.from, valueSpan.to).trim();
		return { span: at, edit: { span: at, text: closesItsStatement(source, at, statementEnd) ? '$value;' : value } };
	}

	/**
	 * The statements `branch` runs. A `default:` arm carries nothing but them; a `case` arm
	 * carries its pattern run first — and `isCatchAll` has already established that run is one
	 * wildcard with no guard behind it.
	 */
	private static function bodyOf(seams: CaseSeams, branch: QueryNode): Array<QueryNode> {
		return branch.kind == seams.defaultBranchKind
			? branch.children
			: branch.children.slice(CasePatternScan.patternRun(seams, branch).length);
	}

	/**
	 * The span of the ONE value an expression arm yields — its single statement's only child, so
	 * the statement terminator stays behind. Null when the arm holds anything else: several
	 * statements, or one that is not a plain expression.
	 */
	private static function soleValueSpan(seams: Seams, body: Array<QueryNode>): Null<Span> {
		final exprStatementKind: Null<String> = seams.exprStatementKind;
		return body.length != 1 || exprStatementKind == null || body[0].kind != exprStatementKind || body[0].children.length != 1
			? null
			: body[0].children[0].span;
	}

	/**
	 * Whether the subject may be DROPPED: side-effect-free by `PurityScan`, or a collection
	 * literal whose every element is. The literal is admitted here rather than in `PurityScan`
	 * because the safe direction differs per caller — dropping an allocation is unobservable,
	 * hoisting one merges two distinct references into one.
	 */
	private static function droppable(seams: Seams, purity: PurityCtx, node: QueryNode): Bool {
		return seams.collectionKinds.contains(node.kind)
			? node.children.foreach(child -> droppable(seams, purity, child))
			: PurityScan.isPure(node, purity);
	}

	/** Resolve the case seams plus this rule's own, or null when the grammar leaves a required one unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final cases: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (cases == null) return null;
		final resolved: CaseSeams = cases;
		final shape: RefShape = plugin.refShape();
		final statementKinds: Array<String> = shape.switchStatementKinds ?? [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (statementKinds.length == 0 || support == null) return null;
		final armKinds: Array<String> = [
			for (k in [resolved.caseBranchKind, resolved.defaultBranchKind]) if (k != null) k
		];
		final collectionKinds: Array<String> = [
			for (k in [shape.arrayLiteralKind, shape.objectLiteralKind, shape.objectFieldKind]) if (k != null) k
		];
		return {
			cases: resolved,
			statementKinds: statementKinds,
			exprStatementKind: shape.exprStatementKind,
			containerKinds: support.blockKinds().concat(armKinds),
			collectionKinds: collectionKinds
		};
	}

	/**
	 * Whether the switch's closing brace IS the last token of the statement holding it — which means
	 * that brace was the statement's terminator, and a bare VALUE spliced in its place needs a `;` of
	 * its own (`return switch x { case _: 42; }` becomes `return 42;`, not `return 42`, which Haxe
	 * rejects with `Missing ;`). Only whitespace may lie between the two ends: a statement span absorbs
	 * trailing trivia, so an exact offset match would answer false for every real case, while any
	 * `;` / `)` / `}` in the gap means the statement closes itself and nothing is owed.
	 *
	 * The gap is read directly rather than through `RefactorSupport.isBlankSpan`, which drops the FIRST
	 * and LAST character of the span it is given — it answers for a `{ }` body's interior — and so calls
	 * a two-character `);` gap blank. That mistake produced `trace(42;);`.
	 */
	private static function closesItsStatement(source: String, at: Span, statementEnd: Null<Int>): Bool {
		return statementEnd != null && statementEnd >= at.to && source.substring(at.to, statementEnd).trim() == '';
	}

}

/** One degenerate switch: the span reported (and keyed on), and the edit that unwraps it. */
private typedef Candidate = {
	final span: Span;
	final edit: { span: Span, text: String };
};

/** The seams `UnnecessarySwitch` reads in both `run` and `fix`. */
private typedef Seams = {
	final cases: CaseSeams;
	final statementKinds: Array<String>;
	final exprStatementKind: Null<String>;
	final containerKinds: Array<String>;
	final collectionKinds: Array<String>;
};
