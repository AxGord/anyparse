package anyparse.check;

import anyparse.check.CasePatternScan.CaseSeams;
import anyparse.check.CasePatternScan.PatternBinder;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a switch arm whose body its IMMEDIATE NEIGHBOUR already carries, in the two
 * shapes where the duplication can be removed without changing what any value
 * matches. `Info`, with a `--fix`:
 *
 * - SUBSUME — the next arm is a CATCH-ALL (`case _:` / `default:`) with the same
 *   body, so this arm only routes its values to a body they would reach anyway. The
 *   arm is DELETED. `case 'User': t(k); case _: t(k);` becomes `case _: t(k);`.
 * - MERGE — the next arm is an ordinary arm with the same body, so the two labels
 *   want to be one. The pair becomes a single or-pattern arm: `case A: r(); case B:
 *   r();` becomes `case A, B: r();`.
 *
 * ADJACENCY is the load-bearing precondition, not a convenience. Removing or merging
 * ACROSS an intervening pattern would reroute every value that intervening arm
 * matches, so a non-adjacent twin is never touched — which also means a chain is
 * folded one neighbour at a time, converging across `--fix` passes (three arms
 * sharing a body merge to one in a single pass, since the two edits are disjoint).
 *
 * ## Why the gates are correctness
 *
 * 1. NEITHER ARM IS GUARDED. A guard may reject, and both rewrites assume the label
 *    alone decides.
 * 2. THE EARLIER ARM BINDS NOTHING, and the merged arm's neighbour binds nothing
 *    either. Two bodies can be byte-identical and still MEAN different things when a
 *    pattern binds: `var x = 1; switch v { case Foo(x): use(x); case _: use(x); }`
 *    reads the binder in the first arm and the OUTER `x` in the second. Requiring an
 *    empty binding set is what makes textual body identity imply behavioural
 *    identity. It also settles or-pattern legality for the merge: Haxe requires every
 *    alternative to bind the same set, and the empty set trivially agrees. A pattern
 *    whose bindings `CasePatternScan` cannot fully model counts as binding, so an
 *    unmodelled shape refuses rather than passes.
 * 3. NO EXTRACTOR in either pattern. An extractor RUNS code while matching, so
 *    deleting an arm — or reordering when its label is evaluated — is observable.
 * 4. NO `null` LITERAL in either pattern. Whether `case _` matches `null` is exactly
 *    the question `nullable-switch-missing-null` exists for, and the answer is
 *    target-dependent, so a `case null:` arm is never subsumed by a wildcard nor
 *    merged into a neighbour that changes when its own null test runs. Refusing the
 *    literal outright is what keeps this rule out of that argument entirely.
 * 5. IDENTICAL BODIES, proved TWICE: the statement lists must be structurally equal
 *    (`RefactorSupport.structurallyEqual`, which compares literal CONTENT, so
 *    `f("a  b")` and `f("a b")` stay distinct) AND their source regions must be equal
 *    after whitespace normalisation (`CheckScan.normalizeSpan`, which a comment
 *    inside either region makes differ). Neither test alone suffices — shape equality
 *    is blind to an interior comment, normalised source collapses whitespace inside
 *    string literals.
 * 6. NO COMMENT in the region the edit DISTURBS. For a subsume that is everything
 *    from the END of the previous arm to the START of the next one — wider than the
 *    deleted arm's own span on BOTH sides, and deliberately: a comment before the arm
 *    would survive the deletion and then document the catch-all instead, and a
 *    trailing `// …` is TRIVIA the span excludes, which the writer re-attaches to
 *    whatever node is left (both were caught folding anyparse's own tree). For a
 *    merge it is the earlier arm's terminator and body plus the later arm's `case`
 *    lead. Text in either region has nowhere to go, or nowhere honest to go.
 * 7. NO CONDITIONAL-COMPILATION REGION and no macro reification in either arm: an
 *    `#if` holds an arm run this scan cannot enumerate, and a reification may splice
 *    code no source scan resolves.
 *
 * ## Exhaustiveness is never lost
 *
 * A subsume deletes an arm only when a catch-all IMMEDIATELY follows it, so the arm
 * list already covered everything and still does. A merge preserves the matched set
 * exactly — the same patterns, written as alternatives of one label. Neither shape
 * can turn an exhaustive `enum` / `enum abstract` switch into a non-exhaustive one,
 * which is why this check needs no compiler oracle.
 *
 * ## Seams and idempotence
 *
 * Detection is seam-driven through `CasePatternScan.seamsOf`; a required kind unset
 * makes the check a no-op, report and fix alike. Candidates whose edits OVERLAP (a
 * merge and a subsume claiming the same middle arm) are reduced to the
 * document-earliest in `fix`, and the loser fires cleanly on the next pass. After a
 * fix the surviving arm has no duplicate neighbour left, so the pass converges.
 */
@:nullSafety(Strict)
final class RedundantCaseBody implements Check {

	private static final RULE_ID: String = 'redundant-case-body';

	/** What separates two alternatives of one label — the writer re-canonicalises the spacing. */
	private static inline final ALTERNATIVE_SEPARATOR: String = ', ';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'a switch arm whose body its immediate neighbour repeats — deletable under a catch-all, mergeable into one or-pattern otherwise';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (seams == null) return [];
		final resolved: CaseSeams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsed == null) continue;
			for (candidate in collect(resolved, parsed, entry.source)) violations.push({
				file: entry.file,
				span: candidate.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: candidate.subsume
					? 'this case body is identical to the catch-all that follows it; the arm is redundant'
					: 'this case body is identical to the next arm\'s; merge the two labels into one case'
			});
		}
		return violations;
	}

	/**
	 * Apply each flagged fold. The candidate set is re-derived from the tree, so a reported
	 * span that no longer names a foldable pair produces no edit; overlapping edits (a merge
	 * and a subsume claiming one middle arm) are reduced to the document-earliest, the loser
	 * firing on the next fixed-point pass.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (seams == null || violations.length == 0) return [];
		final resolved: CaseSeams = seams;
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (parsed == null) return [];
		final byKey: Map<String, Candidate> = [];
		for (candidate in collect(resolved, parsed, source)) byKey['${candidate.span.from}:${candidate.span.to}'] = candidate;

		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final candidate: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (candidate != null) edits.push({ span: candidate.editSpan, text: candidate.editText });
		}
		return disjoint(edits);
	}

	/** Every foldable adjacent pair in `tree`, in document order. */
	private static function collect(seams: CaseSeams, tree: QueryNode, source: String): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(seams, tree, source, out);
		return out;
	}

	/** Walk the whole tree so a nested switch is reached too, never descending into a reification subtree. */
	private static function walk(seams: CaseSeams, node: QueryNode, source: String, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.switchKinds.contains(node.kind)) for (at in 1...node.children.length - 1) {
			final candidate: Null<Candidate> = candidateFor(seams, node, at, source);
			if (candidate != null) out.push(candidate);
		}
		for (child in node.children) walk(seams, child, source, out);
	}

	/** The fold for the pair starting at `switchNode`'s arm `at`, or null when any gate refuses it. */
	private static function candidateFor(seams: CaseSeams, switchNode: QueryNode, at: Int, source: String): Null<Candidate> {
		final first: QueryNode = switchNode.children[at];
		final next: QueryNode = switchNode.children[at + 1];
		if (first.kind != seams.caseBranchKind) return null;
		if (next.kind != seams.caseBranchKind && next.kind != seams.defaultBranchKind) return null;
		if (!armClean(seams, first) || !armClean(seams, next)) return null;
		final firstRun: Array<QueryNode> = CasePatternScan.patternRun(seams, first);
		if (firstRun.length == 0 || CasePatternScan.guardOf(seams, first, firstRun.length) != null) return null;
		final firstBinders: Null<Array<PatternBinder>> = CasePatternScan.binders(seams, first);
		if (firstBinders == null || firstBinders.length != 0) return null;
		final firstBody: Null<Body> = bodyOf(seams, first, firstRun.length);
		final nextBody: Null<Body> = bodyOf(seams, next, patternWidth(seams, next));
		if (firstBody == null || nextBody == null) return null;
		if (!sameBody(source, firstBody, nextBody)) return null;
		final firstSpan: Null<Span> = first.span;
		if (firstSpan == null) return null;
		if (CasePatternScan.isCatchAll(seams, next)) {
			final prev: Null<Span> = switchNode.children[at - 1].span;
			final nextSpan: Null<Span> = next.span;
			// The deletion discards the arm, everything trailing it up to the next arm's first
			// token (a `// …` there is TRIVIA the span excludes, and the writer would re-attach it
			// to a node it never described), and whatever precedes it back to the arm before —
			// text `deletionSpan` sweeps away or strands on an arm it does not document.
			if (prev == null || nextSpan == null) return null;
			if (CheckScan.hasCommentMarker(source, prev.to, nextSpan.from)) return null;
			return {
				span: firstSpan,
				subsume: true,
				editSpan: deletionSpan(source, firstSpan),
				editText: ''
			};
		}
		final nextRun: Array<QueryNode> = CasePatternScan.patternRun(seams, next);
		if (nextRun.length == 0 || CasePatternScan.guardOf(seams, next, nextRun.length) != null) return null;
		final nextBinders: Null<Array<PatternBinder>> = CasePatternScan.binders(seams, next);
		if (nextBinders == null || nextBinders.length != 0) return null;
		final lastPattern: Null<Span> = firstRun[firstRun.length - 1].span;
		final firstOfNext: Null<Span> = nextRun[0].span;
		if (lastPattern == null || firstOfNext == null) return null;
		if (CheckScan.hasCommentMarker(source, lastPattern.to, firstOfNext.from)) return null;
		return {
			span: firstSpan,
			subsume: false,
			editSpan: new Span(lastPattern.to, firstOfNext.from),
			editText: ALTERNATIVE_SEPARATOR
		};
	}

	/**
	 * Whether `arm` holds none of the shapes either rewrite cannot reason about: a
	 * conditional-compilation region, a macro reification, an extractor pattern (which RUNS
	 * code while matching), or a `null` literal (which `case _` does not match).
	 */
	private static function armClean(seams: CaseSeams, arm: QueryNode): Bool {
		final conditional: Null<String> = seams.conditionalKind;
		if (conditional != null && CasePatternScan.containsAnyKind(arm, [conditional])) return false;
		if (CasePatternScan.containsAnyKind(arm, seams.opaqueKinds)) return false;
		for (pattern in CasePatternScan.patternRun(seams, arm)) {
			if (CasePatternScan.containsAnyKind(pattern, seams.extractorKinds)) return false;
			final nullKind: Null<String> = seams.nullLiteralKind;
			if (nullKind != null && CasePatternScan.containsAnyKind(pattern, [nullKind])) return false;
		}
		return true;
	}

	/** How many leading children of `arm` are its label — its pattern run plus a guard, when it has one. */
	private static function patternWidth(seams: CaseSeams, arm: QueryNode): Int {
		final run: Int = CasePatternScan.patternRun(seams, arm).length;
		return CasePatternScan.guardOf(seams, arm, run) == null ? run : run + 1;
	}

	/** `arm`'s body: the statements after its label, and the source region they span (empty when it has none). */
	private static function bodyOf(seams: CaseSeams, arm: QueryNode, skip: Int): Null<Body> {
		final nodes: Array<QueryNode> = arm.children.slice(skip);
		if (nodes.length == 0) return { nodes: nodes, from: 0, to: 0 };
		final head: Null<Span> = nodes[0].span;
		final tail: Null<Span> = nodes[nodes.length - 1].span;
		return head == null || tail == null ? null : { nodes: nodes, from: head.from, to: tail.to };
	}

	/**
	 * Whether two bodies are the SAME body — proved by structural equality of the statement
	 * lists AND by whitespace-normalised source equality. See the type doc for why neither
	 * test alone is enough.
	 */
	private static function sameBody(source: String, a: Body, b: Body): Bool {
		if (a.nodes.length != b.nodes.length) return false;
		if (a.nodes.length == 0) return true;
		for (i in 0...a.nodes.length) if (!RefactorSupport.structurallyEqual(a.nodes[i], b.nodes[i])) return false;
		return CheckScan.normalizeSpan(source, a.from, a.to).norm == CheckScan.normalizeSpan(source, b.from, b.to).norm;
	}

	/**
	 * The deleted arm's span extended backward over its own line's leading indentation and
	 * the newline before it, so the deletion removes the whole line rather than leaving a
	 * blank one. It stops at the first non-whitespace, which is why `candidateFor` refuses
	 * outright when a comment stands anywhere between the previous arm and the next one:
	 * a comment BEFORE the arm would survive to document the catch-all instead, and one
	 * TRAILING it is trivia outside the span that the writer would re-attach elsewhere.
	 */
	private static function deletionSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final ch: String = source.charAt(from - 1);
			if (ch != ' ' && ch != '\t') break;
			from--;
		}
		if (from > 0 && source.charAt(from - 1) == '\n') {
			from--;
			if (from > 0 && source.charAt(from - 1) == '\r') from--;
		}
		return new Span(from, span.to);
	}

	/** `edits` with every span that overlaps an earlier one dropped — the loser refires next pass. */
	private static function disjoint(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final kept: Array<{ span: Span, text: String }> = [];
		var lastTo: Int = -1;
		for (edit in sorted) if (edit.span.from >= lastTo) {
			kept.push(edit);
			lastTo = edit.span.to;
		}
		return kept;
	}

}

/** One foldable pair: the arm reported, which shape folds it, and the single edit that folds it. */
private typedef Candidate = {
	final span: Span;

	/** Whether the fold DELETES the arm (a catch-all follows) rather than merging its label into the next. */
	final subsume: Bool;
	final editSpan: Span;
	final editText: String;
};

/** One arm's body: its statement nodes and the source region they span. */
private typedef Body = {
	final nodes: Array<QueryNode>;
	final from: Int;
	final to: Int;
};
