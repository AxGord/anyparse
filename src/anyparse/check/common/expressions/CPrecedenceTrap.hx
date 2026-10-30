package anyparse.check.common.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.query.SymbolIndex;

using StringTools;

/**
 * Flags a bare operand the grammar groups differently from the C-family precedence a reader carries over — Haxe reads
 * `flags & mask != 0` as `(flags & mask) != 0` and `4 | 1 & 1` as `(4 | 1) & 1`, C reads both the other way — and
 * parenthesizes it the way the parser already groups it, so the edit changes no value. Which slots diverge is the
 * grammar's answer (`RefShape.cPrecedenceDivergences`).
 *
 * A nested divergent operand is fixed one pass after its outer one: only the outermost of overlapping findings is
 * rewritten, so two edits never overlap.
 */
@:nullSafety(Strict)
final class CPrecedenceTrap extends RuleBase {

	private static inline final RULE_ID: String = 'c-precedence-trap';

	public function new() {
		super(
			RULE_ID, 'a bare operand grouped differently than C-family precedence reads it (x & m != 0, a | b & c, a * b % c)',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final table: Array<PrecedenceDivergence> = plugin.refShape().cPrecedenceDivergences ?? [];
		return table.length == 0
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				for (operand in divergentOperands(tree, table)) {
					final span: Null<Span> = operand.span;
					if (span != null) out.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Warning,
						message: 'C-family precedence groups this bare operand differently: parenthesize it'
					});
				}
			});
	}

	/** Wrap each flagged operand that no other flagged operand encloses in parentheses. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.editsWith(plugin, source, plugin.refShape().cPrecedenceDivergences, (tree, table) -> {
			final byKey: Map<String, QueryNode> = [];
			for (operand in divergentOperands(tree, table)) {
				final span: Null<Span> = operand.span;
				if (span != null) byKey['${span.from}:${span.to}'] = operand;
			}
			final spans: Array<Span> = [];
			RunScan.eachMatched(violations, byKey, (_, span) -> spans.push(span));
			// A node's span may run over the whitespace after it; the pair closes on the operand's last token.
			return [
				for (span in spans)
					if (!spans.exists(outer -> outer != span && outer.from <= span.from && span.to <= outer.to)) {
						final text: String = source.substring(span.from, span.to).rtrim();
						{ span: new Span(span.from, span.from + text.length), text: '($text)' };
					}
			];
		});
	}

	/** Every operand under `node` that `table` names as divergent in the slot it occupies, in document order. */
	private static function divergentOperands(node: QueryNode, table: Array<PrecedenceDivergence>): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function walk(n: QueryNode): Void {
			if (n.children.length == 2) for (row in table) if (row.hosts.contains(n.kind)) for (slot in row.slots) {
				final operand: QueryNode = n.children[slot];
				if (row.operands.contains(operand.kind)) out.push(operand);
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return out;
	}

}
