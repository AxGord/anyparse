package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `import` (or `using`) declared more than once in the same file: the
 * second and later occurrences are dead noise the compiler accepts silently.
 *
 * Two imports are duplicates only when their kind, module path, AND alias all
 * match, so `import a.B` vs `using a.B`, or two different aliases of one module,
 * are kept distinct (both bind a usable name) — and so are the two branches of a
 * `#if` region binding one alias name to different modules. That last pair is why the path compared is
`pathImportedBy` and not the `raw` an alias statement exposes: `raw` IS the alias, so both
branches would key as ONE import. That was unreachable while the index dropped the second
branch itself; this rule is the companion of the change that stopped it doing so, and
without the pair `--fix` deletes the `#else` statement, leaving a bare `#if js … #else
#end` and a compilation whose supertype no longer resolves.
 *
 * Import extraction rides on the cross-file `SymbolIndex` (kind / alias / span, skip-parse
handling), the same source `unused-import` uses — so what this rule can see at all is
decided by `SymbolIndexBuilder.importDedupKey`, which keeps a guarded repeat of a
statement out of `FileInfo.imports` before any rule runs. The two keys have to be read
together: this one only ever sees what that one let through.
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
				// `imp.raw` is the ALIAS for an alias statement, so keying on it makes the two
				// branches of `#if js import p.A as U; #else import p.B as U; #end` one import
				// and deletes the second — the module PATH this rule's contract asks for is
				// `pathImportedBy`.
				final key: String = '${imp.kind}|${SymbolIndex.pathImportedBy(imp) ?? imp.raw}|${imp.alias ?? ''}';
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

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: span, text: '' });
		}
		return edits;
	}

}
