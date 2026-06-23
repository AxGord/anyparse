package anyparse.query;

import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The four import-statement forms a Haxe file may carry, distinguished
 * structurally so a consumer can decide which forms participate in a
 * symbol move / rewrite. Modelled as a zero-cost `enum abstract(Int)`
 * because the kind carries no associated data.
 *
 *  - `Import` — `import pkg.Module;` / `import pkg.Module.SubType;`.
 *  - `Alias`  — `import pkg.Module as U;` (the original path is NOT
 *    exposed by the grammar — only the alias is in the node's name
 *    slot, a known limitation; `raw` therefore holds the alias).
 *  - `Wild`   — `import pkg.*;` (the `raw` slot holds `pkg.*`).
 *  - `Using`  — `using pkg.Module;`.
 */
enum abstract ImportKind(Int) {

	final Import = 0;
	final Alias = 1;
	final Wild = 2;
	final Using = 3;

}

/**
 * One import / using statement extracted from a file's top-level
 * declarations. `raw` is the verbatim payload the grammar exposes for
 * the kind (the dotted path for `Import` / `Using`, the alias for
 * `Alias`, `pkg.*` for `Wild`); `alias` is the bound alias when the
 * kind is `Alias`, else null; `span` is the statement's source range.
 */
typedef ImportInfo = {
	var raw: String;
	var kind: ImportKind;
	var alias: Null<String>;
	var span: Span;
}

/**
 * One top-level type declaration. `kind` is the grammar's decl-node
 * kind string (`ClassDecl` / `InterfaceDecl` / `EnumDecl` /
 * `TypedefDecl` / `AbstractDecl`); `isMain` is true when the type's
 * name equals the file basename — i.e. it is the module's main type,
 * importable as `import <package>.<Basename>;`.
 */
typedef TypeDeclInfo = {
	var name: String;
	var kind: String;
	var span: Span;
	var isMain: Bool;

	/**
	 * Simple names (last `.` segment) of this type's `extends` / `implements`
	 * targets — its direct supertypes. Drives `hasSubtype`, the first gate of a
	 * cross-file-safe private-member rename (a subtype could access the member).
	 */
	var supertypes: Array<String>;

	/** True when this is a `typedef X = {…}` anonymous struct — its fields can never be properties, so field access on it is side-effect-free. */
	var isAnonStruct: Bool;
}
typedef FileInfo = {
	var file: String;
	var pkg: String;
	var module: String;
	var imports: Array<ImportInfo>;
	var types: Array<TypeDeclInfo>;

	/**
	 * Simple names of every type referenced in an `@:access(...)` metadata in
	 * this file — types this file grants itself private access to. Drives
	 * `hasAccessGrant`, the second gate of a cross-file-safe private-member rename.
	 */
	var accessGrants: Array<String>;
}
@:nullSafety(Strict)
final class SymbolIndex {

	private final _files: Array<FileInfo>;
	private final _skipped: Array<String>;

	private function new(files: Array<FileInfo>, skipped: Array<String>) {
		_files = files;
		_skipped = skipped;
	}

	/** The `FileInfo` for `file`, or null when the file is not indexed. */
	public function fileInfo(file: String): Null<FileInfo> {
		return _files.find(f -> f.file == file);
	}

	/** Every indexed file's `FileInfo`, in input order. */
	public function allFiles(): Array<FileInfo> {
		return _files.copy();
	}

	/** Files that failed to parse and were excluded from the index. */
	public function skippedFiles(): Array<String> {
		return _skipped.copy();
	}

	/**
	 * Files declaring a top-level type named `typeName`. Length 0 / 1 /
	 * many is the ambiguity signal a move-symbol op tests before
	 * proceeding.
	 */
	public function declaringFiles(typeName: String): Array<FileInfo> {
		return _files.filter(f -> f.types.exists(t -> t.name == typeName));
	}

	/**
	 * The import path that names `typeName`, when EXACTLY ONE file
	 * declares it: the file's `module` when the type is the module's
	 * main type, else `module + '.' + typeName` (a sub-type). Null when
	 * zero or more than one file declares it — the path is ambiguous and
	 * a move cannot pick one without more context.
	 */
	public function importPathOf(typeName: String): Null<String> {
		final declarers: Array<FileInfo> = declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final file: FileInfo = declarers[0];
		final type: Null<TypeDeclInfo> = file.types.find(t -> t.name == typeName);
		return type == null ? null : type.isMain ? file.module : '${file.module}.$typeName';
	}

	/**
	 * Files that import the module `modulePath` — an `ImportInfo` whose
	 * `raw` equals `modulePath` (the main type / module itself) OR
	 * starts with `modulePath + '.'` (a sub-type of the module, e.g.
	 * `anyparse.query.Refs.RefHit` for module `anyparse.query.Refs`).
	 *
	 * `Import`, `Alias` and `Using` kinds are considered: each carries a
	 * dotted path whose prefix can be compared. `Wild` (`pkg.*`) is
	 * skipped — its `raw` is a package-prefix glob, not a module path,
	 * so prefix-matching it against a module path is a different
	 * predicate left for a future package-prefix query. (`Alias` only
	 * matches when its exposed `raw` — the alias — coincides with the
	 * path, since the grammar does not expose the aliased original
	 * path; this is the documented alias limitation carried from
	 * `ImportInfo`.)
	 */
	public function filesImportingModule(modulePath: String): Array<FileInfo> {
		final prefix: String = '$modulePath.';
		return _files.filter(
			f -> f.imports.exists(imp -> imp.kind != ImportKind.Wild && (imp.raw == modulePath || StringTools.startsWith(imp.raw, prefix)))
		);
	}

	/**
	 * Does any indexed type extend / implement `typeName` (matched by simple
	 * name)? The first gate of a cross-file-safe private-member rename — a
	 * subtype could reference the member.
	 */
	public function hasSubtype(typeName: String): Bool {
		return _files.exists(f -> f.types.exists(t -> t.supertypes.contains(typeName)));
	}

	/**
	 * Does any indexed file grant itself `@:access(typeName)` (matched by simple
	 * name)? The second gate — such a file can read the type's private members.
	 */
	public function hasAccessGrant(typeName: String): Bool {
		return _files.exists(f -> f.accessGrants.contains(typeName));
	}

	/**
	 * Parse every `(file, source)` entry through `plugin.parseFile` and
	 * build the index. A file whose parse throws is recorded in
	 * `skippedFiles()` and EXCLUDED from the index — `build` never
	 * throws. The file basename (the path tail sans `.hx`) drives the
	 * module path and the `isMain` flag for each type, mirroring
	 * `CrossRename`'s parse-each-file pattern.
	 */
	public static function build(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): SymbolIndex {
		final infos: Array<FileInfo> = [];
		final skipped: Array<String> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
				continue;
			}
			infos.push(extractFileInfo(entry.file, tree));
		}
		return new SymbolIndex(infos, skipped);
	}

	/**
	 * The MODULE portion of a dotted import path: the segments up to and
	 * INCLUDING the first upper-case-initial segment (packages are
	 * lower-case, modules / types upper-case). Any remaining segments are
	 * sub-type access and are dropped. So `anyparse.query.Refs.RefHit` →
	 * `anyparse.query.Refs` (module `Refs`, sub-type `RefHit`),
	 * `anyparse.query.Rename` → `anyparse.query.Rename` (no sub-type),
	 * `pkg.sub.Foo` → `pkg.sub.Foo`. A path with no upper-case segment
	 * (all lower-case) is returned verbatim — there is no module segment
	 * to anchor on.
	 */
	public static function moduleOf(path: String): String {
		final segments: Array<String> = path.split('.');
		final out: Array<String> = [];
		for (segment in segments) {
			out.push(segment);
			if (segment.length > 0 && isUpperInitial(segment)) return out.join('.');
		}
		return path;
	}

	/**
	 * Build a `FileInfo` from a parsed `parseFile` tree: walk the
	 * top-level module children for the `PackageDecl`, the import /
	 * using statements, and the top-level type declarations. The
	 * basename drives the module path and the per-type `isMain` flag.
	 */
	private static function extractFileInfo(file: String, tree: QueryNode): FileInfo {
		final basename: String = RefactorSupport.baseNameOf(file);
		var pkg: String = '';
		final imports: Array<ImportInfo> = [];
		final types: Array<TypeDeclInfo> = [];

		for (node in tree.children) {
			// Type declarations resolve through the final-aware helper FIRST
			// — a `final class` is a nameless `FinalDecl` wrapper whose inner
			// `ClassForm` holds the name, so a plain `node.name` guard would
			// drop it. `typeDeclOf` normalises both shapes and yields the
			// FULL span (including the `final ` keyword for a final class).
			final typeDecl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (typeDecl != null) {
				types.push({
					name: typeDecl.name,
					kind: typeDecl.kind,
					span: typeDecl.fullSpan,
					isMain: typeDecl.name == basename,
					supertypes: collectSupertypes(node),
					// A `typedef X = {…}` projects an `Anon` child; its fields can
					// never be properties, so field access on it is side-effect-free.
					isAnonStruct: typeDecl.kind == 'TypedefDecl' && node.children.exists(c -> c.kind == 'Anon')
				});
				continue;
			}

			final nullableName: Null<String> = node.name;
			final nullableSpan: Null<Span> = node.span;
			if (nullableName == null || nullableSpan == null) {
				if (node.kind == 'PackageDecl' && nullableName != null) pkg = nullableName;
				continue;
			}
			// Re-bind to non-nullable locals: Strict null-safety narrows
			// the nullable locals for the guard, but the inferred field
			// type of an anonymous struct literal is taken from the
			// DECLARED type — so the literals must read locals whose
			// declared type is already non-null.
			final name: String = nullableName;
			final span: Span = nullableSpan;
			switch node.kind {
				case 'PackageDecl':
					pkg = name;
				case 'ImportDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Import,
						alias: null,
						span: span
					});
				case 'ImportAliasDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Alias,
						alias: name,
						span: span
					});
				case 'ImportWildDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Wild,
						alias: null,
						span: span
					});
				case 'UsingDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Using,
						alias: null,
						span: span
					});
				case _:
			}
		}

		final module: String = pkg == '' ? basename : '$pkg.$basename';
		return {
			file: file,
			pkg: pkg,
			module: module,
			imports: imports,
			types: types,
			accessGrants: collectAccessGrants(tree)
		};
	}

	/** Does `segment` begin with an upper-case ASCII letter? */
	private static inline function isUpperInitial(segment: String): Bool {
		final c: Int = StringTools.fastCodeAt(segment, 0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	/**
	 * Simple names (last `.` segment) of the `extends` / `implements` targets
	 * under `node` — its supertypes — by reading each `Named` child of an
	 * `ExtendsClause` / `ImplementsClause`.
	 */
	private static function collectSupertypes(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(
			node, n -> {
				if (n.kind == 'ExtendsClause' || n.kind == 'ImplementsClause')
					for (c in n.children) {
						final nm: Null<String> = c.name;
						if (nm != null)
							out.push(simpleName(nm));
					}
			}
		);
		return out;
	}

	/** Simple names of every type referenced in an `@:access(...)` metadata in `tree`. */
	private static function collectAccessGrants(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(
			tree, n -> {
				if (n.kind == 'MetaCall' && n.name == '@:access')
					for (c in n.children) {
						final nm: Null<String> = c.name;
						if (nm != null)
							out.push(simpleName(nm));
					}
			}
		);
		return out;
	}

	/** Visit `node` and every descendant, applying `visit` to each. */
	private static function collectInto(node: QueryNode, visit: QueryNode -> Void): Void {
		visit(node);
		for (child in node.children) collectInto(child, visit);
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		final last: Null<String> = segments[segments.length - 1];
		return last ?? path;
	}

	/**
	 * True iff every indexed type with simple name `name` is an anonymous-struct
	 * typedef (and at least one exists) — so a value of that type has only plain
	 * fields and `value.field` access is provably side-effect-free. Conservative
	 * under ambiguity: a single non-anon match (or no match) yields false.
	 */
	public function isAnonStructType(name: String): Bool {
		var found: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == name) {
			if (!t.isAnonStruct) return false;
			found = true;
		}
		return found;
	}

}
