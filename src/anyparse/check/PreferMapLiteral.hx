package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags `new Map()` / `new Map<K, V>()` — an empty-argument Map construction the `[]`
 * literal replaces — and rewrites it to `[]`. `Severity.Info` (a modernization cleanup),
 * with an autofix. The key/value types carry through the assignment target's annotation
 * (see `NewLiteral`). Grammar-agnostic over `RefShape.newExprKind`.
 */
@:nullSafety(Strict)
final class PreferMapLiteral implements Check {

	private static final TYPE_NAME: String = 'Map';

	public function new() {}

	public function id(): String {
		return 'prefer-map-literal';
	}

	public function description(): String {
		return 'a new Map() construction replaceable with the map literal []';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return NewLiteral.run(files, plugin, TYPE_NAME, id(), 'this new Map() can be the map literal []');
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return NewLiteral.fix(source, violations, plugin, TYPE_NAME, index);
	}

}
