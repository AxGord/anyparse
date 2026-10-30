package anyparse.check.haxe;

import anyparse.check.Check.LanguageBound;
import anyparse.check.RuleCategory;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The base of a builtin rule that only Haxe answers — one whose subject is a Haxe standard-library API or a construct
 * no other grammar spells — so it is `LanguageBound` to the Haxe grammar and lives in `anyparse.check.haxe.<category>`.
 */
@:nullSafety(Strict)
abstract class HaxeRule extends RuleBase implements LanguageBound {

	private function new(id: String, description: String, category: RuleCategory) {
		super(id, description, category);
	}

	public final function languages(): Array<String> {
		return [HaxeQueryPlugin.LANG];
	}

}
