package anyparse.check;

import anyparse.check.CasePatternScan.CaseSeams;
import anyparse.check.CasePatternScan.PatternBinder;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags — and DELETES — a TRAILING EMPTY case arm of a STATEMENT switch that has no
 * catch-all, when the subject's type provably carries no exhaustiveness obligation. Such an
 * arm matches values and does nothing, and being LAST it has nothing below it, so the values
 * it names have nowhere else to go: in a statement switch an unmatched value already no-ops.
 * Deleting the arm therefore leaves behaviour identical. `Info`, with a `--fix` that removes
 * the whole line. The arm may itself be an empty `case _:` or an empty `default:` — then it
 * IS the lone catch-all, and a catch-all that does nothing is the same no-op.
 *
 * Registered ON by default. The severity is advisory, the subject whitelist makes the
 * deletion PROVABLE rather than heuristic, and every finding the rule produced while it was
 * being written — over this project's own ~665 sources — was a genuine dead arm. A
 * `DefaultOff` marker would hide a rule with no observed false positive; the day one turns
 * up, the gate that let it through is the thing to fix.
 *
 * ## Why the gates are correctness
 *
 * 1. THE ARM IS LAST. A mid-switch empty arm is the opposite of dead: it deliberately
 *    SUPPRESSES the arm (or catch-all) below it for the values it names — `case 2:` above
 *    `case _: warn();` is how a value opts out of the warning. Deleting one reroutes every
 *    value it matched. Only the final arm has nothing below it to reroute to.
 * 2. TWO ARMS AT LEAST. Deleting the sole arm leaves a degenerate `switch x {}` rather than
 *    a smaller switch, so a one-armed switch is never touched.
 * 3. THE ARM IS EMPTY, UNGUARDED and BINDS NOTHING. A guard RUNS, so an arm carrying one is
 *    not silent even with an empty body. Bindings are asked through `CasePatternScan`, whose
 *    null answer means "this label may bind something I cannot see" — an unmodelled pattern
 *    shape refuses rather than passes.
 * 4. NO EXTRACTOR in the pattern: an extractor RUNS code while matching, so deleting the arm
 *    drops that call — observable. NO `null` LITERAL either: whether a switch reaches a
 *    `case null:` arm is the target-dependent question `nullable-switch-missing-null` exists
 *    for, and refusing the literal keeps this rule out of that argument entirely. The subject
 *    whitelist below already excludes the nullable-enum subjects it would arise on, so the
 *    gate costs no real finding. Both are `CasePatternScan.patternsModellable`, shared with
 *    `redundant-case-body`.
 * 5. NO CONDITIONAL-COMPILATION REGION AMONG THE ARMS. An `#if` there projects as a SIBLING
 *    of the arms, holding arms this scan cannot enumerate, and it defeats the two gates
 *    around it at once: a catch-all may hide inside it (gate 6 unprovable), and the arms
 *    outside it may be the only ones a given build keeps, so deleting the candidate could
 *    leave `switch x { #if … #end }` (gate 2 unprovable). A macro reification inside the
 *    candidate arm is refused for the neighbouring reason — it may splice code no source scan
 *    resolves.
 * 6. NO OTHER CATCH-ALL in the switch. With a `default:` / `case _:` above it the trailing
 *    arm is UNREACHABLE rather than merely silent, and what an author meant by writing an
 *    unreachable label is not a question a deletion should answer. The CANDIDATE itself may
 *    of course be that wildcard.
 * 7. NO COMMENT in the region the deletion disturbs — from the NEWLINE ENDING the previous
 *    arm's line to the switch's closing brace. Wider than the arm's own span on BOTH sides,
 *    deliberately: a comment ABOVE the arm survives the deletion and then documents whatever
 *    follows it, and a trailing `// …` on the ARM's own line is TRIVIA the span excludes,
 *    which the writer re-attaches to a node it never described. The lower bound stops at that
 *    newline rather than at the previous arm's last token because a `// …` on THAT line lies
 *    behind everything the deletion can reach. Same reasoning as `redundant-case-body`'s
 *    subsume gate.
 *
 * ## Exhaustiveness is the whole proof
 *
 * A Haxe `switch` over an `enum`, an `enum abstract` or `Bool` is EXHAUSTIVENESS-CHECKED: its
 * arm list is part of the compile, and dropping an arm there can turn a compiling switch into
 * a non-compiling one. So the subject's type is resolved (`RefactorSupport.valueTypeNominal`,
 * through the symbol index, so a `d.code` / `S.mode` path resolves too) and matched against
 * the `openSwitchSubjectTypes` WHITELIST — `Int` / `UInt` / `Float` / `Single` / `String` for
 * Haxe, the types no arm list is ever checked against. An unresolved subject reads as null and
 * refuses. That whitelist is what lets this check need no compiler oracle: it never looks at a
 * switch whose arm count the compiler cares about.
 *
 * Being a STATEMENT switch is the other half of the same proof, and it is a SEPARATE gate
 * (`switchStatementKinds`): an EXPRESSION switch has to yield a value from every arm, so its
 * arm list is checked whatever the subject's type is.
 *
 * ## Seams and idempotence
 *
 * Detection is seam-driven through `CasePatternScan.seamsOf` plus the two `RefShape` lists
 * above; a required one unset makes the check a no-op, report and fix alike. `fix` re-derives
 * its candidates from the re-parsed tree, so a reported span that no longer names a deletable
 * arm produces no edit — and a subject resolved through ANOTHER file only re-derives when the
 * caller supplies the report-scoped index (`Cli.computeFileLintEdits` does; a direct `fix`
 * call without one falls back to an index over this file alone).
 *
 * The edit region is the arm span with its trailing blanks TRIMMED and its own line leading
 * blanks added (`armDeletionSpan`). Deletions therefore never overlap: a candidate arm is EMPTY,
 * so it can hold no second switch, and the extension walks back over blanks only.
 *
 * A RUN of empty trailing arms is peeled one arm per switch per pass — after a deletion
 * the arm above becomes the trailing one — until gate 2 stops the last one standing. `lint --fix`
 * caps its passes at 10, so a long enough run stops short and the CLI says so.
 */
@:nullSafety(Strict)
final class EmptyCaseArm implements Check {

	private static final RULE_ID: String = 'empty-case-arm';

	/** A deletable switch holds its subject plus at least TWO arms (gate 2). */
	private static inline final MIN_SWITCH_CHILDREN: Int = 3;

	private static inline final MESSAGE: String =
		'this trailing empty case arm matches values and does nothing — the switch has no catch-all, so deleting it changes nothing';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'a trailing empty case arm of a statement switch with no catch-all, over a subject type free of exhaustiveness checking — dead syntax, deletable';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final scan: Null<Scan> = scanOf(plugin);
		if (scan == null) return [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final ctx: Null<Ctx> = contextOf(scan, plugin, entry.file, entry.source, index);
			if (ctx == null) continue;
			for (span in collect(ctx, entry.source)) violations.push({
				file: entry.file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: MESSAGE
			});
		}
		return violations;
	}

	/**
	 * Delete each flagged arm together with its own line. The candidate set is re-derived from the
	 * tree, so a reported span that no longer names a deletable arm produces no edit; a subject
	 * resolved through ANOTHER file re-derives only when the caller supplies the report-scoped
	 * `index` (`Cli.computeFileLintEdits` does), a direct call without one falling back to an index
	 * over this file alone.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		final scan: Null<Scan> = scanOf(plugin);
		if (scan == null) return [];
		final ctx: Null<Ctx> = contextOf(scan, plugin, file, source, index ?? SymbolIndex.build([{ file: file, source: source }], plugin));
		if (ctx == null) return [];
		final deletable: Array<String> = [for (span in collect(ctx, source)) '${span.from}:${span.to}'];
		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			if (deletable.contains('${span.from}:${span.to}')) edits.push({ span: armDeletionSpan(source, span), text: '' });
		}
		return edits;
	}

	/** The grammar seams this check reads, or null when one it requires is unset (making the check a no-op). */
	private static function scanOf(plugin: GrammarPlugin): Null<Scan> {
		final seams: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (seams == null) return null;
		final shape: RefShape = plugin.refShape();
		final statementKinds: Array<String> = shape.switchStatementKinds ?? [];
		final openTypes: Array<String> = shape.openSwitchSubjectTypes ?? [];
		if (statementKinds.length == 0 || openTypes.length == 0) return null;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		return provider == null ? null : {
			seams: seams,
			shape: shape,
			statementKinds: statementKinds,
			openTypes: openTypes,
			provider: provider
		};
	}

	/** One file's scan context, or null when `source` does not parse (a check never throws on bad input). */
	private static function contextOf(scan: Scan, plugin: GrammarPlugin, file: String, source: String, index: SymbolIndex): Null<Ctx> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		return tree == null ? null : {
			scan: scan,
			root: tree,
			declaredTypes: scan.provider.declaredTypes(source),
			index: index,
			file: file
		};
	}

	/** Every deletable trailing arm in `ctx.root`, spanned at the arm, in document order. */
	private static function collect(ctx: Ctx, source: String): Array<Span> {
		final out: Array<Span> = [];
		walk(ctx, ctx.root, source, out);
		return out;
	}

	/** Walk the whole tree so a nested switch is reached too, never descending into a reification subtree. */
	private static function walk(ctx: Ctx, node: QueryNode, source: String, out: Array<Span>): Void {
		if (ctx.scan.seams.opaqueKinds.contains(node.kind)) return;
		if (ctx.scan.statementKinds.contains(node.kind)) {
			final span: Null<Span> = candidateFor(ctx, node, source);
			if (span != null) out.push(span);
		}
		for (child in node.children) walk(ctx, child, source, out);
	}

	/** `switchNode`'s trailing arm when every gate admits it, or null — the type doc says what each gate defends. */
	private static function candidateFor(ctx: Ctx, switchNode: QueryNode, source: String): Null<Span> {
		final kids: Array<QueryNode> = switchNode.children;
		if (kids.length < MIN_SWITCH_CHILDREN) return null;
		final seams: CaseSeams = ctx.scan.seams;
		final arm: QueryNode = kids[kids.length - 1];
		final isDefault: Bool = seams.defaultBranchKind != null && arm.kind == seams.defaultBranchKind;
		if (!isDefault && arm.kind != seams.caseBranchKind) return null;
		if (!armSilent(seams, arm, isDefault)) return null;
		final conditional: Null<String> = seams.conditionalKind;
		for (i in 1...kids.length - 1) {
			final sibling: QueryNode = kids[i];
			if (conditional != null && sibling.kind == conditional) return null;
			if (isOpenBranch(seams, sibling)) return null;
		}
		final armSpan: Null<Span> = arm.span;
		final prevSpan: Null<Span> = kids[kids.length - 2].span;
		final switchSpan: Null<Span> = switchNode.span;
		if (armSpan == null || prevSpan == null || switchSpan == null) return null;
		// The deletion starts at the newline ENDING the previous arm's line, so a trailing `// …` on
		// THAT line is out of its reach and out of the scan; everything from there to the closing brace
		// is text the deletion sweeps away, or strands on a node it does not document. When the two
		// arms share a line there is no such newline and the wider bound stands.
		final lineBreak: Int = source.indexOf('\n', prevSpan.to);
		final scanFrom: Int = lineBreak < 0 || lineBreak > armSpan.from ? prevSpan.to : lineBreak;
		if (CheckScan.hasCommentMarker(source, scanFrom, switchSpan.to)) return null;
		return subjectOpen(ctx, kids[0]) ? armSpan : null;
	}

	/**
	 * Whether `arm` MATCHES AND DOES NOTHING: an empty body, no guard, no binding, and no pattern
	 * shape this scan cannot reason about (`CasePatternScan.patternsModellable`).
	 *
	 * The macro-reification gate is NOT redundant with the tree walk: the walk refuses to DESCEND
	 * into a reification, but `case macro x:` puts one inside a PATTERN of a switch the walk has
	 * already reached. A conditional-compilation gate WOULD be redundant — an `#if` among the arms
	 * projects as a SIBLING of them (`candidateFor` refuses that) and one inside a label projects as
	 * an expression kind of its own that `binders` cannot model, so neither can sit in a candidate.
	 */
	private static function armSilent(seams: CaseSeams, arm: QueryNode, isDefault: Bool): Bool {
		if (CasePatternScan.containsAnyKind(arm, seams.opaqueKinds)) return false;
		if (isDefault) return arm.children.length == 0;
		final run: Array<QueryNode> = CasePatternScan.patternRun(seams, arm);
		if (run.length == 0 || CasePatternScan.guardOf(seams, arm, run.length) != null) return false;
		final bound: Null<Array<PatternBinder>> = CasePatternScan.binders(seams, arm);
		if (bound == null || bound.length != 0) return false;
		if (!CasePatternScan.patternsModellable(seams, arm)) return false;
		// No guard was accepted above, so the pattern run IS the whole label and anything past it is a
		// body statement.
		return arm.children.length == run.length;
	}

	/**
	 * Whether `branch` can still match a value every arm above it declined — a `default:`, a bare `_`,
	 * or a WHOLE-pattern capture binder (`case x:` / `case var x:`), which matches everything the same
	 * way. A pattern shape `CasePatternScan` cannot model counts as open too, and a guard on the run is
	 * deliberately ignored: reading an arm as a catch-all only ever REFUSES a candidate, and a refusal
	 * costs nothing but a finding.
	 *
	 * One shape it does NOT recognise: a PARENTHESISED wildcard, `case (_):`, whose pattern projects
	 * a paren node rather than the identifier. The leak is benign — an arm under an unrecognised
	 * catch-all is unreachable, so deleting it is behaviour-identical anyway — and the same blind
	 * spot pre-exists in `CasePatternScan.isCatchAll`, which is where it would be fixed for both.
	 */
	private static function isOpenBranch(seams: CaseSeams, branch: QueryNode): Bool {
		if (seams.defaultBranchKind != null && branch.kind == seams.defaultBranchKind) return true;
		if (branch.kind != seams.caseBranchKind) return false;
		final bound: Null<Array<PatternBinder>> = CasePatternScan.binders(seams, branch);
		if (bound == null) return true;
		for (binder in bound) if (binder.whole) return true;
		final run: Array<QueryNode> = CasePatternScan.patternRun(seams, branch);
		for (pattern in run) if (pattern.kind == seams.plainCasePatternKind && pattern.children.length == 1) {
			final only: QueryNode = pattern.children[0];
			if (only.kind == seams.identKind && only.name == seams.wildcardPatternName) return true;
		}
		return false;
	}

	/**
	 * Whether `subject`'s type is one the compiler never exhaustiveness-checks a statement switch
	 * against. An unresolved type reads as null and REFUSES — the whitelist IS the deletion's proof, so
	 * "unknown" must never pass it.
	 *
	 * No paren unwrapping: `switch (x)` does not wrap its subject, the parentheses belong to the
	 * switch's own statement form (`SwitchStmt` vs `SwitchStmtBare`). Only a doubly-parenthesised
	 * `switch ((x))` projects a paren node, and that resolves to null here and refuses — the safe
	 * direction, at the cost of one exotic shape nobody writes.
	 */
	private static function subjectOpen(ctx: Ctx, subject: QueryNode): Bool {
		final nominal: Null<String> = RefactorSupport.valueTypeNominal(
			subject, ctx.root, ctx.scan.shape, ctx.declaredTypes, ctx.index, ctx.file
		);
		return nominal != null && ctx.scan.openTypes.contains(nominal);
	}

	/**
	 * The region deleting `arm` removes: its own line's leading blanks and the newline before it
	 * (`CheckScan.lineDeletionSpan`), with the arm's own TRAILING blanks handed back.
	 *
	 * A switch's LAST arm absorbs the whitespace between its final token and the closing brace into
	 * its span, and removing that too would butt the brace against whatever ends the PREVIOUS line —
	 * where a `// …` would swallow it and the result would not parse. Trimming the end is what lets
	 * the comment gate stop at the newline ending that line instead of refusing every trailing
	 * comment on it.
	 */
	private static function armDeletionSpan(source: String, arm: Span): Span {
		var to: Int = arm.to;
		while (to > arm.from) {
			final c: Int = StringTools.fastCodeAt(source, to - 1);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) break;
			to--;
		}
		return CheckScan.lineDeletionSpan(source, new Span(arm.from, to));
	}

}

/** The grammar-level seams the check reads once per run — any one missing makes it a no-op. */
private typedef Scan = {
	final seams: CaseSeams;
	final shape: RefShape;

	/** The STATEMENT-position switch kinds — the gate that keeps expression switches out. */
	final statementKinds: Array<String>;

	/** The subject type names free of exhaustiveness checking (`RefShape.openSwitchSubjectTypes`). */
	final openTypes: Array<String>;
	final provider: TypeInfoProvider;
};

/** One file's scan context: the grammar seams plus everything resolving that file's switch subjects needs. */
private typedef Ctx = {
	final scan: Scan;
	final root: QueryNode;
	final declaredTypes: Map<Int, String>;
	final index: SymbolIndex;
	final file: String;
};
