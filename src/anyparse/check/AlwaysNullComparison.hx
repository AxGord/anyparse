package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a null comparison (`x == null` / `x != null`) whose operand is provably
 * **null** by flow on every path reaching it — a constant comparison: `== null`
 * is always true, `!= null` always false, so the controlled branch is dead.
 *
 * The mirror of `dead-null-guard` (which flags a non-null operand): there a
 * `!= null` is always true; here a known-null operand makes `== null` always
 * true. Null-ness comes purely from `NullFlow`'s flow events — an earlier
 * `x = null` / `var x = null`, or the `== null` arm of a guard narrowing this
 * path. There is no point-wise twin: no declared type is "always null" (a
 * `Null<T>` is merely nullable), so unlike `dead-null-guard` it has nothing to
 * defer to and no `isProvablyNonNull` skip.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty — a join, a loop
 * back-edge, a closure-captured name, a macro subtree — collapses to `Unknown`,
 * so only a genuinely constant comparison is reported.
 *
 * `Severity.Info`; report-only — the correct rewrite (drop the dead branch,
 * keep the live one) is context-dependent, mirroring `dead-null-guard`.
 */
@:nullSafety(Strict)
final class AlwaysNullComparison implements Check {

	public function new() {}

	public function id(): String {
		return 'always-null-comparison';
	}

	public function description(): String {
		return 'a null comparison whose operand is provably null on every path reaching it — the comparison is constant';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		return RunScan.collectWith(files, plugin, NullFlowScan.seamsOf(shape), (entry, tree, s, violations) -> {
			NullFlow.analyze(tree, shape, entry.source, (node, facts) -> {
				final compared: Null<IdentOperand> = NullFlowScan.nullComparedOperand(node, s);
				if (compared == null) return;
				if (facts.isNull(compared.name)) {
					final eqKind: Null<String> = s.eqKind;
					final alwaysTrue: Bool = eqKind != null && node.kind == eqKind;
					violations.push({
						file: entry.file,
						span: compared.span,
						rule: 'always-null-comparison',
						severity: Severity.Info,
						message: alwaysTrue
							? 'null comparison is always true — operand is null on every path'
							: 'null comparison is always false — operand is null on every path'
					});
				}
			});
		});
	}

	/**
	 * No edits — and DELIBERATELY not a `NoAutofix` declaration, because one is writable and nobody has
	 * written it. That is the honest third answer, and stamping the class instead would have said the
	 * rewrite cannot be mechanised when the mirror rule mechanises it today.
	 *
	 * The mirror is `dead-null-guard`: same shape, opposite proof, and its `fix` is one line —
	 * `CheckScan.simplifyNullComparisonFixes`, which is `simplifyConditionFixes(plugin, source,
	 * violations, [eq, notEq], node -> node.kind == notEq)`. The `alwaysTrueOf` predicate is the only
	 * half that differs here: a provably-null operand makes `== null` true where a provably-non-null one
	 * makes `!= null` true, so the dual is `node -> node.kind == eq` over the same two kinds. The shared
	 * helper already carries the always-FALSE direction as a first-class case (`conditionEdit` picks
	 * `orKind` over `andKind` and hands `alwaysTrue` straight to `ifShapeEdit`), so nothing is missing
	 * below this seam.
	 *
	 * What stops it being a one-line slice is the blast radius, not the mechanism: `dead-null-guard` is a
	 * `RiskyFix` and this one is not, so the same edits would land unverified on a run with no compiler
	 * oracle.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}
