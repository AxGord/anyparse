package unit.check;

import anyparse.check.Check;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.query.GrammarPlugin;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using anyparse.util.Arrays;

/**
 * Test-only `RiskyFix` consumer for the compiler-oracle fix-verification path:
 * it flags the first integer literal `1` in a file and rewrites it to a text
 * supplied at construction. Built with `'2'` it yields a fix that still
 * typechecks (kept); with `'"x"'` a fix that breaks an `Int` binding (reverted).
 * Never registered as a builtin — it exists purely to exercise `FixVerifier`.
 */
@:nullSafety(Strict)
final class TestRiskyLiteralRewrite implements Check implements RiskyFix {

	private final _replacement: String;

	public function new(replacement: String) {
		_replacement = replacement;
	}

	public function id(): String {
		return 'test-risky-literal-rewrite';
	}

	public function description(): String {
		return 'test-only: rewrite the first integer literal 1 to a configured text';
	}

	public function category(): RuleCategory {
		return RuleCategory.Literals;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [ for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) {
				final node: Null<QueryNode> = firstLiteralOne(tree);
				if (node != null) {
					final span: Null<Span> = node.span;
					if (span != null) {
						file: entry.file,
						span: span,
						rule: id(),
						severity: Severity.Warning,
						message: 'rewritable literal 1'
					};
				}
			}
		} ];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null) edits.push({ span: span, text: _replacement });
		}
		return edits;
	}

	private static function firstLiteralOne(node: QueryNode): Null<QueryNode> {
		return node.kind == 'IntLit' && node.name == '1' ? node : node.children.findMap(firstLiteralOne);
	}

}
