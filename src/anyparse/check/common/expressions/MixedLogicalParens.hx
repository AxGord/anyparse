package anyparse.check.common.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.query.SymbolIndex;

/**
 * Flags a bare operand of a logical operator that a reader tends to mis-group — `a && b || c`, where `&&` binds tighter
 * than `||` in every C-family grammar but is easy to forget — and parenthesizes it the way the parser already groups it, so
 * the edit changes no value. It is about the reader, not a trap: `c-precedence-trap` leaves this shape alone because both
 * readings agree. Which slots qualify is the grammar's answer (`RefShape.mixedLogicalOperands`).
 *
 * The written pair is also what makes the formatter keep each group on its own line, broken only at the outer operator.
 * DefaultOff: parenthesizing every mixed chain is a house style.
 */
@:nullSafety(Strict)
final class MixedLogicalParens extends RuleBase implements DefaultOff {

	private static inline final RULE_ID: String = 'mixed-logical-parens';

	public function new() {
		super(
			RULE_ID, 'a bare && group inside an || chain, written without the parentheses that make the grouping visible',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final table: Array<PrecedenceDivergence> = plugin.refShape().mixedLogicalOperands ?? [];
		return table.length == 0
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				for (operand in CPrecedenceTrap.divergentOperands(tree, table)) {
					final span: Null<Span> = operand.span;
					if (span != null) out.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: 'parenthesize this group so the precedence of the mixed logical operators is visible'
					});
				}
			});
	}

	/** Wrap each flagged operand that no other flagged operand encloses in parentheses. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return CPrecedenceTrap.wrapEdits(source, violations, plugin, plugin.refShape().mixedLogicalOperands);
	}

}
