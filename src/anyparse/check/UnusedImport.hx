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
 * segment (`Mod` / `Sub`); for `import pkg.Mod as Alias;` it is the alias. If that name occurs as no word-boundary token anywhere outside the import statements, the import is unused → `Warning` — except a plain module import whose module is IN the lint file set: it binds every top-level type of the module, so a reference to any SECONDARY type keeps it (see `secondaryTypeReferenced`), and a reference to a bare CONSTRUCTOR of an in-set enum / enum-abstract type keeps it too (`enumCtorReferenced` — resolved only when the enum module is itself in the lint set, so run `--fix` project-wide). The remaining forms:
 *
 *  - `import pkg.Type.*;` (static wildcard) — when `Type` is in the lint set,
 *    its static fields / enum(-abstract) values / constructors are known, so a
 *    bare reference to any keeps the import and none referenced is a deletable
 *    `Warning` (`addWildViolation`). A package `import pkg.*;` or a wildcard on
 *    an out-of-set type has an unknown symbol set and stays an unverifiable `Info`.
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
		// Top-level type names per in-set module path — a plain module import
		// binds ALL of them, so the used-check must consult every name.
		final moduleTypes: Map<String, Array<String>> = [];
		for (info in index.allFiles()) moduleTypes[info.module] = [for (t in info.types) t.name];
		// Enum-constructor names per importable path (a main type binds under its
		// module, a sub-module type under `module.Type`) — a bare `import pkg.Enum;`
		// is in use when one of its constructors is referenced bare, even if `Enum`
		// itself never appears.
		final enumKinds: Array<String> = plugin.refShape().bareConstructorTypeKinds ?? [];
		final enumCtorsByPath: Map<String, Array<String>> = [];
		for (info in index.allFiles()) for (t in info.types) if (enumKinds.contains(t.kind)) {
			final path: String = t.isMain ? info.module : '${info.module}.${t.name}';
			enumCtorsByPath[path] = [for (m in t.members) m.name];
		}
		// Every in-set type's members keyed by its importable path — a static
		// wildcard `import pkg.Type.*;` brings ALL of them (static fields, enum /
		// enum-abstract values, enum constructors) into unqualified scope, so a
		// bare reference to any one keeps the import.
		final membersByPath: Map<String, Array<String>> = [];
		for (info in index.allFiles()) for (t in info.types) {
			final memberPath: String = t.isMain ? info.module : '${info.module}.${t.name}';
			membersByPath[memberPath] = [for (m in t.members) m.name];
		}
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) {
			final source: String = sourceOf[info.file] ?? '';
			final importSpans: Array<Span> = [for (imp in info.imports) imp.span];
			final ignoreModules: Array<String> = plugin.checkOverrides(info.file)?.unusedImportIgnoreModules ?? [];
			for (imp in info.imports) if (!moduleIgnored(imp, ignoreModules))
				addViolation(violations, info.file, imp, source, importSpans, plugin, moduleTypes, enumCtorsByPath, membersByPath);
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
	 * unverifiable `Info`; a `using` is delegated to `addUsingViolation`; every other form is a `Warning` when its bound name is not referenced outside the import statements AND (for a plain in-set module import) no secondary top-level type of the module is referenced either.
	 */
	private static function addViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, source: String, importSpans: Array<Span>, plugin: GrammarPlugin,
		moduleTypes: Map<String, Array<String>>, enumCtorsByPath: Map<String, Array<String>>, membersByPath: Map<String, Array<String>>
	): Void {
		switch imp.kind {
			case ImportKind.Wild:
				addWildViolation(out, file, imp, source, importSpans, membersByPath);
			case ImportKind.Using:
				addUsingViolation(out, file, imp, source, importSpans, plugin);
			case _:
				final bound: String = imp.alias ?? lastSegment(imp.raw);
				if (RefactorSupport.referencedInRange(source, bound, 0, source.length, importSpans)) return;
				// A plain `import pkg.Mod;` binds every top-level type of the
				// module, not only the main one — a reference to a SECONDARY
				// typedef/enum keeps the import even though `Mod` itself is
				// never named (deleting it broke real builds). Only resolvable
				// when the module is in the lint file set; an out-of-set module
				// (stdlib, haxelib) falls back to the bound-name verdict. An
				// alias import binds just the alias — never widened.
				if (imp.kind == ImportKind.Import && secondaryTypeReferenced(imp.raw, bound, source, importSpans, moduleTypes)) return;
				// A bare `import pkg.Enum;` whose constructor is used as a bare
				// identifier (`Assert.equals(Private, m)`, expected-type resolved)
				// is in use even though `Enum` itself is never named.
				if (imp.kind == ImportKind.Import && enumCtorReferenced(imp.raw, source, importSpans, enumCtorsByPath)) return;
				out.push(make(file, imp, Severity.Warning, 'unused import \'${imp.raw}\''));
		}
	}

	/** True when any OTHER top-level type of in-set module `raw` is referenced in `source` outside the imports. */
	private static function secondaryTypeReferenced(
		raw: String, bound: String, source: String, importSpans: Array<Span>, moduleTypes: Map<String, Array<String>>
	): Bool {
		final types: Null<Array<String>> = moduleTypes[raw];
		if (types == null) return false;
		return types.exists(name -> name != bound && RefactorSupport.referencedInRange(source, name, 0, source.length, importSpans));
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

	/** True when any constructor of the enum-type imported by `raw` is referenced bare in `source` (outside the imports). */
	private static function enumCtorReferenced(
		raw: String, source: String, importSpans: Array<Span>, enumCtorsByPath: Map<String, Array<String>>
	): Bool {
		final ctors: Null<Array<String>> = enumCtorsByPath[raw];
		if (ctors == null) return false;
		return ctors.exists(name -> RefactorSupport.referencedInRange(source, name, 0, source.length, importSpans));
	}

	/**
	 * Verdict for a wildcard import. A STATIC wildcard `import pkg.Type.*;` whose
	 * `Type` is in the lint set (`membersByPath` has its path) brings that type's
	 * static fields / enum(-abstract) values / enum constructors into unqualified
	 * scope: it is in use when any of those member names is referenced outside the
	 * imports, and a verified-unused `Warning` (deletable) when none is. A package
	 * wildcard `import pkg.*;` or a wildcard on an out-of-set type has an unknown
	 * symbol set, so it stays an unverifiable `Info`.
	 */
	private static function addWildViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, source: String, importSpans: Array<Span>,
		membersByPath: Map<String, Array<String>>
	): Void {
		final members: Null<Array<String>> = membersByPath[stripWildStar(imp.raw)];
		if (members == null) {
			out.push(make(file, imp, Severity.Info, 'wildcard import \'${imp.raw}\': usage not tracked'));
			return;
		}
		if (members.exists(name -> RefactorSupport.referencedInRange(source, name, 0, source.length, importSpans))) return;
		out.push(make(file, imp, Severity.Warning, 'unused wildcard import \'${imp.raw}\': no member referenced'));
	}

	/** `pkg.Type.*` -> `pkg.Type` (the path whose members the static wildcard imports); unchanged when it has no trailing `.*`. */
	private static function stripWildStar(raw: String): String {
		return StringTools.endsWith(raw, '.*') ? raw.substr(0, raw.length - 2) : raw;
	}

}
