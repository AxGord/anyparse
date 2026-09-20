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

	private static final RULE_ID: String = 'redundant-import';

	public function new() {}

	public function id(): String {
		return RULE_ID;
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
			final ambient: Null<String> = module != null ? null : ambientProviderOf(info, imp, resolveIndex);
			if (module != null)
				violations.push({
					file: info.file,
					span: imp.span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'redundant import \'${imp.raw}\': \'$module\' is imported here and already binds \''
					+ '${SourceText.lastSegment(imp.raw)}\''
				});
			else if (ambient != null)
				violations.push({
					file: info.file,
					span: imp.span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'redundant ${imp.kind == ImportKind.Using ? 'using' : 'import'} \'${imp.raw}\': \'$ambient\' already puts the '
					+ 'same statement in force in every module here'
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

	/** Whether `o` binds `simple` as a NAME — the shared reading, so this rule and the hoisting one cannot disagree. */
	private static inline function bindsSimpleName(o: ImportInfo, simple: String): Bool {
		return SymbolIndex.bindsSimpleName(o, simple);
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
	 * The NEAREST ambient group binding `simple` at all — the one that decides the name once the file's
	 * own statement goes. Guardedness must not steer the SEARCH, only the verdict at the group it lands
	 * on; filtered here it walks past a nearer group whose only binder is `#if`-guarded.
	 */
	private static function nearestBinder(info: FileInfo, simple: String): Null<AmbientImportGroup> {
		return info.ambientImports.find(g -> g.imports.exists(o -> bindsSimpleName(o, simple)));
	}

	/**
	 * The ambient source that already puts `imp` in force in `info`, or null when deleting `imp` could
	 * change what a name means there.
	 *
	 * ONE shape qualifies, and it is stated positively: `imp` is an unguarded `import` or `using`, the
	 * NEAREST ambient statement binding its simple name is an unguarded statement of the very same
	 * kind and path, the chain was bounded, and nothing else in the file binds that name. An identical
	 * statement binds an identical thing whatever it names — which is why this arm consults no
	 * declaration at all, and why anything short of identical is refused instead of reasoned about. A
	 * nearer ambient source binding the simple name to something ELSE is what makes the file's own
	 * statement load-bearing, and it is the case this refuses on.
	 */
	private static function ambientProviderOf(info: FileInfo, imp: ImportInfo, index: SymbolIndex): Null<String> {
		if (imp.guarded || !info.ambientImportsBounded) return null;
		if (imp.kind != ImportKind.Import && imp.kind != ImportKind.Using) return null;
		if (imp.kind == ImportKind.Using && usingCompetitorInScope(info, imp)) return null;
		final simple: String = SourceText.lastSegment(imp.raw);
		// The NEAREST group binding the name AT ALL — guardedness must not steer this choice. Filtered
		// to unguarded binders the search walks PAST a nearer group whose only binder is `#if`-guarded
		// and reports a farther identical one, so deleting the file's own statement retargets the name
		// in the builds that guard is on. A guarded binder in the nearest group makes the question refuse.
		final nearest: Null<AmbientImportGroup> = nearestBinder(info, simple);
		if (nearest == null) return null;
		// EVERY binder of the name in that group must be the identical statement: within one file the
		// LAST binder of a simple name wins, so a guarded or differently-pathed sibling decides the name
		// in some build. And no own statement is exempt — the binder that survives is an ambient one, so
		// a second own binder would decide it instead and the deletion is a retarget.
		final binders: Array<ImportInfo> = nearest.imports.filter(o -> bindsSimpleName(o, simple));
		final identical: Bool = binders.foreach(o -> !o.guarded && o.kind == imp.kind && o.raw == imp.raw);
		return identical && !bindsElsewhere(info, imp, '', simple, index) ? nearest.file : null;
	}

	/**
	 * Whether a `using` other than `imp` and its ambient twins is in scope for `info` — the gate that
	 * keeps the identity argument honest for the one kind it does not hold for.
	 *
	 * A `using` binds a NAME and a POSITION in the static-extension order, and the position is what an
	 * identical statement elsewhere does NOT reproduce. Checked against the compiler rather than
	 * assumed: extensions are tried in REVERSE declaration order, every own statement outranks every
	 * ambient one, a NEARER
	 * ambient group outranks a farther one, and within one file the last declaration wins. So deleting
	 * the file's own statement hands each method to whichever competitor is next in that order, and
	 * only an EMPTY field of competitors makes the two positions interchangeable. Naming the method
	 * that would actually move needs a receiver-aware collision test, which this rule does not have.
	 *
	 * An ambient `using` of the SAME module is not a competitor: it names the module this statement
	 * names, so whichever of them wins, the method resolves to the same static.
	 */
	private static function usingCompetitorInScope(info: FileInfo, imp: ImportInfo): Bool {
		for (o in info.imports) if (o.kind == ImportKind.Using && (o.span.from != imp.span.from || o.span.to != imp.span.to)) return true;
		for (group in info.ambientImports) for (o in group.imports) if (o.kind == ImportKind.Using && o.raw != imp.raw) return true;
		return false;
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
