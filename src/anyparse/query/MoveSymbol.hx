package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Outcome of a `MoveSymbol.moveType` call. `Ok` carries the per-file
 * rewrites (only files that actually changed) plus a non-null advisory
 * — the import-completeness caveat the caller surfaces to the user.
 * `Err` carries a human-readable diagnostic (cursor not on a type
 * declaration, an ambiguous / missing type, a cross-package move, a
 * scope file that does not parse, a post-rewrite re-parse failure, or a
 * no-op). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention.
 * Mirrors `CrossRenameResult`.
 */
enum MoveResult {

	Ok(changes: Array<MoveChange>, advisory: Null<String>);
	Err(message: String);

}

/**
 * One file's rewrite produced by a move. `newSource` is the full
 * rewritten file content; only files whose content actually changed are
 * emitted. Unlike `CrossRename.FileChange` there is no occurrence count
 * — a move edits a file in several distinct ways (cut a decl, insert a
 * decl, add / remove / rewrite an import), so a single count would be
 * meaningless; the CLI reports the file as "moved" / "updated" instead.
 */
typedef MoveChange = {
	var file: String;
	var newSource: String;
}

/**
 * One binding a file already has for a simple type name: the importable path it resolves to, and
 * whether that binding is the file's OWN module declaration — the half that decides which side of a
 * collision would silently change meaning, and therefore what the refusal tells its author to do
 * about it. Asked of the destination and of the source alike, which is why it is not named for
 * either.
 */
typedef NameBinding = {
	var path: String;
	var ownModule: Bool;
}

/**
 * Outcome of the dependency-import carry — the statements the moved code needs at the
 * destination, or the reason a move must not happen at all.
 *
 * The carry needs an error channel because a bound-name COLLISION is not a missing import it can
 * work around: the destination already binds that simple name to a different module, and every
 * way of proceeding changes what some existing code means. Emitting the second binding — what the
 * op did until 2026-08-27 — is the worst of them, because Haxe resolves the last import and says
 * nothing: `import b.Dep;` carried into a destination holding `import p.Dep;` compiled clean and
 * silently retyped the destination's own `new Dep()` from `p.Dep` to `b.Dep`.
 */
enum CarryResult {

	CarryOk(lines: Array<String>);
	CarryErr(message: String);

}

/**
 * Scope-correct, format-preserving move of a TYPE declaration from one
 * file to another within the SAME PACKAGE, fixing imports across a
 * scope. The largest cross-file refactoring op in the query suite — it
 * relocates a type's source verbatim, carries the imports the type's
 * body depends on, and rewrites every importer that named the type
 * through its old module path.
 *
 * ## Same-package only — the correctness boundary
 *
 * A cross-package move is REFUSED. The moved type's body may reference
 * other types in its original package that are auto-visible WITHOUT an
 * import (Haxe same-package visibility). Moving the type to a different
 * package would silently break those references — they would need new
 * imports the op cannot derive syntactically (it has no type system to
 * resolve a bare same-package name to its declaring module). Restricting
 * to same-package moves keeps the moved type's same-package dependencies
 * auto-visible at the destination, so no new same-package import is ever
 * required. Cross-package is documented future work.
 *
 * ## Import-carrying is best-effort — the loud residual
 *
 * The op carries the source file's EXPLICIT imports that the moved
 * type's body depends on (a `D` referenced in a type position inside the
 * decl, for which the source has an `import …D;` / `using …D;` and the
 * destination does not). This is conservative and syntactic: a
 * dependency reached via a static receiver (`T.staticMethod()`) or a
 * bare value position is NOT in the type-position set `Uses.find`
 * surfaces, so its import may be missed. A missed import is a LOUD
 * residual — the destination fails to COMPILE, surfacing as an error the
 * user sees, never a silent semantic change. The advisory (always
 * non-null on success) names this gap.
 *
 * ## Atomicity
 *
 * Every rewritten file is re-parsed before ANY is returned; a rewrite
 * that fails to re-parse turns the whole move into an `Err` and the CLI
 * writes nothing. A move therefore either applies cleanly across all
 * touched files or not at all — there is never a partially-applied,
 * non-parsing multi-file state.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based) — identical to `CrossRename`.
 *
 * The op is PURE: it never reads or writes the filesystem. The CLI reads
 * every scope file (including the cursor file and the destination file)
 * and passes them in `scopeFiles`, and decides whether to write the
 * returned rewrites.
 */
@:nullSafety(Strict)
final class MoveSymbol {

	/** The advisory appended to every successful move. */
	private static final ADVISORY: String = 'verify imports in the destination — dependencies reached via a static receiver ('
		+ 'T.staticMethod()) or a value position are not auto-detected and may need a manual import. A '
		+ 'cross-package move repoints importers and the source/dest imports; a fully-qualified pkg.Type code reference is '
		+ 'refused. The bound-name collision gate reads the SCOPE index, so a name the destination binds outside it — a stdlib '
		+ 'or top-level type, a package wildcard, a `#if`-guarded import — is not seen and cannot be refused.';

	/**
	 * Move the type declaration at `line:col` (in `cursorFile`) into
	 * `destFile` (same package), fixing imports across `scopeFiles`.
	 * `plugin` / `typeRefShape` are the caller-owned grammar plugin and
	 * its `TypeRefShape` (the same pair the `uses` CLI builds), so the
	 * walk stays language-agnostic. `scopeFiles` MUST include both
	 * `cursorFile` and `destFile` — the CLI adds them when they sit
	 * outside the scope directory.
	 *
	 * Returns `Ok(changes, advisory)` with only the files that changed,
	 * or an `Err` describing why the move could not be applied.
	 */
	public static function moveType(
		cursorFile: String, line: Int, col: Int, destFile: String, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin, typeRefShape: TypeRefShape
	): MoveResult {
		// 1-3. Build the index, resolve the type at the cursor, and run the guards.
		final index: SymbolIndex = SymbolIndex.build(scopeFiles, plugin);
		final prep: MovePrep = resolveMoveTarget(index, scopeFiles, cursorFile, destFile, line, col, plugin);
		final target: MoveTarget = switch prep {
			case PErr(message): return Err(message);
			case POk(t): t;
		};
		final typeName: String = target.typeName;
		final declSpan: Span = target.declSpan;
		final cursorSource: String = target.cursorSource;
		final cursorInfo: FileInfo = target.cursorInfo;
		final destInfo: FileInfo = target.destInfo;
		final sourceOf: Map<String, String> = target.sourceOf;

		// 4. Cut span: extend backward over leading doc-comment / @:meta /
		//    indentation, and forward over one trailing newline plus the blank
		//    lines the untrimmed group had claimed. Refuse a decl sharing a source
		//    line with other code (its modifiers are part of `declSpan`, so a
		//    module-level `private` type is not that case).
		final cutInfo: Null<{ span: Span, textEnd: Int }> = computeCutSpan(cursorSource, declSpan, target.declGroupEnd);
		if (cutInfo == null) return Err('the type "$typeName" shares a source line with other code — refusing to move');
		final cut: Span = cutInfo.span;
		final declText: String = cursorSource.substring(cut.from, cutInfo.textEnd);

		// 5. Dependency imports to carry: type-position names referenced
		//    INSIDE the decl that the source imports explicitly and the
		//    destination lacks.
		final destSource: Null<String> = sourceOf[destFile];
		if (destSource == null) return Err('destination file $destFile is not in the scope file set');
		final oldImportPath: Null<String> = index.importPathOf(typeName);
		if (cursorInfo.pkg != destInfo.pkg) {
			final fqnErr: Null<String> = crossPackageFqnRefusal(index, sourceOf, oldImportPath, typeName);
			if (fqnErr != null) return Err(fqnErr);
		}
		final carried: Array<String> = switch dependencyImportLinesToCarry(
			cursorSource, declSpan, cursorInfo, destInfo, destSource, index, plugin, typeRefShape, typeName
		) {
			case CarryErr(message): return Err(message);
			case CarryOk(lines): lines;
		};

		// 6. Compute the new import path the moved type is reached by.
		final destBasename: String = RefactorSupport.baseNameOf(destFile);
		final newImportPath: String = typeName == destBasename ? destInfo.module : '${destInfo.module}.$typeName';

		// 7. Assemble per-file edits, keyed by file path.
		final editsByFile: Map<String, Array<{ span: Span, text: String }>> = [];

		// 7a. Cut the decl from the source file. A decl cut from the END of its module leaves the
		//     blank line that separated it from the previous declaration standing as the file's
		//     trailing blank, which `fmt --list` rejects — `declText` is already taken, so the cut
		//     span widens over that run and the destination is unaffected.
		editsFor(editsByFile, cursorFile).push({
			span: isBlank(cursorSource, cut.to, cursorSource.length) ? new Span(blankRunStart(cursorSource, cut.from), cut.to) : cut,
			text: ''
		});

		// 7b. Insert the decl (plus carried imports) into the destination.
		//     The carried imports go at the destination's import region;
		//     the decl text is appended after the existing content.
		final destInsertEdits: Array<{ span: Span, text: String }> = buildDestInsertEdits(destSource, declText, carried, plugin);
		for (e in destInsertEdits) editsFor(editsByFile, destFile).push(e);

		// 7c. Rewrite cross-file importers: every file (other than dest)
		//     whose import `raw` equals the old import path is repointed at
		//     the new path. Computed BEFORE the move via the index.
		buildImporterEdits(editsByFile, index, sourceOf, oldImportPath, newImportPath, destFile);

		// 7d. Source-file local import: if the source still references the
		//     moved type after the cut, it now needs an import of the new
		//     path (the type left the file). Destination-file import: if it
		//     previously imported the type through the old path, that import
		//     is now redundant (the type is local) and is removed — unless it
		//     is an ALIAS, whose binding the destination still needs.
		if (oldImportPath != null) {
			if (sourceStillUsesType(cursorSource, cut, plugin, typeRefShape, typeName)) {
				// A module-`private` type is invisible outside its own module, so the
				// import that would repair the remaining references cannot be written
				// at all — refuse instead of emitting one that does not compile.
				if (target.declPrivate)
					return Err(
						'the type "$typeName" is module-private and $cursorFile still references it after the move — '
						+ 'a private type cannot be imported from another module; make it public or move its uses too'
					);
				final insert: Null<{ span: Span, text: String }> = addImportEdit(cursorSource, cursorInfo, plugin, newImportPath);
				if (insert != null) editsFor(editsByFile, cursorFile).push(insert);
			}
			for (imp in destInfo.imports) if (SymbolIndex.pathImportedBy(imp) == oldImportPath) {
				// An ALIAS import is not made redundant by the type becoming local — the
				// destination's own code names it through the ALIAS, and nothing else binds that
				// name — so it is repointed at the new path rather than deleted. Compiled on
				// 4.3.7: a module may alias its own sub-type (`import pkg.B.Foo as F;` in
				// `pkg/B.hx`) and its own MAIN type (`import pkg.B as F;` there).
				//
				// A SELF-alias is the exception: `import pkg.A.Foo as Foo;` binds the name the
				// moved declaration itself now binds, so it is redundant in exactly the way a
				// plain import is, and repointing it leaves the destination importing its own
				// type under its own name. It compiles and no rule reports it — which is why it
				// has to be decided here rather than left to one.
				final redundant: Bool = imp.kind != ImportKind.Alias || imp.alias == typeName;
				editsFor(editsByFile, destFile).push(redundant ? { span: removeImportSpan(destSource, imp), text: '' } : {
					span: imp.span,
					text: importStatementText(imp, newImportPath, destSource.substring(imp.span.from, imp.span.to))
				});
			}
		}

		// 8-9. Apply edits per file, atomically re-parse, collect changed files.
		return applyMoveEdits(editsByFile, sourceOf, plugin, typeName);
	}

	/**
	 * The explicit imports the moved decl's body depends on that the
	 * destination lacks. A dependency name `D` is a type-position
	 * reference (`Uses.find` on the `parseFileTypeRefs` tree) whose span
	 * falls INSIDE the decl's span. For each such `D` the source binds by
	 * an explicit statement (any kind but `Wild`) whose BOUND name is `D`,
	 * and that the destination does not already carry verbatim, the
	 * statement is returned as READY TEXT for the destination.
	 *
	 * Text rather than the `ImportInfo`, because two callers used to spell
	 * that statement themselves and `raw` is the ALIAS for an `Alias` one:
	 * either would have emitted `import D;` the moment an alias dependency
	 * became carriable. The path comes from the project's one decoder
	 * (`SymbolIndex.pathImportedBy`) and the `as` / `in` suffix from the
	 * statement's own text, so a bound name is never re-spelled twice.
	 *
	 * Same-package dependencies are auto-visible at the destination (the move is same-package), so
	 * an `import` for them is neither present in the source's explicit set in a way that resolves
	 * to a different module, nor needed — only the source's genuine cross-module explicit imports
	 * are carried.
	 *
	 * A carry is REFUSED, not performed, when the destination already binds that simple name to a
	 * different module. Three shapes, all measured on the base engine at 11f22a25, all compiled and
	 * run to a CHANGED runtime class with rc 0 and no diagnostic: the destination module declares
	 * the name itself (its own type wins over any import, so the MOVED code silently rebinds to
	 * it); the destination imports the name from elsewhere (Haxe resolves the last import, so the
	 * DESTINATION's code silently rebinds to the carried module); and a sibling module of the
	 * destination's package declares it (an import beats same-package visibility, same rebind).
	 * The alias spelling is the same defect in different clothes — `import q.Thing as D;` carried
	 * next to `import r.Thing as D;` produced the identical rebind — and one gate on the BOUND
	 * name covers both. The destination-side reference test over-counts (a name in a comment or a
	 * string reads as a use), which is the conservative direction for a refusal.
	 */
	public static function dependencyImportLinesToCarry(
		source: String, declSpan: Span, cursorInfo: FileInfo, destInfo: FileInfo, destSource: String, index: SymbolIndex,
		plugin: GrammarPlugin, typeRefShape: TypeRefShape, typeName: String
	): CarryResult {
		final depNames: Array<String> = [];
		collectDependencyNames(plugin.parseFileTypeRefs(source), declSpan, typeRefShape, typeName, depNames);
		// A declaration's own type PARAMETERS stand in the same type positions its dependencies do, and
		// shadow every module-level binding of that name INSIDE it — so pricing one asks about a type
		// the moved code never means. `class Moved<Key>` beside a `p/Key.hx` refused a move that was
		// correct. The enclosing type is found by span containment, which is also what makes this work
		// for `move-member`, where `declSpan` is a member's and the parameters are the type's.
		// METHOD-level parameters are not in the index and stay priced; that residue costs a refusal,
		// never a silent rebind.
		for (t in cursorInfo.types) if (t.span.from <= declSpan.from && t.span.to >= declSpan.to) for (param in t.typeParamNames)
			depNames.remove(param);

		// One copy of the file list for the whole carry — `allFiles()` copies, and the binding walk
		// runs once per dependency name on each side.
		final files: Array<FileInfo> = index.allFiles();
		final carried: Array<String> = [];
		for (dep in depNames) {
			// The source's explicit TOP-LEVEL statement that BINDS `dep` — for a plain import /
			// using that is a path whose last segment is `dep`, for an alias it is the alias
			// itself, and `raw` is exactly the bound name in both. The kinds are listed rather
			// than `!= Wild`: this writes a statement into ANOTHER file, so a kind nobody has
			// thought about yet must be refused, not admitted. An alias whose path did not decode
			// names nothing to carry. A guarded (`#if`) provider is skipped: it would be carried
			// into the destination as an unconditional import, which could be platform-inappropriate.
			final provider: Null<ImportInfo> = cursorInfo.imports.find(
				imp ->
					!imp.guarded && (imp.kind == ImportKind.Import || imp.kind == ImportKind.Using || imp.kind == ImportKind.Alias)
					&& SymbolIndex.pathImportedBy(imp) != null && RefactorSupport.lastSegment(imp.raw) == dep
			);
			// What the SOURCE means by `dep`: its own explicit import when it has one, else the same
			// resolution ladder the destination is measured on — a dependency reached by same-package
			// visibility has no import statement to carry and was therefore never checked at all, which
			// left the headline defect open through a second route (compile-proved: a bare `Dep` from
			// `p/Dep.hx` moved into a `p/Host.hx` holding `import r.Dep;` returned `r.Dep` where it had
			// returned `p.Dep`, rc 0, nothing carried, nothing reported).
			final wanted: Null<String> = provider != null ? SymbolIndex.pathImportedBy(provider) : bindingOf(dep, cursorInfo, files)?.path;
			// A binding the destination has and the moved code does not share is the one thing carrying
			// cannot repair: whichever of the two wins, code that compiled before means a different
			// type, with no diagnostic anywhere.
			final collision: Null<String> = wanted == null
				? null
				: carryCollision(dep, wanted, destInfo, destSource, files, provider != null);
			if (collision != null) return CarryErr(collision);
			if (provider == null) continue;
			// Already present in the destination → no carry. The PATH is part of the identity: two
			// alias statements binding one name to different modules share a `raw`, and reading
			// them as the same statement would silently leave the moved decl on the DESTINATION's
			// binding instead of its own. The differing-path case no longer reaches here at all —
			// the collision gate above refuses it, for the plain and the alias spelling alike.
			final already: Bool = destInfo.imports.exists(
				imp ->
					imp.kind == provider.kind && imp.raw == provider.raw
					&& SymbolIndex.pathImportedBy(imp) == SymbolIndex.pathImportedBy(provider)
			);
			if (already) continue;
			// De-dup the carry list (a single import line could provide more
			// than one referenced name only via wildcards, which we skipped).
			final line: String = importLineFor(provider, source);
			if (!carried.contains(line)) carried.push(line);
		}
		return CarryOk(carried);
	}

	/**
	 * An edit that inserts `import <path>;` into `info` (the source file
	 * gaining a reference to the moved type), placed after the last
	 * existing import (or after the package declaration). Returns null
	 * when the import is already present.
	 */
	public static function addImportEdit(
		source: String, info: FileInfo, plugin: GrammarPlugin, path: String
	): Null<{ span: Span, text: String }> {
		// A guarded (`#if`) import of the same path does NOT satisfy `already`: the
		// moved reference must resolve in every config, so an unconditional
		// top-level import is still added.
		final already: Bool = info.imports.exists(imp -> !imp.guarded && imp.kind == ImportKind.Import && imp.raw == path);
		if (already) return null;
		final anchor: ImportAnchor = importAnchor(source, plugin, path);
		return { span: new Span(anchor.offset, anchor.offset), text: '${anchor.lead}import $path;\n${anchor.trail}' };
	}

	/**
	 * The edit that writes a carry list into `destSource`'s import region, or null when there is
	 * nothing to carry — the ONE spelling of that edit, because `MoveSymbol` and `MoveMember` had
	 * grown a byte-identical copy each and both had to change in lockstep the moment `ImportAnchor`
	 * gained `trail`. The lines land under the anchor with whatever blank lines it says the fresh run
	 * owes its neighbours; `ImportAnchor`'s own doc holds that ladder.
	 */
	public static function carriedImportEdit(
		destSource: String, carried: Array<String>, plugin: GrammarPlugin
	): Null<{ span: Span, text: String }> {
		if (carried.length == 0) return null;
		final anchor: ImportAnchor = importAnchor(destSource, plugin);
		return {
			span: new Span(anchor.offset, anchor.offset),
			text: '${anchor.lead}${carried.join('\n')}\n${anchor.trail}'
		};
	}

	/**
	 * Where a fresh import line of `path` goes in `source` — `ImportOrder.insertionFor`, the one seat
	 * every inserting caller shares (its doc holds the slot-then-fallbacks ladder). `path` is omitted
	 * by a caller with nothing to place, which asks only where the header ends.
	 *
	 * The file is re-parsed here rather than read off its indexed `FileInfo`: the seat answers from the
	 * TREE, which is what lets it see the header of a module whose whole body sits inside one `#if`
	 * region — a shape `FileInfo`'s flat import list, with only a `guarded` flag per statement, cannot
	 * describe. An unparseable source anchors at the file start, which the caller's own re-parse
	 * validation then rejects.
	 */
	public static function importAnchor(source: String, plugin: GrammarPlugin, ?path: String): ImportAnchor {
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		return tree == null ? {
			offset: 0,
			lead: '',
			trail: '',
			order: -1
		} : ImportOrder.insertionFor(source, tree, plugin, path);
	}

	/**
	 * What `info`'s file ALREADY means by the simple name `name`, or null when nothing in the indexed
	 * scope binds it (a stdlib or top-level type, which no scope-limited index can see — the fail-open
	 * direction, and the one the base engine took for every name).
	 *
	 * The order IS Haxe's resolution order, measured on 4.3.7 rather than read off the spec: a type the
	 * file's own module declares beats an import (a carried import placed next to it is inert, and the
	 * moved code binds to the module's type); an import beats a sibling module of the same package;
	 * among imports the LAST one wins, which is why the fold keeps the last match instead of the first.
	 * A `#if`-guarded import is skipped — it binds the name in some configurations only, and a carry
	 * that is a collision in one build and not in another is not a question this seat can answer.
	 *
	 * Asked of the DESTINATION it says what a carried import would collide with; asked of the SOURCE it
	 * says what the moved code means today, which is the only way to price a dependency the source
	 * reaches with no import statement at all.
	 */
	private static function bindingOf(name: String, info: FileInfo, files: Array<FileInfo>): Null<NameBinding> {
		for (t in info.types) if (t.name == name) return { path: t.isMain ? info.module : '${info.module}.${t.name}', ownModule: true };
		var imported: Null<String> = null;
		for (imp in info.imports) if (!imp.guarded && RefactorSupport.lastSegment(imp.raw) == name) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path != null) imported = path;
		}
		if (imported != null) return { path: imported, ownModule: false };
		// `isMain` FILTERS here, where in the branch above it only spells the path: a sibling module's
		// SUB-module type is not visible by simple name from another file of the package — this file's
		// own header proves it, importing `SymbolIndex.ImportKind` from its own package — so counting
		// one was a refusal against a binding that does not exist. Compile-proved: a file naming `Dep`
		// beside a sibling `p/Other.hx` declaring a secondary `Dep` is `Type not found : Dep` on 4.3.7,
		// and this used to refuse a move over it.
		for (fi in files) if (fi.pkg == info.pkg && fi.file != info.file) for (t in fi.types) if (t.name == name && t.isMain)
			return { path: fi.module, ownModule: false };
		return null;
	}

	/**
	 * Whether the destination's own code names `name` outside its import statements — the test that
	 * decides whether a differing binding is OBSERVABLE there. `RefactorSupport`'s raw scan is
	 * deliberate: it counts a mention in a comment or a string literal as a use, so the gate refuses
	 * a move it cannot prove harmless rather than performing one it cannot prove safe.
	 */
	private static function referencedInDest(destSource: String, destInfo: FileInfo, name: String): Bool {
		return RefactorSupport.referencedUnqualifiedInRange(
			destSource, name, 0, destSource.length, [for (imp in destInfo.imports) imp.span],
			RefactorSupport.collectCommentRegions(destSource)
		);
	}

	/**
	 * The reason a dependency must NOT follow the moved declaration into the destination, or null when
	 * nothing about it changes meaning. A collision is a binding the destination already has for the
	 * same simple name, resolving to a different module.
	 *
	 * Which SIDE silently moves decides both whether the collision is observable at all and what its
	 * author has to do about it, so there is one sentence per arm rather than one for the gate.
	 * `carried` says whether there is an import statement to bring along: without one the moved code
	 * takes the destination's own resolution and always moves; with one the carried line wins over
	 * everything except a type the destination module declares itself, so the side that moves is the
	 * destination's own code — and only when it names `dep`.
	 */
	private static function carryCollision(
		dep: String, wanted: String, destInfo: FileInfo, destSource: String, files: Array<FileInfo>, hasProvider: Bool
	): Null<String> {
		final standing: Null<NameBinding> = bindingOf(dep, destInfo, files);
		if (standing == null || standing.path == wanted) return null;
		final head: String = 'the moved code reaches "$dep" as $wanted, and ${destInfo.file} ';
		return if (!hasProvider)
			// Nothing to carry — the source reaches `dep` with no import statement, so at the
			// destination the moved code takes the DESTINATION's ladder. Always observable: the moved
			// declaration references `dep` by construction, which is why it is in the dependency set.
			'${head}resolves "$dep" to ${standing.path} instead, and the source binds it with no import to carry — so the moved '
				+ 'code would silently rebind to ${standing.path}; import it explicitly at the source first, or move the dependency too';
		else if (standing.ownModule)
			// A type the destination MODULE declares beats every import, so the carried line would be
			// inert and the MOVED code is the side that changes meaning — true whether or not the
			// destination names `dep` anywhere, which is why this arm does not ask.
			'${head}declares "$dep" itself (${standing.path}) — a module\'s own type wins over an import, so carrying the import '
				+ 'would silently rebind the moved code to ${standing.path}; rename one of the two, or move the dependency too';
		else if (referencedInDest(destSource, destInfo, dep))
			// An import or a same-package sibling loses to the carried line instead, so the side that
			// changes meaning is the destination's own code — and only if it names `dep` at all.
			'${head}already binds "$dep" to ${standing.path} — Haxe resolves the last import, so carrying the import would '
				+ 'silently rebind that file\'s own references from ${standing.path} to $wanted; alias one of the two imports, or '
				+ 'qualify the references';
		else
			null;
	}

	/**
	 * Append to `out` the distinct names `node`'s subtree references in a TYPE position INSIDE
	 * `declSpan` — the moved declaration's dependency set, minus the declaration's own name. Walks
	 * every hit of the type-ref projection and keeps the ones the span contains.
	 */
	private static function collectDependencyNames(
		node: QueryNode, declSpan: Span, typeRefShape: TypeRefShape, typeName: String, out: Array<String>
	): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (
			name != null && span != null && typeRefShape.typeRefKinds.contains(node.kind) && span.from >= declSpan.from
			&& span.to <= declSpan.to && name != typeName && !out.contains(name)
		)
			out.push(name);
		for (c in node.children) collectDependencyNames(c, declSpan, typeRefShape, typeName, out);
	}

	/**
	 * The source range to CUT for the declaration that OWNS `declSpan`:
	 * extended BACKWARD over the decl's leading indentation and any contiguous
	 * preceding doc-comment / line-comment / block-comment / `@:meta` lines (the
	 * `parseFile` tree drops trivia, so the cut is computed from the raw source,
	 * not the tree), and FORWARD over one trailing newline plus any blank lines up
	 * to `groupEnd`.
	 *
	 * `declSpan` is the modifier-folded, trailing-trimmed span, so the leading
	 * `private` of a module-level type is inside it and a neighbour's doc comment is
	 * not. `groupEnd` is where that group ended BEFORE the trim: the blank-line
	 * extension never runs past it, which keeps the blank separation the untrimmed
	 * cut used to remove while giving the neighbour its trivia back. (The one
	 * trailing newline is taken unconditionally, as before, so the cut can end one
	 * byte past `groupEnd` for a `;`-terminated decl.)
	 *
	 * `textEnd` splits the two: the cut REMOVES up to `span.to`, but only the
	 * text up to `textEnd` MOVES, so the blank separation the cut also takes does
	 * not arrive at the destination as a stray blank run.
	 *
	 * Returns null when the declaration shares its source line with other code
	 * (the line-up-to the decl is not pure whitespace), which a whole-line cut
	 * cannot safely express.
	 */
	private static function computeCutSpan(source: String, declSpan: Span, groupEnd: Int): Null<{ span: Span, textEnd: Int }> {
		// Start of the decl's own line.
		final lineStart: Int = lineStartOf(source, declSpan.from);
		// The characters between the line start and the decl must be pure
		// whitespace (the decl's indentation) — otherwise the decl shares a
		// line with other code and a whole-line cut would corrupt it.
		if (!isBlank(source, lineStart, declSpan.from)) return null;

		// Walk backward over contiguous preceding trivia / meta lines.
		var cutStart: Int = lineStart;
		while (cutStart > 0) {
			// `cutStart` is at the start of the current line; step to the
			// previous line.
			final prevLineEnd: Int = cutStart - 1; // the '\n' terminating the previous line
			final prevLineStart: Int = lineStartOf(source, prevLineEnd);
			final prevLine: String = source.substring(prevLineStart, prevLineEnd);
			if (isContiguousTriviaLine(prevLine))
				cutStart = prevLineStart;
			else
				break;
		}

		// Extend forward over one trailing newline so the cut removes the
		// whole decl block including its line terminator. Everything up to here is
		// the decl's OWN text, which is what the destination receives.
		var cutEnd: Int = declSpan.to;
		if (cutEnd < source.length && source.charAt(cutEnd) == '\n') cutEnd++;
		final textEnd: Int = cutEnd;

		// Then over the BLANK lines the untrimmed group had already claimed.
		// `declSpan` is the trimmed span, so for a `@:trailOpt` decl written without
		// its `;` it now stops at the closing brace — leaving behind the blank line
		// that separated the decl from its neighbour, which the untrimmed cut
		// removed. Only blank lines are taken, and never past `groupEnd`: a comment
		// in that run documents the NEXT declaration, and a `;`-terminated decl
		// (whose span never ran on) cuts exactly as before.
		while (cutEnd < groupEnd) {
			final lineEnd: Int = source.indexOf('\n', cutEnd);
			if (lineEnd < 0 || lineEnd + 1 > groupEnd || !isBlank(source, cutEnd, lineEnd)) break;
			cutEnd = lineEnd + 1;
		}

		return { span: new Span(cutStart, cutEnd), textEnd: textEnd };
	}

	/**
	 * The offset of the first byte of the run of BLANK lines that ends at `at` (a line start), or
	 * `at` itself when the line above carries code. Used to absorb the separator blank line left
	 * behind when a cut reaches the end of the module and there is no following declaration for it
	 * to separate.
	 */
	private static function blankRunStart(source: String, at: Int): Int {
		var start: Int = at;
		while (start > 0) {
			final prevLineStart: Int = lineStartOf(source, start - 1);
			if (!isBlank(source, prevLineStart, start - 1)) return start;
			start = prevLineStart;
		}
		return start;
	}

	/**
	 * Whether the declaration is module-`private` — a `Private` node inside the
	 * modifier run `declGroupSpan` folded in, i.e. between `group.from` and the
	 * declaration's own start. A module-private type is invisible OUTSIDE its own
	 * module, which is what makes an import of it after the move impossible.
	 */
	private static function hasPrivateModifier(parent: Null<QueryNode>, group: Span, declSpan: Span): Bool {
		if (parent == null) return false;
		for (sibling in parent.children) {
			final span: Null<Span> = sibling.span;
			if (sibling.kind == 'Private' && span != null && span.from >= group.from && span.to <= declSpan.from) return true;
		}
		return false;
	}

	/**
	 * Edits that insert the moved decl (and any carried imports) into the
	 * destination file. Carried imports are inserted on their own lines
	 * immediately after the destination's last existing import (or after
	 * the package declaration / at the top when there is none); the decl
	 * text is appended after the file's existing content, separated by a
	 * blank line.
	 */
	private static function buildDestInsertEdits(
		destSource: String, declText: String, carried: Array<String>, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];

		final carriedEdit: Null<{ span: Span, text: String }> = carriedImportEdit(destSource, carried, plugin);
		if (carriedEdit != null) edits.push(carriedEdit);

		// Append the decl after the file content. Ensure exactly one blank
		// line of separation from the prior content.
		final trimmedEnd: Int = trimTrailingNewlines(destSource);
		final tail: String = destSource.substring(trimmedEnd);
		final sep: String = trimmedEnd == 0 ? '' : '\n\n';
		// The cut span reaches over the decl's own line terminator, so `declText` ends in the
		// newline the SOURCE file's next line started on. Re-adding the destination's own trailing
		// newlines on top of it left every destination one blank line longer than canonical — no
		// gate saw it, because the move op splices spans and never re-emits through the writer.
		final decl: String = declText.substring(0, trimTrailingNewlines(declText));
		// The destination's OWN trailing newlines are preserved rather than normalised — a file that
		// arrived with a blank line at EOF is not this op's to canonicalise — but a destination with
		// none still gets the one terminator the appended declaration's last line needs, which is
		// what the untrimmed `declText` used to supply by accident.
		final eof: String = tail.length > 0 ? tail : '\n';
		// Replace the trailing-newline region with: separator + decl + that EOF run.
		edits.push({ span: new Span(trimmedEnd, destSource.length), text: '$sep$decl$eof' });

		return edits;
	}

	/**
	 * Does the source file STILL reference `typeName` in a type position
	 * after the moved decl is cut? Counts type-position hits OUTSIDE the
	 * cut range. When true, the source needs an import of the moved type's
	 * new path.
	 */
	private static function sourceStillUsesType(
		source: String, cut: Span, plugin: GrammarPlugin, typeRefShape: TypeRefShape, typeName: String
	): Bool {
		final typeRefTree: QueryNode = plugin.parseFileTypeRefs(source);
		var used: Bool = false;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (
				!used && node.name == typeName && span != null && typeRefShape.typeRefKinds.contains(node.kind)
				&& (span.from < cut.from || span.from >= cut.to)
			)
				used = true;
			for (c in node.children) walk(c);
		}
		walk(typeRefTree);
		return used;
	}

	/**
	 * The span to remove for an import statement, extended forward over
	 * one trailing newline so the whole line disappears (no blank-line
	 * residue).
	 */
	private static function removeImportSpan(source: String, imp: ImportInfo): Span {
		var to: Int = imp.span.to;
		if (to < source.length && source.charAt(to) == '\n') to++;
		// Also drop the import's own leading indentation if any.
		final from: Int = lineStartOf(source, imp.span.from);
		final actualFrom: Int = isBlank(source, from, imp.span.from) ? from : imp.span.from;
		return new Span(actualFrom, to);
	}

	/**
	 * Rewrite an importer's import-statement text to point at
	 * `newImportPath`, preserving the statement's kind (`import` vs. `using`) and its `as` / `in` alias
	 * suffix. The whole statement span is replaced and re-emitted with single-space
	 * separators, so the source's own spacing does NOT survive — only its meaning does.
	 * `statementText` is that file's own bytes for the span, which is the only place the
	 * alias spelling is recorded (both forms share one `ImportKind`).
	 */
	private static function importStatementText(imp: ImportInfo, newImportPath: String, statementText: String): String {
		final keyword: String = imp.kind == ImportKind.Using ? 'using' : 'import';
		final alias: Null<String> = imp.alias;
		if (alias == null) return '$keyword $newImportPath;';
		// The two spellings are interchangeable to the compiler but not to the file's author, and
		// this rewrite is a repoint, not a restyle — so the statement's own keyword is re-emitted.
		// `''` means the text did not decode as an alias import; every caller gates on
		// `pathImportedBy(imp)` matching a path, which an undecodable statement never does, so it
		// cannot arrive here — `as` is what it would fall back on.
		final spelling: String = ModuleScan.aliasKeywordOf(statementText);
		return '$keyword $newImportPath ${spelling == '' ? 'as' : spelling} $alias;';
	}

	/**
	 * `import <path>;` / `using <path>;` / `import <path> as <alias>;` text for a carried import,
	 * spelled out of `statementSource` — which MUST be the source of the file `imp` was read from,
	 * since the `as` / `in` keyword is recovered by slicing `imp.span` out of it. `raw` is the path
	 * for every kind but `Alias`, where it is the alias, so the path comes from the project's one
	 * decoder and the suffix from `importStatementText`, which already writes a repointed one.
	 *
	 * The undecodable case throws rather than falling back: the value a fallback would produce is
	 * `import <the alias>;`, the exact line this seam exists to stop emitting, and it would reach
	 * the destination file silently. The carry filter already drops such a statement, so widening
	 * that filter without widening this is what the throw is here to catch.
	 */
	private static function importLineFor(imp: ImportInfo, statementSource: String): String {
		final path: Null<String> = SymbolIndex.pathImportedBy(imp);
		if (path == null) throw new Exception('importLineFor: carried import "${imp.raw}" names no decodable module path');
		return importStatementText(imp, path, statementSource.substring(imp.span.from, imp.span.to));
	}

	/** Start offset of the line containing `offset`. */
	private static function lineStartOf(source: String, offset: Int): Int {
		var i: Int = offset < source.length ? offset : source.length;
		while (i > 0 && source.charAt(i - 1) != '\n') i--;
		return i;
	}

	/** Are `[from, to)` of `source` all whitespace (space / tab)? */
	private static function isBlank(source: String, from: Int, to: Int): Bool {
		for (i in from ... to) {
			final c: String = source.charAt(i);
			if (c != ' ' && c != '\t' && c != '\r') return false;
		}
		return true;
	}

	/**
	 * Is `line` (the verbatim text of a source line, no terminator) a
	 * contiguous trivia line that belongs WITH the following declaration:
	 * a line-comment (opens with `//`), a doc / block comment line (opens
	 * with a slash-star, a lone star, or a star-slash close), or a
	 * metadata line (opens with `@`)? Leading indentation is ignored. A
	 * blank line is NOT trivia — it is the boundary that stops the
	 * backward scan, so a blank line between the decl and an earlier
	 * comment severs the comment from the move.
	 */
	private static function isContiguousTriviaLine(line: String): Bool {
		final trimmed: String = line.trim();
		return trimmed.length != 0
			&& (trimmed.startsWith('//') || trimmed.startsWith('/*') || trimmed.startsWith('*') || trimmed.startsWith('@'));
	}

	/** Offset just past the last non-newline character of `source`. */
	private static function trimTrailingNewlines(source: String): Int {
		var i: Int = source.length;
		while (i > 0) {
			final c: String = source.charAt(i - 1);
			if (c == '\n' || c == '\r')
				i--;
			else
				break;
		}
		return i;
	}

	/**
	 * Build the source-text lookup, resolve the type declaration the cursor sits
	 * on, and run every move guard: the scope must fully parse, the cursor file
	 * must be in the scope set and on a type declaration, that type must be
	 * uniquely declared at the cursor, source and destination must differ, and
	 * both must be indexed in the SAME package (cross-package is refused). Returns
	 * the validated `MoveTarget` or a `PErr` with the precise refusal reason.
	 */
	private static function resolveMoveTarget(
		index: SymbolIndex, scopeFiles: Array<{ file: String, source: String }>, cursorFile: String, destFile: String, line: Int, col: Int,
		plugin: GrammarPlugin
	): MovePrep {
		// 1. Refuse on any skip-parse — a file we cannot read cannot be proven
		//    free of references to the type. Whole-scope on purpose, unlike the
		//    check layer's per-name gates: moving a type between modules changes
		//    the path every importer spells, and `buildImporterEdits` walks
		//    `filesImportingModule`, which sees PARSED files only — so a skipped
		//    importer would be left pointing at the old module path, silently.
		//    Unlike `MoveMember`'s twin gate there is NO later parse loop to
		//    catch it: this one is load-bearing, and removing it corrupts rather
		//    than merely widens. Single-subject and it names the files, which is
		//    what makes the refusal actionable.
		final skipped: Array<String> = index.skippedFiles();
		if (skipped.length > 0) return PErr('cannot move across scope: ${skipped.length} file(s) do not parse: ${skipped.join(', ')}');

		// Source text lookup for every scope file (the index keeps only
		// structural info, not the raw bytes).
		final sourceOf: Map<String, String> = [for (entry in scopeFiles) entry.file => entry.source];
		final cursorSource: Null<String> = sourceOf[cursorFile];
		if (cursorSource == null) return PErr('cursor file $cursorFile is not in the scope file set');

		// 2. Resolve the type declaration the cursor sits on. `fullSpan` is the
		//    FULL decl span — for a `final class` the OUTER `FinalDecl` span.
		final cursorTree: QueryNode = try plugin.parseFile(cursorSource) catch (exception: ParseError) return PErr(
			'$cursorFile does not parse: $exception'
		)
		catch (exception: Exception) return PErr('$cursorFile does not parse: ${exception.message}');
		final cursor: Int = Span.offsetOf(cursorSource, line, col);
		final declMatch: Null<TypeDeclMatch> = RefactorSupport.resolveTypeDeclAtCursor(cursorTree, cursor, cursorSource);
		if (declMatch == null) return PErr('position $line:$col is not on a type declaration');
		final typeName: String = declMatch.name;

		// 3. Guards.
		final declarers: Array<FileInfo> = index.declaringFiles(typeName);
		if (declarers.length == 0) return PErr('no type "$typeName" declared under scope');
		if (declarers.length > 1)
			return PErr('type "$typeName" is declared in ${declarers.length} files under scope — ambiguous, refusing');
		if (declarers[0].file != cursorFile)
			return PErr('the type "$typeName" at the cursor is not the one declared under scope — refusing');
		if (cursorFile == destFile) return PErr('source and destination are the same file — nothing to move');

		final cursorInfo: Null<FileInfo> = index.fileInfo(cursorFile);
		final destInfo: Null<FileInfo> = index.fileInfo(destFile);
		if (destInfo == null) return PErr('destination file $destFile is not a parseable file under scope');
		if (cursorInfo == null) return PErr('$cursorFile is not indexed');

		// Narrow the null-checked locals for the struct literal (Strict does
		// not propagate narrowing into anonymous struct fields).
		final cursorSourceNN: String = cursorSource;
		final cursorInfoNN: FileInfo = cursorInfo;
		final destInfoNN: FileInfo = destInfo;

		// The bytes the declaration OWNS, which is neither end of `fullSpan`:
		//  - `declGroupSpan` folds in the modifier / `@:meta` siblings the grammar
		//    projects BEFORE the decl, so an ordinary module-level `private
		//    typedef` no longer reads as sharing its line with other code.
		//  - `trailingTrimmedSpan` cuts the run a `@:trailOpt(';')` decl written
		//    WITHOUT its `;` swallows past its own closing brace — the blank line
		//    and the NEXT declaration's doc comment, which the parser re-stashes as
		//    that neighbour's leading trivia (the 816bb666 family).
		final parseSpan: Span = declMatch.fullSpan;
		final declParent: Null<QueryNode> = TreePath.parentOf(cursorTree, declMatch.declNode);
		final groupSpan: Span = RefactorSupport.declGroupSpan(declMatch.declNode, declParent, parseSpan);
		return POk({
			typeName: typeName,
			declSpan: RefactorSupport.trailingTrimmedSpan(cursorSourceNN, groupSpan),
			declGroupEnd: groupSpan.to,
			declPrivate: hasPrivateModifier(declParent, groupSpan, parseSpan),
			cursorSource: cursorSourceNN,
			cursorInfo: cursorInfoNN,
			destInfo: destInfoNN,
			sourceOf: sourceOf
		});
	}

	/** The per-file edit accumulator for `file`, created on first use. */
	private static function editsFor(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, file: String
	): Array<{ span: Span, text: String }> {
		var arr: Null<Array<{ span: Span, text: String }>> = editsByFile[file];
		if (arr == null) {
			arr = [];
			editsByFile[file] = arr;
		}
		return arr;
	}

	/**
	 * Repoint every cross-file importer of the moved type: a file (other than the
	 * destination, which is handled separately) whose import points at the old
	 * import path is rewritten to the new path — an `import p.T as U;` among
	 * them, matched on the path its alias binds and re-emitted with that
	 * binding intact, since dropping it strands the file on a module that no
	 * longer defines the type. A no-op when the type had no
	 * import path or the path is unchanged. Edits are accumulated into
	 * `editsByFile`.
	 */
	private static function buildImporterEdits(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, index: SymbolIndex, sourceOf: Map<String, String>,
		oldImportPath: Null<String>, newImportPath: String, destFile: String
	): Void {
		if (oldImportPath == null || oldImportPath == newImportPath) return;
		final oldModule: String = SymbolIndex.moduleOf(oldImportPath);
		for (importer in index.filesImportingModule(oldModule)) if (importer.file != destFile) { // dest handled separately.
			final importerSource: Null<String> = sourceOf[importer.file];
			if (importerSource == null) continue;
			final src: String = importerSource;
			// The path an alias statement names is not its `raw` (which is the ALIAS), and the
			// statement's own text is what tells `as` from `in`.
			for (imp in importer.imports) if (SymbolIndex.pathImportedBy(imp) == oldImportPath) editsFor(editsByFile, importer.file)
				.push({
					span: imp.span,
					text: importStatementText(imp, newImportPath, src.substring(imp.span.from, imp.span.to))
				});
		}
	}

	/**
	 * Apply the accumulated edits to each file, re-parse the result, and collect
	 * the files whose content actually changed. Atomic: a single rewritten file
	 * that fails to re-parse aborts the whole move with `Err`. `Ok` with the
	 * changed files + advisory, or `Err` when nothing changed.
	 */
	private static function applyMoveEdits(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, sourceOf: Map<String, String>, plugin: GrammarPlugin,
		typeName: String
	): MoveResult {
		final changes: Array<MoveChange> = [];
		for (file => edits in editsByFile) {
			final original: Null<String> = sourceOf[file];
			if (original == null) continue;
			final newSource: String = RefactorSupport.applyEdits(original, edits);
			if (newSource == original) continue;

			// Atomic validation: every rewritten file must re-parse.
			try
				plugin.parseFile(newSource)
			catch (exception: ParseError)
				return Err('rewritten $file does not parse: $exception')
			catch (exception: Exception)
				return Err('rewritten $file does not parse: ${exception.message}');

			changes.push({ file: file, newSource: newSource });
		}
		return changes.length == 0 ? Err('move of "$typeName" changed nothing') : Ok(changes, ADVISORY);
	}

	/**
	 * Cross-package refusal: a fully-qualified code reference to the moved
	 * type (`a.b.T` in a type position, `new a.b.T()`, `a.b.T.staticCall()`)
	 * cannot be safely repointed — the package segment would dangle after the
	 * move, and the type's import path spans several representations. Bare
	 * `T` references (reached through an import) ARE handled; the import
	 * statement itself is excluded. Returns a refusal listing the first
	 * offending file, or null. Word-bounded so `a.b.Talon` / `xa.b.T` never
	 * match; import / using statements of the same path are skipped.
	 */
	private static function crossPackageFqnRefusal(
		index: SymbolIndex, sourceOf: Map<String, String>, oldImportPath: Null<String>, typeName: String
	): Null<String> {
		if (oldImportPath == null) return null;
		final path: String = oldImportPath;
		for (file => source in sourceOf) {
			final info: Null<FileInfo> = index.fileInfo(file);
			if (info == null) continue;
			final infoNN: FileInfo = info;
			var from: Int = 0;
			while (true) {
				final at: Int = source.indexOf(path, from);
				if (at < 0) break;
				from = at + 1;
				final beforeOk: Bool = at == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(at - 1));
				final afterIdx: Int = at + path.length;
				final afterOk: Bool = afterIdx >= source.length || !RefactorSupport.isIdentChar(source.fastCodeAt(afterIdx));
				if (!beforeOk || !afterOk) continue;
				// An ALIAS statement's `raw` is the alias, so the path it spells is `aliasTarget` —
				// read `raw` here and the statement's own `p.Thing` reads as a fully-qualified CODE
				// reference, refusing a move over a file that only ever names the type through the
				// alias, with a message telling its author to add the import they already wrote.
				final inImport: Bool = infoNN.imports.exists(imp ->
					SymbolIndex.pathImportedBy(imp) == path && at >= imp.span.from && at < imp.span.to
				);
				if (!inImport)
					return 'cross-package move: "$file" references "$path" by its fully-qualified path — repointing it is unsafe; '
						+ 'convert it to a bare "$typeName" (with an import) first';
			}
		}
		return null;
	}

}

/**
 * A validated move target: the type name, the span of the bytes the
 * declaration OWNS (modifier group folded in, trailing trivia trimmed off), the
 * UNTRIMMED end of that group, whether the declaration is module-`private`, the
 * cursor file's source, the source and destination file infos, and the scope's
 * source-text lookup.
 *
 * `declGroupEnd` is kept only so the cut can tell blank-line separation the
 * span already claimed from trivia that belongs to the next declaration — see
 * `computeCutSpan`. `declPrivate` gates the source-side import: a module-private
 * type cannot be imported from another module.
 */
private typedef MoveTarget = {
	final typeName: String;
	final declSpan: Span;
	final declGroupEnd: Int;
	final declPrivate: Bool;
	final cursorSource: String;
	final cursorInfo: FileInfo;
	final destInfo: FileInfo;
	final sourceOf: Map<String, String>;
};

/** Resolution outcome of `resolveMoveTarget`: the target or a refusal. */
private enum MovePrep {

	POk(target: MoveTarget);
	PErr(message: String);

}
