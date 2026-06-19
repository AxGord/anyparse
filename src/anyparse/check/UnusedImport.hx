package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags `import` statements whose bound name is never referenced elsewhere
 * in the same file. Import extraction (kind / alias / span, skip-parse
 * handling) rides on the cross-file `SymbolIndex`; the "is it referenced"
 * test is a raw word-boundary scan of the source, OUTSIDE the import
 * statements themselves.
 *
 * ## Why a raw scan, not the AST
 *
 * An earlier version collected occurrences from the plugin's `parseFile` +
 * `parseFileTypeRefs` trees. That MISSED references the type projection does
 * not surface — a type nested in `Array<{ f: Array<Name> }>`, for one — and
 * `lint --fix` then deleted a needed import, breaking the build. A raw
 * word-boundary scan catches every reference the compiler can see, at the
 * cost of also counting the name inside comments / strings. That trade is
 * the right one for an autofix: err toward a false NEGATIVE (a missed unused
 * import) over a false POSITIVE (deleting a needed one).
 *
 * ## Conservative by design
 *
 * The bound name of an `import pkg.Mod;` / `import pkg.Mod.Sub;` is the leaf
 * segment (`Mod` / `Sub`); for `import pkg.Mod as Alias;` it is the alias. If
 * that name occurs as no word-boundary token anywhere outside the import
 * statements, the import is unused → `Warning`. The remaining forms:
 *
 *  - `import pkg.*;` (wildcard) — brings in an unknown set of symbols; a bare
 *    reference can come from it without naming the package, so it stays an
 *    unverifiable `Info`.
 *  - `using pkg.Mod;` — in use when its bound name is referenced (a static /
 *    type use such as `StringTools.fastCodeAt`) OR one of the extension methods
 *    it provides is called as `.method(`. Verified-unused when the module's
 *    methods are known (`knownExtensionMethods`, a `Warning` that `--fix`
 *    deletes); an unknown module stays an `Info`. See `addUsingViolation`.
 */
@:nullSafety(Strict)
final class UnusedImport implements Check {

	public function new() {}

	public function id(): String {
		return 'unused-import';
	}

	public function description(): String {
		return 'import whose bound name is never referenced in the file';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final sourceOf: Map<String, String> = [];
		for (entry in files) sourceOf[entry.file] = entry.source;

		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) {
			final source: String = sourceOf[info.file] ?? '';
			final importSpans: Array<Span> = [for (imp in info.imports) imp.span];
			final ignoreModules: Array<String> = plugin.checkOverrides(info.file)?.unusedImportIgnoreModules ?? [];
			for (imp in info.imports) if (!moduleIgnored(imp, ignoreModules))
				addViolation(violations, info.file, imp, source, importSpans, plugin);
		}
		return violations;
	}

	/**
	 * Fix the unused-import `Warning`s by deleting the import statement (its
	 * span — which is the whole `import …;` line). The wildcard / `using`
	 * `Info` advisories are deliberately NOT fixed: they cannot be verified,
	 * so removing one could break the file. The caller batches these edits
	 * into one whole-file `canonicalize`, which drops the now-blank line.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			if (v.severity != Severity.Warning) continue;
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: span, text: '' });
		}
		return edits;
	}

	/**
	 * Append the verdict for one import. A wildcard (`import pkg.*;`) is an
	 * unverifiable `Info`; a `using` is delegated to `addUsingViolation`; every
	 * other form is a `Warning` when its bound name is not referenced outside the
	 * import statements.
	 */
	private static function addViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, source: String, importSpans: Array<Span>, plugin: GrammarPlugin
	): Void {
		switch imp.kind {
			case ImportKind.Wild:
				out.push(make(file, imp, Severity.Info, 'wildcard import \'${imp.raw}\': usage not tracked'));
			case ImportKind.Using:
				addUsingViolation(out, file, imp, source, importSpans, plugin);
			case _:
				final bound: String = imp.alias ?? lastSegment(imp.raw);
				if (!RefactorSupport.referencedInRange(source, bound, 0, source.length, importSpans))
					out.push(make(file, imp, Severity.Warning, 'unused import \'${imp.raw}\''));
		}
	}

	private static function make(file: String, imp: ImportInfo, severity: Severity, message: String): Violation {
		return {
			file: file,
			span: imp.span,
			rule: 'unused-import',
			severity: severity,
			message: message
		};
	}

	/** Last dot-segment of a path (`pkg.Mod.Sub` -> `Sub`); the whole string when undotted. */
	private static function lastSegment(path: String): String {
		final segments: Array<String> = path.split('.');
		final last: Null<String> = segments.length > 0 ? segments[segments.length - 1] : path;
		return last ?? path;
	}

	/**
	 * Append the verdict for a `using` import. It is in use when its bound name is
	 * referenced outside the imports — a static / type reference such as
	 * `MetaInspect.foo()` or `StringTools.fastCodeAt()` — OR when one of its
	 * extension methods is invoked as a `.method(` call. When neither holds:
	 *
	 *  - the module's extension methods are KNOWN (a stdlib `using`) → a verified
	 *    `unused using` `Warning`, deletable like any other unused import;
	 *  - the module is UNKNOWN (`knownExtensionMethods` returns null) → it stays an
	 *    `Info` advisory, since an extension call cannot be ruled out.
	 */
	private static function addUsingViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, source: String, importSpans: Array<Span>, plugin: GrammarPlugin
	): Void {
		final bound: String = lastSegment(imp.raw);
		if (RefactorSupport.referencedInRange(source, bound, 0, source.length, importSpans)) return;
		final methods: Null<Array<String>> = plugin.knownExtensionMethods(imp.raw);
		if (methods == null) {
			out.push(make(file, imp, Severity.Info, 'using import \'${imp.raw}\': extension use not tracked'));
			return;
		}
		if (methods.exists(m -> RefactorSupport.methodCalledInSource(source, m))) return;
		out.push(make(file, imp, Severity.Warning, 'unused using \'${imp.raw}\''));
	}

	/** Whether `imp`'s full module path is in a checkstyle `ignoreModules` list. */
	private static function moduleIgnored(imp: ImportInfo, ignore: Array<String>): Bool {
		return ignore.contains(imp.raw);
	}

}
