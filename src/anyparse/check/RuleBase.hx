package anyparse.check;

/**
 * The base of every builtin rule: its identity — id, one-line description and `RuleCategory` — fixed by the
 * constructor, so a rule that names no category does not compile. `run` and `fix` stay the subclass's own `Check`
 * implementation; the marker interfaces (`DefaultOff`, `RiskyFix`, …) are still declared by the rule itself.
 */
@:nullSafety(Strict)
abstract class RuleBase implements Check {

	private final _id: String;
	private final _description: String;
	private final _category: RuleCategory;

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

}
