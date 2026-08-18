package anyparse.check;

import anyparse.check.BoolLoopScan.BoolLoopKind;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a manual ANY-MATCH `for` loop — one that iterates a collection and returns `true` from
 * the first element satisfying a condition, with a `return false;` right after — which the
 * user's rule replaces with `Lambda.exists`. `Severity.Info`, with an autofix that rewrites the
 * loop to `xs.exists(x -> cond)` and inserts a `using Lambda;` when the file lacks one. The
 * GUARDED variant `if (g) for (x in xs) if (cond) return true;` + `return false;` collapses to
 * `return g && xs.exists(x -> cond);` — more than half the real sites measured on a ~800-file
 * application are that one. Purely structural; the shape recovery, the gates and the edit all
 * live in `BoolLoopScan`, shared with the twin `prefer-foreach`.
 *
 * ## Why `DefaultOff`
 *
 * A brand-new check, and a style preference besides: the loop and the call are equivalent, so
 * which one a project wants is its own call. Opt in with `"prefer-exists": { "enabled": true }`.
 *
 * ## Why `RiskyFix`, when the twin is not
 *
 * `haxe.ds.Map` DECLARES a member `exists(key:K):Bool`, and a real member always beats a `using`
 * static extension — so on a `Map` receiver the rewrite resolves to the key lookup and does not
 * compile (a lambda where a key is expected). The receiver's type is exactly what a structural
 * check cannot see, and a measured site over a real application iterates a
 * `Null<Map<Int, ObjectFrameData>>`, so this is a live hazard rather than a hypothetical. As a
 * `RiskyFix` the edit is applied speculatively and REVERTED when it breaks the build, and with
 * no compiler oracle configured the check is report-only. `Lambda.foreach` has no such
 * collision — no stdlib collection declares `foreach` — which is why `prefer-foreach` ships as
 * an ordinary trusted fix, on the same footing as `prefer-find`.
 */
@:nullSafety(Strict)
final class PreferExists implements Check implements DefaultOff implements RiskyFix {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'prefer-exists';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a manual any-match for loop (return true / return false) replaceable with Lambda.exists';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return BoolLoopScan.findings(files, plugin, BoolLoopKind.Exists, RULE_ID);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return BoolLoopScan.edits(source, violations, plugin, index, BoolLoopKind.Exists);
	}

}
