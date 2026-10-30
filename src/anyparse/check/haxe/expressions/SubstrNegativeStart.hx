package anyparse.check.haxe.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.RunScan;
import anyparse.query.SymbolIndex;

/**
 * Flags a `substr` call whose start is a subtraction — an index that goes negative once the subtrahend outgrows the
 * minuend — since `substr` counts a negative start back from the END of the string and returns a window there instead of
 * failing or clamping (`'0123456789'.substr(3 - 6, 2)` is `78`). The subtraction kind is the grammar's
 * (`ExecutionShape.integerFoldOperators`).
 *
 * `DefaultOff`: the rule cannot see a guard that keeps the start non-negative (`n < k ? 0 : n - k`, a length test before
 * the call, a loop bound), so the standard `s.substr(s.length - k)` idiom is flagged wherever it is already safe.
 */
@:nullSafety(Strict)
final class SubstrNegativeStart extends HaxeRule implements DefaultOff implements NoAutofix {

	private static inline final RULE_ID: String = 'substr-negative-start';

	/** The method whose negative start counts from the end; `substring` clamps one to 0 instead. */
	private static inline final METHOD: String = 'substr';

	public function new() {
		super(
			RULE_ID, 'a substr call whose start is a subtraction, which counts from the end of the string once it goes negative',
			RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final subtractKinds: Array<String> = [
			for (kind => op in shape.execution?.integerFoldOperators ?? []) if (op == 'subtract') kind
		];
		return callKind == null || fieldAccessKind == null || subtractKinds.length == 0
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				function walk(node: QueryNode): Void {
					if (node.kind == callKind && node.children.length >= 2) {
						final callee: QueryNode = node.children[0];
						final start: QueryNode = node.children[1];
						final span: Null<Span> = start.span;
						if (
							span != null && callee.kind == fieldAccessKind && callee.name == METHOD && subtractKinds.contains(start.kind)
						) out.push({
							file: entry.file,
							span: span,
							rule: RULE_ID,
							severity: Severity.Warning,
							message: 'substr counts a negative start from the end of the string: guard this start, or use substring'
						});
					}
					for (c in node.children) walk(c);
				}
				walk(tree);
			});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'substring clamps a negative start to 0 but takes an end index where substr takes a length, and a guard keeps'
			+ ' substr: which repair is right depends on what the call meant';
	}

}
