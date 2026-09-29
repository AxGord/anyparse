package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.LambdaLoopScan.LambdaLoopKind;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a manual COUNTING loop — a counter declared at `0` and stepped once per matching element
 * by the loop right below it — which the user's rule replaces with `Lambda.count`:
 *
 * ```
 * var selected:Int = 0;
 * for (checkBox in boxes) if (checkBox.value) selected++;   ->   final selected:Int = boxes.count(checkBox -> checkBox.value);
 * ```
 *
 * `Severity.Info`, with an autofix that inserts a `using Lambda;` when the file lacks one. An
 * UNFILTERED loop over a proven `Array` / `List` becomes the container's own `xs.length`, and any
 * other unfiltered one `xs.count()`. The shape recovery, the gates and the edit live in
 * `LambdaLoopScan` — this is the FLAG form of `prefer-exists` / `prefer-foreach` with a counter for
 * the sink, and that engine's type doc says why it needs no purity gate where they do.
 *
 * ## Why `DefaultOff`
 *
 * A brand-new check and a style preference: the loop and the call count the same elements. Opt in
 * with `"prefer-count": { "enabled": true }`.
 *
 * ## Why `RiskyFix` + `GroupedFix`, as `prefer-exists`
 *
 * A plain identifier or field iterable is claimed WITHOUT a type proof, and only a proven `Iterator`
 * refuses it — so an unresolved one may still be a container `Lambda.count` does not accept, or one
 * that is not an `Array` after all. Verified against the compiler oracle and reverted when it breaks
 * the build; report-only with no oracle configured. Grouped, because reverting the call while
 * keeping the inserted `using Lambda;` would leave an orphaned import that still compiles.
 */
@:nullSafety(Strict)
final class PreferCount implements Check implements DefaultOff implements RiskyFix implements GroupedFix {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'prefer-count';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a var n = 0 counter stepped by the for loop right after it, replaceable with Lambda.count or length';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return LambdaLoopScan.findings(files, plugin, LambdaLoopKind.Count, RULE_ID);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (e in fixGrouped(source, violations, plugin, index)) { span: e.span, text: e.text }
		];
	}

	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		return LambdaLoopScan.edits(source, violations, plugin, index, LambdaLoopKind.Count);
	}

}
