package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.TypeDeclInfo;
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
 * A simple name paired with the source span it is written at. Two readings, both needing the span
 * the bare name loses: a type-POSITION occurrence inside the moved declaration, and the REGION a
 * function's type parameter shadows that name over.
 *
 * A method's `<Dep>` shadows `Dep` only inside that method, so the same name can be a parameter at
 * one occurrence and a genuine dependency at another in the same declaration — un-pricing it by
 * NAME dropped the dependency from the gate entirely, which a `pick<Dep>` beside a `var d:Dep;`
 * compile-ran to a changed runtime class with rc 0.
 */
typedef NameSpan = {
	var name: String;
	var span: Span;
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
		+ 'refused. The bound-name collision gate reads the SCOPE index and REFUSES rather than guesses whenever ONE file can '
		+ 'name its binding for a dependency and the other cannot — unless the two spell the same import statement for it, or '
		+ 'the destination never names it at all. A `#if`-guarded destination import is named separately and refused on its '
		+ 'own. What is left is the case where NEITHER side is nameable: the move proceeds, which is right for the standard '
		+ 'library (the same scope in every file) and NOT right for a wildcard of a package outside the scope, which is '
		+ 'per-file and is the door still open. A dependency reached through a MODULE import (import pkg.Mod; binding '
		+ 'pkg.Mod.Sub) is carried when the statement that produced the binding is one the index can name; a `#if`-guarded '
		+ 'module import and a module OUTSIDE the scope produce none it can, so such a dependency is neither carried nor '
		+ 'refused and the destination may need the import written by hand. A MODULE import at an importer keeps its '
		+ 'statement beside the repointed one when the source module still declares types that file names.';

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
		// Asked in BOTH directions. The path a fully-qualified code reference spells changes on every
		// move, not only a cross-package one: a SAME-package move of a secondary type takes it from
		// `p.Mod.Sub` to `p.Dest.Sub`, and of a main type from `p.Mod` to `p.Dest.Mod` — so the guard
		// that was only asked cross-package let `pony.net.rpc.IRPC.RPCBuilder` stand over a move inside
		// `pony.net.rpc` and wrote two files at rc 0 for a tree that no longer compiles.
		final fqnErr: Null<String> = qualifiedPathRefusal(index, sourceOf, oldImportPath, typeName, cursorInfo.pkg == destInfo.pkg);
		if (fqnErr != null) return Err(fqnErr);
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

		// 7a. Insert the decl (plus carried imports) into the destination.
		//     The carried imports go at the destination's import region;
		//     the decl text is appended after the existing content.
		final destInsertEdits: Array<{ span: Span, text: String }> = buildDestInsertEdits(destSource, declText, carried, plugin);
		for (e in destInsertEdits) editsFor(editsByFile, destFile).push(e);

		// 7b. Rewrite cross-file importers: every file (other than dest)
		//     whose import `raw` equals the old import path is repointed at
		//     the new path, and every file that reached the moved type through
		//     a MODULE import of the source keeps that statement or gains one.
		//     Computed BEFORE the move via the index.
		buildImporterEdits(editsByFile, index, sourceOf, oldImportPath, newImportPath, destFile, cursorInfo, typeName);
		if (oldImportPath != null)
			statementlessRepairEdits(editsByFile, index, sourceOf, oldImportPath, newImportPath, target, destFile, plugin, typeRefShape);

		// 7c. Source-file local import: if the source still references the
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
			destinationImportEdits(editsByFile, target, destSource, declText, oldImportPath, newImportPath);
		}

		// 7d. Cut the decl from the source file — LAST, because `cutEditSpan` has to see every other
		//     edit this file already carries before it may widen over an adjacent blank run. The cut and
		//     the source file's own new import share ONE offset whenever the declaration sat directly
		//     under the import region; `applyEdits` orders that tie by span width so the removal goes
		//     first, which is what keeps the insert's text out of the range being removed.
		final cursorEdits: Array<{ span: Span, text: String }> = editsFor(editsByFile, cursorFile);
		cursorEdits.push({ span: cutEditSpan(cursorSource, cut, cursorEdits), text: '' });

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
		final depNames: Array<String> = dependencyNames(source, declSpan, cursorInfo, plugin, typeRefShape, typeName);
		// One copy of the file list for the whole carry — `allFiles()` copies, and the binding walk
		// runs once per dependency name on each side.
		final files: Array<FileInfo> = index.allFiles();
		final carried: Array<String> = [];
		for (dep in depNames) {
			// A DOTTED type path is ONE leaf, so `dep` can be `Mod.Sub`. Its head is not resolved by
			// any import — `import q.Mod;` does NOT make `Mod.Sub` legal (`Type not found : Mod` on
			// 4.3.7) — it is a MODULE looked up in the file's own package and then at the top level.
			// So the PACKAGE decides it, a same-package move cannot move it, and a cross-package one
			// silently can: compile-run through the base engine, `Mod.Sub` went `p.Sub` -> `s.Sub`
			// with rc 0. A lowercase head is a fully-qualified path and is absolute everywhere.
			final dot: Int = dep.indexOf('.');
			if (dot > 0) {
				final head: String = dep.substring(0, dot);
				if (!RefactorSupport.isUpperInitial(head)) continue;
				final mineHead: Null<String> = headModuleOf(head, cursorInfo, files);
				final theirsHead: Null<String> = headModuleOf(head, destInfo, files);
				// Equal includes null == null: a head the index cannot see is a top-level module,
				// which resolves the same from every package.
				if (mineHead == theirsHead) continue;
				return CarryErr(
					'the moved code writes the qualified type "$dep", whose head "$head" is a module resolved through the '
					+ 'file\'s own package: ${cursorInfo.file} reaches ${mineHead == null ? 'the top level' : '$mineHead'} and '
					+ '${destInfo.file} reaches ${theirsHead == null ? 'the top level' : '$theirsHead'} — the reference would '
					+ 'silently change meaning; spell it fully qualified, or move the head module too'
				);
			}
			// The source's explicit TOP-LEVEL statement that BINDS `dep` — for a plain import /
			// using that is a path whose last segment is `dep`, for an alias it is the alias
			// itself, and `raw` is exactly the bound name in both. The kinds are listed rather
			// than `!= Wild`: this writes a statement into ANOTHER file, so a kind nobody has
			// thought about yet must be refused, not admitted. An alias whose path did not decode
			// names nothing to carry. A guarded (`#if`) provider is skipped: it would be carried
			// into the destination as an unconditional import, which could be platform-inappropriate.
			final direct: Null<ImportInfo> = cursorInfo.imports.find(
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
			final wanted: Null<String> = direct != null ? SymbolIndex.pathImportedBy(direct) : bindingOf(dep, cursorInfo, files)?.path;
			// A MODULE import binds every type the module declares, so the statement that provides
			// `dep` need not spell it. That rung has been PRICED by `bindingOf` since S29 and carried by
			// nobody, which cost a refusal naming "no import to carry" over an import that was right
			// there (compile-proved: the same move writes and the tree types clean once it is carried).
			final provider: Null<ImportInfo> = direct ?? moduleStatementBinding(dep, wanted, cursorInfo);
			// A binding the destination has and the moved code does not share is the one thing carrying
			// cannot repair: whichever of the two wins, code that compiled before means a different
			// type, with no diagnostic anywhere. `wanted == null` is NOT a licence to skip the gate —
			// the source binding is then merely unnameable, and it is exactly the case the base engine
			// fell through on for a stdlib name, a package wildcard and a `#if`-guarded import alike.
			final collision: Null<String> = carryCollision(dep, wanted, cursorInfo, destInfo, destSource, files, provider != null);
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
			// than one referenced name only via wildcards, which we skipped —
			// and via a MODULE import, which now reaches here and repeats).
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
	 * scope binds it. Null is UNKNOWN, never "nothing binds it": the name may still resolve through the
	 * AMBIENT top-level scope — the standard library, or a root-package module outside the scope — which
	 * no scope-limited index can see. Reading null as "free" is what let a carried import shadow a
	 * stdlib name with no diagnostic, so every caller must decide what an unknown means for its own
	 * direction rather than fall through.
	 *
	 * The order IS Haxe's resolution order, measured on 4.3.7 rather than read off the spec: a type the
	 * file's own module declares beats an import; an EXPLICIT import beats a WILDCARD one whichever is
	 * written first; a wildcard beats a sibling module of the same package; and the package beats the
	 * TOP LEVEL. Among explicit imports the LAST one wins, which is why the fold keeps the last match
	 * instead of the first. A `#if`-guarded import is skipped here — it binds the name in some
	 * configurations only, so it is not a rung of any one build's ladder; `guardedImportPath` asks about
	 * it separately, and the caller refuses on it rather than ranking it.
	 *
	 * Asked of the DESTINATION it says what a carried import would collide with; asked of the SOURCE it
	 * says what the moved code means today, which is the only way to price a dependency the source
	 * reaches with no import statement at all.
	 */
	private static function bindingOf(name: String, info: FileInfo, files: Array<FileInfo>): Null<NameBinding> {
		for (t in info.types) if (t.name == name) return { path: t.isMain ? info.module : '${info.module}.${t.name}', ownModule: true };
		final imported: Null<String> = importBinding(name, info, files);
		if (imported != null) return { path: imported, ownModule: false };
		final wild: Null<String> = wildcardBinding(name, info, files);
		if (wild != null) return { path: wild, ownModule: false };
		final scoped: Null<String> = packageOrTopLevelBinding(name, info, files);
		return scoped == null ? null : { path: scoped, ownModule: false };
	}

	/**
	 * The module path an unguarded EXPLICIT import / using of `info`'s file binds `name` to, or null.
	 * The LAST such statement wins, which is why the fold keeps the last match rather than the first.
	 *
	 * A MODULE import binds every type the module declares, not only the one that shares its name:
	 * `import q.Mod;` makes `q.Mod.Sub` reachable as bare `Sub` — compile-run on 4.3.7, and
	 * `Type.getClassName` on what it built came back `q.Sub`. Reading only the import's last segment
	 * left every such name unbound, and an unbound SOURCE name is what the collision gate refuses on.
	 * An ALIAS is excluded: `import q.Mod as X;` binds X and nothing else.
	 */
	private static function importBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		var imported: Null<String> = null;
		for (imp in info.imports) if (!imp.guarded) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path == null) continue;
			if (RefactorSupport.lastSegment(imp.raw) == name) {
				imported = path;
				continue;
			}
			if (imp.kind != ImportKind.Import && imp.kind != ImportKind.Using) continue;
			for (fi in files) if (fi.module == path) for (t in fi.types) if (t.name == name && !t.isPrivate) imported = '$path.$name';
		}
		return imported;
	}

	/**
	 * The two IMPLICIT rungs of the ladder, in their measured order: a sibling MODULE of `info`'s own
	 * package first, then the TOP LEVEL — a module of the root package, visible by simple name from
	 * every file in the project exactly as the standard library's own top-level types are. The root
	 * package's own files skip the second walk; the first has already answered for them.
	 *
	 * `isMain` FILTERS both, where the module-own branch of `bindingOf` only spells a path with it: a
	 * sibling module's SUB-module type is not visible by simple name from another file of the package
	 * — this file's own header proves it, importing `SymbolIndex.ImportKind` from its own package — so
	 * counting one was a refusal against a binding that does not exist (`Type not found : Dep` on
	 * 4.3.7). `isPrivate` filters for the same reason one step further in: `private class Dep` in
	 * `p/Dep.hx` is equally `Type not found` from `p/Host.hx`.
	 */
	private static function packageOrTopLevelBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		for (fi in files) if (fi.pkg == info.pkg && fi.file != info.file) {
			for (t in fi.types) if (t.name == name && t.isMain && !t.isPrivate) return fi.module;
		}
		if (info.pkg == '') return null;
		for (fi in files) if (fi.pkg == '') {
			for (t in fi.types) if (t.name == name && t.isMain && !t.isPrivate) return fi.module;
		}
		return null;
	}

	/**
	 * The module path a `#if`-guarded import of `info`'s file binds `name` to, or null when it has
	 * none. Kept OUT of `bindingOf`'s ladder on purpose: a guarded import is a rung in some builds and
	 * absent in others, so ranking it would answer one configuration and hide the rest.
	 *
	 * The caller uses it as a VETO rather than as an answer. Both directions were compile-run on 4.3.7
	 * with a destination holding `#if neko import r.Dep; #end`: with the carried line written ABOVE the
	 * guard the guarded import wins under `-D neko` and the MOVED code rebinds (`q.Dep` -> `r.Dep`);
	 * with an unguarded import below the guard the carried line lands last and the DESTINATION's own
	 * code rebinds (`r.Dep` -> `q.Dep`). Both exited 0 with no output. Which of the two happens is
	 * decided by where the anchor puts the line, so the veto does not ask.
	 */
	private static function guardedImportPath(name: String, info: FileInfo): Null<String> {
		var found: Null<String> = null;
		for (imp in info.imports) if (imp.guarded && RefactorSupport.lastSegment(imp.raw) == name) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path != null) found = path;
		}
		return found;
	}

	/**
	 * The module path a WILDCARD import of `info`'s file binds `name` to, or null when none of them
	 * does — including when the wildcard names a package the scope index does not hold, where the
	 * honest answer is "unknown" and the caller's unknown handling takes over.
	 *
	 * Only ONE of the two `.*` spellings binds a TYPE. `import pkg.*` brings in each MODULE of `pkg`
	 * under its main type's name — a SUB-module type stays unbound, which is why `isMain` filters here as
	 * it does on the package rung. `import pkg.Module.*` binds no type at all: it imports that
	 * module's STATIC FIELDS, measured on 4.3.7 (`trace(STATIC_FIELD)` prints, `new Mod()` and
	 * `new Sub()` are both `Type not found`), so it is not a rung and modelling it as one INVENTED a
	 * binding — which then matched `wanted` and cancelled the very ambient refusal this slice added.
	 * Privacy filters what remains: a module-`private` type is not importable by any spelling.
	 *
	 * Without this rung a wildcard was simply invisible, and the collision gate read the destination as
	 * binding nothing: `p/Host.hx` holding `import r.*` next to a moved decl reaching `q.Dep` had the
	 * carried `import q.Dep;` win over the wildcard, and `Host.dep()` came back `q.Dep` where it had
	 * been `r.Dep`, rc 0.
	 */
	private static function wildcardBinding(name: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		var found: Null<String> = null;
		for (imp in info.imports) if (!imp.guarded && imp.kind == ImportKind.Wild && imp.raw.endsWith('.*')) {
			final head: String = imp.raw.substring(0, imp.raw.length - 2);
			for (fi in files) if (fi.pkg == head) for (t in fi.types) if (t.name == name && t.isMain && !t.isPrivate) found = fi.module;
		}
		return found;
	}

	/**
	 * Whether `path` — a MODULE some file imports — could bind `name`. A module the index HOLDS is
	 * asked and answers definitively; a module OUTSIDE the scope cannot be asked and answers YES,
	 * because the constructed `<path>.<name>` is the only handle there is on `import haxe.macro.Expr;`
	 * providing `Field`.
	 *
	 * The unproven YES cannot manufacture a FALSE agreement between two files, which is what every
	 * membership test on `importCandidates` rests on. For the constructed path to EQUAL a real binding
	 * path on the other side, that side must hold an import spelling `<path>.<name>` — and on 4.3.7
	 * such an import means the SUB-TYPE of module `<path>` whenever a module `<path>` exists at all
	 * (verified with a module `P.hx` and a package `P/` both declaring `Dep`: `import P.Dep;` bound the
	 * module's sub-type). If `<path>` were only a package, the `import <path>;` this YES was read off
	 * does not compile at all (`Type not found : P`, verified) — so no source Haxe accepts reaches the
	 * disagreement, and two files that agree on such a path are naming the same type.
	 *
	 * A CARRY reads the answer rather than testing membership, so it cannot survive the unproven YES —
	 * `moduleStatementBinding`, which picks the line a carry writes, deliberately does not call this,
	 * and the measurement that forced that is recorded there.
	 */
	private static function moduleMayDeclare(path: String, name: String, files: Array<FileInfo>): Bool {
		final known: Null<FileInfo> = files.find(fi -> fi.module == path);
		return known == null || known.types.exists(t -> t.name == name && !t.isPrivate);
	}

	/**
	 * The file's LAST unguarded MODULE statement whose sub-type rung spells `wanted` — the statement
	 * that PRODUCED the binding `bindingOf` reports for `name`, and therefore the one line a carry may
	 * write into another file. Null when the ladder's answer came from anywhere else (the module's own
	 * types, an explicit import, a wildcard, the package), where this statement is not what the moved
	 * code means by the name.
	 *
	 * Asking which statement produced the ANSWER, rather than which statement COULD have, is what keeps
	 * an out-of-scope module out of the carry: nothing in the ladder ever constructs
	 * `<out-of-scope-module>.<name>`, so such a statement can never match. Admitting them on their own —
	 * the `moduleMayDeclare` answer, which is right for a membership test and wrong for a carry — makes
	 * EVERY out-of-scope module import a candidate for EVERY unbound name, `String` / `Int` / `Void` /
	 * `Array` included: measured over 285 same-package moves on the Pony tree, that priced ambient names
	 * to paths like `StringTools.String` and `haxe.MainLoop.Void` and turned 62 of 147 accepted moves
	 * into refusals.
	 */
	private static function moduleStatementBinding(name: String, wanted: Null<String>, info: FileInfo): Null<ImportInfo> {
		if (wanted == null) return null;
		var found: Null<ImportInfo> = null;
		for (imp in info.imports) if (!imp.guarded && (imp.kind == ImportKind.Import || imp.kind == ImportKind.Using)) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path != null && '$path.$name' == wanted) found = imp;
		}
		return found;
	}

	/**
	 * The module a QUALIFIED type path's head segment names from `info`'s position — its own package
	 * first, then the top level. Imports do not enter this ladder: `import q.Mod;` does not make
	 * `Mod.Sub` resolve (`Type not found : Mod` on 4.3.7), which is what makes a head PACKAGE-relative
	 * and a cross-package move able to rebind it. Null means the head is not a module this index holds,
	 * which for a head with no package of its own is the ambient top level — the same answer from every
	 * file, so two nulls agree.
	 */
	private static function headModuleOf(head: String, info: FileInfo, files: Array<FileInfo>): Null<String> {
		for (fi in files) if (fi.pkg == info.pkg && RefactorSupport.lastSegment(fi.module) == head) return fi.module;
		if (info.pkg == '') return null;
		for (fi in files) if (fi.pkg == '' && RefactorSupport.lastSegment(fi.module) == head) return fi.module;
		return null;
	}

	/**
	 * Every module path an import / using statement of `info`'s file could bind `name` to — the
	 * statement's own path when its last segment IS `name`, and `<path>.<name>` for a module import,
	 * which brings the module's other types along. Guarded statements are included: this answers "could
	 * the two files mean the same thing by this name", not "what does this build mean by it".
	 *
	 * The reconciliation half of the collision gate. `bindingOf` deliberately cannot name a binding that
	 * comes from a `#if`-guarded import or from a module OUTSIDE the indexed scope — and a refusal built
	 * on "cannot name it" then fires on the commonest macro-file shape there is, where BOTH files carry
	 * the same `#if macro import haxe.macro.Expr;`. Measured on the Pony tree: four of eleven changed
	 * outcomes in a 60-case census were exactly that, and each names a path both sides already agree on.
	 *
	 * The set is deliberately not proof of a binding — an entry is a path the statement WOULD produce if
	 * the module declares `name`, which an out-of-scope module cannot be asked. It is only ever used to
	 * cancel a refusal whose other side names one of these paths exactly, so a wrong entry costs a
	 * missed refusal on a shape where the two files already spell the same import.
	 */
	private static function importCandidates(name: String, info: FileInfo, files: Array<FileInfo>): Array<String> {
		final out: Array<String> = [];
		for (imp in info.imports) if (imp.kind != ImportKind.Wild) {
			final path: Null<String> = SymbolIndex.pathImportedBy(imp);
			if (path == null) continue;
			if (RefactorSupport.lastSegment(imp.raw) == name) {
				if (!out.contains(path)) out.push(path);
				continue;
			}
			if (imp.kind == ImportKind.Alias) continue;
			if (!moduleMayDeclare(path, name, files)) continue;
			final candidate: String = '$path.$name';
			if (!out.contains(candidate)) out.push(candidate);
		}
		return out;
	}

	/**
	 * Whether the destination's own code names `name` outside its import statements — the test that
	 * decides whether a differing binding is OBSERVABLE there. `RefactorSupport`'s raw scan is
	 * deliberate: it counts a mention in a comment or a string literal as a use, so the gate refuses
	 * a move it cannot prove harmless rather than performing one it cannot prove safe.
	 */
	private static function referencedInDest(destSource: String, destInfo: FileInfo, name: String): Bool {
		// A type that declares `name` as a HEADER type parameter spells it all over its own body, and
		// the reference scan cannot tell that from a reference to a module of that name — so those
		// declarations' spans are excluded alongside the import statements. Excluded by SPAN rather
		// than by a file-wide flag: `class Box<Date>` says nothing about a `Date` a SIBLING type in the
		// same module writes, and cancelling the whole file on it left that sibling's carry unrefused
		// (compile-run to a changed runtime class with rc 0).
		//
		// And only for a type that declares NO STATIC member, because a class type parameter is not in
		// scope inside one — `class Box<Date> { static function tag() return Date.now(); }` compiles and
		// answers the STDLIB `Date`, measured on 4.3.7 — so a static member's `Date` is an ambient
		// reference the exclusion would hide. The index carries a member's start offset but not its end,
		// so the span cannot be cut around the statics; refusing to exclude at all when the type has any
		// is the direction that costs a refusal rather than a rebind.
		final excluded: Array<Span> = [for (imp in destInfo.imports) imp.span];
		for (t in destInfo.types) if (t.typeParamNames.contains(name) && !t.members.exists(m -> m.isStatic)) excluded.push(t.span);
		return RefactorSupport.referencedUnqualifiedInRange(
			destSource, name, 0, destSource.length, excluded, RefactorSupport.collectCommentRegions(destSource)
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
		dep: String, wanted: Null<String>, cursorInfo: FileInfo, destInfo: FileInfo, destSource: String, files: Array<FileInfo>,
		hasProvider: Bool
	): Null<String> {
		final standing: Null<NameBinding> = bindingOf(dep, destInfo, files);
		final guardedDest: Null<String> = guardedImportPath(dep, destInfo);
		if (wanted == null) return unnameableSourceCollision(dep, cursorInfo, destInfo, files, standing, guardedDest);
		// A guarded import at the destination is a rung of SOME build's ladder and of no other, so
		// whether the carried line wins or loses is a per-configuration question. Refuse either way:
		// both directions were compile-run to a changed runtime class with rc 0.
		if (guardedDest != null && guardedDest != wanted && !importCandidates(dep, cursorInfo, files).contains(guardedDest))
			return 'the moved code reaches "$dep" as $wanted, and ${destInfo.file} binds "$dep" to $guardedDest inside a `#if` '
				+ 'guard — under that guard one of the two imports is last and the other loses, silently rebinding either the '
				+ 'moved code or the destination\'s; alias one of the two imports, or move the dependency too';
		if (standing == null) {
			// Nothing the index can name binds `dep` at the destination, which is NOT "nothing binds
			// it": the ambient top-level scope is invisible from here. Two ways that bites, one per
			// side of the move.
			return if (!hasProvider)
				// No carry, so the moved code takes the destination's ladder, and the ladder's visible
				// rungs are all empty — what is left is the ambient scope. Compile-proved: `p/Date.hx`
				// shadowing the stdlib `Date` for a same-package source, moved to a destination the
				// index says nothing about, resolved to the STDLIB `Date` with rc 0.
				'the moved code reaches "$dep" as $wanted with no import to carry, and nothing in the indexed scope binds '
					+ '"$dep" at ${destInfo.file} — the moved code would take that file\'s own resolution, which this index '
					+ 'cannot see; import "$dep" explicitly at the source first, or move the dependency too';
			else if (referencedInDest(destSource, destInfo, dep) && !importCandidates(dep, destInfo, files).contains(wanted))
				// The destination NAMES `dep` and the index cannot say what it means by it, so it means
				// something ambient — and a carried import outranks the ambient scope. Compile-proved
				// twice: a stdlib `Date` and a root-package `Dep.hx` at the destination each came back
				// as the carried module's type instead, rc 0, no output.
				'the moved code reaches "$dep" as $wanted, and ${destInfo.file} references "$dep" while nothing in the '
					+ 'indexed scope binds it there — it resolves through the ambient top level (a stdlib or top-level type, or '
					+ 'an out-of-scope package), which a carried import outranks, so carrying it would silently rebind that '
					+ 'file\'s own references to $wanted; alias the import, or qualify the references';
			else
				null;
		}
		if (standing.path == wanted) return null;
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
	 * The `wanted == null` half of the collision gate: the SOURCE's own binding for `dep` is not
	 * nameable — the moved code reaches it through the ambient top level (the stdlib, or a module
	 * outside the scope), a wildcard whose package the index does not hold, or a `#if`-guarded import.
	 * Nothing is carried for any of those, so at the destination the moved code takes the DESTINATION's
	 * ladder, and there are only two answers: the destination's ladder is ALSO ambient, which is the
	 * same scope in every file and so cannot differ — or it names something, and then it names
	 * something else.
	 *
	 * Except when the two files spell the SAME statement for `dep`. Two macro modules each carrying
	 * `#if macro import haxe.macro.Expr;` is the commonest shape in the tree, and there the index can
	 * name neither side while the two agree perfectly — four of eleven changed outcomes in a 60-case
	 * `move` census over the Pony tree were exactly that.
	 */
	private static function unnameableSourceCollision(
		dep: String, cursorInfo: FileInfo, destInfo: FileInfo, files: Array<FileInfo>, standing: Null<NameBinding>,
		guardedDest: Null<String>
	): Null<String> {
		if (standing == null && guardedDest == null) return null;
		final reachable: Array<String> = importCandidates(dep, cursorInfo, files);
		if ((standing == null || reachable.contains(standing.path)) && (guardedDest == null || reachable.contains(guardedDest)))
			return null;
		// The path once, and the `#if` note once beside it — interpolating a pre-suffixed string into
		// both slots produced "rebind to X under a #if guard under a #if guard".
		final theirs: String = standing != null ? standing.path : '$guardedDest';
		final howTheirs: String = standing != null ? '' : ' inside a `#if` guard';
		final mine: Null<String> = guardedImportPath(dep, cursorInfo);
		final why: String = mine != null
			? 'the source binds it to $mine inside a `#if` guard, which is not carried'
			: 'the source reaches it outside the indexed scope (a stdlib or top-level type, or a package wildcard)';
		return 'the moved code reaches "$dep" through a binding this index cannot name — $why — and ${destInfo.file} binds '
			+ '"$dep" to $theirs$howTheirs, so the moved code would silently rebind to $theirs; import "$dep" explicitly at '
			+ 'the source first, or qualify its references';
	}

	/**
	 * Append to `out` the distinct names `node`'s subtree references in a TYPE position INSIDE
	 * `declSpan` — the moved declaration's dependency set, minus the declaration's own name. Walks
	 * every hit of the type-ref projection and keeps the ones the span contains.
	 */
	private static function collectDependencyNames(
		node: QueryNode, declSpan: Span, typeRefShape: TypeRefShape, typeName: String, out: Array<NameSpan>
	): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (
			name != null && span != null && typeRefShape.typeRefKinds.contains(node.kind) && span.from >= declSpan.from
			&& span.to <= declSpan.to && name != typeName
		) {
			// Re-bound: a narrowed local does not reach an anonymous-structure literal whose expected
			// field type is non-nullable.
			final at: Span = span;
			final spelled: String = name;
			out.push({ name: spelled, span: at });
		}
		for (c in node.children) collectDependencyNames(c, declSpan, typeRefShape, typeName, out);
	}

	/**
	 * The simple type names the moved declaration depends on, with every name that is really a TYPE
	 * PARAMETER of its own removed.
	 *
	 * Two kinds of parameter, subtracted two different ways. The DECLARATION's own (`class Moved<Key>`)
	 * shadow the whole span and come from the index, so the name goes at once — pricing one asked about
	 * a type the moved code never means, and `class Mover<Key>` beside a `p/Key.hx` was refused a move
	 * that was correct. A METHOD's are not indexed at all (the grammar projects no `<...>` list for a
	 * function at any depth), so they reach the type-ref walk only through the annotations that spell
	 * them and look exactly like a dependency on a module of that name — and they are subtracted PER
	 * OCCURRENCE, because `<Dep>` on one method shadows `Dep` inside that method and nowhere else.
	 * Dropping the NAME instead dropped a sibling `var d:Dep;` from the gate as well, which compile-ran
	 * to a changed runtime class with rc 0 on a move the base engine refused.
	 */
	private static function dependencyNames(
		source: String, declSpan: Span, cursorInfo: FileInfo, plugin: GrammarPlugin, typeRefShape: TypeRefShape, typeName: String
	): Array<String> {
		final refs: Array<NameSpan> = [];
		collectDependencyNames(plugin.parseFileTypeRefs(source), declSpan, typeRefShape, typeName, refs);
		final shadows: Array<NameSpan> = functionTypeParamNames(plugin, source, declSpan);
		for (t in cursorInfo.types)
			if (t.span.from <= declSpan.from && t.span.to >= declSpan.to)
				for (param in t.typeParamNames) shadows.push({ name: param, span: declSpan });
		final out: Array<String> = [];
		for (ref in refs) {
			final shadowed: Bool = shadows.exists(s -> s.name == ref.name && ref.span.from >= s.span.from && ref.span.to <= s.span.to);
			if (!shadowed && !out.contains(ref.name)) out.push(ref.name);
		}
		return out;
	}

	/**
	 * Every type-parameter name a FUNCTION inside `declSpan` declares (`function f<K, V>(...)`).
	 *
	 * The grammar does not project a function's `<...>` list — there is no node for it at any depth —
	 * so the names exist in the tree only as the type POSITIONS that spell them, indistinguishable
	 * from a dependency on a module of that name. This recovers them from the source the same way a
	 * type declaration's header parameters are recovered: the `<...>` run that closes immediately
	 * before the parameter list's `(`, split on its top-level commas.
	 *
	 * Anchored on the `(` rather than on the function's name, because a function node's span starts at
	 * the `function` keyword and searching forward for the name would match that keyword's own first
	 * letter. A multi-constraint parameter (`<T:(A, B)>`) puts a `(` inside the list and so is not
	 * read — the names stay priced, which costs a refusal rather than a miss.
	 */
	private static function functionTypeParamNames(plugin: GrammarPlugin, source: String, declSpan: Span): Array<NameSpan> {
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		if (kinds.length == 0) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return [];
		final out: Array<NameSpan> = [];
		collectFunctionTypeParams(tree, source, declSpan, kinds, out);
		return out;
	}

	/** The recursive half of `functionTypeParamNames`. */
	private static function collectFunctionTypeParams(
		node: QueryNode, source: String, declSpan: Span, kinds: Array<String>, out: Array<NameSpan>
	): Void {
		final nullableSpan: Null<Span> = node.span;
		if (nullableSpan != null && kinds.contains(node.kind) && nullableSpan.from >= declSpan.from && nullableSpan.to <= declSpan.to) {
			final span: Span = nullableSpan;
			final list: Null<String> = typeParamListBefore(source, span);
			if (list != null) for (segment in NominalTypes.splitTypeArgumentList(list)) {
				final name: Null<String> = NominalTypes.typeParamNameOf(segment);
				// The FUNCTION's span, not the parameter's: that is the region the name shadows.
				if (name == null) continue;
				final param: String = name;
				out.push({ name: param, span: span });
			}
		}
		for (c in node.children) collectFunctionTypeParams(c, source, declSpan, kinds, out);
	}

	/**
	 * The text between the `<` and the `>` of the type-parameter list that closes immediately before
	 * the parameter list of the function starting at `span`, or null when there is none.
	 *
	 * Anchored on the `(` rather than on the function's name: a function node's span starts at the
	 * `function` keyword, so searching forward for the name would match that keyword's own first
	 * letter. A multi-constraint parameter (`<T:(A, B)>`) puts a `(` inside the list and so reads as
	 * "no list" — the names stay priced, which costs a refusal rather than a miss.
	 */
	private static function typeParamListBefore(source: String, span: Span): Null<String> {
		final open: Int = source.indexOf('(', span.from);
		if (open <= span.from || open >= span.to) return null;
		var close: Int = open - 1;
		while (close > span.from && RefactorSupport.isSpace(source.fastCodeAt(close))) close--;
		if (source.fastCodeAt(close) != '>'.code) return null;
		var depth: Int = 0;
		var i: Int = close;
		while (i > span.from) {
			final ch: Int = source.fastCodeAt(i);
			if (ch == '>'.code && source.fastCodeAt(i - 1) != '-'.code)
				depth++;
			else if (ch == '<'.code) {
				depth--;
				if (depth == 0) break;
			}
			i--;
		}
		return depth == 0 && i > span.from ? source.substring(i + 1, close) : null;
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
	 * The span the cut actually removes: `cut` itself, widened BACK over the blank run in front of it
	 * when the declaration had a blank line on both sides and the two would otherwise end up adjacent —
	 * a trailing blank at the end of a module, a double separator anywhere else. `fmt --list` rejects
	 * both, and `declText` has already been taken, so the destination is unaffected either way.
	 *
	 * The double separator was invisible until `move` stopped leaving a declaration's conditional
	 * prefix behind to fill the gap; before that only the end-of-module shape was reachable, which is
	 * why the widening read as an end-of-file special case.
	 *
	 * The widening goes FORWARD instead — over the ONE blank line after the declaration; a
	 * writer-canonical file never has two — when another edit on this file lands anywhere in
	 * `[runStart, cut.to]`, which is the leading run plus the declaration itself. Today only ONE writer
	 * can land there — the source file's own new import, whenever the declaration sat directly under the
	 * import region — and widening backward over that gap would leave the two spans overlapping: the
	 * splice produced a `pony/Or.hx` that no longer parsed, which the move's own re-parse gate turned
	 * into a refusal of the whole write. Either direction leaves exactly one separator standing,
	 * which is what the declaration owned.
	 */
	private static function cutEditSpan(source: String, cut: Span, existing: Array<{ span: Span, text: String }>): Span {
		final lineEnd: Int = source.indexOf('\n', cut.to);
		if (!isBlank(source, cut.to, lineEnd < 0 ? source.length : lineEnd)) return cut;
		final runStart: Int = blankRunStart(source, cut.from);
		return if (runStart == cut.from)
			cut
		else if (existing.exists(e -> e.span.from >= runStart && e.span.from <= cut.to))
			new Span(cut.from, lineEnd < 0 ? source.length : lineEnd + 1)
		else
			new Span(runStart, cut.to);
	}

	/**
	 * The offset of the first byte of the run of BLANK lines that ends at `at` (a line start), or
	 * `at` itself when the line above carries code — the run `cutEditSpan` absorbs.
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
		// A destination that holds NO declaration puts the import anchor at or past the point the
		// declaration is appended at, so two independent edits splice the import BELOW it and the file
		// stops compiling — `import and using may not appear after a declaration`, compile-proved on a
		// destination that was only `package p;` and on one that was `package p;` plus an import.
		// Nothing but newlines stands between the two offsets, so there is one line to write, not two:
		// emit a single edit spelling the whole tail, the header's own terminator included. The test is
		// `>=`, not `>`: a header with NO trailing newline puts the anchor exactly ON the append point,
		// and `>` sent that spelling straight back down the two-edit path.
		if (carriedEdit != null && carriedEdit.span.from >= trimmedEnd) {
			final head: String = destSource.substring(trimmedEnd, carriedEdit.span.from) + carriedEdit.text;
			edits.push({
				span: new Span(trimmedEnd, destSource.length),
				text: '${head.substring(0, trimTrailingNewlines(head))}\n\n$decl$eof'
			});
			return edits;
		}
		if (carriedEdit != null) edits.push(carriedEdit);
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

	/**
	 * Does `source` name any of `names` by its bare name, outside `excluded` spans and its comments?
	 * The question a MODULE statement's fate turns on: repointing or removing one takes away every type
	 * the module declares, so what decides is whether the file still names ANY of them.
	 */
	private static function namesAnyOf(source: String, names: Array<String>, excluded: Array<Span>): Bool {
		final comments: Array<Span> = RefactorSupport.collectCommentRegions(source);
		return names.exists(n -> RefactorSupport.referencedUnqualifiedInRange(source, n, 0, source.length, excluded, comments));
	}

	/**
	 * The DESTINATION's own statements that spelled the moved type's old path. The type is local there
	 * now, so such a statement is redundant — except in the two shapes below, where dropping it takes a
	 * binding away instead.
	 */
	private static function destinationImportEdits(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, target: MoveTarget, destSource: String, declText: String,
		oldImportPath: String, newImportPath: String
	): Void {
		final destInfo: FileInfo = target.destInfo;
		final typeName: String = target.typeName;
		final remaining: Array<String> = remainingBoundNames(target.cursorInfo, typeName);
		final destExcluded: Array<Span> = [for (imp in destInfo.imports) imp.span];
		for (imp in destInfo.imports) if (SymbolIndex.pathImportedBy(imp) == oldImportPath) {
			// A MODULE statement here binds the source module's OTHER types too, so removing it as
			// "redundant" takes them away — the destination-side twin of the importer defect, and the
			// one that survived fixing that: moving `pony.ui.gui.ButtonCore` into `ButtonImgN.hx`, whose
			// own `import pony.ui.gui.ButtonCore;` was what bound `ButtonState` for the moved code, left
			// `Type not found : ButtonState`. The moved declaration is scanned beside the destination's
			// own text because it is exactly the code the statement is being kept for; for a `using` no
			// scan is asked at all, its other types being reached through extension calls no name scan
			// sees.
			final moduleWide: Bool = (imp.kind == ImportKind.Import || imp.kind == ImportKind.Using)
				&& oldImportPath == target.cursorInfo.module;
			final keepsOthers: Bool = moduleWide && remaining.length > 0
				&& (imp.kind == ImportKind.Using || namesAnyOf(destSource, remaining, destExcluded) || namesAnyOf(declText, remaining, []));
			// A `using` is NOT made redundant by the type becoming local: the static extension is
			// granted by the STATEMENT, not by the declaration's module, and a module may `using` its
			// own sub-type (compile-proved on 4.3.7). Deleting it took `3.twice()` away from a
			// destination whose whole reason for the statement was that call — and left the two sides
			// disagreeing, since the IMPORTER side repoints the same statement. So it is repointed here
			// too, and kept beside the repointed line when the source module still declares extensions
			// this file had. Every shape this arm can emit was compiled on 4.3.7: a module `using` its
			// own sub-type, a module `using` ITSELF (the destination-basename case), `using` a module
			// with no type of its own name, and `using` a module the cut left empty.
			if (imp.kind == ImportKind.Using) {
				final statement: String = destSource.substring(imp.span.from, imp.span.to);
				editsFor(editsByFile, destInfo.file).push({
					span: imp.span,
					text: (keepsOthers ? '$statement\n${importIndent(destSource, imp)}' : '')
					+ importStatementText(imp, newImportPath, statement)
				});
				continue;
			}
			if (keepsOthers) continue;
			// An ALIAS import is not made redundant by the type becoming local — the destination's own
			// code names it through the ALIAS, and nothing else binds that name — so it is repointed at
			// the new path rather than deleted. Compiled on 4.3.7: a module may alias its own sub-type
			// (`import pkg.B.Foo as F;` in `pkg/B.hx`) and its own MAIN type (`import pkg.B as F;` there).
			//
			// A SELF-alias is the exception: `import pkg.A.Foo as Foo;` binds the name the moved
			// declaration itself now binds, so it is redundant in exactly the way a plain import is, and
			// repointing it leaves the destination importing its own type under its own name. It
			// compiles and no rule reports it — which is why it has to be decided here rather than left
			// to one.
			final redundant: Bool = imp.kind != ImportKind.Alias || imp.alias == typeName;
			editsFor(editsByFile, destInfo.file).push(redundant ? { span: removeImportSpan(destSource, imp), text: '' } : {
				span: imp.span,
				text: importStatementText(imp, newImportPath, destSource.substring(imp.span.from, imp.span.to))
			});
		}
		destinationUsingMirror(editsByFile, target, destSource, oldImportPath, newImportPath);
	}

	/**
	 * The destination-side mirror of the importer's SECONDARY-type arm: a `using <sourceModule>;` here
	 * spells the module, not the moved type's path, so the loop above never sees it — and a static
	 * extension is granted by the STATEMENT, not by the declaration's module, so the moved type stops
	 * being an extension at the very file it moved INTO. Compile-proved: a destination holding
	 * `using q.Mod;` and calling `3.twice()` through `Mod`'s secondary `Sub` loses the call.
	 *
	 * The old statement is kept unconditionally, as it is on the importer side and for the same reason
	 * — the module's remaining types are reached through extension calls no name scan can see — and the
	 * new one is written beside it. `using` only: a plain `import <sourceModule>;` needs nothing,
	 * because a module's own declaration is what the destination now reads the type off.
	 */
	private static function destinationUsingMirror(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, target: MoveTarget, destSource: String, oldImportPath: String,
		newImportPath: String
	): Void {
		final destInfo: FileInfo = target.destInfo;
		final sourceModule: String = target.cursorInfo.module;
		// A MAIN-type move spells the module path itself, and then the statement IS the one the loop
		// above already repointed — asking again would emit the new line twice.
		if (oldImportPath == sourceModule) return;
		// So does a destination `using` of the moved type's OWN path, which the loop repoints to
		// exactly the line this mirror writes: `using q.Mod;` beside `using q.Mod.Sub;` came out with
		// `using q.Dest.Sub;` twice. This is the same question `spellsOldPath` asks on the importer
		// side, and only a `using` can answer yes — a repointed ALIAS binds its alias rather than
		// granting the extension, and a plain `import` of the old path is REMOVED rather than repointed.
		if (destInfo.imports.exists(imp -> imp.kind == ImportKind.Using && SymbolIndex.pathImportedBy(imp) == oldImportPath)) return;
		for (imp in destInfo.imports) if (imp.kind == ImportKind.Using && SymbolIndex.pathImportedBy(imp) == sourceModule) {
			final statement: String = destSource.substring(imp.span.from, imp.span.to);
			editsFor(editsByFile, destInfo.file).push({
				span: imp.span,
				text: '$statement\n${importIndent(destSource, imp)}${importStatementText(imp, newImportPath, statement)}'
			});
		}
	}

	/**
	 * One importer statement's fate under a repoint. Null when the statement binds nothing the move
	 * touches.
	 *
	 * A MODULE statement — `import pkg.Mod;` / `using pkg.Mod;` — binds every type the module declares,
	 * compile-proved on 4.3.7 both ways: the module needs no type of its own name for the statement to
	 * be legal, and the two statements may stand side by side. An ALIAS is NOT one:
	 * `import pkg.Mod as M;` binds `M` and nothing else (`Type not found` on the module's other types),
	 * so its repoint is already complete.
	 */
	private static function importerStatementEdit(
		imp: ImportInfo, src: String, plan: ImporterRepoint, needsRemaining: Bool, needsMoved: Bool
	): Null<{ span: Span, text: String }> {
		final path: Null<String> = SymbolIndex.pathImportedBy(imp);
		if (path == null) return null;
		final moduleWide: Bool = imp.kind == ImportKind.Import || imp.kind == ImportKind.Using;
		// The path an alias statement names is not its `raw` (which is the ALIAS), and the statement's
		// own text is what tells `as` from `in`.
		final statement: String = src.substring(imp.span.from, imp.span.to);
		if (path == plan.oldPath) {
			// Repointing a module statement at the moved type's SUB-TYPE path strips the module's other
			// types from this file — the ButtonCore family, where eight importers lost `ButtonState`.
			// Keep the module statement beside the new one when it still has something to bind here: a
			// `using` unconditionally, because its other types are reached through EXTENSION CALLS that
			// no name scan can see.
			final keep: Bool = moduleWide && plan.mainMoved && plan.remaining.length > 0 && (
				imp.kind == ImportKind.Using || needsRemaining
			);
			return {
				span: imp.span,
				text: (keep ? '$statement\n${importIndent(src, imp)}' : '') + importStatementText(imp, plan.newPath, statement)
			};
		}
		// The mirror: a SECONDARY type leaving a module this file imports as a module. Nothing here
		// spells the OLD path, so the repoint above never sees the statement and the moved type simply
		// leaves this file's scope. The new statement goes in the old one's SLOT so that a later import
		// binding the same name still wins.
		return moduleWide && !plan.mainMoved && path == plan.sourceModule && needsMoved ? {
			span: imp.span,
			text: '$statement\n${importIndent(src, imp)}${importStatementText(imp, plan.newPath, statement)}'
		} : null;
	}

	/**
	 * The names the source module still binds for another module — every type it still declares
	 * plus their enum constructors — the binding set a MODULE statement keeps after the move, and the
	 * reason such a statement cannot simply be repointed away or dropped.
	 *
	 * `!isPrivate` is load-bearing and cheap to get wrong, because the consumer is a TEXT scan: what
	 * reaches it is a name COLLISION, not a reference. An importer that declares its own `Helper` while
	 * the source module holds a `private class Helper` is a program Haxe accepts, and without the flag
	 * the scan reads that file's own `Helper` as a reason to keep an import for a binding the language
	 * never granted.
	 */
	private static function remainingBoundNames(cursorInfo: FileInfo, typeName: String): Array<String> {
		return boundNamesOf([for (t in cursorInfo.types) if (t.name != typeName && !t.isPrivate) t]);
	}

	/**
	 * Every name the given declarations bind into a scope that reaches them: each type's own name,
	 * plus the ENUM CONSTRUCTORS an enum binds along with itself.
	 *
	 * A constructor is reachable as a bare `A` wherever its enum is — `case A(cb)` names it with the
	 * enum nowhere in the line — so a file can depend entirely on an enum it never spells, and the
	 * scan that decides whether a MODULE statement still has work to do reads only names. That is one
	 * defect in each direction, and both are compile-proved on `pony.Or`: the module statement of a
	 * file that only pattern-matches is dropped (`Unknown identifier : A` on
	 * `Pony/pony/ServiceProvider.hx`), and the statement of a file that reaches a REMAINING enum the
	 * same way would be repointed away from under it.
	 *
	 * Enum-ABSTRACT values bind the same way and are deliberately NOT collected: once the `enum`
	 * keyword is the legacy `@:enum` — or, in this corpus, a `#if (haxe_ver >= 4.2) enum #else @:enum
	 * #end` region — the index sees a plain `AbstractDecl`, so the values cannot be told from an
	 * ordinary abstract's static constants, whose names (`Red`, `Default`, `White`) would spray
	 * imports across every file that happens to spell one.
	 *
	 * `MemberInfo.guarded` is deliberately NOT filtered: a constructor declared inside a `#if`
	 * region still binds its name under that flag, and every consumer of this set answers in the
	 * direction where an extra name KEEPS or WRITES a statement. That is the opposite stance from
	 * `addImportEdit`, which refuses to let a guarded import satisfy `already` — for the same
	 * reason, since there the conservative answer is to write one anyway.
	 */
	private static function boundNamesOf(types: Array<TypeDeclInfo>): Array<String> {
		final out: Array<String> = [];
		for (t in types) {
			out.push(t.name);
			for (m in t.members) if (RefactorSupport.isEnumConstructorKind(m.kind)) out.push(m.name);
		}
		return out;
	}

	/**
	 * The names the MOVED declaration takes with it — its own plus its enum constructors, and just its
	 * own when the index carries no record of it, which is the answer the scan had before.
	 */
	private static function movedBoundNames(cursorInfo: FileInfo, typeName: String): Array<String> {
		final moved: Null<TypeDeclInfo> = cursorInfo.types.find(t -> t.name == typeName);
		return moved == null ? [typeName] : boundNamesOf([moved]);
	}

	/**
	 * Repairs for files that named the moved type without a statement spelling its path — bare
	 * same-package visibility, or an `import p.*;` wildcard, both of which the repoint walk cannot see
	 * because it only ever rewrites statements that already spell the old path, and neither of which
	 * is confined to the cursor's own package. A sibling module's MAIN type is visible package-wide
	 * by its bare name, and a SUB-TYPE is not (`Type not found`, compile-proved) — so a main type that
	 * lands as a sub-type of another module leaves every same-package file that named it with an
	 * unresolved name. Measured on the Pony tree: moving
	 * `ButtonCore` out of its own module left `pony/ui/gui/SwitchableList.hx` reading
	 * `Type not found : ButtonCore`, on the base engine and on the repoint fix alike.
	 *
	 * The file has to resolve the name to the MOVED type through its own ladder before an import is
	 * written into it — a file that means something else by `typeName` is a file this move does not
	 * touch — and a file the repoint walk already edited is left to that walk.
	 */
	private static function statementlessRepairEdits(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, index: SymbolIndex, sourceOf: Map<String, String>,
		oldImportPath: String, newImportPath: String, target: MoveTarget, destFile: String, plugin: GrammarPlugin,
		typeRefShape: TypeRefShape
	): Void {
		final cursorInfo: FileInfo = target.cursorInfo;
		// One guard this walk does NOT carry, unreachable by construction rather than forgotten: "only
		// a MAIN type was bare-visible". A SECONDARY type of a sibling module is `Type not found` from
		// that sibling's neighbours (compile-proved) — a bare name resolves to a MODULE of that name in
		// the package, never to another module's sub-type. A same-package file that DOES resolve
		// `typeName` to `oldImportPath` for a secondary move did it through a STATEMENT (`import p.Mod;`
		// answers `p.Mod.Sub` on the module rung), and the repoint walk has already edited that file —
		// which is the `editsByFile` test below, not the ladder test. Both remaining statementless rungs
		// carry `isMain` themselves.
		//
		// The walk is NOT filtered to the cursor's package. A wildcard `import p.*;` reaches a main type
		// from any package at all and has no statement spelling the old path either, so the same repair
		// is owed to a file the package filter used to skip. The second guard the same-package version
		// carried — "it stays bare-visible at the destination" — is dropped with the filter: a
		// cross-package move CAN put `p/Foo.hx`'s `Foo` at `s/Foo.hx`, where a file of package `s` (or
		// one holding `import s.*;`) already sees it. The import written there is then redundant rather
		// than wrong, which is the direction this whole walk answers in.
		final files: Array<FileInfo> = index.allFiles();
		for (info in files) {
			if (info.file == cursorInfo.file || info.file == destFile) continue;
			if (editsByFile.exists(info.file)) continue;
			final src: Null<String> = sourceOf[info.file];
			if (src == null) continue;
			if (bindingOf(target.typeName, info, files)?.path != oldImportPath) continue;
			// An empty cut span makes the source walk count every type-position reference in the file.
			if (!sourceStillUsesType(src, new Span(0, 0), plugin, typeRefShape, target.typeName)) continue;
			final insert: Null<{ span: Span, text: String }> = addImportEdit(src, info, plugin, newImportPath);
			if (insert != null) editsFor(editsByFile, info.file).push(insert);
		}
	}

	/**
	 * The whitespace an import statement's own line starts with — what a second statement written
	 * into that slot has to repeat. Empty unless the run from the line start to the statement is
	 * blank, so a statement sharing its line with code contributes no indentation.
	 */
	private static function importIndent(source: String, imp: ImportInfo): String {
		final at: Int = imp.span.from;
		final start: Int = lineStartOf(source, at);
		return isBlank(source, start, at) ? source.substring(start, at) : '';
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
		oldImportPath: Null<String>, newImportPath: String, destFile: String, cursorInfo: FileInfo, typeName: String
	): Void {
		if (oldImportPath == null || oldImportPath == newImportPath) return;
		// `moduleOf` reads the path's SHAPE (up to its first upper-initial segment) while
		// `cursorInfo.module` comes from the file path, which is what a statement's binding set
		// actually follows. They coincide for every lower-initial package — every package in this
		// project and in the corpus — so the shape-derived one only narrows the candidate importer
		// set and the file-derived one decides what each statement binds.
		final oldModule: String = SymbolIndex.moduleOf(oldImportPath);
		// Re-bound: a narrowed local does not reach an anonymous-structure literal whose expected field
		// type is non-nullable.
		final oldPath: String = oldImportPath;
		final plan: ImporterRepoint = {
			oldPath: oldPath,
			newPath: newImportPath,
			sourceModule: cursorInfo.module,
			// True when the moved type IS the source module's main type, so `import <sourceModule>;`
			// spells the old path — and is the statement the repoint consumes.
			mainMoved: oldImportPath == cursorInfo.module,
			// The names the source module still declares and another module can name. A MODULE import
			// binds EVERY one of them, not the single name it looks like it names.
			remaining: remainingBoundNames(cursorInfo, typeName),
			// The names the moved declaration takes away — its own plus its enum constructors, which
			// may be the only thing an importer ever spells.
			moved: movedBoundNames(cursorInfo, typeName)
		};
		for (importer in index.filesImportingModule(oldModule)) if (importer.file != destFile) { // dest handled separately.
			final importerSource: Null<String> = sourceOf[importer.file];
			if (importerSource == null) continue;
			final src: String = importerSource;
			final excluded: Array<Span> = [for (imp in importer.imports) imp.span];
			// Keeping an import this file no longer needs costs a lint advisory; dropping one it
			// does need costs the build — so both scans answer conservatively, and a name reached
			// through a QUALIFIED path (which needs no import) is not counted by either.
			final needsRemaining: Bool = plan.mainMoved && namesAnyOf(src, plan.remaining, excluded);
			// A file that ALSO spells the old path in a statement binding the type's OWN NAME gets the
			// moved type from the repoint of that statement, so the module statement owes it nothing —
			// without this the two both emitted the new path and the file came out with a duplicate
			// import. The two exclusions are what makes the question the right one, and each costs a
			// `Type not found` when it is missing: an ALIAS spelling the old path binds its alias and
			// not the bare name (`pathImportedBy` answers an alias's TARGET, so it matches here), and a
			// `#if`-guarded one binds the name under its own flag and under no other — which is worse
			// than the duplicate it would suppress, because the default configuration is the one that
			// stops compiling. It is the same filter `moduleStatementBinding` applies for the same
			// reason.
			final spellsOldPath: Bool = importer.imports.exists(
				imp -> !imp.guarded && imp.kind != ImportKind.Alias && SymbolIndex.pathImportedBy(imp) == plan.oldPath
			);
			final needsMoved: Bool = !plan.mainMoved && !spellsOldPath && namesAnyOf(src, plan.moved, excluded);
			for (imp in importer.imports) {
				final edit: Null<{ span: Span, text: String }> = importerStatementEdit(imp, src, plan, needsRemaining, needsMoved);
				if (edit != null) editsFor(editsByFile, importer.file).push(edit);
			}
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
	 * A fully-qualified code reference to the moved type (`a.b.T` in a type position,
	 * `new a.b.T()`, `a.b.T.staticCall()`) cannot be safely repointed — the path it spells
	 * is the one the move CHANGES, and the type's import path spans several representations.
	 * Asked in both directions: a same-package move changes `p.Mod.Sub` to `p.Dest.Sub` and
	 * `p.Mod` to `p.Dest.Mod` exactly as a cross-package one does, so the guard being asked
	 * cross-package only was the whole of T340. Bare
	 * `T` references (reached through an import) ARE handled; the import
	 * statement itself is excluded. Returns a refusal listing the first
	 * offending file, or null. Word-bounded so `a.b.Talon` / `xa.b.T` never
	 * match; import / using statements of the same path are skipped.
	 */
	private static function qualifiedPathRefusal(
		index: SymbolIndex, sourceOf: Map<String, String>, oldImportPath: Null<String>, typeName: String, samePackage: Bool
	): Null<String> {
		if (oldImportPath == null) return null;
		final path: String = oldImportPath;
		// An UNQUALIFIED path is a ROOT-package type's own module path, and the scan then matches the
		// declaration's own bare name in its own file — so asking it over a same-package move refuses
		// every such move outright. Only that direction is exempt. Cross-package the question is real
		// and the answer was already no: a bare `Foo` somewhere else stops resolving the moment `Foo`
		// enters a package, and the repair walk covers only its TYPE positions, so `Foo.make()` in a
		// third file is left dangling (`Module Foo does not define type Foo`, compile-proved on both
		// engines). Exempting the dotless path unconditionally turned that refusal into a silent write.
		if (samePackage && path.indexOf('.') < 0) return null;
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
					return '"$file" references "$path" by its fully-qualified path — the move changes that path and '
						+ 'repointing a code reference is unsafe; convert it to a bare "$typeName" (with an import) first';
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

/**
 * The per-move constants an importer repoint reads: the two import paths, the source module, whether
 * the moved type was that module's MAIN type (which decides what a statement spelling `oldPath`
 * binds), and the names the module still declares.
 */
private typedef ImporterRepoint = {
	final oldPath: String;
	final newPath: String;
	final sourceModule: String;
	final mainMoved: Bool;
	final remaining: Array<String>;
	final moved: Array<String>;
};

/** Resolution outcome of `resolveMoveTarget`: the target or a refusal. */
private enum MovePrep {

	POk(target: MoveTarget);
	PErr(message: String);

}
