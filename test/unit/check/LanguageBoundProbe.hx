package unit.check;

import anyparse.check.Check;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;

/** A check bound to one named grammar that reports every file it is handed: what a language gate must keep from any other grammar. */
@:nullSafety(Strict)
final class LanguageBoundProbe implements Check implements LanguageBound {

	private final _lang: String;

	public function new(lang: String) {
		_lang = lang;
	}

	public function id(): String {
		return 'language-bound-probe';
	}

	public function description(): String {
		return 'reports every file it runs on';
	}

	public function category(): RuleCategory {
		return Design;
	}

	public function languages(): Array<String> {
		return [_lang];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (f in files)
				{
					file: f.file,
					span: null,
					rule: id(),
					severity: Severity.Info,
					message: 'ran on ${plugin.langName()}'
				}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

}
