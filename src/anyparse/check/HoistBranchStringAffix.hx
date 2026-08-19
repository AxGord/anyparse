package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * STUB — the failing-test arm of slice E4. Registered so the fixtures fail on the mechanism
 * rather than on a build break; the implementation lands in the next commit.
 */
@:nullSafety(Strict)
final class HoistBranchStringAffix implements Check implements DefaultOff {

	/** The rule id, also the `rule` field of every violation it reports. */
	private static inline final RULE_ID: String = 'hoist-branch-string-affix';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a conditional-compilation region whose every branch returns a string with the same edges, the shared text hoistable out '
			+ 'of the region';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}
