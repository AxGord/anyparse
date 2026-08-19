package anyparse.check;

import anyparse.check.BoolLoopScan.BoolLoopKind;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a manual ANY-MATCH `for` loop — one that iterates a collection and records that some
 * element satisfies a condition — which the user's rule replaces with `Lambda.exists`.
 * `Severity.Info`, with an autofix that rewrites the loop and inserts a `using Lambda;` when the
 * file lacks one. Purely structural; the shape recovery, the gates and the edit all live in
 * `BoolLoopScan`, shared with the twin `prefer-foreach`.
 *
 * Two SINKS carry the answer, and the rule claims both:
 *
 * - the RETURN form, `for (x in xs) if (cond) return true;` + `return false;`, which becomes
 *   `return xs.exists(x -> cond);`. Its GUARDED variant
 *   `if (g) for (x in xs) if (cond) return true;` collapses to `return g && xs.exists(x -> cond);`
 *   — more than half the real sites measured on a ~800-file application are that one;
 * - the FLAG form, `var f:Bool = false;` immediately followed by
 *   `for (x in xs) if (cond) f = true;`, which becomes `final f:Bool = xs.exists(x -> cond);`.
 *   Eleven sites over that same application, and it is the form the code actually writes.
 *
 * The flag form carries a gate the return form does not need: the CONDITION must be side-effect
 * free (`PurityScan.isPure`). A `return` leaves the loop at the first match, so the emitted call's
 * short-circuit is invisible; a flag assignment does not, and five of those eleven sites call a
 * function that does the loop's work on every element. `BoolLoopScan`'s type doc has the full
 * reasoning and names them.
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
 * no compiler oracle configured the check is report-only. It is a `GroupedFix` for the same
 * reason: reverting the rewrite while keeping the `using Lambda;` the fix inserted would leave a
 * file that still compiles, so the verifier could not tell that subset was wrong — measured on
 * the very fixture above, which came back with an orphaned `using` before the grouping landed. `Lambda.foreach` has no such
 * collision — no stdlib collection declares `foreach` — which is why `prefer-foreach` ships as
 * an ordinary trusted fix, on the same footing as `prefer-find`.
 *
 * ## The shadow no longer costs the site
 *
 * A receiver whose type declares `exists` is not out of reach, only out of reach of the EXTENSION
 * spelling: `Lambda.exists(m, x -> …)` names the module outright and never consults the receiver's
 * members. `BoolLoopScan` emits that QUALIFIED form wherever the shadow gate fires (and inserts no
 * `using`, which a static call does not need), so the `Map` receiver above converts rather than
 * staying silent. The one gate the fallback adds is its own name: `Lambda` must still MEAN the
 * module here — see `UsingScan.qualifiedCallReaches`.
 */
@:nullSafety(Strict)
final class PreferExists implements Check implements DefaultOff implements RiskyFix implements GroupedFix {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'prefer-exists';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a manual any-match for loop (returning, or setting a bool flag) replaceable with Lambda.exists';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return BoolLoopScan.findings(files, plugin, BoolLoopKind.Exists, RULE_ID);
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
		return BoolLoopScan.edits(source, violations, plugin, index, BoolLoopKind.Exists);
	}

}
