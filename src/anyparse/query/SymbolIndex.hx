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
typedef MemberInfo = {
	/** The member's name. */
	var name: String;

	/** True when the member is a property whose READ accessor is a getter (`get` / `dynamic`) — reading it runs code. A plain field / method is false. */
	var hasGetter: Bool;
};

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

	/** This type's directly-declared members (name + getter-property flag), for type-aware purity. */
	var members: Array<MemberInfo>;
};
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

	/**
	 * Whether type `typeName`'s member `field` is a getter-property (true → reading
	 * it runs code), a plain member (false → side-effect-free read), or not a known
	 * direct member (null). Conservative under ambiguity: any matching type whose
	 * `field` is a getter yields true.
	 */
	public function memberGetter(typeName: String, field: String): Null<Bool> {
		var found: Null<Bool> = null;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == field) {
			if (m.hasGetter) return true;
			found = false;
		}
		return found;
	}

	/**
	 * The single declaring file + decl span of the type named `typeName`, or null when
	 * zero or more than one file declares it (ambiguous — a write-confinement query
	 * cannot pin a unique decl range and must bail). The decl span is the type's full
	 * source range, used to tell an internal write from an external one.
	 */
	public function declarationSiteOf(typeName: String): Null<{ file: String, span: Span }> {
		final declarers: Array<FileInfo> = declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final f: FileInfo = declarers[0];
		final t: Null<TypeDeclInfo> = f.types.find(td -> td.name == typeName);
		return t == null ? null : { file: f.file, span: t.span };
	}

	/**
	 * Whether a (transitive) supertype of `typeName` declares a member named `field`.
	 * Such a field's property access is fixed by the supertype, so a check must not
	 * tighten it (`var` → `final` / `(default, null)`) — Haxe rejects an override /
	 * implementation whose access differs — and an interface-typed write to it
	 * attributes to the supertype, not `typeName`. The supertype-ward companion of
	 * `hasSubtype`, used by the public-field immutability checks as a soundness gate.
	 */
	public function supertypeDeclaresMember(typeName: String, field: String): Bool {
		return supertypeDeclares(typeName, field, []);
	}

	/** Recursive supertype walk for `supertypeDeclaresMember`, cycle-guarded by `seen`. */
	private function supertypeDeclares(typeName: String, field: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return false;
		seen.push(typeName);
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (sup in t.supertypes)
			if (declaresMember(sup, field) || supertypeDeclares(sup, field, seen)) return true;
		return false;
	}

	/** Whether any indexed type named `typeName` directly declares a member named `field`. */
	private function declaresMember(typeName: String, field: String): Bool {
		for (fi in _files) for (t in fi.types) if (t.name == typeName) if (t.members.exists(m -> m.name == field)) return true;
		return false;
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
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
				continue;
			}
			final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(entry.source) : [];
			infos.push(extractFileInfo(entry.file, tree, accessors));
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
	private static function extractFileInfo(file: String, tree: QueryNode, accessors: Map<Int, Bool>): FileInfo {
		final basename: String = RefactorSupport.baseNameOf(file);
		var pkg: String = '';
		final imports: Array<ImportInfo> = [];
		final types: Array<TypeDeclInfo> = [];

		for (node in tree.children) {
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
					isAnonStruct: typeDecl.kind == 'TypedefDecl' && node.children.exists(c -> c.kind == 'Anon'),
					members: collectMembers(node, accessors)
				});
				continue;
			}

			final nullableName: Null<String> = node.name;
			final nullableSpan: Null<Span> = node.span;
			if (nullableName == null || nullableSpan == null) {
				if (node.kind == 'PackageDecl' && nullableName != null) pkg = nullableName;
				continue;
			}
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
	 * The directly-declared members of the type rooted at `node` — every
	 * field-member-kind descendant (a type body's own `var`/`final`/`fn` members;
	 * a method's LOCAL vars are `VarStmt`, a different kind, so excluded) — paired
	 * with its getter-property flag from the `accessors` span map (absent = plain).
	 */
	private static function collectMembers(node: QueryNode, accessors: Map<Int, Bool>): Array<MemberInfo> {
		final out: Array<MemberInfo> = [];
		collectInto(
			node, n -> {
				if (RefactorSupport.FIELD_MEMBER_KINDS.contains(n.kind)) {
					final nm: Null<String> = n.name;
					final sp: Null<Span> = n.span;
					if (nm != null && sp != null) {
						// Re-bind to a non-null local — Strict null-safety takes a struct
						// literal's field type from the declared type, not the narrowed one.
						final memberName: String = nm;
						out.push({ name: memberName, hasGetter: accessors[sp.from] ?? false });
					}
				}
			}
		);
		return out;
	}

}
