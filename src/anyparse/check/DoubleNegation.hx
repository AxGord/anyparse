package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a double logical negation `!!x` — a not-node directly wrapping another. In Haxe
 * `!` already yields `Bool`, so the pair is redundant. `Severity.Info`; `fix` strips the pair (`!!x` → `x`,
 * `!!!x` → `!x`), but only for a provably non-null operand: `!!null` is
 * `false` where `null` is not, so an operand reaching a nullable-access
 * kind is reported, never auto-stripped.
 *
 * ## Grammar-agnostic
 *
 * The logical-not kind comes from `RefShape.notKind` (unset → no-op). The OUTERMOST not of
 * a chain is flagged once; the check does not descend into it. Macro-reification subtrees
 * (`RefShape.opaqueKinds`) are not descended into either — a `!!x` that exists only as
 * reified macro source is generated code, not authored style, and is left alone.
 */
@:nullSafety(Strict)
final class DoubleNegation implements Check {

	public function new() {}

	public function id(): String {
		return 'double-negation';
	}

	public function description(): String {
		return 'a redundant double logical negation (!!x)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, seams.notKind, seams.opaqueKinds);
		}
		return violations;
	}

	/**
	 * Strip each flagged redundant negation pair down to one fewer `!` — `!!x` → `x`,
	 * `!!!x` → `!x`. An odd-length chain still leaves a leading `!`, so its result is a
	 * definite Bool regardless of the operand and is always safe; the even reduction to a
	 * bare operand is emitted only when that operand is provably non-null (its subtree
	 * reaches no `nullableOperandKinds`), since `!!null` is `false` where `null` is not.
	 * Unset `notKind` makes `fix` a no-op.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(
				plugin, source, violations, [seams.notKind],
				(node, span) -> negationEdit(node, span, seams.notKind, seams.nullableKinds, source)
			);
	}

	/**
	 * Walk `node`; flag a not directly wrapping another not, then STOP descending into it.
	 * A macro-reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, notKind: String, opaqueKinds: Array<String>): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (node.kind == notKind && node.children.length == 1 && node.children[0].kind == notKind) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'double-negation',
					severity: Severity.Info,
					message: 'redundant double negation'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, notKind, opaqueKinds);
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		for (k in nullableKinds) if (RefactorSupport.subtreeContainsKind(operand, k)) return true;
		return false;
	}


	/** Resolve the not / opaque / nullable-operand seam kinds, or null when `notKind` is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final notKind: Null<String> = shape.notKind;
		if (notKind == null) return null;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final nullSafeKind: Null<String> = shape.nullSafeAccessKind;
		final nullableKinds: Array<String> = shape.nullableOperandKinds ?? (nullSafeKind != null ? [nullSafeKind] : []);
		return { notKind: notKind, opaqueKinds: opaqueKinds, nullableKinds: nullableKinds };
	}


	/**
	 * The strip edit for one flagged double-negation pair, or null when it cannot be
	 * rewritten: the indexed node isn't a not-wrapping-not, or the fully-stripped
	 * operand isn't provably non-null (see `fix`'s doc for the `!!null` caveat).
	 */
	private static function negationEdit(
		node: QueryNode, span: Span, notKind: String, nullableKinds: Array<String>, source: String
	): Null<{ span: Span, text: String }> {
		if (node.children.length != 1 || node.children[0].kind != notKind) return null;
		final inner: QueryNode = node.children[0];
		if (inner.children.length != 1) return null;
		final operand: QueryNode = inner.children[0];
		if (operand.kind != notKind && operandIsNullable(operand, nullableKinds)) return null;
		final operandSpan: Null<Span> = operand.span;
		return operandSpan == null ? null : { span: span, text: source.substring(operandSpan.from, operandSpan.to) };
	}

}

/** The resolved seams `DoubleNegation` reads in both `run` and `fix`. */
private typedef Seams = {
	final notKind: String;
	final opaqueKinds: Array<String>;
	final nullableKinds: Array<String>;
};
