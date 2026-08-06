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
 * Flags a case-pattern BINDER that neither the arm's guard nor its body ever reads,
 * and replaces it with the wildcard — `case _data:` becomes `case _:`,
 * `case Node(x, y): use(y);` becomes `case Node(_, y): use(y);`, `case var q:`
 * becomes `case _:`, and an unread `=`-capture head is dropped outright
 * (`case q = P(v):` becomes `case P(v):`). `Warning`, the same rank
 * `unused-local` and `unused-parameter` carry: a bound name nothing reads is dead
 * weight, and spelling it `_` is what tells the next reader the slot is
 * deliberately ignored.
 *
 * ## What counts as a read
 *
 * Everything. A binder is UNUSED only when the number of nodes MENTIONING its name
 * anywhere in the whole arm — the pattern, the guard, the body, a nested switch's
 * own labels — equals the number of BINDER occurrences the pattern scan found. So a
 * guard read (`case x if (x > 0):`), a `'$x'` string-interpolation read, and a
 * re-binding of the same name in a nested arm all block the fix, and a name the
 * scan cannot fully account for blocks it too. The count is deliberately coarse:
 * over-counting can only ever REFUSE.
 *
 * ## Or-patterns are replaced together
 *
 * Haxe requires every alternative of `case A(x), B(x):` to bind the SAME set of
 * names, so an unread `x` is unread in all of them and must lose its binding in all
 * of them at once. Grouping by NAME rather than by occurrence is what makes that
 * automatic: one finding carries every occurrence's edit, and `case A(_), B(_):`
 * stays legal. The same grouping owns the comment gate — a capture-head drop whose
 * `x = ` run holds a comment refuses the whole group, never one alternative.
 *
 * ## The two gates the spelling assumption needs
 *
 * A bare lowercase identifier reads as a capture binder (the assumption
 * `CasePatternScan` documents, shared with `prefer-case-guard` and
 * `collapse-nested-switch`), but Haxe resolves several kinds of CONSTANT
 * unqualified in a pattern too — a lowercase `enum` / `enum abstract` value, and any
 * `static inline` field, both from inside its own type and through a static import.
 * `case one:` may therefore denote a constant, and widening a constant to `_` would
 * change what the arm matches while still COMPILING — the one failure mode a
 * compiler oracle could not catch, which is why the gates below ARE the rule's
 * safety rather than a verifier. Both apply only to BARE identifiers (a `var x`
 * capture and an `=`-capture head are binders by syntax, so neither gate touches
 * them):
 *
 * 1. NO DECLARED CONSTANT of that name. `CasePatternScan.declaredConstantNames`
 *    collects, from every file in the lint scope, each member of an
 *    exhaustiveness-checked type, each member of any abstract or alias declaration
 *    (which is what reaches a legacy `@:enum abstract`, projected as a plain
 *    abstract with no marker the scan can read), and each STATIC member of any
 *    type. A name in that set is refused. What survives is a constant declared
 *    OUTSIDE the lint scope — a library's lowercase enum value, or a static import
 *    from one — so a single-file run refuses LESS than a project-wide one, and
 *    project-wide is the intended scope for `--fix`.
 * 2. A binder that IS the whole pattern must sit in the LAST arm of its switch, and
 *    be that arm's only pattern. Under the binder reading the arm is a catch-all
 *    and `_` is exactly equivalent: Haxe compiles a bare capture to a wildcard plus
 *    a binding, so the two decide identically for every subject, `null` included
 *    (checked on `--interp` and `-js`). Under the constant reading, the arm list
 *    still compiles today, which for an `enum` / `enum abstract` subject means the
 *    compiler proved it EXHAUSTIVE — so at the last position `_` covers precisely
 *    the values the constant did, and nothing else can reach it. Both readings
 *    therefore agree, without knowing which one holds. A non-final position has no
 *    such agreement (`case one: a; case two: b;` would turn `two` into dead code),
 *    so it is refused; a subject the compiler does NOT check for exhaustiveness (a
 *    `String` switch) has no such agreement either, and that is precisely the
 *    residual gate 1 has to carry.
 *
 * A NESTED bare identifier (a constructor argument, an array element, a structure
 * field's value) rests on the spelling assumption plus gate 1 alone; that is the
 * rule's one documented residual. It is NOT the residual the sibling rules carry:
 * `prefer-case-guard` excludes bare lowercase identifiers from its whitelist
 * outright, and its own residual is a hard compile error rather than a silent
 * behaviour change. Widening the constant scan is what shrinks this one; nothing
 * structural can close it.
 *
 * ## Seams and idempotence
 *
 * Detection is seam-driven through `CasePatternScan.seamsOf`; a required kind unset
 * makes the check a no-op, report and fix alike. An arm holding a
 * conditional-compilation region or a macro reification is skipped outright — the
 * first because its arm run cannot be enumerated, the second because a splice may
 * carry a read no source scan resolves. After the fix every flagged name is spelled
 * `_`, which is never a binder, so a second pass finds nothing.
 */
@:nullSafety(Strict)
final class UnusedCaseBinder implements Check {

	private static final RULE_ID: String = 'unused-case-binder';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a switch case-pattern binder never read in the arm\'s guard or body — replaceable with _';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (seams == null) return [];
		final resolved: CaseSeams = seams;
		final parsed: Array<{ file: String, source: String, tree: QueryNode }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) parsed.push({ file: entry.file, source: entry.source, tree: tree });
		}
		final constants: Array<String> = CasePatternScan.declaredConstantNames(resolved, [for (p in parsed) p.tree]);
		final violations: Array<Violation> = [];
		for (entry in parsed) for (candidate in collect(resolved, entry.tree, entry.source, constants)) violations.push({
			file: entry.file,
			span: candidate.span,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'case binder \'${candidate.name}\' is never read; replace it with _'
		});
		return violations;
	}

	/**
	 * Replace every flagged binder with the wildcard. The candidate set is re-derived from
	 * the tree, so a reported span that no longer names an unread binder produces no edit.
	 * The declared-constant set is rebuilt from this ONE file and is therefore a SUBSET of
	 * the one `run` used, so `collect` here can admit candidates `run` refused — harmless,
	 * because only a candidate whose span a violation reports is ever applied, and every
	 * reported span came from the stricter set.
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
		final tree: QueryNode = parsed;
		final constants: Array<String> = CasePatternScan.declaredConstantNames(resolved, [tree]);
		final byKey: Map<String, Candidate> = [];
		for (candidate in collect(resolved, tree, source, constants)) byKey['${candidate.span.from}:${candidate.span.to}'] = candidate;

		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final candidate: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (candidate != null) for (edit in candidate.edits) edits.push(edit);
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Every unread binder in `tree`, in document order. */
	private static function collect(seams: CaseSeams, tree: QueryNode, source: String, constants: Array<String>): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(seams, tree, source, constants, out);
		return out;
	}

	/**
	 * Walk the whole tree so a switch nested in another switch's arm is reached too, but
	 * never DESCEND into a macro-reification subtree: a splice inside one may carry a read
	 * of the binder that no source scan can see.
	 */
	private static function walk(seams: CaseSeams, node: QueryNode, source: String, constants: Array<String>, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.switchKinds.contains(node.kind)) for (at in 1...node.children.length)
			armCandidates(seams, node, at, source, constants, out);
		for (child in node.children) walk(seams, child, source, constants, out);
	}

	/** Every unread binder of `switchNode`'s arm at `at`, grouped by name so an or-pattern is replaced as one. */
	private static function armCandidates(
		seams: CaseSeams, switchNode: QueryNode, at: Int, source: String, constants: Array<String>, out: Array<Candidate>
	): Void {
		final arm: QueryNode = switchNode.children[at];
		if (arm.kind != seams.caseBranchKind) return;
		final conditional: Null<String> = seams.conditionalKind;
		if (conditional != null && CasePatternScan.containsAnyKind(arm, [conditional])) return;
		if (CasePatternScan.containsAnyKind(arm, seams.opaqueKinds)) return;
		final found: Null<Array<PatternBinder>> = CasePatternScan.binders(seams, arm);
		if (found == null) return;
		final all: Array<PatternBinder> = found;
		final last: Bool = at == switchNode.children.length - 1;
		final single: Bool = CasePatternScan.patternRun(seams, arm).length == 1;
		final seen: Array<String> = [];
		for (binder in all) {
			final name: String = binder.name;
			if (seen.contains(name)) continue;
			seen.push(name);
			final group: Array<PatternBinder> = all.filter(b -> b.name == name);
			if (CasePatternScan.mentionCount(seams, arm, name) != group.length) continue;
			if (!admissible(group, constants, last, single) || !commentFree(group, source)) continue;
			final span: Null<Span> = group[0].node.span;
			if (span == null) continue;
			final reported: Span = span;
			out.push({
				span: reported,
				name: name,
				edits: [for (binder in group) { span: binder.editSpan, text: binder.editText }]
			});
		}
	}

	/**
	 * Whether every occurrence of one name may lose its binding — the two gates the bare
	 * spelling assumption needs, stated on the whole group so an or-pattern cannot pass on
	 * the strength of its least constrained alternative.
	 */
	private static function admissible(group: Array<PatternBinder>, constants: Array<String>, last: Bool, single: Bool): Bool {
		for (binder in group) {
			if (!binder.bare) continue;
			if (constants.contains(binder.name)) return false;
			if (binder.whole && !(last && single)) return false;
		}
		return true;
	}

	/**
	 * Whether no occurrence's edit would DISCARD a comment. Only a capture-head drop does —
	 * its edit deletes the `x = ` run rather than replacing a name — and it refuses the whole
	 * NAME GROUP, never one occurrence: an or-pattern must lose its binding in every
	 * alternative or in none.
	 */
	private static function commentFree(group: Array<PatternBinder>, source: String): Bool {
		for (binder in group) if (binder.editText == '' && CheckScan.hasCommentMarker(source, binder.editSpan.from, binder.editSpan.to))
			return false;
		return true;
	}

}

/** One unread binder name: the span reported, and the edit per occurrence that unbinds it. */
private typedef Candidate = {
	final span: Span;
	final name: String;
	final edits: Array<{ span: Span, text: String }>;
};
