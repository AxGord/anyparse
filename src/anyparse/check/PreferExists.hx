package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/** Stub. */
@:nullSafety(Strict)
final class PreferExists implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-exists';
	}

	public function description(): String {
		return 'a manual any-match for loop replaceable with Lambda.exists';
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
