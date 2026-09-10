package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.DuplicateCode.DupMode;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The RENAMED reading of `duplicate-code`: the same runs of three or more consecutive statements,
 * compared after every LOCAL binding's name is replaced by the position at which the run first
 * binds it. Two copies differing only in what their parameters, locals, loop variables, `catch`
 * binders and pattern captures are called are therefore one clone, while members, types, method
 * names and literals still have to match byte for byte — type-2, not type-3.
 *
 * ## Why its own rule id
 *
 * A mode of `duplicate-code` would merge two populations into one history (`--baseline` and
 * `lint-diff` key on the rule id) and would make "the exact reading did not widen" unverifiable
 * from the CLI. The two also differ in cost and in false-positive risk, so a reader has to be able
 * to switch one off without the other. `DefaultOff` follows from the same asymmetry: a renaming
 * buys clones a reader may judge coincidental, so a project opts in.
 *
 * ## What it inherits
 *
 * Everything else is `duplicate-code`'s contract, engine and all — the block seam, the
 * layout-insensitive literal-exact render, the content gate, the non-overlapping occurrence rule,
 * the same-file and cross-file passes. `Info`, REPORT-ONLY: extraction is a refactoring and
 * whether two renamed copies are one idea is a design judgement, so `fix` emits nothing.
 */
@:nullSafety(Strict)
@:access(anyparse.check.DuplicateCode)
final class DuplicateCodeRenamed implements Check implements NoAutofix implements VolatileMessage implements DefaultOff {

	private static inline final RULE_ID: String = 'duplicate-code-renamed';

	/** The same-file wording's tail — the parenthesis is what tells the two rules' messages apart. */
	private static inline final SAME_FILE_TAIL: String = ' — extract a helper (bindings renamed; hxq extract-method)';

	/** Anchors `messageIdentity`'s backward mask, so this wording and that mask cannot drift apart. */
	private static inline final CROSS_FILE_TAIL: String = ' — extract a shared helper (bindings renamed; report-only, cross-file)';

	/** This rule's reading of the shared engine: local binder names normalized by binding position. */
	private static final RENAMED: DupMode = {
		ruleId: RULE_ID,
		normalizeBinders: true,
		sameFileTail: SAME_FILE_TAIL,
		crossFileTail: CROSS_FILE_TAIL
	};

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'three or more consecutive statements duplicated up to a renaming of their local bindings (layout-insensitive, literal-exact)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return DuplicateCode.scan(files, plugin, RENAMED);
	}

	/** Extraction is a refactoring (`hxq extract-method`), not a mechanical span edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * A renaming makes two copies LOOK alike without making them one idea, and only a reader can
	 * tell which they are.
	 */
	public function noAutofixReason(): String {
		return 'whether a renaming reveals one idea or a coincidence — and where a shared factor belongs — is a design judgement';
	}

	/** The ORIGINAL's line is masked; the statement count and the partner filename are not — as in `duplicate-code`. */
	public function messageIdentity(message: String): String {
		return DuplicateCode.maskCoordinate(message, RENAMED);
	}

}
