package anyparse.query;

import anyparse.query.CondDirectives.CondBlock;
import anyparse.query.DependencyCarry.CarryResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.query.LexicalRegions.LexRegion;
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
 * The destination-file edits a carry list becomes, plus the `using` statements it found no seat for.
 * `unseated` non-empty is a REFUSAL the caller owes — never a silent drop.
 */
typedef CarriedEdits = {
	var usingEdit: Null<{ span: Span, text: String }>;
	var importEdit: Null<{ span: Span, text: String }>;

	/**
	 * Inserts INSIDE a `#if` region the destination already holds — one per carried guarded block
	 * whose condition the destination repeats. A block with no such region is written whole at the
	 * import anchor instead, and is then part of `importEdit`.
	 */
	var guardedEdits: Array<{ span: Span, text: String }>;

	var unseated: Array<String>;
}

/**
 * Scope-correct, format-preserving move of a TYPE declaration from one
 * file to another, in the same package or across packages, fixing
 * imports across a scope. The largest cross-file refactoring op in the
 * query suite — it relocates a type's source verbatim, carries the
 * imports the type's body depends on, and rewrites every importer that
 * named the type through its old module path.
 *
 * ## The correctness boundary — refuse rather than guess
 *
 * A cross-package move is SUPPORTED and has been since S40: the moved body's bare same-package
 * names are priced through the resolution ladder `DependencyCarry.bindingOf` walks, carried when the source has a
 * statement to carry and REFUSED when the two sides would mean different things by one name. What
 * the boundary now protects is that gate — the op refuses rather than guesses whenever one side can
 * name its binding and the other cannot. The paragraph this replaces claimed cross-package was
 * refused outright and called it future work; the CLI help said the same until S41 corrected it.
 *
 * ## Import-carrying is best-effort — and the residual is not always loud
 *
 * The op carries the source file's EXPLICIT imports that the moved type's body depends on — a `D`
 * written in a type POSITION or as the RECEIVER of a member access (`D.go()`) inside the decl, for
 * which the source has an `import …D;` / `using …D;` and the destination does not — plus every
 * unguarded `using` of the source module the destination lacks, whenever the declaration contains a
 * member access at all.
 *
 * "A missed import is a LOUD residual — the destination fails to COMPILE, never a silent semantic
 * change" is what this paragraph asserted until 2026-08-31, and it is FALSE. Measured through the
 * base engine on 4.3.7: a `Moved` reaching `r.Helper` through its source file's import, moved into
 * a destination whose own package declares `p.Helper`, came back bound to `p.Helper` — the value
 * `Moved.use()` returns went from 42 to 7, rc 0, three files written and no diagnostic anywhere.
 * The upper-initial receiver form is priced now and that move carries the import.
 * Three shapes are still missed and each is silent in the same way: a bare VALUE position
 * (`Type.createInstance(Dep, [])`), a constructor PATTERN (`case Red:`, indistinguishable from a
 * module name to the ladder), and a LOWERCASE receiver (`tools.go()`), which is deliberately
 * traded away so that every local variable does not reach the collision gate. The advisory names
 * the first and the third.
 *
 * ## Where the pieces live
 *
 * Two questions this file used to answer inline now have their own modules, and the split is by
 * EVIDENCE, not by caller. `NameMentionScan` owns the raw-TEXT question — "does this source spell
 * this name where the compiler would bind it" — over one lexical mask for every shape of it;
 * `DependencyCarry` owns the INDEX question — "what does this file bind this name to, and must the
 * source's statement travel with the moved code" — and every refusal that follows from it. What is
 * left here is the move itself: locate the declaration, compute its cut, splice it into the
 * destination, and repoint every importer.
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

	/**
	 * The advisory appended to every successful move — the residual gaps a caller must check by
	 * hand, each one a case the op deliberately declines to guess at rather than one it forgot.
	 */
	private static final ADVISORY: String = 'verify imports in the destination — a dependency reached through a VALUE position ('
		+ 'Type.createInstance(Dep, [])), a CONSTRUCTOR PATTERN (case Red:, which no index can tell from a module name) '
		+ 'or a LOWERCASE receiver (tools.go(), traded away so that every local variable does not reach the collision gate) is not '
		+ 'auto-detected and may need a manual import. An UPPER-initial static receiver (T.go()) IS priced — carried, or refused when the '
		+ 'two sides disagree about the name. So is every unguarded `using` of the source FILE the destination lacks, whenever the '
		+ 'declaration holds a member access at all: an extension call names only its method, so nothing can tell which `using` supplies '
		+ 'it, and a carried one whose bound TYPE name collides at the destination is SKIPPED rather than refused. A carried `using` is '
		+ 'declared FIRST in the destination\'s own `using` run, so Haxe (which tries static extensions in reverse declaration order) '
		+ 'ranks it LAST: where two `using` modules supply one method name for one type, the MOVED body takes the destination\'s and the '
		+ 'destination\'s own calls are untouched. That is the deliberate half — the other placement rebinds the destination instead, '
		+ 'measured q.Other -> q.Ext at rc 0 — and where the destination offers no such seat (a `#if`-guarded run below the anchor, a '
		+ '`using` sharing its line) the move is REFUSED rather than written in an order picked by accident. A cross-package move repoints '
		+ 'importers and the source/dest imports; a fully-qualified pkg.Type code reference is refused. The bound-name collision gate '
		+ 'reads the SCOPE index and REFUSES rather than guesses whenever ONE file can name its binding for a dependency and the other '
		+ 'cannot — unless the two spell the same import statement for it, or the destination never names it at all. A `#if`-guarded '
		+ 'destination import is named separately and refused on its own. What is left is the case where NEITHER side is nameable: the '
		+ 'move proceeds, which is right for the standard library (the same scope in every file) and NOT right for a wildcard of a package '
		+ 'outside the scope, which is per-file and is the door still open. A dependency reached through a MODULE import (import pkg.Mod; '
		+ 'binding pkg.Mod.Sub) is carried when the statement that produced the binding is one the index can name. A `#if`-guarded '
		+ 'statement is carried too, re-emitted at the destination under the condition that guards it at the source and merged into a '
		+ 'region the destination already spells that condition for. It is REFUSED by name where one condition cannot carry it: two '
		+ 'different regions binding one name, a statement nested in more than one region, a statement in an `#else` / `#elseif` branch '
		+ '(whose condition is the negation of the ones above it), and one sharing its line with a directive. A module OUTSIDE '
		+ '--scope is the one that still produces no nameable binding: the scope is the RESOLUTION index as well as the rewrite '
		+ 'set, so such a dependency is neither carried nor refused and the destination may need the import written by hand — '
		+ 'widen --scope to cover the dependency roots. A MODULE import at an importer keeps its statement beside the repointed one '
		+ 'when the source module still declares types that file names. The SOURCE file keeps every import it had, including one the '
		+ 'departed declaration was the last user of: whether an import is now unused is a whole-file question (a module import binds the '
		+ 'sibling types of its module, a wildcard binds no single name, and a `using` grants extension methods no name scan sees). Run '
		+ '`apq lint <file> --rule unused-import --fix`, which answers it with the resolution index — and AUTOFIXES the unguarded '
		+ 'statements only. A `#if`-guarded import no branch uses IS reported, at `info` severity with "advisory only: delete it by '
		+ 'hand", so it is hidden unless the run passes --all; re-measured on `#if sys import sys.io.File; #end` with no `File` in the '
		+ 'file, which is the shape a carried region leaves behind. Read it with --all and delete that copy yourself.';

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
		// ONE lexical scan of the cursor file for the two span walks below. Both step BACKWARD over
		// the declaration's leading trivia, and a per-line prefix test cannot tell a block comment's
		// continuation line from ordinary code — see `triviaStartOf`.
		final cursorComments: Array<Span> = SourceComments.collectCommentRegions(plugin.lexicalRegions(cursorSource));
		final cutInfo: Null<{ span: Span, textEnd: Int }> = computeCutSpan(cursorSource, declSpan, target.declGroupEnd, cursorComments);
		if (cutInfo == null) return Err('the type "$typeName" shares a source line with other code — refusing to move');
		final cut: Span = cutInfo.span;
		final declText: String = cursorSource.substring(cut.from, cutInfo.textEnd);

		// 5. Dependency imports to carry: type-position and member-access-RECEIVER
		//    names referenced INSIDE the decl that the source imports explicitly
		//    and the destination lacks, plus the source file's own unguarded
		//    `using` statements when the decl holds a member access at all.
		final destSource: Null<String> = sourceOf[destFile];
		if (destSource == null) return Err('destination file $destFile is not in the scope file set');
		final oldImportPath: Null<String> = index.importPathOf(typeName);
		// Asked in BOTH directions. The path a fully-qualified code reference spells changes on every
		// move, not only a cross-package one: a SAME-package move of a secondary type takes it from
		// `p.Mod.Sub` to `p.Dest.Sub`, and of a main type from `p.Mod` to `p.Dest.Mod` — so the guard
		// that was only asked cross-package let `pony.net.rpc.IRPC.RPCBuilder` stand over a move inside
		// `pony.net.rpc` and wrote two files at rc 0 for a tree that no longer compiles.
		final fqnErr: Null<String> = qualifiedPathRefusal(
			index, sourceOf, oldImportPath, typeName, cursorInfo.pkg == destInfo.pkg, plugin.lexicalRegions
		);
		if (fqnErr != null) return Err(fqnErr);
		final carried: Array<String> = switch DependencyCarry.dependencyImportLinesToCarry(
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
		// A `using` the destination cannot seat is a refusal, and it is asked BEFORE any edit is built:
		// the alternative is an order picked by accident, which was measured rebinding the destination's
		// own calls at rc 0.
		final unseated: Array<String> = carriedDestEdits(destSource, destInfo, carried, plugin).unseated;
		if (unseated.length > 0) return Err(unseatedUsingRefusal(destFile, unseated));
		final destInsertEdits: Array<{ span: Span, text: String }> = buildDestInsertEdits(destSource, destInfo, declText, carried, plugin);
		for (e in destInsertEdits) editsFor(editsByFile, destFile).push(e);

		// 7b. Rewrite cross-file importers: every file (other than dest)
		//     whose import `raw` equals the old import path is repointed at
		//     the new path, and every file that reached the moved type through
		//     a MODULE import of the source keeps that statement or gains one.
		//     Computed BEFORE the move via the index.
		buildImporterEdits(
			editsByFile, index, sourceOf, oldImportPath, newImportPath, destFile, cursorInfo, typeName, plugin.lexicalRegions
		);
		if (oldImportPath != null)
			statementlessRepairEdits(editsByFile, index, sourceOf, oldImportPath, newImportPath, target, destFile, plugin);

		// 7c. Source-file local import: if the source still references the
		//     moved type after the cut, it now needs an import of the new
		//     path (the type left the file). Destination-file import: if it
		//     previously imported the type through the old path, that import
		//     is now redundant (the type is local) and is removed — unless it
		//     is an ALIAS, whose binding the destination still needs.
		if (oldImportPath != null) {
			final moved: Array<String> = movedBoundNames(cursorInfo, typeName);
			if (target.declPrivate) {
				// A module-`private` type is invisible outside its own module, so the import that would
				// repair the remaining references cannot be written at all — refuse instead of emitting one
				// that does not compile. This arm asks the PROVEN scan, not the text one the import below
				// uses, and the split is the point: the text scan counts a mention in a comment or a string
				// literal, which is the conservative direction when the answer WRITES an import and the
				// wrong one when it REFUSES a move. A `/** Companion of Moved. */` above a sibling was
				// enough to refuse a move the base engine performed.
				if (NameMentionScan.nodeNamesAny(
					plugin.parseFileTypeRefs(cursorSource), moved, cut, NameMentionScan.provenRefKinds(plugin, typeRefShape)
				))
					return Err(
						'the type "$typeName" is module-private and $cursorFile still references it after the move — '
						+ 'a private type cannot be imported from another module; make it public or move its uses too'
					);
			} else if (NameMentionScan.sourceNamesAny(
				cursorSource, moved, NameMentionScan.referenceExclusions(cursorInfo, cut), plugin.lexicalRegions(cursorSource)
			)) {
				final insert: Null<{ span: Span, text: String }> = addImportEdit(cursorSource, cursorInfo, plugin, newImportPath);
				if (insert != null) editsFor(editsByFile, cursorFile).push(insert);
			}
			destinationImportEdits(editsByFile, target, destSource, declText, oldImportPath, newImportPath, plugin.lexicalRegions);
		}

		// 7d. Cut the decl from the source file — LAST, because `cutEditSpan` has to see every other
		//     edit this file already carries before it may widen over an adjacent blank run. The cut and
		//     the source file's own new import share ONE offset whenever the declaration sat directly
		//     under the import region; `applyEdits` orders that tie by span width so the removal goes
		//     first, which is what keeps the insert's text out of the range being removed.
		final cursorEdits: Array<{ span: Span, text: String }> = editsFor(editsByFile, cursorFile);
		final needsSeparator: Bool = hasSiblingsOnBothSides(cursorSource, target.declParent, target.declNode, cut, cursorComments);
		cursorEdits.push({ span: cutEditSpan(cursorSource, cut, cursorEdits, needsSeparator), text: '' });

		// 8-9. Apply edits per file, atomically re-parse, collect changed files.
		return applyMoveEdits(editsByFile, sourceOf, plugin, typeName);
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
	 * The destination-file edits a carry list becomes: at most one for the `using` half and one for the
	 * rest, plus the `using` lines the file offers no seat for, which the caller must REFUSE on.
	 *
	 * Haxe tries static extensions in REVERSE declaration order, so where a carried `using` lands decides
	 * which of two modules wins a method name they share. The ordinary import anchor cannot decide it:
	 * `ImportOrder.lastHeaderEnd` answers the last plain `import` when the file has one and the last
	 * statement of ANY import kind otherwise, so the same carried line ranked LAST in a destination
	 * holding `import a.B; using q.Other;` and FIRST in one holding only `using q.Other;`. Both were
	 * measured at rc 0 on 4.3.7 and they lose opposite halves: `q.Ext -> q.Other` for the MOVED body in
	 * the first, `q.Other -> q.Ext` for the destination's OWN call in the second.
	 *
	 * Declaring the carried line FIRST makes it rank last, deterministically. That is the half worth
	 * keeping: the destination's existing code is left exactly as it was, and the residual — the moved
	 * body taking the destination's extension where the two collide — is the one the user is looking at
	 * and the one the advisory names. Where no such seat exists the answer is a refusal, not an order
	 * picked by accident; `usingSeatOf` says which shapes have none and what each cost.
	 */
	public static function carriedDestEdits(
		destSource: String, destInfo: FileInfo, rawCarried: Array<String>, plugin: GrammarPlugin
	): CarriedEdits {
		// A carried `#if` REGION whose condition the destination already spells is merged into that
		// region instead of being written beside it: two same-condition regions in one header compile
		// identically, but leaving a file the `cond-region-merge` check reports is work made for the
		// user. What does not merge stays in the anchor group — and goes LAST there, so the plain
		// statements keep the order the dependency walk found them in.
		final guardedEdits: Array<{ span: Span, text: String }> = [];
		final carried: Array<String> = splitGuardedBlocks(destSource, destInfo, rawCarried, plugin, guardedEdits);
		final usings: Array<String> = carriedUsingLines(carried);
		final ranked: Bool = destInfo.imports.exists(imp -> imp.kind == ImportKind.Using);
		// Nothing to rank, or nothing to rank AGAINST: the ordinary anchor is the whole answer, and a
		// lone carried `using` is then the only one the destination has.
		if (usings.length == 0 || !ranked) return foldColocated({
			usingEdit: null,
			importEdit: carriedImportEdit(destSource, carried, plugin),
			guardedEdits: guardedEdits,
			unseated: []
		});
		final ordinary: Int = importAnchor(destSource, plugin).offset;
		final seat: Int = usingSeatOf(destSource, destInfo, ordinary);
		final rest: Array<String> = carriedImportLines(carried);
		// The seat and the ordinary anchor COINCIDE whenever no statement of the destination's own run
		// offers a lower one — a guarded region the anchor already sits above, or a last plain import on
		// the line directly over the run. Two zero-width inserts at one offset would be separated only
		// by `applyEdits`' width tie-break, which cannot tell them apart, leaving the order to
		// `Array.sort` — which Haxe does not guarantee stable. ONE edit removes the question, and the
		// `using` lines lead it so they still rank last.
		final seated: CarriedEdits = if (seat < 0)
			{
				usingEdit: null,
				importEdit: carriedImportEdit(destSource, rest, plugin),
				guardedEdits: guardedEdits,
				unseated: usings
			};
		else if (seat == ordinary)
			{
				usingEdit: null,
				importEdit: carriedImportEdit(destSource, usings.concat(rest), plugin),
				guardedEdits: guardedEdits,
				unseated: []
			};
		else
			{
				usingEdit: { span: new Span(seat, seat), text: '${usings.join('\n')}\n' },
				importEdit: carriedImportEdit(destSource, rest, plugin),
				guardedEdits: guardedEdits,
				unseated: []
			};
		return foldColocated(seated);
	}

	/**
	 * The refusal a non-empty `unseated` list owes, naming the statements and why no seat exists.
	 */
	public static function unseatedUsingRefusal(destFile: String, unseated: Array<String>): String {
		return 'the moved code needs ${unseated.join(' ')} at $destFile, and that file\'s own `using` run offers no seat above '
			+ 'it — one of its `using` statements is `#if`-guarded or shares its line with other code, so the carried statement '
			+ 'could only be written below it, where Haxe (which tries static extensions in reverse declaration order) would '
			+ 'give the destination\'s own calls the carried module instead; put the destination\'s `using` on its own '
			+ 'unguarded line, or add the statement by hand';
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
	 *
	 * A carried `using` needs a second question this one cannot answer — where the destination's own
	 * `using` RUN begins, so the new statement can be declared above it — and `usingSeatOf` answers
	 * that from `FileInfo`, falling back to this offset when the run offers no candidate of its own.
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
	 * Fold a merged `#if` region's edit into the ordinary import edit when the two land on the SAME
	 * offset — which they now can, since a carried region merges on the line after its region's own
	 * last import and that is exactly where the ordinary anchor sits when the header root IS that
	 * region (a whole-file `#if macro`, the shape `src/anyparse/macro` is written in).
	 *
	 * Two zero-width inserts at one offset are separated only by `applyEdits`' width tie-break, which
	 * cannot tell them apart, leaving their order to `Array.sort` — which Haxe does not guarantee
	 * stable. The same reason `carriedDestEdits` folds a coinciding `using` seat rather than emitting
	 * a second edit beside it.
	 */
	private static function foldColocated(edits: CarriedEdits): CarriedEdits {
		final importEdit: Null<{ span: Span, text: String }> = edits.importEdit;
		if (importEdit == null || edits.guardedEdits.length == 0) return edits;
		final kept: Array<{ span: Span, text: String }> = [];
		var text: String = importEdit.text;
		for (edit in edits.guardedEdits) if (
			edit.text != '' && edit.span.from == importEdit.span.from && edit.span.to == importEdit.span.to
		)
			text += edit.text;
		else
			kept.push(edit);
		return {
			usingEdit: edits.usingEdit,
			importEdit: { span: importEdit.span, text: text },
			guardedEdits: kept,
			unseated: edits.unseated
		};
	}

	/**
	 * `carried` with every guarded REGION that merges into one the destination already has taken out
	 * of it and appended to `into` as an edit; a region with no such seat stays in the returned list,
	 * at its end, to be written whole at the import anchor.
	 */
	private static function splitGuardedBlocks(
		destSource: String, destInfo: FileInfo, carried: Array<String>, plugin: GrammarPlugin, into: Array<{ span: Span, text: String }>
	): Array<String> {
		final shape: RefShape = plugin.refShape();
		final blocks: Array<String> = carried.filter(line -> GuardedImportCarry.isBlock(line, shape));
		if (blocks.length == 0) return carried;
		final out: Array<String> = carried.filter(line -> !GuardedImportCarry.isBlock(line, shape));
		final destBlocks: Array<CondBlock> = GuardedImportCarry.blocksOf(destSource, plugin);
		for (block in blocks) {
			final seat: Null<{ span: Span, text: String }> = GuardedImportCarry.mergeSeat(
				destSource, destBlocks, block, shape, destInfo.imports
			);
			if (seat == null)
				out.push(block);
			else if (seat.text != '')
				into.push(seat);
		}
		return out;
	}

	/**
	 * The offset a carried `using` may be written at so that it is declared BEFORE every `using` the
	 * destination already has — or -1 when the file offers no such seat.
	 *
	 * The candidates are the destination's own unguarded, own-line `using` statements, and `ordinary` (the
	 * anchor every other carried line takes) is the floor. A `#if`-GUARDED run offers no candidate of its
	 * own — writing the carried line at its line start would put it INSIDE the region — but the ordinary
	 * anchor often sits above it already, and then the seat is fine. It is only when some `using` ends up
	 * ABOVE the best candidate that there is nothing to do, and each such shape was a corrupting write
	 * before this asked.
	 *
	 * Measured at rc 0 on 4.3.7, both in `move` and in `move-member`: a destination reading
	 * `#if eval using q.Other; #end import a.B;` anchors below the region, so the carried `using` landed
	 * under the import and `Dest.d("x")` went from `OTHER` to `EXT` — the destination's own call, which
	 * is the half this seat exists to protect. And `package p; using q.Other;` on ONE line has no line
	 * start above the statement that is still below the package declaration, so the carried statement was
	 * written above `package`, which anyparse re-parses happily and Haxe rejects with
	 * `Unexpected keyword "package"`.
	 */
	private static function usingSeatOf(destSource: String, destInfo: FileInfo, ordinary: Int): Int {
		// An UNGUARDED statement on its own line offers a seat directly above itself, and the FIRST of
		// them is preferred over `ordinary` even where the ordinary anchor is already high enough: it
		// puts the carried statement adjacent to the run it joins instead of a blank line above it.
		var seat: Int = -1;
		for (imp in destInfo.imports) if (imp.kind == ImportKind.Using && !imp.guarded) {
			final at: Int = imp.span.from;
			final start: Int = lineStartOf(destSource, at);
			if (isBlank(destSource, start, at) && (seat < 0 || start < seat)) seat = start;
		}
		// A guarded statement, and one sharing its line, offer no candidate of their own — but the
		// ordinary anchor may already sit above them, which is why this asks rather than refusing on the
		// shape.
		if (seat < 0) seat = ordinary;
		for (imp in destInfo.imports) if (imp.kind == ImportKind.Using && imp.span.from < seat) return -1;
		return seat;
	}

	/**
	 * The `using` half of a carry list, and its complement, split on the keyword `importStatementText`
	 * writes — an exact test on generated text, not a guess about a user's spelling.
	 */
	private static function carriedUsingLines(carried: Array<String>): Array<String> {
		return carried.filter(line -> line.startsWith('using '));
	}

	/** The lines of a carry list that are NOT `using` statements. */
	private static function carriedImportLines(carried: Array<String>): Array<String> {
		return carried.filter(line -> !line.startsWith('using '));
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
	private static function computeCutSpan(
		source: String, declSpan: Span, groupEnd: Int, comments: Array<Span>
	): Null<{ span: Span, textEnd: Int }> {
		// Start of the decl's own line.
		final lineStart: Int = lineStartOf(source, declSpan.from);
		// The characters between the line start and the decl must be pure
		// whitespace (the decl's indentation) — otherwise the decl shares a
		// line with other code and a whole-line cut would corrupt it.
		if (!isBlank(source, lineStart, declSpan.from)) return null;

		// Walk backward over contiguous preceding trivia / meta lines.
		final cutStart: Int = triviaStartOf(source, declSpan.from, comments);

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
	 * The span the cut actually removes — `cut` widened over the blank run in front of it, or behind it,
	 * so that exactly the separation the REMAINING structure needs survives. `declText` has already been
	 * taken, so the destination is unaffected either way.
	 *
	 * With a blank run on BOTH sides one of them goes, whatever the neighbours are: that is the one
	 * blank a declaration between two siblings owned, and it is also the one a trailing COMMENT below
	 * still needs. With a run on exactly ONE side, `needsSeparator` decides — a declaration between two
	 * siblings keeps it, a declaration at either END of its container does not, and there the cut takes
	 * it. With no run at all the cut stands as computed.
	 *
	 * The end case is what `#if macro … #end` made reachable: cutting the LAST declaration out of a
	 * region left `}` + blank + `#end`, cutting the FIRST left `#if macro` + blank, because the old rule
	 * keyed on whether the line AFTER the cut was blank — true only between siblings, and a directive
	 * line is neither blank nor a declaration. Both shapes `fmt --list` rejects, and the canonical-in /
	 * canonical-out gate at the CLI seam hid them only where the file was canonical to begin with; a
	 * move into a file that already drifted kept them.
	 *
	 * The end-of-module shape the widening was first written for is the same question with no container
	 * directive: a trailing blank, which is why it read as an end-of-file special case.
	 */
	private static function cutEditSpan(
		source: String, cut: Span, existing: Array<{ span: Span, text: String }>, needsSeparator: Bool
	): Span {
		final runStart: Int = blankRunStart(source, cut.from);
		final runEnd: Int = blankRunEnd(source, cut.to);
		final leading: Bool = runStart < cut.from;
		final trailing: Bool = runEnd > cut.to;
		// Widening BACKWARD would overlap another edit this file already carries — today only the
		// source file's own new import, whenever the declaration sat directly under the import
		// region. The splice then produced a `pony/Or.hx` that no longer parsed, which the move's own
		// re-parse gate turned into a refusal of the whole write.
		final backwardBlocked: Bool = existing.exists(e -> e.span.from >= runStart && e.span.from <= cut.to);
		// Taking BOTH runs is only ever right when at most one of them exists. A container's end is
		// not always a directive or EOF: a trailing COMMENT is trivia, so it is no sibling and the
		// declaration still reads as the last in its container, while the blank in front of the
		// comment is a real separator — taking both glued `// note` onto the previous declaration's
		// closing brace. With both runs present exactly one survives, the same answer as between two
		// sibling declarations.
		if (needsSeparator || (leading && trailing)) return if (!leading || !trailing)
			cut
		else if (backwardBlocked)
			new Span(cut.from, runEnd)
		else
			new Span(runStart, cut.to);
		return new Span(leading && !backwardBlocked ? runStart : cut.from, runEnd);
	}

	/**
	 * End of the run of whole BLANK lines starting at `at`. `at` is a line start for every cut whose
	 * declaration was followed by a newline, which is the shape the caller normally hands it; where it
	 * is not — a declaration ending at EOF with no terminator, or one whose closing line carries
	 * trailing spaces — the remainder of that line is read as the first blank line, and it belongs to
	 * the removed declaration either way. A final line with no terminator is never one: there is no
	 * separator there to take.
	 */
	private static function blankRunEnd(source: String, at: Int): Int {
		var end: Int = at;
		while (end < source.length) {
			final lineEnd: Int = source.indexOf('\n', end);
			if (lineEnd < 0 || !isBlank(source, end, lineEnd)) break;
			end = lineEnd + 1;
		}
		return end;
	}

	/**
	 * Whether the declaration `node` has a NEIGHBOUR on both sides inside `parent` — a sibling with
	 * nothing but whitespace between it and the cut. Its own leading modifier / `@:meta` run does not
	 * count as one on the backward side, since `RefactorSupport.isDeclPrefixSibling` is what the cut
	 * span already folds in; on the forward side no such walk is needed, because a prefix sibling there
	 * belongs to the NEXT declaration and its presence proves one follows.
	 *
	 * False at either end of a container, and at a `#if … #else … #end` BRANCH edge, which a child index
	 * alone cannot see: the grammar flattens every branch into one child list, so two declarations
	 * either side of an `#else` are adjacent children of one node. `adjoins` asks the source instead.
	 *
	 * False is where the blank line the declaration carried may not be a separator at all: at the end of
	 * a module it can be a trailing blank, and against a directive it is a blank a writer-canonical file
	 * never has. Both `fmt --list` rejects. It is only MAY — a container's end can also be a trailing
	 * COMMENT, which is trivia and so no sibling, and there the blank still separates — which is why
	 * `cutEditSpan` consults this answer only when ONE side carries a blank run.
	 */
	private static function hasSiblingsOnBothSides(
		source: String, parent: Null<QueryNode>, node: QueryNode, cut: Span, comments: Array<Span>
	): Bool {
		if (parent == null) return true;
		final siblings: Array<QueryNode> = parent.children;
		final index: Int = siblings.indexOf(node);
		if (index < 0) return true;
		var start: Int = index;
		while (start > 0 && ElementSpan.isDeclPrefixSibling(siblings[start - 1])) start--;
		return adjoins(source, siblings, start - 1, cut.from, true, comments)
			&& adjoins(source, siblings, index + 1, cut.to, false, comments);
	}

	/**
	 * Whether `siblings[at]` exists AND nothing but whitespace lies between it and the cut edge at
	 * `edge` — so it is a NEIGHBOUR this declaration owns a blank line against, rather than a sibling
	 * the container's own text stands between.
	 *
	 * The whitespace half is what a child INDEX cannot answer. A `#if … #else … #end` region flattens
	 * EVERY branch into one child list, so two declarations either side of an `#else` are adjacent
	 * children of one node while the source has a directive between them; the text is the only
	 * evidence the tree keeps. The same test answers the region's outer ends, a module's start and
	 * end, and — read against the CUT rather than the declaration — leaves a swallowed doc comment on
	 * the declaration's own side.
	 */
	private static function adjoins(
		source: String, siblings: Array<QueryNode>, at: Int, edge: Int, before: Bool, comments: Array<Span>
	): Bool {
		if (at < 0 || at >= siblings.length) return false;
		final span: Null<Span> = siblings[at].span;
		if (span == null) return false;
		// The NEXT sibling's own leading trivia — its doc comment, its `@:meta` — is bytes that
		// declaration owns, not text standing between the two: measuring to its `span.from` read a
		// neighbour's doc block as a container boundary and cut the blank line above it away.
		final from: Int = before ? span.to : edge;
		final to: Int = before ? edge : triviaStartOf(source, span.from, comments);
		return from <= to && source.substring(from, to).trim().length == 0;
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
		destSource: String, destInfo: FileInfo, declText: String, carried: Array<String>, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];

		// The `using` half takes its own seat when the destination has a `using` run to rank against;
		// only then is the remainder what the ordinary anchor gets. That seat is the line start of a
		// statement the destination already holds, so it is strictly inside the header and cannot reach
		// the append point the branch below reasons about. `unseated` is handled by the caller, which
		// refuses — `buildDestInsertEdits` only ever builds edits.
		final carriedEdits: CarriedEdits = carriedDestEdits(destSource, destInfo, carried, plugin);
		final usingEdit: Null<{ span: Span, text: String }> = carriedEdits.usingEdit;
		if (usingEdit != null) edits.push(usingEdit);
		// A merge into a `#if` region the destination already holds sits INSIDE its header, strictly
		// above the append point the branch below reasons about, so it never competes with either.
		for (edit in carriedEdits.guardedEdits) edits.push(edit);
		final carriedEdit: Null<{ span: Span, text: String }> = carriedEdits.importEdit;

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
	 * The DESTINATION's own statements that spelled the moved type's old path. The type is local there
	 * now, so such a statement is redundant — except in the two shapes below, where dropping it takes a
	 * binding away instead.
	 */
	private static function destinationImportEdits(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, target: MoveTarget, destSource: String, declText: String,
		oldImportPath: String, newImportPath: String, lexicalRegions: (String) -> Array<LexRegion>
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
				&& (imp.kind == ImportKind.Using
					|| NameMentionScan.sourceNamesAny(destSource, remaining, destExcluded, lexicalRegions(destSource))
					|| NameMentionScan.sourceNamesAny(declText, remaining, [], lexicalRegions(declText)));
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
			for (m in t.members) if (MemberKinds.isEnumConstructorKind(m.kind)) out.push(m.name);
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
		oldImportPath: String, newImportPath: String, target: MoveTarget, destFile: String, plugin: GrammarPlugin
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
		final moved: Array<String> = movedBoundNames(cursorInfo, target.typeName);
		for (info in files) {
			if (info.file == cursorInfo.file || info.file == destFile) continue;
			if (editsByFile.exists(info.file)) continue;
			final src: Null<String> = sourceOf[info.file];
			if (src == null) continue;
			if (DependencyCarry.bindingOf(target.typeName, info, files)?.path != oldImportPath) continue;
			// The same scan the repoint walk runs, over the same names — the moved type's own plus the
			// enum constructors an importer may be the only thing to spell. No cut: nothing of this
			// file moves.
			if (!NameMentionScan.sourceNamesAny(src, moved, NameMentionScan.referenceExclusions(info), plugin.lexicalRegions(src)))
				continue;
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
	 * uniquely declared at the cursor, source and
	 * destination must differ, and both must be indexed. Cross-package is NOT
	 * refused here and has not been since S40 — this doc said it was until
	 * 2026-08-31. Returns the validated `MoveTarget` or a `PErr` with the
	 * precise refusal reason.
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
		final declarers: Array<FileInfo> = index.refs.declaringFiles(typeName);
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
		final groupSpan: Span = ElementSpan.declGroupSpan(declMatch.declNode, declParent, parseSpan);
		return POk({
			typeName: typeName,
			declSpan: ElementSpan.trailingTrimmedSpan(cursorSourceNN, groupSpan, plugin.lexicalRegions.bind(cursorSourceNN)),
			declGroupEnd: groupSpan.to,
			declNode: declMatch.declNode,
			declParent: declParent,
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
		oldImportPath: Null<String>, newImportPath: String, destFile: String, cursorInfo: FileInfo, typeName: String,
		lexicalRegions: (String) -> Array<LexRegion>
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
			final excluded: Array<Span> = NameMentionScan.referenceExclusions(importer);
			// Keeping an import this file no longer needs costs a lint advisory; dropping one it
			// does need costs the build — so both scans answer conservatively, and a name reached
			// through a QUALIFIED path (which needs no import) is not counted by either.
			final needsRemaining: Bool = plan.mainMoved && NameMentionScan.sourceNamesAny(
				src, plan.remaining, excluded, lexicalRegions(src)
			);
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
			final needsMoved: Bool = !plan.mainMoved && !spellsOldPath
				&& NameMentionScan.sourceNamesAny(src, plan.moved, excluded, lexicalRegions(src));
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
			final newSource: String = CanonicalEdit.applyEdits(original, edits);
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
	 *
	 * COMMENT interiors are skipped as well, and this is the ONE scan in the file where the comment
	 * question is a REFUSAL rather than an import-writing one. A doc line spelling `a.b.T` is not a
	 * code reference, so refusing on it blocks a legitimate move and hands its author advice
	 * ("convert it to a bare T with an import") that means nothing for prose — T511, reproduced at
	 * rc 1 on a three-file scope whose only mention was a doc block. A STRING literal is deliberately
	 * NOT skipped: `Type.resolveClass("a.b.T")` is a real reference the move breaks and nothing in
	 * the repair walk rewrites, so the refusal is the correct answer there.
	 */
	private static function qualifiedPathRefusal(
		index: SymbolIndex, sourceOf: Map<String, String>, oldImportPath: Null<String>, typeName: String, samePackage: Bool,
		lexicalRegions: (String) -> Array<LexRegion>
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
			// The lexical scan is per file and only for the files that spell the path at all — an
			// early `indexOf` keeps every other file at the cost it had.
			if (source.indexOf(path) < 0) continue;
			final info: Null<FileInfo> = index.fileInfo(file);
			if (info == null) continue;
			// An ALIAS statement's `raw` is the alias, so the path it spells is `aliasTarget` — read
			// `raw` here and the statement's own `p.Thing` reads as a fully-qualified CODE reference,
			// refusing a move over a file that only ever names the type through the alias, with a
			// message telling its author to add the import they already wrote.
			final own: Array<Span> = [for (imp in info.imports) if (SymbolIndex.pathImportedBy(imp) == path) imp.span];
			final comments: Array<Span> = SourceComments.collectCommentRegions(lexicalRegions(source));
			if (NameMentionScan.qualifiedPathMention(source, path, own, comments) >= 0)
				return '"$file" references "$path" by its fully-qualified path — the move changes that path and '
					+ 'repointing a code reference is unsafe; convert it to a bare "$typeName" (with an import) first';
		}
		return null;
	}

	/**
	 * Start of the run of contiguous trivia / meta lines immediately above `at`'s line — the doc
	 * comment and annotations a whole-line cut of that declaration takes with it. A BLANK line is
	 * not trivia, so the walk stops at the separator rather than swallowing it.
	 */
	private static function triviaStartOf(source: String, at: Int, comments: Array<Span>): Int {
		var start: Int = lineStartOf(source, at);
		while (start > 0) {
			// `start` is at the start of the current line; step to the previous line.
			final prevLineEnd: Int = start - 1; // the n terminating the previous line
			final prevLineStart: Int = lineStartOf(source, prevLineEnd);
			// A BLOCK comment whose continuation lines carry no `*` gutter — the
			// `/**\n\tText\n**/` spelling — is ordinary prose to a per-line prefix test, so the
			// walk stopped one line below the opener and the cut took only the closing `**/`.
			// Measured: `move` of `DocRendererTest` wrote a destination beginning `**/` and
			// refused on the re-parse, with no offset to look at. The lexer already knows where
			// the comment starts; ask it before reading the text.
			final open: Int = commentStartCovering(comments, prevLineEnd);
			if (open >= 0 && open < prevLineStart) {
				start = lineStartOf(source, open);
				continue;
			}
			if (!isContiguousTriviaLine(source.substring(prevLineStart, prevLineEnd))) break;
			start = prevLineStart;
		}
		return start;
	}

	/**
	 * The start offset of the comment `comments` places over `at`, or -1 when `at` is code. The
	 * regions are in source order and disjoint, so the first one reaching past `at` decides.
	 */
	private static function commentStartCovering(comments: Array<Span>, at: Int): Int {
		for (region in comments) {
			if (region.from > at) return -1;
			if (at < region.to) return region.from;
		}
		return -1;
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
	final declNode: QueryNode;
	final declParent: Null<QueryNode>;
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
