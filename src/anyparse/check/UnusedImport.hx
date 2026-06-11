package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Flags `import` statements whose bound name is never referenced
 * elsewhere in the same file. Built on the cross-file `SymbolIndex` for
 * import extraction (kind / alias / span, skip-parse handling) and on a
 * union of the plugin's two parse projections for the occurrence set:
 * `parseFile` surfaces value references (`Foo.bar()`, `new Foo()`, `case
 * Foo:`) and `parseFileTypeRefs` adds type-position references (`var
 * x:Foo`, `extends Foo`, `cast(_, Foo)`, parameter / generic types). A
 * type-only-used import is invisible in `parseFile` alone, so both trees
 * are required.
 *
 * ## Conservative by design
 *
 * The check only warns when it is confident. The bound name of an
 * `import pkg.Mod;` / `import pkg.Mod.Sub;` is the leaf segment (`Mod` /
 * `Sub`); for `import pkg.Mod as Alias;` it is the alias. If that name
 * does not appear as any node's name slot in either tree, the import is
 * unused → `Warning`. Two forms cannot be verified and are reported as
 * `Info` rather than warned on:
 *
 *  - `import pkg.*;` (wildcard) — brings in an unknown set of symbols; a
 *    bare reference can come from it without naming the package.
 *  - `using pkg.Mod;` — its methods are applied implicitly as extension
 *    calls (`s.trim()`), so the module name need never appear.
 */
@:nullSafety(Strict)
final class UnusedImport implements Check {

	/**
	 * Top-level node kinds excluded from the occurrence set: the import /
	 * package statements themselves. Excluding them matters for the alias
	 * form — an `ImportAliasDecl`'s own name slot IS the alias, so without
	 * this exclusion an alias would always "reference itself" and never be
	 * flagged. Mirrors the kind strings `SymbolIndex` keys on.
	 */
	private static final SKIP_KINDS: Array<String> = [
		'ImportDecl',
		'ImportAliasDecl',
		'ImportWildDecl',
		'UsingDecl',
		'PackageDecl'
	];

	public function new() {}

	public function id(): String {
		return 'unused-import';
	}

	public function description(): String {
		return 'import whose bound name is never referenced in the file';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final sourceOf: Map<String, String> = new Map();
		for (entry in files) sourceOf[entry.file] = entry.source;

		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) {
			final source: String = sourceOf[info.file] ?? '';
			final occurrences: Array<String> = collectOccurrences(plugin, source);
			for (imp in info.imports) addViolation(violations, info.file, imp, occurrences);
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
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			if (v.severity != Severity.Warning) continue;
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: span, text: '' });
		}
		return edits;
	}

	/**
	 * Append the verdict for one import. Wildcard / `using` forms are
	 * unverifiable advisories (`Info`); every other form is a `Warning`
	 * when its bound name is absent from `occurrences`.
	 */
	private static function addViolation(out: Array<Violation>, file: String, imp: ImportInfo, occurrences: Array<String>): Void {
		switch imp.kind {
			case ImportKind.Wild:
				out.push(make(file, imp, Severity.Info, 'wildcard import \'${imp.raw}\': usage not tracked'));
			case ImportKind.Using:
				out.push(make(file, imp, Severity.Info, 'using import \'${imp.raw}\': extension use not tracked'));
			case _:
				final bound: String = imp.alias ?? lastSegment(imp.raw);
				if (!occurrences.contains(bound))
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

	/**
	 * Every name-slot value across the file's `parseFile` and
	 * `parseFileTypeRefs` trees, excluding the import / package statements
	 * (`SKIP_KINDS`). Either parse may throw — a thrown projection simply
	 * contributes nothing, so a file that parses one way but not the other
	 * still yields the names it can.
	 */
	private static function collectOccurrences(plugin: GrammarPlugin, source: String): Array<String> {
		final names: Array<String> = [];
		final valueTree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (valueTree != null) collectNames(valueTree, names);
		final typeTree: Null<QueryNode> = try plugin.parseFileTypeRefs(source) catch (_: Exception) null;
		if (typeTree != null) collectNames(typeTree, names);
		return names;
	}

	/** Recursively gather non-null `name` slots, skipping import subtrees. */
	private static function collectNames(node: QueryNode, out: Array<String>): Void {
		if (SKIP_KINDS.contains(node.kind)) return;
		final name: Null<String> = node.name;
		if (name != null) out.push(name);
		for (child in node.children) collectNames(child, out);
	}

	/** Last dot-segment of a path (`pkg.Mod.Sub` -> `Sub`); the whole string when undotted. */
	private static function lastSegment(path: String): String {
		final segments: Array<String> = path.split('.');
		final last: Null<String> = segments.length > 0 ? segments[segments.length - 1] : path;
		return last ?? path;
	}

}
