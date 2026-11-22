package anyparse.check.common.members;

/**
 * The option keys of the `member-order` rule's `apq.json` entry, in one place: the one answer to "which keys does
 * `member-order` read", read by the rule and by its `acceptedOptions`.
 */
@:nullSafety(Strict)
final class MemberOrderOptions {

	/** The key that replaces the relocation budget of a fix pass. */
	public static final BUDGET: String = 'maxRelocatedLines';

	/** The key that lets the fix move an argument-less `new`. */
	public static final MOVABLE_ARGLESS_NEW: String = 'movableArglessNew';

	/** The key that separates an inline subgroup from the members around it. */
	public static final SEPARATE_INLINE_SUBGROUP: String = 'separateInlineSubgroup';

	/** The key that sorts a rank's documented fields first and separates them from the rest of it. */
	public static final SEPARATE_DOCUMENTED_SUBGROUP: String = 'separateDocumentedSubgroup';

	/** The rule's id, under which `apq.json` keeps these options. */
	public static final RULE_ID: String = 'member-order';

	/**
	 * `config` with this rule's review budget set to `lines`: the one place that knows the rule id and the option key, so a
	 * run-wide override never names either.
	 */

	public static inline function withBudget(config: LintConfig, lines: Int): LintConfig {
		return config.withIntOption(RULE_ID, BUDGET, lines);
	}

}
