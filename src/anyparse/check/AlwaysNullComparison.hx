package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final identKind: Null<String> = shape.identKind;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (equalityKinds.length == 0 || identKind == null || nullLitKind == null) return [];
		final nullLit: String = nullLitKind;
		final ident: String = identKind;
		final eqKind: Null<String> = shape.eqKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			NullFlow.analyze(tree, shape, (node, facts) -> {
				if (!equalityKinds.contains(node.kind) || node.children.length != 2) return;
				final operand: Null<QueryNode> = NullFlow.nullComparisonOperand(node, ident, nullLit);
				final span: Null<Span> = node.span;
				if (operand == null || span == null) return;
				final name: Null<String> = operand.name;
				if (name == null) return;
				if (facts.isNull(name)) {
					final alwaysTrue: Bool = eqKind != null && node.kind == eqKind;
					violations.push({
						file: entry.file,
						span: span,
						rule: 'always-null-comparison',
						severity: Severity.Info,
						message: alwaysTrue
							? 'null comparison is always true — operand is null on every path'
							: 'null comparison is always false — operand is null on every path'
					});
				}
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}
