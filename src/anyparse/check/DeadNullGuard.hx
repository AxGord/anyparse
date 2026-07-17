package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a null comparison (`x != null` / `x == null`) whose operand is already
 * provably non-null **by flow** on every path reaching it — a dead guard: the
 * controlled branch is constant (always taken for `!=`, never for `==`).
 *
 * ## Flow-only — complements the point-wise checks, never duplicates them
 *
 * Non-null-ness is established by `NullFlow` purely from flow events: an earlier
 * `if (x != null)` narrowing this path, or a syntactically-non-null assignment
 * (`x = new T()`). It deliberately does NOT seed declared types, and it skips
 * any operand the declared prover `TypeResolver.isProvablyNonNull` already
 * proves non-null — those belong to `unnecessary-null-check`. So a redundant
 * null comparison is reported exactly once: by `unnecessary-null-check` when the
 * declared type proves it, by `dead-null-guard` when only the flow does.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty — a join, a loop
 * back-edge, a closure-captured name, a macro subtree — collapses to `Unknown`,
 * so the check reports only a genuinely dead guard, never a load-bearing one.
 *
 * `Severity.Info`; `fix` conservatively drops the dead guard where a safe span rewrite
 * exists — unwrap / delete a sole-condition `if`, or drop a conjunct / disjunct from a
 * homogeneous `&&` / `||` chain — and refuses (leaves a finding) everywhere else. Its
 * proof is FLOW-based (`NullFlow`), never declared-type trust, so a default-null parameter
 * — which the declared prover now exempts too — reaches this check only when flow narrows it.
 */
@:nullSafety(Strict)
final class DeadNullGuard implements Check {

	public function new() {}

	public function id(): String {
		return 'dead-null-guard';
	}

	public function description(): String {
		return 'a null comparison whose operand is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final identKind: Null<String> = shape.identKind;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (equalityKinds.length == 0 || identKind == null || nullLitKind == null) return [];
		final nullLit: String = nullLitKind;
		final ident: String = identKind;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(entry.source) : [];
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (!equalityKinds.contains(node.kind) || node.children.length != 2) return;
				final operand: Null<QueryNode> = NullFlow.nullComparisonOperand(node, ident, nullLit);
				final span: Null<Span> = node.span;
				if (operand == null || span == null) return;
				final name: Null<String> = operand.name;
				if (name == null) return;
				// Owned by `unnecessary-null-check` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(operand, root, shape, declaredTypes)) return;
				if (facts.nonNull(name)) violations.push({
					file: entry.file,
					span: span,
					rule: 'dead-null-guard',
					severity: Severity.Info,
					message: 'null check is redundant — operand is already non-null on this path'
				});
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.simplifyNullComparisonFixes(plugin, source, violations);
	}

}
