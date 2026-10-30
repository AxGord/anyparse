package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.ScopeFiles.ParsedFile;
import anyparse.query.ScopeFiles.ScopeParse;
import anyparse.runtime.Span;

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

	/**
	 * The splices that turn the file's source into `newSource`, as original-source spans. A caller
	 * that must combine several renames over one file, or verify a subset of them (the `naming` rule's
	 * compiler-verified rename arm), needs the edits rather than the finished text.
	 */
	var edits: Array<{ span: Span, text: String }>;
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
 *    parameters + struct extensions `{ > T, … }` — every node `Uses.find`
 *    emits on the `parseFileTypeRefs` tree.
 *  - The type DECLARATION's own name — spliced in the declaring file.
 *  - `import ….T;` / `using ….T;` — the LAST dotted segment `T`,
 *    located precisely (the earlier segments are lower-case packages,
 *    but the splice anchors on the segment after the final `.` so a
 *    package segment that happens to match the type name is never hit).
 *  - Imports THROUGH the type (`import pkg.T.f;`, `import pkg.T.*;`), an alias import's path,
 *    and access grants by the TYPE path `pkg.T` (`docs/decisions.md`, N35).
 *  - QUALIFIED type positions — the type named THROUGH its module path,
 *    which the type-ref tree carries as ONE node whose name is the whole
 *    dotted string. The spellings Haxe accepts are enumerated by
 *    `RefactorSupport.qualifiedPaths` and matched WHOLE, never by last segment: that
 *    is what keeps a same-simple-name type from another module (`haxe.io.Bytes`
 *    against a local `Bytes`) out of the rewrite.
 *  - Static-receiver access `T.staticMethod()` / `T.CONST` — a
 *    `FieldAccess` whose receiver child is an `IdentExpr T` that does
 *    NOT resolve to a value binding. Such a receiver is the type used
 *    as a static namespace; it is still in the type namespace, so
 *    renaming it is safe. A FieldAccess receiver is never an
 *    enum-constructor (ctors are bare `T` / `T(args)` / `case T:`,
 *    never `T.x`), and a value named `T` used as `T.x()` DOES resolve
 *    (an in-file binding) and is excluded — so this stays zero false
 *    positives. A DOTTED path — a receiver `pkg.Mod.CONST`, every
 *    `macro pkg.Mod.Ctor(…)` reification, and the VALUE `pkg.T` (a
 *    `Class<T>`) — is a `FieldAccess` CHAIN rather than an identifier; it is
 *    flattened and matched WHOLE against the same qualified candidates, and
 *    left alone when its root identifier is a value binding of the file.
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

	/** The advisory appended to every successful rename. */
	private static final ADVISORY: String = 'type-namespace rename only — verify bare `Class<T>` value uses (`var c = T;`)'
		+ ' and any cross-package declarations by hand. Renaming the MAIN type of a module renames the module path with it: rename the '
		+ 'FILE to match, and check references to the other sub-module types of that module.';

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
		if (!SourceText.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		// 1. Resolve the type declaration the cursor sits on.
		final cursorTree: QueryNode = switch ParseGate.parse(plugin, cursorSource, cursorFile) {
			case Unparsed(message): return Err(message);
			case Parsed(tree): tree;
		};

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(cursorSource, line, col);
		final declNode: Null<QueryNode> = resolveTypeDeclAtCursor(cursorTree, cursor, cursorSource);
		if (declNode == null) return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		final typeName: Null<String> = declNode.name;
		if (typeName == null) return Err('position $line:$col is not on a type declaration (cross-file --scope renames types only)');
		if (typeName == newName) return Err('rename "$typeName" -> "$newName" is a no-op');

		// 2. Parse every scope file once; refuse on any skip-parse.
		final parse: ScopeParse = ScopeFiles.parseScope(scopeFiles, plugin, 'rename');
		if (parse.error != null) return Err(parse.error);

		// 3. Uniqueness: exactly one declaration of `typeName` under scope.
		final uniqueErr: Null<String> = ScopeFiles.uniquenessRefusal(parse.parsed, cursorFile, typeName);
		if (uniqueErr != null) return Err(uniqueErr);

		// 4. The declaring MODULE. A qualified reference names the type THROUGH its module path, so
		//    the rewrite needs that path and not only the simple name.
		final module: ModulePath = ModuleScan.moduleOf(cursorTree, cursorFile);
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
	 * Gather every occurrence-token span of `typeName` in one file:
	 *
	 *  a. Type positions — `Uses.find` on the `parseFileTypeRefs` tree
	 *     (annotations, `extends` / `implements`, type params, cast,
	 *     `new T`, struct extensions).
	 *  b. The declaration name — every type-decl node named `typeName` in
	 *     the `parseFile` tree.
	 *  c. Imports / using — `ImportDecl` / `UsingDecl` whose dotted path's
	 *     LAST segment is `typeName`, and any import kind whose path IS the
	 *     type's absolute module path or runs THROUGH it (`throughOffset`).
	 *  d. Static-receiver access — a `FieldAccess` whose receiver child
	 *     is an `IdentExpr` named `typeName` that does NOT resolve to a
	 *     value binding (`T.staticMethod()` / `T.CONST`). The value-
	 *     resolved receiver offsets are computed once from `Refs.find`:
	 *     any read / write whose `bindingSpan` is non-null is an in-file
	 *     value named `typeName` and is EXCLUDED, leaving only the
	 *     type-as-namespace receivers.
	 *  e. Qualified type positions (`qualifiedOffsets`), and f. qualified
	 *     dotted paths in expressions (`qualifiedPathOffset`).
	 *  g. Access grants (`grantOffset`).
	 *
	 * Each returned span is the identifier token `[from, from+len)`.
	 * Spans are deduped by `from` offset (a node can be matched by more
	 * than one collector).
	 */
	private static function collectOccurrences(
		source: String, typeName: String, tree: QueryNode, plugin: GrammarPlugin, typeRefShape: TypeRefShape, refShape: RefShape,
		module: ModulePath
	): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		inline function add(identFrom: Int): Void OccurrenceScan.pushUniqueSpan(out, seen, identFrom, typeName.length);

		// a. Type positions.
		final typeRefTree: QueryNode = plugin.parseFileTypeRefs(source);
		for (hit in Uses.find(typeName, typeRefTree, typeRefShape)) add(SourceText.identTokenOffset(source, hit.span, typeName));

		// e. QUALIFIED type positions — the same type named THROUGH its module path.
		final paths: TypePaths = pathsOf(typeName, module, tree, refShape);
		for (off in qualifiedOffsets(source, typeRefTree, typeName, paths.qualified, typeRefShape)) add(off);

		// d-prep. Receiver offsets that resolve to a value binding — an
		// in-file var / param / field named `typeName`. A static-receiver
		// occurrence is renamed only when its receiver is NOT in this set
		// (an unresolved receiver is the type used as a namespace).
		final valueResolved: Array<Int> = RefactorSupport.valueBoundOffsets(typeName, tree, refShape);

		// b. Declaration names + c. imports / using + d. static-receiver
		//    accesses + f. qualified paths + g. access grants (one walk of the
		//    parseFile tree — every arm reads node kinds from it).
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			// b. Declaration name — final-aware: for a `final class` the
			//    named node is the inner `ClassForm`, so anchor the splice on
			//    `typeDeclOf(...).nameNode` (its span holds the name token),
			//    NOT on the `FinalDecl` wrapper, which carries no name.
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl != null && decl.name == typeName) {
				final nameSpan: Null<Span> = decl.nameNode.span;
				if (nameSpan != null) add(SourceText.identTokenOffset(source, nameSpan, typeName));
			} else if (span != null && ModuleScan.IMPORT_DECL_KINDS.contains(node.kind)) {
				if (node.kind == 'ImportDecl' || node.kind == 'UsingDecl')
					add(RefactorSupport.lastSegmentOffset(source, span, node.name, typeName));
				add(throughOffset(source, span, importedPath(node, source, refShape), paths.absolute, typeName));
			}
			final children: Array<QueryNode> = node.children;
			if (node.kind == MemberKinds.FIELD_ACCESS_KIND) {
				add(qualifiedPathOffset(source, node, typeName, paths));
				if (children.length > 0) add(namespaceReceiverOffset(source, children[0], typeName, paths.qualified, valueResolved));
			} else if (MemberKinds.META_KINDS.contains(node.kind) && paths.grantMetas.contains(node.name ?? '')) {
				for (arg in children) add(grantOffset(source, arg, typeName, paths.grant));
			}
			for (c in children) walk(c);
		}
		walk(tree);

		return out;
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
		refShape: RefShape, module: ModulePath
	): CrossRenameResult {
		// A type name is reachable from any file of the scope, so an unparsed
		// conditional-compilation region ANYWHERE in it can hide a type position.
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionInAny(parsed, typeName, refShape, 'rename of "$typeName"');
		if (opaque != null) return Err(opaque);
		final changes: Array<FileChange> = [];
		for (entry in parsed) {
			final occurrences: Array<Span> = collectOccurrences(entry.source, typeName, entry.tree, plugin, typeRefShape, refShape, module);
			if (occurrences.length == 0) continue;
			final edits: Array<{ span: Span, text: String }> = [for (occ in occurrences) { span: occ, text: newName }];
			final newSource: String = CanonicalEdit.applyEdits(entry.source, edits);

			// Atomic validation: every rewritten file must re-parse.
			final refusal: Null<String> = ParseGate.refusal(plugin, newSource, 'rewritten ${entry.file}');
			if (refusal != null) return Err(refusal);

			changes.push({
				file: entry.file,
				newSource: newSource,
				count: occurrences.length,
				edits: edits
			});
		}
		return changes.length == 0 ? Err('rename "$typeName" -> "$newName" changed nothing') : Ok(changes, ADVISORY);
	}

	/**
	 * The last-segment offset of every QUALIFIED type position naming `typeName` through its
	 * module path. The type-ref tree carries `pkg.Mod.T` as ONE node whose name is the whole
	 * dotted string, so the plain-name arm never sees it and the declaration used to be renamed
	 * with every such reference left behind — source that does not compile, reported as success.
	 *
	 * `tree` is the PLAIN tree, read only for the referencing file's own `package`: which dotted
	 * spellings are legal depends on it (see `RefactorSupport.qualifiedPaths`).
	 */
	private static function qualifiedOffsets(
		source: String, typeRefTree: QueryNode, typeName: String, qualified: Array<String>, typeRefShape: TypeRefShape
	): Array<Int> {
		return [
			for (path in qualified) for (hit in Uses.find(path, typeRefTree, typeRefShape))
				RefactorSupport.lastSegmentOffset(source, hit.span, path, typeName)
		];
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
		return recvSpan == null
			|| recv.kind != MemberKinds.IDENT_EXPR_KIND
			|| !RefactorSupport.receiverIsTypeNamespace(recv, typeName, qualified, valueResolved)
			? -1
			: SourceText.identTokenOffset(source, recvSpan, typeName);
	}

	/**
	 * The paths a file can name the type through, resolved once per file (`collectOccurrences`):
	 * the qualified spellings a TYPE or VALUE position accepts, the ABSOLUTE module path an import
	 * names it by, the TYPE path an access grant names it by, the grant metadata names, and the
	 * offsets of every identifier that roots a qualified spelling but is a VALUE binding here.
	 */
	private static function pathsOf(typeName: String, module: ModulePath, tree: QueryNode, refShape: RefShape): TypePaths {
		final qualified: Array<String> = RefactorSupport.qualifiedPaths(typeName, module, ModuleScan.packageOf(tree));
		final roots: Array<String> = [];
		for (path in qualified) {
			final root: String = path.split('.')[0];
			if (!roots.contains(root)) roots.push(root);
		}
		final grantMetas: Array<String> = [AllowGrants.TAG];
		final access: Null<String> = refShape.takesPrivateAccessMetaName;
		if (access != null) grantMetas.push(access);
		return {
			qualified: qualified,
			absolute: typeName == module.base ? module.path : '${module.path}.$typeName',
			grant: module.pkg == '' ? typeName : '${module.pkg}.$typeName',
			grantMetas: grantMetas,
			shadowedRoots: [
				for (root in roots) for (off in RefactorSupport.valueBoundOffsets(root, tree, refShape)) off
			]
		};
	}

	/**
	 * f. The offset of the type's segment in a dotted path `node` (a `FieldAccess` chain) that names
	 * the type through one of its qualified spellings — as a receiver (`pkg.Mod.CONST`, every
	 * `macro pkg.Mod.Ctor(…)` reification), as a VALUE (`var c = pkg.T;`, `Std.isOfType(x, pkg.T)`)
	 * or as a metadata argument — or -1. The chain is matched WHOLE, so a same-simple-name type from
	 * another module is unreachable; and a chain whose root identifier is a value binding in this
	 * file (`final p = {C: 1}; p.C`) is a field read, not the package.
	 */
	private static function qualifiedPathOffset(source: String, node: QueryNode, typeName: String, paths: TypePaths): Int {
		final span: Null<Span> = node.span;
		final path: String = RefactorSupport.flattenPath(node);
		if (span == null || !paths.qualified.contains(path)) return -1;
		var root: QueryNode = node;
		while (root.kind == MemberKinds.FIELD_ACCESS_KIND && root.children.length > 0) root = root.children[0];
		final rootSpan: Null<Span> = root.span;
		return rootSpan == null || paths.shadowedRoots.contains(rootSpan.from)
			? -1
			: RefactorSupport.lastSegmentOffset(source, span, path, typeName);
	}

	/**
	 * g. The offset of the type's segment in an access-grant argument (`@:access(pkg.T)`,
	 * `@:allow(pkg.T.field)`), or -1. A grant names the TYPE path `pkg.T` and never the module path:
	 * the compiler grants `@:access(p.Sub)` for a sub-module type `Sub` of `p.M` and grants nothing for
	 * `@:access(p.M.Sub)` (docs/decisions.md, N35). A stale grant compiles silently, which is why
	 * this arm matters more than its frequency.
	 */
	private static function grantOffset(source: String, arg: QueryNode, typeName: String, grant: String): Int {
		final span: Null<Span> = arg.span;
		return span == null ? -1 : throughOffset(source, span, RefactorSupport.flattenPath(arg), grant, typeName);
	}

	/**
	 * The dotted path an import statement names — its name slot, or for an alias import (whose name
	 * slot is the ALIAS) the aliased path, decoded by the project's one decoder of that text.
	 */
	private static function importedPath(node: QueryNode, source: String, refShape: RefShape): String {
		final span: Null<Span> = node.span;
		return span != null && (refShape.importAliasKinds ?? []).contains(node.kind)
			? ModuleScan.aliasTargetOf(source.substring(span.from, span.to))
			: node.name ?? '';
	}

	/**
	 * The offset of `prefix`'s LAST segment (the type's name) inside `path` written within `span`, when
	 * `path` IS `prefix` or runs THROUGH it (`p.C.K`, `p.C.*` through `p.C`), else -1.
	 */
	private static function throughOffset(source: String, span: Span, path: String, prefix: String, typeName: String): Int {
		if (path != prefix && !path.startsWith('$prefix.')) return -1;
		final at: Int = RefactorSupport.pathOffset(source, span, path);
		return at < 0 ? -1 : at + prefix.length - typeName.length;
	}

}

/** The paths one file can name a renamed type through — `CrossRename.pathsOf`. */
private typedef TypePaths = {
	/** The qualified spellings a type or value position accepts here (`RefactorSupport.qualifiedPaths`). */
	final qualified: Array<String>;

	/** The absolute module path an import names the type by: `pkg.Mod` for a main type, `pkg.Mod.T` for a sub-module one. */
	final absolute: String;

	/** The TYPE path an access grant names it by: `pkg.T`, or the bare name in the root package. */
	final grant: String;

	/** The metadata names whose arguments are access grants. */
	final grantMetas: Array<String>;

	/** Offsets of the identifiers that root a qualified spelling but are value bindings in this file. */
	final shadowedRoots: Array<Int>;
}
