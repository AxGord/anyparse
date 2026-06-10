package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), inverted via
 * `Span.offsetOf(source, line, col + 1)` — identical to `CrossRename`.
 *
 * The op is PURE: it never reads or writes the filesystem. The CLI reads
 * every scope file (including the cursor file and the destination file)
 * and passes them in `scopeFiles`, and decides whether to write the
 * returned rewrites.
 */
@:nullSafety(Strict)
final class MoveSymbol {

	/** The advisory appended to every successful move. */
	private static final ADVISORY: String = 'verify imports in the destination — dependencies reached via a '
		+ 'static receiver (T.staticMethod()) or a value position are not '
		+ 'auto-detected and may need a manual import; same-package moves only.';

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

		// 1. Build the cross-file index; refuse on any skip-parse — a file
		//    we cannot read cannot be proven free of references to the type.
		final index: SymbolIndex = SymbolIndex.build(scopeFiles, plugin);
		final skipped: Array<String> = index.skippedFiles();
		if (skipped.length > 0) return Err('cannot move across scope: ${skipped.length} file(s) do not parse: ${skipped.join(", ")}');

		// Source text lookup for every scope file (the index keeps only
		// structural info, not the raw bytes).
		final sourceOf: Map<String, String> = [for (entry in scopeFiles) entry.file => entry.source];
		final cursorSource: Null<String> = sourceOf[cursorFile];
		if (cursorSource == null) return Err('cursor file $cursorFile is not in the scope file set');

		// 2. Resolve the type declaration the cursor sits on. `fullSpan` is
		//    the FULL decl span — for a `final class` that is the OUTER
		//    `FinalDecl` span (includes the `final ` keyword) so the cut and
		//    the dependency-body scan both cover `final class X {…}` whole.
		final cursorTree: QueryNode = try plugin.parseFile(cursorSource) catch (exception: ParseError) return Err(
			'$cursorFile does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('$cursorFile does not parse: ${exception.message}');
		final cursor: Int = Span.offsetOf(cursorSource, line, col + 1);
		final declMatch: Null<TypeDeclMatch> = RefactorSupport.resolveTypeDeclAtCursor(cursorTree, cursor, cursorSource);
		if (declMatch == null) return Err('position $line:$col is not on a type declaration');
		final typeName: String = declMatch.name;
		final declSpan: Span = declMatch.fullSpan;

		// 3. Guards.
		final declarers: Array<FileInfo> = index.declaringFiles(typeName);
		if (declarers.length == 0) return Err('no type "$typeName" declared under scope');
		if (declarers.length > 1) return Err('type "$typeName" is declared in ${declarers.length} files under scope — ambiguous, refusing');
		if (declarers[0].file != cursorFile)
			return Err('the type "$typeName" at the cursor is not the one declared under scope — refusing');
		if (cursorFile == destFile) return Err('source and destination are the same file — nothing to move');

		final cursorInfo: Null<FileInfo> = index.fileInfo(cursorFile);
		final destInfo: Null<FileInfo> = index.fileInfo(destFile);
		if (destInfo == null) return Err('destination file $destFile is not a parseable file under scope');
		if (cursorInfo == null) return Err('$cursorFile is not indexed');
		if (cursorInfo.pkg != destInfo.pkg)
			return Err(
				'cross-package move not supported in this increment '
				+ '(source package "${cursorInfo.pkg}" != destination package "${destInfo.pkg}")'
			);

		// 4. Cut span: extend backward over leading doc-comment / @:meta /
		//    indentation, and forward over one trailing newline. Refuse a
		//    decl sharing a source line with other code.
		final cut: Null<Span> = computeCutSpan(cursorSource, declSpan);
		if (cut == null) return Err('the type "$typeName" shares a source line with other code — refusing to move');
		final declText: String = cursorSource.substring(cut.from, cut.to);

		// 5. Dependency imports to carry: type-position names referenced
		//    INSIDE the decl that the source imports explicitly and the
		//    destination lacks.
		final destSource: Null<String> = sourceOf[destFile];
		if (destSource == null) return Err('destination file $destFile is not in the scope file set');
		final oldImportPath: Null<String> = index.importPathOf(typeName);
		final carried: Array<ImportInfo> = dependencyImportsToCarry(
			cursorSource, declSpan, cursorInfo, destInfo, plugin, typeRefShape, typeName
		);

		// 6. Compute the new import path the moved type is reached by.
		final destBasename: String = RefactorSupport.baseNameOf(destFile);
		final newImportPath: String = typeName == destBasename ? destInfo.module : '${destInfo.module}.$typeName';

		// 7. Assemble per-file edits.
		//    Per-file edit accumulators keyed by file path.
		final editsByFile: Map<String, Array<{ span: Span, text: String }>> = [];
		inline function editsFor(file: String): Array<{ span: Span, text: String }> {
			var arr: Null<Array<{ span: Span, text: String }>> = editsByFile[file];
			if (arr == null) {
				arr = [];
				editsByFile[file] = arr;
			}
			return arr;
		}

		// 7a. Cut the decl from the source file.
		editsFor(cursorFile).push({ span: cut, text: '' });

		// 7b. Insert the decl (plus carried imports) into the destination.
		//     The carried imports go at the destination's import region;
		//     the decl text is appended after the existing content.
		final destInsertEdits: Array<{ span: Span, text: String }> = buildDestInsertEdits(destSource, destInfo, declText, carried);
		for (e in destInsertEdits) editsFor(destFile).push(e);

		// 7c. Rewrite cross-file importers: every file (other than dest)
		//     whose import `raw` equals the old import path is repointed at
		//     the new path. Computed BEFORE the move via the index.
		if (oldImportPath != null && oldImportPath != newImportPath) {
			final oldModule: String = SymbolIndex.moduleOf(oldImportPath);
			for (importer in index.filesImportingModule(oldModule)) {
				if (importer.file == destFile) continue; // dest handled in 7d.
				final importerSource: Null<String> = sourceOf[importer.file];
				if (importerSource == null) continue;
				for (imp in importer.imports) if (imp.raw == oldImportPath)
					editsFor(importer.file).push({ span: imp.span, text: importStatementText(imp, newImportPath) });
			}
		}

		// 7d. Source-file local import: if the source still references the
		//     moved type after the cut, it now needs an import of the new
		//     path (the type left the file). Destination-file import: if it
		//     previously imported the type through the old path, that import
		//     is now redundant (the type is local) and is removed.
		if (oldImportPath != null) {
			if (sourceStillUsesType(cursorSource, cut, plugin, typeRefShape, typeName)) {
				final insert: Null<{ span: Span, text: String }> = addImportEdit(cursorSource, cursorInfo, newImportPath);
				if (insert != null) editsFor(cursorFile).push(insert);
			}
			for (imp in destInfo.imports) if (imp.raw == oldImportPath)
				editsFor(destFile).push({ span: removeImportSpan(destSource, imp), text: '' });
		}

		// 8. Apply edits per file, re-parse each, collect changed files.
		final changes: Array<MoveChange> = [];
		for (file => edits in editsByFile) {
			final original: Null<String> = sourceOf[file];
			if (original == null) continue;
			final newSource: String = RefactorSupport.applyEdits(original, edits);
			if (newSource == original) continue;

			// 9. Atomic validation: every rewritten file must re-parse.
			try
				plugin.parseFile(newSource)
			catch (exception: ParseError)
				return Err('rewritten $file does not parse: ${exception.toString()}')
			catch (exception: Exception)
				return Err('rewritten $file does not parse: ${exception.message}');

			changes.push({ file: file, newSource: newSource });
		}

		if (changes.length == 0) return Err('move of "$typeName" changed nothing');

		return Ok(changes, ADVISORY);
	}

	/**
	 * The source range to CUT for the declaration whose own span is
	 * `declSpan`: extended BACKWARD over the decl's leading indentation
	 * and any contiguous preceding doc-comment / line-comment /
	 * block-comment / `@:meta` lines (the `parseFile` tree drops trivia
	 * and emits `@:meta` as separate preceding sibling nodes, so the cut
	 * is computed from the raw source, not the tree), and FORWARD over
	 * one trailing newline. Returns null when the declaration shares its
	 * source line with other code (the line-up-to the decl is not pure
	 * whitespace), which a whole-line cut cannot safely express.
	 */
	private static function computeCutSpan(source: String, declSpan: Span): Null<Span> {
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
		// whole decl block including its line terminator.
		var cutEnd: Int = declSpan.to;
		if (cutEnd < source.length && source.charAt(cutEnd) == '\n') cutEnd++;

		return new Span(cutStart, cutEnd);
	}

	/**
	 * The explicit imports the moved decl's body depends on that the
	 * destination lacks. A dependency name `D` is a type-position
	 * reference (`Uses.find` on the `parseFileTypeRefs` tree) whose span
	 * falls INSIDE the decl's span. For each such `D` that the source
	 * imports explicitly (kind `Import` / `Using`, not `Wild` / `Alias`)
	 * via a path whose last dotted segment is `D`, and that the
	 * destination does not already carry verbatim, the source's
	 * `ImportInfo` is returned for copying into the destination.
	 *
	 * Same-package dependencies are auto-visible at the destination (the
	 * move is same-package), so an `import` for them is neither present
	 * in the source's explicit set in a way that resolves to a different
	 * module, nor needed — only the source's genuine cross-module
	 * explicit imports are carried.
	 */
	private static function dependencyImportsToCarry(
		source: String, declSpan: Span, cursorInfo: FileInfo, destInfo: FileInfo, plugin: GrammarPlugin, typeRefShape: TypeRefShape,
		typeName: String
	): Array<ImportInfo> {
		final typeRefTree: QueryNode = plugin.parseFileTypeRefs(source);
		// Distinct dependency names referenced in a type position inside
		// the decl. Walk every type-ref hit and keep those inside the span.
		final depNames: Array<String> = [];
		function collectDeps(node: QueryNode): Void {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (
				name != null && span != null && typeRefShape.typeRefKinds.contains(node.kind) && span.from >= declSpan.from
				&& span.to <= declSpan.to && name != typeName && !depNames.contains(name)
			) depNames.push(name);
			for (c in node.children) collectDeps(c);
		}
		collectDeps(typeRefTree);

		final carried: Array<ImportInfo> = [];
		for (dep in depNames) {
			// The source's explicit import that provides `dep` (path's last
			// segment is `dep`).
			final provider: Null<ImportInfo> = cursorInfo.imports.find(imp -> (
				imp.kind == ImportKind.Import || imp.kind == ImportKind.Using
			) && lastSegment(imp.raw) == dep);
			if (provider == null) continue;
			// Already present in the destination → no carry.
			final already: Bool = destInfo.imports.exists(imp -> imp.kind == provider.kind && imp.raw == provider.raw);
			if (already) continue;
			// De-dup the carry list (a single import line could provide more
			// than one referenced name only via wildcards, which we skipped).
			if (!carried.exists(c -> c.kind == provider.kind && c.raw == provider.raw)) carried.push(provider);
		}
		return carried;
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
		destSource: String, destInfo: FileInfo, declText: String, carried: Array<ImportInfo>
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];

		if (carried.length > 0) {
			final importLines: String = carried.map(imp -> importLineFor(imp)).join('\n');
			final insertAt: Int = importInsertionOffset(destSource, destInfo);
			// Insert as its own line(s) after the anchor.
			edits.push({ span: new Span(insertAt, insertAt), text: '$importLines\n' });
		}

		// Append the decl after the file content. Ensure exactly one blank
		// line of separation from the prior content.
		final trimmedEnd: Int = trimTrailingNewlines(destSource);
		final tail: String = destSource.substring(trimmedEnd);
		final sep: String = trimmedEnd == 0 ? '' : '\n\n';
		// Replace the trailing-newline region with: separator + decl +
		// the file's original trailing newlines (preserve EOF newline).
		edits.push({ span: new Span(trimmedEnd, destSource.length), text: '$sep$declText$tail' });

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
			if (!used && node.name == typeName && span != null && typeRefShape.typeRefKinds.contains(node.kind) && (
				span.from < cut.from || span.from >= cut.to
			)) used = true;
			for (c in node.children) walk(c);
		}
		walk(typeRefTree);
		return used;
	}

	/**
	 * An edit that inserts `import <path>;` into `info` (the source file
	 * gaining a reference to the moved type), placed after the last
	 * existing import (or after the package declaration). Returns null
	 * when the import is already present.
	 */
	private static function addImportEdit(source: String, info: FileInfo, path: String): Null<{ span: Span, text: String }> {
		final already: Bool = info.imports.exists(imp -> imp.kind == ImportKind.Import && imp.raw == path);
		if (already) return null;
		final insertAt: Int = importInsertionOffset(source, info);
		return { span: new Span(insertAt, insertAt), text: 'import $path;\n' };
	}

	/**
	 * Offset at which a fresh import line should be inserted: the start of
	 * the line AFTER the last existing import statement, else after the
	 * package declaration, else the very start of the file. The returned
	 * offset is always a line start, so the caller appends `text + '\n'`.
	 */
	private static function importInsertionOffset(source: String, info: FileInfo): Int {
		var anchorEnd: Int = -1;
		for (imp in info.imports) if (imp.span.to > anchorEnd) anchorEnd = imp.span.to;
		if (anchorEnd < 0) {
			// No imports — anchor after the package decl's line, if any.
			final pkgIdx: Int = source.indexOf('package ');
			if (pkgIdx == 0) {
				final semi: Int = source.indexOf(';', pkgIdx);
				if (semi >= 0) anchorEnd = semi + 1;
			}
		}
		if (anchorEnd < 0) return 0;
		// Step to the start of the next line after the anchor.
		final nl: Int = source.indexOf('\n', anchorEnd);
		return nl < 0 ? source.length : nl + 1;
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
	 * `newImportPath`, preserving the statement's kind (`import` vs.
	 * `using`) and its leading keyword spacing. The whole statement span
	 * is replaced — the original `raw` path is swapped for the new path.
	 */
	private static function importStatementText(imp: ImportInfo, newImportPath: String): String {
		final keyword: String = imp.kind == ImportKind.Using ? 'using' : 'import';
		return '$keyword $newImportPath;';
	}

	/** `import <path>;` / `using <path>;` text for a carried import. */
	private static function importLineFor(imp: ImportInfo): String {
		final keyword: String = imp.kind == ImportKind.Using ? 'using' : 'import';
		return '$keyword ${imp.raw};';
	}

	/** Last dotted segment of a path (`pkg.sub.Foo` -> `Foo`). */
	private static inline function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot < 0 ? path : path.substr(dot + 1);
	}

	/** Start offset of the line containing `offset`. */
	private static function lineStartOf(source: String, offset: Int): Int {
		var i: Int = offset < source.length ? offset : source.length;
		while (i > 0 && source.charAt(i - 1) != '\n') i--;
		return i;
	}

	/** Are `[from, to)` of `source` all whitespace (space / tab)? */
	private static function isBlank(source: String, from: Int, to: Int): Bool {
		for (i in from...to) {
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
		final trimmed: String = StringTools.trim(line);
		if (trimmed.length == 0) return false; // blank line = boundary
		return StringTools.startsWith(trimmed, '//') || StringTools.startsWith(trimmed, '/*') || StringTools.startsWith(trimmed, '*')
			|| StringTools.startsWith(trimmed, '@');
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

}
