package anyparse.check;

import anyparse.check.Check.ConfigNoting;
import anyparse.check.LintConfig.ConfigNote;

/**
 * The base of every builtin rule: its identity — id, one-line description and `RuleCategory` — fixed by the
 * constructor, so a rule that names no category does not compile. `run` and `fix` stay the subclass's own `Check`
 * implementation; the marker interfaces (`DefaultOff`, `RiskyFix`, …) are still declared by the rule itself.
 */
@:nullSafety(Strict)
abstract class RuleBase implements Check implements ConfigNoting {

	private final _id: String;
	private final _description: String;
	private final _category: RuleCategory;

	/** Where the rule's config diagnostics go this run (`ConfigNoting`); null says them through `ConfigNotes`' fallback. */
	private var _configNotes: Null<Array<ConfigNote>> = null;

	private function new(id: String, description: String, category: RuleCategory) {
		_id = id;
		_description = description;
		_category = category;
	}

	public final function id(): String {
		return _id;
	}

	public final function description(): String {
		return _description;
	}

	public final function category(): RuleCategory {
		return _category;
	}

	public final function setConfigNotes(notes: Null<Array<ConfigNote>>): Void {
		_configNotes = notes;
	}

}
