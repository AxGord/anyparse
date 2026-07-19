package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags `new Array()` / `new Array<T>()` — an empty-argument Array construction the
 * `[]` literal replaces — and rewrites it to `[]`. `Severity.Info` (a modernization
 * cleanup), with an autofix. The element type carries through the assignment target's
 * annotation (see `NewLiteral`). Grammar-agnostic over `RefShape.newExprKind`.
 */
@:nullSafety(Strict)
final class PreferArrayLiteral implements Check {

	private static final TYPE_NAME: String = 'Array';

	public function new() {}

	public function id(): String {
		return 'prefer-array-literal';
	}

	public function description(): String {
		return 'a new Array() construction replaceable with the array literal []';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return NewLiteral.run(files, plugin, TYPE_NAME, id(), 'this new Array() can be the array literal []');
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return NewLiteral.fix(source, violations, plugin, TYPE_NAME, index);
	}

}
