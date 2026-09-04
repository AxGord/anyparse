package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * One file's text plus the two masks every reference test takes. `excluded` is where an occurrence
 * does not count at all — the file's own import statements, plus its comment regions, since a
 * comment resolves no type. `commentRegions` is the same comment list under its OTHER job: a `.`
 * inside a comment qualifies nothing, so the dotted-tail test has to know where comments are
 * even for an occurrence outside them. Both hoisted once per file.
 */
private typedef FileScan = { source: String, excluded: Array<Span>, commentRegions: Array<Span> };

/**
 * Flags `import` / `using` statements whose bound name is never referenced
 * elsewhere in the same file. Import extraction (kind / alias / span,
 * skip-parse handling) rides on the cross-file `SymbolIndex`; the "is it
 * referenced" test is a raw word-boundary scan of the source, OUTSIDE the
 * import statements themselves.
 *
 * ## Why a raw scan, not the AST
 *
 * An earlier version collected occurrences from the plugin's `parseFile` +
 * `parseFileTypeRefs` trees. That MISSED references the type projection does
 * not surface — a type nested in `Array<{ f: Array<Name> }>`, for one — and
 * `lint --fix` then deleted a needed import, breaking the build. A raw word-boundary scan catches every reference the compiler can see, at the cost of also
 * counting the name inside STRING literals. That trade is the right one for an autofix: err
 * toward a false NEGATIVE (a missed unused import) over a false POSITIVE (deleting a needed
 * one), and a string is where the trade earns its keep — `Type.resolveClass('Foo')` and the
 * macro family reach a type through one, and nothing else in the check would see them.
 *
 * COMMENTS are masked out, and were not until 2026-08-27. A comment resolves nothing, so the
 * false-positive risk the string case carries does not exist there, and the cost of the blanket
 * bias was measured: masking comments turned up 41 dead imports across this project's own `src`
 * and `test`, all 41 deleted with both binaries still building, and 11 more on the Pony corpus,
 * where the `lint-oracle` compile before and after came back byte-identical.
 *
 * ## Dotted tails do not count
 *
 * The one occurrence class the scan does NOT accept is a qualified tail:
 * `RefactorSupport.referencedUnqualifiedInRange` drops an occurrence whose
 * preceding non-whitespace char is a qualification `.`. An import binds a
 * SIMPLE name, while a dotted path resolves from its root — a file whose only
 * mentions of the bound name are `haxe.macro.Context.currentPos()` needs no
 * import, and counting those tails kept such an import alive forever. The
 * root of a path is not dot-preceded and still counts (`Mod.VALUE` is what
 * `import pkg.Mod;` provides), and a `...` dot is the range / rest operator,
 * never a qualifier — `for (i in 0...Limit.MAX)` is a bare reference.
 *
 * ## Conservative by design
 *
 * The bound name of an `import pkg.Mod;` / `import pkg.Mod.Sub;` is the leaf
 * segment (`Mod` / `Sub`); for `import pkg.Mod as Alias;` it is the alias. If
 * that name occurs as no word-boundary token anywhere outside the import
 * statements the import is unused → `Warning` — except a plain module import
 * whose module is IN the lint file set: it binds every top-level type of the
 * module, so a reference to any SECONDARY type keeps it (see
 * `secondaryTypeReferenced`), and a reference to a bare CONSTRUCTOR of an
 * in-set enum / enum-abstract type keeps it too (`enumCtorReferenced` —
 * resolved only when the enum module is itself in the lint set, so run
 * `--fix` project-wide). The remaining forms:
 *
 *  - `import pkg.Type.*;` (static wildcard) — when `Type` is in the lint set
 *    its static fields / enum(-abstract) values / constructors are known, so
 *    a bare reference to any keeps the import and none referenced is a
 *    deletable `Warning` (`addWildViolation`). A package `import pkg.*;` or a
 *    wildcard on an out-of-set type has an unknown symbol set and stays an
 *    unverifiable `Info`.
 *  - `using pkg.Mod;` — in use when its bound name is referenced (a static /
 *    type use such as `StringTools.fastCodeAt`) OR one of the extension
 *    methods it provides is called as `.method(`. Verified-unused when the
 *    module's methods are known (`knownExtensionMethods`, a `Warning` that
 *    `--fix` deletes); an unknown module stays an `Info`. See
 *    `addUsingViolation`.
 *
 * ## Report vs fix
 *
 * `fix` emits an empty-text edit over the statement span of every `Warning`,
 * so `lint --fix` deletes exactly the imports the scan PROVED unreferenced.
 * Everything the scan cannot prove is an `Info` and is report-only: a
 * wildcard or `using` whose symbol set is outside the lint scope, an import
 * whose declaring module is not in the scope, and any `#if`-guarded import
 * (the branch-blind scan cannot tell used-here from used-in-another-branch,
 * and a deletion inside a conditional region would be unsafe).
 */
@:nullSafety(Strict)
final class UnusedImport implements Check {

	/**
	 * The half of a `not in lint scope` message that is the GUARD's sentence rather than the
	 * import's name — shared with `DECLINE_NOT_IN_SCOPE` below so the reported message and the
	 * `--fix` ledger's reason cannot drift apart. Same contract for the three constants after it.
	 */
	private static inline final MSG_NOT_IN_SCOPE: String =
		'declaration not in lint scope, cannot verify unused (lint with its source module included)';

	/** The wildcard arm's own words for "the symbol set behind this import is unknown". */
	private static inline final MSG_WILD_UNTRACKED: String = 'usage not tracked';

	/** The `using` arm's own words for the same unknown symbol set. */
	private static inline final MSG_USING_UNTRACKED: String = 'extension use not tracked';

	/** The suffix `make` appends when it caps a guarded `Warning` at `Info`. */
	private static inline final MSG_GUARDED: String = '`#if`-guarded, so advisory only: delete it by hand';

	/**
	 * Why `fix` produced nothing for a finding, per arm — the sentence `apq lint --fix` prints after
	 * `fix DECLINED — `. Each one OPENS with the constant its own message is built from, so the two
	 * are one string by construction: a reader of the report and a reader of the ledger get the same
	 * verdict, and editing either edits both.
	 *
	 * `fix` deletes exactly the `Warning`s, so every `Info` this check emits IS a decline, and each
	 * of the four is a different question the run could not answer — which is why one reason per arm,
	 * written where the arm decides, and not one sentence for the rule.
	 */
	private static final DECLINE_NOT_IN_SCOPE: String = '$MSG_NOT_IN_SCOPE — the module is declared in no file this run read, so a '
		+ 'SECONDARY top-level type or a bare enum constructor of it could be the reference that keeps the import alive; deleting one '
		+ 'on the bound name alone broke real builds. Lint the project root, or add the module\'s root to `resolutionLibs`.';

	/** Why a wildcard import is never deleted: nobody can enumerate what it brings into scope. */
	private static final DECLINE_WILD_UNTRACKED: String = '$MSG_WILD_UNTRACKED — a package wildcard, or one on a type outside the '
		+ 'report set, has an unknown member set, so no reference test can prove that NONE of its members is used';

	/** Why an unrecognised `using` is never deleted: an extension call cannot be ruled out. */
	private static final DECLINE_USING_UNTRACKED: String = '$MSG_USING_UNTRACKED — the module\'s extension methods are known neither '
		+ 'to the std probe nor to the report index, so a `.method(` call on any receiver could be resolving through it';

	/** Why a guarded import stays advisory even when the scan PROVED it unused. */
	private static final DECLINE_GUARDED: String = '$MSG_GUARDED — the verdict holds in every branch (the scan reads the raw text of '
		+ 'all of them), but the canonicaliser normalises the module-level import block ONLY, so deleting a span inside a `#if` region '
		+ 'leaves the emptied line behind as a second blank';

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

		// The report-scoped index drives the per-file violation loop and the
		// report-scoped member set (kept report-scoped so a wildcard / `using`
		// verdict never widens).
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		// The resolution index — report files UNION configured library roots (openfl /
		// lime) — when the plugin carries a resolution scope, else the report index.
		// Named-import liveness and existence resolve against it, so an unused library
		// import becomes a verifiable deletable Warning, while a library import kept
		// live by a secondary type / bare enum constructor stays live.
		final resolveIndex: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		// Top-level type names per resolution-scoped module — a plain module import
		// binds ALL of them, so the used-check must consult every name.
		final moduleTypes: Map<String, Array<String>> = [];
		for (info in resolveIndex.allFiles()) moduleTypes[info.module] = [for (t in info.types) t.name];
		// Enum-constructor names per importable path (a main type binds under its
		// module, a sub-module type under `module.Type`) — a bare `import pkg.Enum;`
		// is in use when one of its constructors is referenced bare, even if `Enum`
		// itself never appears.
		final enumKinds: Array<String> = plugin.refShape().bareConstructorTypeKinds ?? [];
		final enumCtorsByPath: Map<String, Array<String>> = [];
		for (info in resolveIndex.allFiles()) for (t in info.types) if (enumKinds.contains(t.kind)) {
			final path: String = t.isMain ? info.module : '${info.module}.${t.name}';
			enumCtorsByPath[path] = [for (m in t.members) m.name];
		}
		// Members keyed by importable path from the resolution index — drives the
		// named-import existence gate (a module resolvable in the report set OR the
		// library is verifiable).
		final membersByPath: Map<String, Array<String>> = membersByImportPath(resolveIndex);
		// Report-scoped members, for the two arms whose SYMBOL SET must be known in
		// full before they may warn: a static wildcard (`import pkg.Type.*;`) and a
		// `using` the std probe does not recognise. Neither verdict may widen to the
		// library, so on an out-of-report type both stay unverifiable Infos. Reuse
		// the resolution map when no scope.
		final reportMembersByPath: Map<String, Array<String>> = resolveIndex == index ? membersByPath : membersByImportPath(index);
		// The `using` arm's own set: every top-level type of the module contributes
		// static extensions, so a per-PATH map (which names one type) under-reports
		// it. Report-scoped for the same reason as `reportMembersByPath` — a verdict
		// that may DELETE the statement must not rest on a partially-indexed library.
		final reportMembersByModule: Map<String, Array<String>> = membersByModule(index);
		final violations: Array<Violation> = [];
		for (info in index.allFiles()) {
			final source: String = sourceOf[info.file] ?? '';
			// One mask, hoisted per file: the import statements (an occurrence inside one is not a
			// use) AND the comment regions (a comment resolves no type, so a name spelled only
			// there is not a use either). String literals are deliberately NOT in it — see the
			// class doc.
			final comments: Array<Span> = SourceComments.collectCommentRegions(plugin.lexicalRegions(source));
			final scan: FileScan = {
				source: source,
				excluded: [for (imp in info.imports) imp.span].concat(comments),
				commentRegions: comments
			};
			final ignoreModules: Array<String> = plugin.checkOverrides(info.file)?.unusedImportIgnoreModules ?? [];
			for (imp in info.imports) if (!moduleIgnored(imp, ignoreModules))
				addViolation(
					violations, info.file, imp, scan, plugin, moduleTypes, enumCtorsByPath, membersByPath, reportMembersByPath,
					reportMembersByModule
				);
		}
		return violations;
	}

	/**
	 * Fix the unused-import `Warning`s by deleting the import statement (its
	 * span — which is the whole `import …;` line). The wildcard / `using`
	 * `Info` advisories are deliberately NOT fixed: they cannot be verified,
	 * so removing one could break the file. The caller batches these edits
	 * into one whole-file `canonicalize`, which drops the now-blank line.
	 *
	 * The gate here is one line — `severity == Warning` — but the DECISION it
	 * reads was taken in `run`, one arm per unverifiable form, so that is where
	 * each `Violation.declineReason` is written (see the `DECLINE_*` constants).
	 * A measured 204 of 205 findings on an 851-file tree take this branch, and
	 * until the reason travelled with them the run reported the rule as having
	 * withheld an autofix "without saying why".
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

	/** Whether `imp`'s full module path is in a checkstyle `ignoreModules` list. */
	private static inline function moduleIgnored(imp: ImportInfo, ignore: Array<String>): Bool {
		return ignore.contains(imp.raw);
	}

	/**
	 * Append the verdict for one import. A wildcard (`import pkg.*;`) is an
	 * unverifiable `Info`; a `using` is delegated to `addUsingViolation`; every
	 * other form is a `Warning` when its bound name is not referenced outside
	 * the import statements AND (for a plain resolvable module import — report
	 * set or resolution scope) no secondary top-level type of the module is
	 * referenced either.
	 *
	 * A `#if`-guarded import takes exactly the same arms. `referenced` scans the
	 * raw text of EVERY branch, so a bound name absent from the whole file is
	 * unused whichever branch compiles — guardedness is a property of the DELETE
	 * mechanics, not of the verdict, and `make` caps it there. Short-circuiting it
	 * into a blanket "cannot verify unused" `Info` discarded the secondary-type,
	 * enum-ctor, `using` and scope-existence evidence, and reported every guarded
	 * import of a macro-heavy tree as an unactionable advisory: 50 of them here,
	 * of which 44 were live and 6 were provably dead.
	 */
	private static function addViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, scan: FileScan, plugin: GrammarPlugin,
		moduleTypes: Map<String, Array<String>>, enumCtorsByPath: Map<String, Array<String>>, membersByPath: Map<String, Array<String>>,
		reportMembersByPath: Map<String, Array<String>>, reportMembersByModule: Map<String, Array<String>>
	): Void {
		switch imp.kind {
			case ImportKind.Wild:
				addWildViolation(out, file, imp, scan, reportMembersByPath);
			case ImportKind.Using:
				addUsingViolation(out, file, imp, scan, plugin, reportMembersByModule);
			case _:
				final bound: String = imp.alias ?? SourceText.lastSegment(imp.raw);
				if (referenced(scan, bound)) return;
				// A plain `import pkg.Mod;` binds every top-level type of the
				// module, not only the main one — a reference to a SECONDARY
				// typedef/enum keeps the import even though `Mod` itself is
				// never named (deleting it broke real builds). Resolvable when
				// the module is in the report set OR the resolution scope (a
				// library root); a module resolvable in neither (stdlib, an
				// unconfigured haxelib) falls back to the bound-name verdict. An
				// alias import binds just the alias — never widened.
				if (imp.kind == ImportKind.Import && secondaryTypeReferenced(imp.raw, bound, scan, moduleTypes)) return;
				// A bare `import pkg.Enum;` whose constructor is used as a bare
				// identifier (`Assert.equals(Private, m)`, expected-type resolved)
				// is in use even though `Enum` itself is never named.
				if (imp.kind == ImportKind.Import && enumCtorReferenced(imp.raw, scan, enumCtorsByPath)) return;
				if (imp.kind == ImportKind.Import && !membersByPath.exists(imp.raw)) {
					out.push(make(file, imp, Severity.Info, 'import \'${imp.raw}\': $MSG_NOT_IN_SCOPE', DECLINE_NOT_IN_SCOPE));
					return;
				}
				// `raw` is the BOUND NAME — the right thing for this rule to judge, and for an alias
				// statement the wrong thing to LABEL a finding with: one file may bind one alias name
				// twice, `#if`-guarded or not (`import a.One as U; import a.Two as U;` compiles, and
				// the last one wins), and two findings both reading `unused import 'U'` name different
				// statements a reader cannot tell apart. The module each binds is what separates them,
				// and it is exactly the half `raw` cannot carry.
				final path: Null<String> = imp.kind == ImportKind.Alias ? SymbolIndex.pathImportedBy(imp) : null;
				out.push(make(file, imp, Severity.Warning, 'unused import \'${imp.raw}\'${path == null ? '' : ' (binds $path)'}'));
		}
	}

	/** True when any OTHER top-level type of in-set module `raw` is referenced in the file outside the imports. */
	private static function secondaryTypeReferenced(
		raw: String, bound: String, scan: FileScan, moduleTypes: Map<String, Array<String>>
	): Bool {
		final types: Null<Array<String>> = moduleTypes[raw];
		return types != null && types.exists(name -> name != bound && referenced(scan, name));
	}

	/**
	 * Is `name` referenced as a SIMPLE name anywhere in the file, outside its own import statements and outside its comments? The one liveness test every arm of the check asks — see
	 * `RefactorSupport.referencedUnqualifiedInRange` for why a dotted tail is not
	 * a reference.
	 */
	private static function referenced(scan: FileScan, name: String): Bool {
		return OccurrenceScan.referencedUnqualifiedInRange(scan.source, name, 0, scan.source.length, scan.excluded, scan.commentRegions);
	}

	/**
	 * Build one violation, capping a `#if`-guarded import's verdict at `Info`.
	 *
	 * Guardedness does not change what is TRUE — `referenced` reads the raw text of
	 * every branch, so a bound name absent from the whole file is unused in every
	 * configuration, and the arms above resolve a guarded import exactly like a
	 * top-level one. It changes what the FIX may do. Deleting a span inside a `#if`
	 * region is safe but not clean: the canonicaliser normalises the module-level
	 * import block only, so the emptied line survives as a second blank, and
	 * deleting the region's last member leaves an empty `#if`/`#end` pair welded to
	 * the next declaration. Until the writer normalises inside a conditional, a
	 * guarded verdict is reported with its real reason and left to a human.
	 */
	private static function make(file: String, imp: ImportInfo, severity: Severity, message: String, ?decline: String): Violation {
		final guarded: Bool = imp.guarded && severity == Severity.Warning;
		return {
			file: file,
			span: imp.span,
			rule: 'unused-import',
			severity: guarded ? Severity.Info : severity,
			message: guarded ? '$message — $MSG_GUARDED' : message,
			// The cap IS the decline, so the reason belongs where the cap happens — not at the four
			// call sites, which would each have to restate a rule they do not apply.
			declineReason: guarded ? DECLINE_GUARDED : decline
		};
	}

	/**
	 * Append the verdict for a `using` import. It is in use when its bound name is
	 * referenced outside the imports — a static / type reference such as
	 * `MetaInspect.foo()` or `StringTools.fastCodeAt()` — OR when one of its
	 * extension methods is invoked as a `.method` call. When neither holds:
	 *
	 *  - the module's extension methods are KNOWN — a stdlib `using` the std probe
	 *    reads, or a module the REPORT set declares, whose members the index
	 *    carries in full — → a verified `unused using` `Warning`, deletable like
	 *    any other unused import;
	 *  - the module is declared NOWHERE the run can read → it stays an `Info`
	 *    advisory, since an extension call cannot be ruled out.
	 *
	 * The report-set fallback is the `using` twin of `addWildViolation`: both need
	 * the module's COMPLETE symbol set before they may warn, and both get it from
	 * the same report-scoped map so the verdict never widens to a library the run
	 * only partially indexed. Without it every project-local `using` — the whole
	 * `using pkg.MetaInspect` family of a macro-heavy tree — was unverifiable.
	 */
	private static function addUsingViolation(
		out: Array<Violation>, file: String, imp: ImportInfo, scan: FileScan, plugin: GrammarPlugin,
		reportMembersByModule: Map<String, Array<String>>
	): Void {
		final bound: String = SourceText.lastSegment(imp.raw);
		if (referenced(scan, bound)) return;
		final methods: Null<Array<String>> = plugin.knownExtensionMethods(imp.raw) ?? reportMembersByModule[imp.raw];
		if (methods == null) {
			out.push(make(file, imp, Severity.Info, 'using import \'${imp.raw}\': $MSG_USING_UNTRACKED', DECLINE_USING_UNTRACKED));
			return;
		}
		if (methods.exists(m -> OccurrenceScan.methodCalledInSource(scan.source, m, bound))) return;
		out.push(make(file, imp, Severity.Warning, 'unused using \'${imp.raw}\''));
	}

	/** True when any constructor of the enum-type imported by `raw` is referenced bare in the file (outside the imports). */
	private static function enumCtorReferenced(raw: String, scan: FileScan, enumCtorsByPath: Map<String, Array<String>>): Bool {
		final ctors: Null<Array<String>> = enumCtorsByPath[raw];
		return ctors != null && ctors.exists(name -> referenced(scan, name));
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
		out: Array<Violation>, file: String, imp: ImportInfo, scan: FileScan, membersByPath: Map<String, Array<String>>
	): Void {
		final members: Null<Array<String>> = membersByPath[stripWildStar(imp.raw)];
		if (members == null) {
			out.push(make(file, imp, Severity.Info, 'wildcard import \'${imp.raw}\': $MSG_WILD_UNTRACKED', DECLINE_WILD_UNTRACKED));
			return;
		}
		if (members.exists(name -> referenced(scan, name))) return;
		out.push(make(file, imp, Severity.Warning, 'unused wildcard import \'${imp.raw}\': no member referenced'));
	}

	/** `pkg.Type.*` -> `pkg.Type` (the path whose members the static wildcard imports); unchanged when it has no trailing `.*`. */
	private static function stripWildStar(raw: String): String {
		return raw.endsWith('.*') ? raw.substr(0, raw.length - 2) : raw;
	}

	/** Member names keyed by importable path (`module` for a main type, `module.Type` for a sub-module type). */
	private static function membersByImportPath(index: SymbolIndex): Map<String, Array<String>> {
		final map: Map<String, Array<String>> = [];
		for (info in index.allFiles()) for (t in info.types) {
			final memberPath: String = t.isMain ? info.module : '${info.module}.${t.name}';
			map[memberPath] = [for (m in t.members) m.name];
		}
		return map;
	}

	/**
	 * Member names keyed by MODULE — the union over EVERY top-level type the module
	 * declares, main and sub-module alike.
	 *
	 * This is the set `using pkg.Mod;` actually brings into scope: a static extension
	 * is contributed by every type in the module, not only by the one that shares its
	 * name. `membersByImportPath` answers a different question (what does THIS path
	 * name), and reading it in the `using` arm made the check assert that
	 * `Math.abs(ms).toFixed('000')` was not an extension call, because `toFixed` lives
	 * in the sub-module type `pony.Tools.FloatTools`. That produced a verified-unused
	 * Warning, and `--fix` deleted the `using` and broke the build.
	 */
	private static function membersByModule(index: SymbolIndex): Map<String, Array<String>> {
		final map: Map<String, Array<String>> = [];
		for (info in index.allFiles()) map[info.module] = [for (t in info.types) for (m in t.members) m.name];
		return map;
	}

}
