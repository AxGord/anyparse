package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a `CrossRename.crossRenameType` call. `Ok` carries the
 * per-file rewrites (only files that actually changed) plus a non-null
 * advisory — the static-receiver / cross-package caveat the caller
 * surfaces to the user. `Err` carries a human-readable diagnostic
 * (cursor not on a type declaration, an ambiguous / missing type, a
 * scope file that does not parse, a post-rewrite re-parse failure, or a
 * no-op). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention.
 * Mirrors `RenameResult` / `ChangeSigResult`.
 */
enum CrossRenameResult {

	Ok(changes: Array<FileChange>, advisory: Null<String>);
	Err(message: String);

}

/**
 * One file's rewrite. `count` is the number of occurrence spans
 * replaced in `file`. Only files whose `count > 0` are emitted — an
 * unchanged scope file is never returned.
 */
typedef FileChange = {
	var file: String;
	var newSource: String;
	var count: Int;
}

/**
 * Scope-correct, format-preserving cross-file TYPE rename — hardens the
 * single-file ceiling of the refactoring quartet (`Rename` / `Inline` /
 * `ExtractVar` / `ChangeSig`). The sibling `Rename` renames ONE binding
 * within ONE file; this operation renames ONE type declaration across
 * EVERY `.hx` file in a scope directory.
 *
 * ## Why type-only — the correctness model
 *
 * Cross-file value / method rename needs a type system: the receiver
 * type of an `obj.foo()` call is not resolvable syntactically, so a
 * by-name transform would rename unrelated members. TYPE references, by
 * contrast, live in the TYPE NAMESPACE — a type-position occurrence of
 * `T` can ONLY be the type `T`, never a value / enum-constructor named
 * `T`. Covering the type-namespace forms therefore yields ZERO false
 * positives. The forms collected:
 *
 *  - Type positions + `new T` + cast + `extends` / `implements` + type
 *    parameters — every node `Uses.find` emits on the
 *    `parseFileTypeRefs` tree.
 *  - The type DECLARATION's own name — spliced in the declaring file.
 *  - `import ….T;` / `using ….T;` — the LAST dotted segment `T`,
 *    located precisely (the earlier segments are lower-case packages,
 *    but the splice anchors on the segment after the final `.` so a
 *    package segment that happens to match the type name is never hit).
 *  - QUALIFIED type positions — the type named THROUGH its module path,
 *    which the type-ref tree carries as ONE node whose name is the whole
 *    dotted string. The spellings Haxe accepts are enumerated by
 *    `qualifiedPaths` and matched WHOLE, never by last segment: that is what
 *    keeps a same-simple-name type from another module (`haxe.io.Bytes`
 *    against a local `Bytes`) out of the rewrite.
 *  - Static-receiver access `T.staticMethod()` / `T.CONST` — a
 *    `FieldAccess` whose receiver child is an `IdentExpr T` that does
 *    NOT resolve to a value binding. Such a receiver is the type used
 *    as a static namespace; it is still in the type namespace, so
 *    renaming it is safe. A FieldAccess receiver is never an
 *    enum-constructor (ctors are bare `T` / `T(args)` / `case T:`,
 *    never `T.x`), and a value named `T` used as `T.x()` DOES resolve
 *    (an in-file binding) and is excluded — so this stays zero false
 *    positives. A DOTTED receiver — `pkg.Mod.CONST`, and every
 *    `macro pkg.Mod.Ctor(…)` reification — is a `FieldAccess` CHAIN rather than an
 *    identifier; it is flattened and matched WHOLE against the same qualified
 *    candidates, and its root is a package identifier no value binding can shadow.
 *
 * ## Documented residual (loud-fail, not silent)
 *
 * A type-namespace occurrence this operation does NOT rewrite leaves a
 * dangling `T` that fails to COMPILE — it is never a silent semantic
 * change. Excluded:
 *
 *  - Bare `Class<T>` value-position `IdentExpr T` (e.g. `var c = T;`) —
 *    a bare unresolved `T` is indistinguishable from a nullary
 *    enum-constructor `T`, so it stays a residual. Only the
 *    FieldAccess-RECEIVER form is safe to rename.
 *  - Aliased imports `import pkg.T as U;` — the node's name slot is the
 *    alias `U`, not `T`, so the `pkg.T` segment is not matched. The
 *    alias `U` (used in type positions) IS covered, but the import's
 *    own `T` segment is left, which dangles if `T` moved package.
 *  - A type position inside an ANONYMOUS STRUCTURE type — `{ node: T, … }`. The
 *    type-ref projection does not carry it, so `Uses.find(T)` reports nothing there
 *    and the plain-name arm has never covered it either. Measured on this repo, renaming
 *    `anyparse.core.Doc` (1044 occupied sites): 70 such positions across 3 files, every
 *    one a loud `Type not found`, and the ONLY class that rename still leaves behind.
 *  - Renaming a module's MAIN type renames the MODULE PATH with it, and the op
 *    does not touch the FILE: `Mod.hx` must be renamed to match by hand, and
 *    references to the module's OTHER sub-module types (`pkg.Mod.Other`) still
 *    carry the old module segment. That has always been true of the `import`
 *    segment this op rewrites; the qualified positions now agree with it rather
 *    than disagreeing.
 *  - Cross-package: a type declared under a DIFFERENT scope than the
 *    one being renamed (the uniqueness proof is over the given scope
 *    only).
 *
 * The advisory (always non-null on success) reminds the user to check
 * these. Combined with atomicity — every rewritten file is re-parsed
 * before ANY is returned, and the caller writes nothing unless all
 * parse — a missed form surfaces as a compile error the user can see,
 * never as a corrupted file.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based) — identical to `Rename`.
 */
@:nullSafety(Strict)
final class CrossRename {

	/** The node kind a qualified namespace receiver chains through. */
	private static final FIELD_ACCESS_KIND: String = 'FieldAccess';

	/** The advisory appended to every successful rename. */
	private static final ADVISORY: String = 'type-namespace rename only — verify bare `Class<T>` value uses (`var c = T;`),'
		+ ' aliased imports (`import pkg.T as U;`), type positions inside an anonymous structure (`{ node: T }`), and any'
		+ ' cross-package declarations by hand. Renaming the MAIN type of a module renames the module path with it: rename the'
		+ ' FILE to match, and check references to the other sub-module types of that module.';

	/**
	 * Rename the type declaration at `line:col` (in `cursorFile` /
	 * `cursorSource`) to `newName` across every file in `scopeFiles`.
	 * `plugin` / `typeRefShape` are the caller-owned grammar plugin and
	 * its `TypeRefShape` (the same pair the `uses` CLI builds), so the
	 * walk stays language-agnostic.
	 *
	 * The function is PURE: it never reads or writes the filesystem — the
	 * CLI reads the scope files and passes them in, and decides whether
	 * to write the returned rewrites. `scopeFiles` SHOULD include
	 * `cursorFile` (the CLI adds it when the file is not already under
	 * the scope directory).
	 *
	 * Returns `Ok(changes, advisory)` with only the files that changed,
	 * or an `Err` describing why the rename could not be applied.
	 */
	public static function crossRenameType(
		cursorFile: String, cursorSource: String, line: Int, col: Int, newName: String,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeRefShape: TypeRefShape, refShape: RefShape
	): CrossRenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		// 1. Resolve the type declaration the cursor sits on.
		final cursorTree: QueryNode = try plugin.parseFile(cursorSource) catch (exception: ParseError) return Err(
			'$cursorFile does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('$cursorFile does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(cursorSource, line, col);
		final declNode: Null<QueryNode> = resolveTypeDeclAtCursor(cursorTree, cursor, cursorSource);
		if (declNode == null) return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		final typeName: Null<String> = declNode.name;
		if (typeName == null) return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		if (typeName == newName) return Err('rename "$typeName" -> "$newName" is a no-op');

		// 2. Parse every scope file once; refuse on any skip-parse.
		final parse: ScopeParse = parseScopeFiles(scopeFiles, plugin);
		if (parse.error != null) return Err(parse.error);

		// 3. Uniqueness: exactly one declaration of `typeName` under scope.
		final uniqueErr: Null<String> = checkScopeUniqueness(parse.parsed, cursorFile, typeName);
		if (uniqueErr != null) return Err(uniqueErr);

		// 4. The declaring MODULE. A qualified reference names the type THROUGH its module path, so
		//    the rewrite needs that path and not only the simple name.
		final modulePkg: String = ModuleScan.packageOf(cursorTree);
		final moduleBase: String = RefactorSupport.baseNameOf(cursorFile);
		final module: { path: String, pkg: String, base: String } = {
			path: modulePkg == '' ? moduleBase : '$modulePkg.$moduleBase',
			pkg: modulePkg,
			base: moduleBase
		};
		return applyTypeRename(parse.parsed, typeName, newName, plugin, typeRefShape, refShape, module);
	}

	/**
	 * Resolve the cursor to the type declaration it sits on, returning the
	 * node that carries the type NAME (the decl node itself, or the inner
	 * `ClassForm` of a `final class`). The rest of the rename reads
	 * `.name` off it. Final-aware via
	 * `RefactorSupport.resolveTypeDeclAtCursor`. Returns null when the
	 * cursor is not on a type declaration.
	 */
	private static function resolveTypeDeclAtCursor(tree: QueryNode, cursor: Int, source: String): Null<QueryNode> {
		final m: Null<TypeDeclMatch> = RefactorSupport.resolveTypeDeclAtCursor(tree, cursor, source);
		return m?.nameNode;
	}

	/**
	 * Count the type-declaration nodes named `typeName` in `tree` (a
	 * `parseFile` tree). Drives the cross-scope uniqueness proof.
	 * Final-aware: a `final class` is recognised through its `FinalDecl`
	 * wrapper so it counts toward uniqueness exactly like a plain class.
	 */
	private static function countTypeDecls(tree: QueryNode, typeName: String): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/**
	 * Gather every occurrence-token span of `typeName` in one file:
	 *
	 *  a. Type positions — `Uses.find` on the `parseFileTypeRefs` tree
	 *     (annotations, `extends` / `implements`, type params, cast,
	 *     `new T`).
	 *  b. The declaration name — every type-decl node named `typeName` in
	 *     the `parseFile` tree.
	 *  c. Imports / using — `ImportDecl` / `UsingDecl` whose dotted path's
	 *     LAST segment is `typeName`.
	 *  d. Static-receiver access — a `FieldAccess` whose receiver child
	 *     is an `IdentExpr` named `typeName` that does NOT resolve to a
	 *     value binding (`T.staticMethod()` / `T.CONST`). The value-
	 *     resolved receiver offsets are computed once from `Refs.find`:
	 *     any read / write whose `bindingSpan` is non-null is an in-file
	 *     value named `typeName` and is EXCLUDED, leaving only the
	 *     type-as-namespace receivers.
	 *
	 * Each returned span is the identifier token `[from, from+len)`.
	 * Spans are deduped by `from` offset (a node can be matched by more
	 * than one collector).
	 */
	private static function collectOccurrences(
		source: String, typeName: String, tree: QueryNode, plugin: GrammarPlugin, typeRefShape: TypeRefShape, refShape: RefShape,
		module: { path: String, pkg: String, base: String }
	): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		inline function add(identFrom: Int): Void RefactorSupport.pushUniqueSpan(out, seen, identFrom, typeName.length);

		// a. Type positions.
		final typeRefTree: QueryNode = plugin.parseFileTypeRefs(source);
		for (hit in Uses.find(typeName, typeRefTree, typeRefShape)) add(RefactorSupport.identTokenOffset(source, hit.span, typeName));

		// e. QUALIFIED type positions — the same type named THROUGH its module path.
		final qualified: Array<String> = qualifiedPaths(typeName, module, ModuleScan.packageOf(tree));
		for (off in qualifiedOffsets(source, typeRefTree, typeName, qualified, typeRefShape)) add(off);

		// d-prep. Receiver offsets that resolve to a value binding — an
		// in-file var / param / field named `typeName`. A static-receiver
		// occurrence is renamed only when its receiver is NOT in this set
		// (an unresolved receiver is the type used as a namespace).
		final valueResolved: Array<Int> = [
			for (h in Refs.find(typeName, tree, refShape))
				if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null) h.span.from
		];

		// b. Declaration names + c. imports / using + d. static-receiver
		//    accesses (one walk of the parseFile tree — every arm reads
		//    node kinds from it).
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			// b. Declaration name — final-aware: for a `final class` the
			//    named node is the inner `ClassForm`, so anchor the splice on
			//    `typeDeclOf(...).nameNode` (its span holds the name token),
			//    NOT on the `FinalDecl` wrapper, which carries no name.
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl != null && decl.name == typeName) {
				final nameSpan: Null<Span> = decl.nameNode.span;
				if (nameSpan != null) add(RefactorSupport.identTokenOffset(source, nameSpan, typeName));
			} else if (span != null && (node.kind == 'ImportDecl' || node.kind == 'UsingDecl'))
				add(lastSegmentOffset(source, span, node.name, typeName));
			final children: Array<QueryNode> = node.children;
			if (node.kind == FIELD_ACCESS_KIND && children.length > 0)
				add(namespaceReceiverOffset(source, children[0], typeName, qualified, valueResolved));
			for (c in children) walk(c);
		}
		walk(tree);

		return out;
	}

	/**
	 * Offset of the LAST dotted segment of a qualified path when that segment equals
	 * `typeName`, else -1. `pathName` is the node's name slot — the verbatim dotted path
	 * (`pkg.sub.Foo`), which both an `import` / `using` declaration and a QUALIFIED type
	 * reference carry whole. The segment is located by finding the path text inside the node
	 * span and anchoring on the character after the final `.`, so a leading package segment
	 * that happens to match `typeName` (e.g. `import Foo.sub.Foo;`) is never mistaken for the
	 * type segment.
	 */
	private static function lastSegmentOffset(source: String, span: Span, pathName: Null<String>, typeName: String): Int {
		if (pathName == null) return -1;
		final lastDot: Int = pathName.lastIndexOf('.');
		if (RefactorSupport.lastSegment(pathName) != typeName) return -1;
		final pathStart: Int = source.indexOf(pathName, span.from);
		return pathStart < 0 || pathStart >= span.to ? -1 : pathStart + lastDot + 1;
	}

	/**
	 * Parse every scope file once. A file that does not parse is recorded as
	 * skipped — a file we cannot read cannot be proven free of references to
	 * the renamed type — and turned into a refusal so the rename stays atomic.
	 * Returns the parsed files (empty `error`) or the skip diagnostic.
	 */
	private static function parseScopeFiles(scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin): ScopeParse {
		final parsed: Array<ParsedFile> = [];
		final skipped: Array<String> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: ParseError) null
			catch (exception: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
			} else {
				final parsedTree: QueryNode = tree;
				parsed.push({ file: entry.file, source: entry.source, tree: parsedTree });
			}
		}
		final error: Null<String> = skipped.length > 0
			? 'cannot rename across scope: ${skipped.length} file(s) do not parse: ${skipped.join(', ')}'
			: null;
		return { parsed: parsed, error: error };
	}

	/**
	 * Prove exactly one declaration of `typeName` exists under scope and that it
	 * is the one in `cursorFile`. Returns the refusal diagnostic — none declared,
	 * declared in more than one file (ambiguous), or the unique declaration is
	 * not the cursor's — or null when the type is uniquely the cursor's.
	 */
	private static function checkScopeUniqueness(parsed: Array<ParsedFile>, cursorFile: String, typeName: String): Null<String> {
		var declCount: Int = 0;
		var declInCursorFile: Bool = false;
		for (entry in parsed) {
			final n: Int = countTypeDecls(entry.tree, typeName);
			declCount += n;
			if (n > 0 && entry.file == cursorFile) declInCursorFile = true;
		}
		return if (declCount == 0)
			'no type "$typeName" declared under scope'
		else if (declCount > 1)
			'type "$typeName" is declared in $declCount files under scope — ambiguous, refusing'
		else if (!declInCursorFile)
			'the type "$typeName" at the cursor is not the one declared under scope — refusing'
		else
			null;
	}

	/**
	 * Collect every type-namespace occurrence of `typeName` in each parsed file,
	 * rewrite it to `newName`, and re-parse the rewritten file before any change
	 * is returned (atomicity — a single file whose rewrite breaks the parse fails
	 * the whole rename). Unchanged files are omitted. `Err` on a re-parse failure
	 * or when nothing changed; otherwise `Ok` with the per-file changes + advisory.
	 */
	private static function applyTypeRename(
		parsed: Array<ParsedFile>, typeName: String, newName: String, plugin: GrammarPlugin, typeRefShape: TypeRefShape,
		refShape: RefShape, module: { path: String, pkg: String, base: String }
	): CrossRenameResult {
		final changes: Array<FileChange> = [];
		for (entry in parsed) {
			final occurrences: Array<Span> = collectOccurrences(entry.source, typeName, entry.tree, plugin, typeRefShape, refShape, module);
			if (occurrences.length == 0) continue;
			final edits: Array<{ span: Span, text: String }> = [for (occ in occurrences) { span: occ, text: newName }];
			final newSource: String = RefactorSupport.applyEdits(entry.source, edits);

			// Atomic validation: every rewritten file must re-parse.
			try
				plugin.parseFile(newSource)
			catch (exception: ParseError)
				return Err('rewritten ${entry.file} does not parse: ${exception.toString()}')
			catch (exception: Exception)
				return Err('rewritten ${entry.file} does not parse: ${exception.message}');

			changes.push({ file: entry.file, newSource: newSource, count: occurrences.length });
		}
		return changes.length == 0 ? Err('rename "$typeName" -> "$newName" changed nothing') : Ok(changes, ADVISORY);
	}

	/**
	 * Every DOTTED spelling of `typeName` a file in `filePkg` may legally use for a type declared
	 * in `module` — the candidate paths arm (e) matches WHOLE, which is what keeps a type of the
	 * same simple name declared anywhere else out of the rewrite.
	 *
	 * Read off the compiler rather than assumed. `pkg.Mod.T`, the full path from a class-path
	 * root, works from anywhere. The short `Mod.T` works ONLY from a file in the module's own
	 * package: an `import pkg.Mod;` does not make it legal elsewhere (`Type not found : Mod`),
	 * and a module in the root package makes the two spellings the same string. A type whose name
	 * equals the module's is the module's MAIN type — its qualified spelling IS the module path,
	 * with no segment of its own, and in the root package it has no dotted spelling at all.
	 */
	private static function qualifiedPaths(
		typeName: String, module: { path: String, pkg: String, base: String }, filePkg: String
	): Array<String> {
		if (typeName == module.base) return module.path == module.base ? [] : [module.path];
		final out: Array<String> = ['${module.path}.$typeName'];
		if (filePkg == module.pkg && module.path != module.base) out.push('${module.base}.$typeName');
		return out;
	}

	/**
	 * The last-segment offset of every QUALIFIED type position naming `typeName` through its
	 * module path. The type-ref tree carries `pkg.Mod.T` as ONE node whose name is the whole
	 * dotted string, so the plain-name arm never sees it and the declaration used to be renamed
	 * with every such reference left behind — source that does not compile, reported as success.
	 *
	 * `tree` is the PLAIN tree, read only for the referencing file's own `package`: which dotted
	 * spellings are legal depends on it (see `qualifiedPaths`).
	 */
	private static function qualifiedOffsets(
		source: String, typeRefTree: QueryNode, typeName: String, qualified: Array<String>, typeRefShape: TypeRefShape
	): Array<Int> {
		return [
			for (path in qualified) for (hit in Uses.find(path, typeRefTree, typeRefShape))
				lastSegmentOffset(source, hit.span, path, typeName)
		];
	}

	/**
	 * The dotted path a receiver CHAIN spells — `anyparse.core.Doc` for the
	 * `FieldAccess Doc (FieldAccess core (IdentExpr anyparse))` a qualified namespace access
	 * projects as. Anything the chain cannot express as a plain path (a call, an index) makes it
	 * not a path at all, and the empty string it returns matches no candidate.
	 */
	private static function flattenPath(node: QueryNode): String {
		final name: Null<String> = node.name;
		if (name == null) return '';
		if (node.kind == 'IdentExpr') return name;
		if (node.kind != FIELD_ACCESS_KIND || node.children.length == 0) return '';
		final head: String = flattenPath(node.children[0]);
		return head == '' ? '' : '$head.$name';
	}

	/**
	 * d/f. The offset of the type token in a static-access RECEIVER, or -1 when `recv` is not this
	 * type used as a namespace. Two shapes:
	 *
	 *  - d. A bare `IdentExpr T` that does NOT resolve to a value binding (an in-file var / param /
	 *    field named `T` shadows the namespace and is excluded through `valueResolved`).
	 *  - f. A DOTTED chain — `pkg.Mod.CONST`, and every `macro pkg.Mod.Ctor(…)` reification, whose
	 *    receiver is a `FieldAccess` chain rather than an identifier and which arm (d) therefore
	 *    never saw. The chain is flattened and matched WHOLE against the same candidates the
	 *    qualified type positions use, so a same-simple-name type from another module is
	 *    unreachable. Such a chain is rooted in a PACKAGE identifier, which no value binding can
	 *    shadow, so it needs no `valueResolved` test of its own.
	 */
	private static function namespaceReceiverOffset(
		source: String, recv: QueryNode, typeName: String, qualified: Array<String>, valueResolved: Array<Int>
	): Int {
		final recvSpan: Null<Span> = recv.span;
		if (recv.name != typeName || recvSpan == null) return -1;
		if (recv.kind == 'IdentExpr')
			return valueResolved.contains(recvSpan.from) ? -1 : RefactorSupport.identTokenOffset(source, recvSpan, typeName);
		if (recv.kind != FIELD_ACCESS_KIND) return -1;
		final path: String = flattenPath(recv);
		return qualified.contains(path) ? lastSegmentOffset(source, recvSpan, path, typeName) : -1;
	}

}

/**
 * One scope file parsed once: its path, source, and parse tree. The shared
 * unit passed between the cross-rename phases.
 */
private typedef ParsedFile = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * The result of parsing the scope: the parsed files, plus a non-null `error`
 * diagnostic when any file skip-parsed (the rename is then refused).
 */
private typedef ScopeParse = {
	final parsed: Array<ParsedFile>;
	final error: Null<String>;
};
