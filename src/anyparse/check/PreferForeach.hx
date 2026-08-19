package anyparse.check;

import anyparse.check.BoolLoopScan.BoolLoopKind;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a manual ALL-MATCH `for` loop — one that iterates a collection and returns `false` from
 * the first element satisfying a condition, with a `return true;` right after — which the
 * user's rule replaces with `Lambda.foreach`. `Severity.Info`, with an autofix that rewrites the
 * loop to `xs.foreach(x -> !(cond))` and inserts a `using Lambda;` when the file lacks one. The
 * inversion is a WRAP, never De Morgan (distributing `!` through a chain reorders the operands a
 * null narrowing depends on); a condition that is already a `!` drops it instead of gaining a
 * second. Purely structural; the shape recovery, the gates and the edit all live in
 * `BoolLoopScan`, shared with the twin `prefer-exists`.
 *
 * The GUARDED variant that twin claims has no counterpart here: `if (g) for … return false;` +
 * `return true;` reads as `!g || xs.foreach(…)`, and negating a guard — a null test, at every
 * measured site — strands the narrowing the rest of the expression needs.
 *
 * ## Why `DefaultOff`, and why the fix is not `RiskyFix`
 *
 * A brand-new check, and a style preference besides — opt in with
 * `"prefer-foreach": { "enabled": true }`. On hxcpp the call is also measurably heavier than the
 * loop (`Lambda.foreach` erases its `Iterable<A>` to `Dynamic`, so the generated C++ makes
 * reflective calls by field name every iteration, plus a closure allocation): negligible on UI
 * paths, worth declining in a measured hot spot, which the `Info` severity is there to say.
 * Unlike `exists`, `foreach` names nothing in the standard collections, so the emitted call
 * cannot be captured by a member — the fix is trusted, as `prefer-find`'s is.
 */
@:nullSafety(Strict)
final class PreferForeach implements Check implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'prefer-foreach';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a manual all-match for loop (return false / return true) replaceable with Lambda.foreach';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return BoolLoopScan.findings(files, plugin, BoolLoopKind.Foreach, RULE_ID);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (e in BoolLoopScan.edits(source, violations, plugin, index, BoolLoopKind.Foreach)) { span: e.span, text: e.text }
		];
	}

}
