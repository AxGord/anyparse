package anyparse.check;

import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a SUB-MODULE type import (`import pkg.Mod.Sub;`) whose MODULE is already imported in the
 * same file. A plain `import pkg.Mod;` binds every TOP-LEVEL type the module declares — not only
 * its main one — so the second statement binds nothing the first has not already bound, and
 * deleting it changes no name in the file.
 *
 * This is the report side of a fact the shared `TypeRefPrinter` prints by. When the two disagreed,
 * a fixer that materialised a secondary type (`explicit-local-type`'s annotation) spliced
 * `import fs.FileSystemInterface.FileSystemCloudAction;` into a file already carrying
 * `import fs.FileSystemInterface;` — observed on a real project. The printer now takes the
 * module-import route; this rule cleans up what earlier runs left behind.
 *
 * ## The evidence a finding needs
 *
 * Every gate demands POSITIVE evidence — an unprovable case is left alone, never deleted:
 *
 *  - the statement is a PLAIN, UNALIASED, unguarded `import` whose leaf is UPPER-INITIAL (a
 *    lower-initial leaf imports a static field, which a module import does not bring in) and whose
 *    parent path's last segment is upper-initial too (a lower-initial parent is a package, so the
 *    path is a main type, not a sub-module one);
 *  - the same file carries an unguarded, unaliased `import <module>;` or `using <module>;` — a
 *    `using` IS an import plus static extension, so it binds the module's types as well. An ALIASED
 *    module import binds only the alias and never qualifies;
 *  - the resolution index PROVES the module declares a top-level type of that name. An unindexed
 *    module (outside the lint scope) yields no finding, and an enum CONSTRUCTOR / static import
 *    (`import pkg.Colors.Red;`) fails this gate by construction — `Red` is a member, not a type;
 *  - nothing ELSE in the file binds the same simple name: another plain import or `using` whose
 *    module declares it, an alias of that name, a duplicate of this very path, or a type the file
 *    itself declares. Haxe accepts two imports of one simple name and lets the LAST win, so removing
 *    one where a second binder exists could change what the name means. A wildcard is measured to be
 *    outranked by the surviving module import and is deliberately NOT a binder (`bindsElsewhere`).
 *
 * ## Why `RiskyFix`, not a trusted deletion
 *
 * The last gate is only as complete as the RESOLUTION INDEX, and that is a property of the RUN, not
 * of the file: a competing module OUTSIDE the lint scope contributes no veto, so the same file
 * yields "delete" or "refuse" depending on what else was linted. The window where that matters is
 * narrow — a third module must declare a type of the SAME simple name AND sit positionally BETWEEN
 * the qualifying module import and this one, since only then does deleting change which binder is
 * last — but it is not a structurally-provable shape invariant, which is exactly `Check.RiskyFix`'s
 * definition. So the deletions are applied speculatively and REVERTED per file when the project's
 * `compilerOracle` says the build broke; with no oracle configured the rule stays report-only. A
 * silent survivor still needs the two same-named types to be assignment-compatible, which the
 * report leaves for a human.
 *
 * `fix` deletes the flagged statement; the caller batches the deletions into one whole-file
 * canonicalize, which drops the blank line.
 */
@:nullSafety(Strict)
final class RedundantImport implements Check implements RiskyFix {

	public function new() {}

	public function id(): String {
		return 'redundant-import';
	}

	public function description(): String {
		return 'a sub-type import already bound by a plain import of its module';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		// The resolution index — report files UNION the configured library roots — proves what a
		// module declares. Widening it only ever adds evidence: it can turn an unprovable statement
		// into a finding, and it can reveal a SECOND binder of the name, which vetoes one.
		final resolveIndex: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) for (imp in info.imports) {
			final module: Null<String> = redundantModuleOf(info, imp, resolveIndex);
			if (module != null) violations.push({
				file: info.file,
				span: imp.span,
				rule: 'redundant-import',
				severity: Severity.Warning,
				message: 'redundant import \'${imp.raw}\': \'$module\' is imported here and already binds \''
				+ '${SourceText.lastSegment(imp.raw)}\''
			});
		}
		return violations;
	}

	/**
	 * Delete each flagged import statement (its span IS the whole `import …;`). The caller batches
	 * the edits into one whole-file `RefactorSupport.canonicalize`, which drops the now-blank line.
	 */
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

	/**
	 * Whether `o` brings every top-level type of `module` into scope: an unguarded, unaliased
	 * `import <module>;` or `using <module>;` (a `using` is an import plus static extension). An
	 * `Alias` binds only its alias, a `Wild` binds statics or main types, and a GUARDED statement
	 * exists in some builds only — none of the three qualifies.
	 */
	private static inline function providesModule(o: ImportInfo, module: String): Bool {
		return !o.guarded && (o.kind == ImportKind.Import || o.kind == ImportKind.Using) && o.raw == module;
	}

	/**
	 * The module path that already binds `imp`'s leaf name in `info`, or null when `imp` is not a
	 * provably redundant sub-module type import. See the class doc for the gate set; each one fails
	 * closed.
	 */
	private static function redundantModuleOf(info: FileInfo, imp: ImportInfo, index: SymbolIndex): Null<String> {
		if (imp.guarded || imp.kind != ImportKind.Import) return null;
		final dot: Int = imp.raw.lastIndexOf('.');
		if (dot <= 0) return null;
		final simple: String = imp.raw.substring(dot + 1);
		// A lower-initial leaf is a static field / enum-constructor import, and a lower-initial
		// parent segment is a package — neither shape is a module's sub-type.
		if (!SourceText.isUpperInitial(simple)) return null;
		final module: String = imp.raw.substring(0, dot);
		return if (!SourceText.isUpperInitial(SourceText.lastSegment(module)))
			null
		else if (!info.imports.exists(o -> providesModule(o, module)))
			null
		else if (!moduleDeclaresType(index, module, simple))
			null
		else if (bindsElsewhere(info, imp, module, simple, index))
			null
		else
			module;
	}

	/** Whether the index knows a file whose module IS `module` and which declares a top-level type named `name`. */
	private static function moduleDeclaresType(index: SymbolIndex, module: String, name: String): Bool {
		return index.refs.declaringFiles(name).exists(f -> f.module == module);
	}

	/**
	 * Whether anything in `info` OTHER than `imp` and the qualifying module import binds `name`.
	 * Two imports of one simple name are legal in Haxe and the LAST one wins, so a second binder
	 * makes the deletion a possible retarget rather than a no-op — refuse it.
	 *
	 * A WILDCARD is deliberately not a binder here, measured rather than assumed: a package
	 * `import pkg.*;` is OUTRANKED by an explicit module import in either statement order (verified
	 * on 4.3.7), and the qualifying module import always survives the deletion — so a wildcard can
	 * never become the winner and vetoing on one would only suppress a true finding. A module
	 * wildcard `import pkg.Mod.*;` binds statics and enum constructors, no type name at all.
	 *
	 * A type the FILE ITSELF declares outranks every import, so the deletion would be safe there
	 * too; it stays a veto because the finding's MESSAGE would be false — the module import is not
	 * what binds the name in that file.
	 */
	private static function bindsElsewhere(info: FileInfo, imp: ImportInfo, module: String, name: String, index: SymbolIndex): Bool {
		if (info.types.exists(t -> t.name == name)) return true;
		for (o in info.imports) if (o.span.from != imp.span.from || o.span.to != imp.span.to) switch o.kind {
			case ImportKind.Alias:
				if ((o.alias ?? o.raw) == name) return true;
			case ImportKind.Wild:
			case _:
				if (SourceText.lastSegment(o.raw) == name) return true;
				if (o.raw != module && moduleDeclaresType(index, o.raw, name)) return true;
		}
		return false;
	}

}
