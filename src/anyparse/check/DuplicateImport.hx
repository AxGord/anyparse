package anyparse.check;

import anyparse.query.SymbolIndex;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import anyparse.check.Check.Violation;

/**
 * Flags an `import` (or `using`) declared more than once in the same file: the
 * second and later occurrences are dead noise the compiler accepts silently.
 *
 * Two imports are duplicates only when their kind, module path, AND alias all
 * match, so `import a.B` vs `using a.B`, or two different aliases of one module,
 * are kept distinct (both bind a usable name). Import extraction rides on the
 * cross-file `SymbolIndex` (kind / alias / span, skip-parse handling), the same
 * source `unused-import` uses.
 *
 * `fix` deletes every duplicate occurrence, keeping the first; the caller batches
 * the deletions into one whole-file canonicalize.
 */
@:nullSafety(Strict)
final class DuplicateImport implements Check {

	public function new() {}

	public function id(): String {
		return 'duplicate-import';
	}

	public function description(): String {
		return 'an import declared more than once in the same file';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) {
			final seen: Array<String> = [];
			for (imp in info.imports) {
				final key: String = '${imp.kind}|${imp.raw}|${imp.alias ?? ""}';
				if (seen.contains(key))
					violations.push({
						file: info.file,
						span: imp.span,
						rule: 'duplicate-import',
						severity: Severity.Warning,
						message: 'duplicate import \'${imp.raw}\''
					});
				else
					seen.push(key);
			}
		}
		return violations;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: span, text: '' });
		}
		return edits;
	}

}
