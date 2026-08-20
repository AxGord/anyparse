package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a double logical negation `!!x` — a not-node wrapping another, through any
 * parentheses between them (`!(!x)` is the same redundancy, spelled longer). In Haxe
 * `!` already yields `Bool`, so the pair is redundant. `Severity.Info`; `fix` strips the pair (`!!x` → `x`,
 * `!!!x` → `!x`, `!(!x)` → `x`), but only for a provably non-null operand: `!!null` is
 * `false` where `null` is not, so an operand reaching a nullable-access
 * kind is reported, never auto-stripped.
 *
 * The stripped text is the inner operand's own SOURCE, parentheses included
 * (`!(!(a && b))` → `(a && b)`), so the result needs no precedence analysis of its own: the
 * operand already bound tightly enough to sit under a `!`, and a redundant surviving pair is
 * `redundant-parens`' business on the next pass.
 *
 * ## Grammar-agnostic
 *
 * The logical-not and parenthesis kinds come from `RefShape.notKind` / `RefShape.parenKind`
 * (an unset `notKind` → no-op; an unset `parenKind` → the bare `!!x` shape only). The
 * OUTERMOST not of a chain is flagged once; the check does not descend into it.
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into either — a
 * `!!x` that exists only as reified macro source is generated code, not authored style, and
 * is left alone.
 *
 * A not over a `&&` / `||` COMPOUND (`!(!a || b)`), or over a single COMPARISON (`!(x < 0)`),
 * is a different rewrite — De Morgan or an operator flip, both behind a worth gate — and
 * belongs to `simplify-negated-compound`. That rule's operand whitelist excludes the not-kind
 * outright, so the two shapes stay disjoint and neither ever claims the other's node.
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
		final seams: Null<Seams> = resolveSeams(plugin, files);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, tree, entry.source, seams);
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
		if (violations.length == 0) return [];
		final seams: Null<Seams> = resolveSeams(plugin, [{ file: violations[0].file, source: source }]);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [seams.notKind], (node, span) -> negationEdit(node, span, seams, source));
	}

	/**
	 * Walk `node`; flag a not wrapping another not (parentheses transparent), then STOP
	 * descending into it. A macro-reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(
		out: Array<Violation>, file: String, root: QueryNode, node: QueryNode, source: String, seams: Seams
	): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (innerNotOf(node, seams) != null && builtinNot(node, file, root, source, seams)) {
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
		for (c in node.children) walk(out, file, root, c, source, seams);
	}

	/**
	 * The inner not `node` redundantly negates — parentheses between the two unwrapped — or
	 * null when `node` is not a not, or its operand is anything else. `!(!x)` and `!!x` are the
	 * same redundancy, so both answer here; an unset `parenKind` leaves only the bare form.
	 */
	private static function innerNotOf(node: QueryNode, seams: Seams): Null<QueryNode> {
		if (node.kind != seams.notKind || node.children.length != 1) return null;
		var inner: QueryNode = node.children[0];
		final parenKind: Null<String> = seams.parenKind;
		while (parenKind != null && inner.kind == parenKind && inner.children.length == 1) inner = inner.children[0];
		return inner.kind == seams.notKind ? inner : null;
	}

	/**
	 * Whether the `!` pair this rule would strip is the language own. `!!x` is redundant because
	 * the built-in `!` is an involution on `Bool`; an abstract declaring `@:op(!A)` need not be
	 * one, and then stripping the pair changes the value while the program still compiles (such a
	 * type usually carries a `to Bool` too). So an overloaded `!` makes the FINDING false, not
	 * merely the fix unsafe, and the site is left unreported.
	 *
	 * The chain is judged as a whole: `verdictFor` flattens same-kind children, so `!!!x` asks
	 * about every `!` in it at once. On a tree that overloads nothing this is one map lookup —
	 * see `OperatorSelection`.
	 */
	private static function builtinNot(not: QueryNode, file: String, root: QueryNode, source: String, seams: Seams): Bool {
		final selection: Null<OperatorSelection> = seams.selection;
		final kinds: Array<String> = [seams.notKind];
		if (selection == null || !selection.declared(kinds)) return true;
		return selection.verdictFor(not, kinds, selection.typesFor(file, source, root)).match(Builtin);
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		return nullableKinds.exists(k -> RefactorSupport.subtreeContainsKind(operand, k));
	}


	/** Resolve the not / opaque / nullable-operand seam kinds, or null when `notKind` is unset. */
	private static function resolveSeams(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final notKind: Null<String> = shape.notKind;
		if (notKind == null) return null;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final nullSafeKind: Null<String> = shape.nullSafeAccessKind;
		final nullableKinds: Array<String> = shape.nullableOperandKinds ?? (nullSafeKind != null ? [nullSafeKind] : []);
		return {
			notKind: notKind,
			parenKind: shape.parenKind,
			opaqueKinds: opaqueKinds,
			nullableKinds: nullableKinds,
			selection: OperatorSelection.of(plugin, files)
		};
	}


	/**
	 * The strip edit for one flagged double-negation pair, or null when it cannot be
	 * rewritten: the indexed node isn't a not-wrapping-not, or the fully-stripped
	 * operand isn't provably non-null (see `fix`'s doc for the `!!null` caveat).
	 */
	private static function negationEdit(node: QueryNode, span: Span, seams: Seams, source: String): Null<{ span: Span, text: String }> {
		final inner: Null<QueryNode> = innerNotOf(node, seams);
		if (inner == null || inner.children.length != 1) return null;
		final operand: QueryNode = inner.children[0];
		if (operand.kind != seams.notKind && operandIsNullable(operand, seams.nullableKinds)) return null;
		final operandSpan: Null<Span> = operand.span;
		return operandSpan == null ? null : { span: span, text: source.substring(operandSpan.from, operandSpan.to) };
	}

}

/** The resolved seams `DoubleNegation` reads in both `run` and `fix`. */
private typedef Seams = {
	final notKind: String;

	/** The parenthesis kind the redundancy scan reads THROUGH (`!(!x)`), or null when the grammar has none — then only the bare `!!x` shape is seen. */
	final parenKind: Null<String>;

	final opaqueKinds: Array<String>;
	final nullableKinds: Array<String>;

	/**
	 * The run OPERATOR table, or null when the grammar declares no operator-overload annotation —
	 * the proof that the stripped `!` is an involution at all (`builtinNot`).
	 */
	final selection: Null<OperatorSelection>;
};
