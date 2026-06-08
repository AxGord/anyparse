package anyparse.query;

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
	var raw:String;
	var kind:ImportKind;
	var alias:Null<String>;
	var span:Span;
}

/**
 * One top-level type declaration. `kind` is the grammar's decl-node
 * kind string (`ClassDecl` / `InterfaceDecl` / `EnumDecl` /
 * `TypedefDecl` / `AbstractDecl`); `isMain` is true when the type's
 * name equals the file basename — i.e. it is the module's main type,
 * importable as `import <package>.<Basename>;`.
 */
typedef TypeDeclInfo = {
	var name:String;
	var kind:String;
	var span:Span;
	var isMain:Bool;
}

/**
 * The package / imports / type-declarations of one parseable file.
 * `module` is the canonical module path (`<pkg>.<basename>` — see the
 * class docstring); `pkg` is the empty string for a file with no
 * `package;` declaration (the root package).
 */
typedef FileInfo = {
	var file:String;
	var pkg:String;
	var module:String;
	var imports:Array<ImportInfo>;
	var types:Array<TypeDeclInfo>;
}

/**
 * Pure, I/O-free cross-file symbol resolver — the foundation for a
 * move-symbol op and for hardening cross-file rename. `build` parses a
 * set of in-memory `(file, source)` entries through a `GrammarPlugin`
 * and records, per parseable file, its package, its import / using
 * statements, and its top-level type declarations. A file that throws
 * / skip-parses is recorded in `skippedFiles()` and EXCLUDED from the
 * index (never throws). The index then answers the cross-file
 * questions a move needs: who declares a type, what import path names
 * it, and which files import a given module.
 *
 * ## Haxe module / visibility semantics this index bakes in
 *
 * These rules are verified against the Haxe language and against
 * anyparse's own `src/` import patterns; a move-symbol op relies on
 * them being exact.
 *
 *  - A `.hx` FILE is a MODULE. Its module path is the package plus the
 *    file basename: `src/anyparse/query/Cli.hx` with `package
 *    anyparse.query;` → module `anyparse.query.Cli`. With no `package;`
 *    the module path is just the basename (root package).
 *
 *  - The module's MAIN type is the type whose name equals the file
 *    basename. It is imported as `import <package>.<Basename>;` (the
 *    `Module` path itself, no trailing segment). Every OTHER type in
 *    the file (a sub-type) is imported as `import
 *    <package>.<Basename>.<SubType>;`. Evidence in anyparse `src/`:
 *    `Cli.hx` carries both `import anyparse.query.Rename;` (main type
 *    `Rename`, the module path) and `import anyparse.query.Rename.RenameResult;`
 *    (the sub-type `RenameResult`, the module path plus the type).
 *
 *  - Same-PACKAGE types are auto-visible WITHOUT an import in Haxe.
 *    anyparse nonetheless imports them explicitly and redundantly —
 *    `Cli.hx` (package `anyparse.query`) imports `anyparse.query.Rename`,
 *    `anyparse.query.Inline`, `anyparse.query.CrossRename`, all of which
 *    live in the same package. Consequence for a move: a move WITHIN a
 *    package may leave a stale explicit import that was never strictly
 *    required — `filesImportingModule` surfaces those so the caller can
 *    fix or drop them.
 *
 * ## Scope — what is and is NOT indexed
 *
 * Index covers ONLY the module's package, its imports / usings, and its
 * top-level type declarations. Type MEMBERS and module-level functions
 * are deliberately out of scope — they extend the index later when a
 * move-static op needs them.
 */
@:nullSafety(Strict)
final class SymbolIndex {

	/**
	 * Grammar decl-node kinds that count as a top-level type
	 * declaration. Mirrors the five top-level Haxe decls (and
	 * `CrossRename.TYPE_DECL_KINDS`); a type-position occurrence can
	 * only ever resolve to one of these.
	 */
	private static final TYPE_DECL_KINDS:Array<String> = [
		'ClassDecl', 'InterfaceDecl', 'EnumDecl', 'TypedefDecl', 'AbstractDecl',
	];

	private final _files:Array<FileInfo>;
	private final _skipped:Array<String>;

	private function new(files:Array<FileInfo>, skipped:Array<String>) {
		_files = files;
		_skipped = skipped;
	}

	/** The `FileInfo` for `file`, or null when the file is not indexed. */
	public function fileInfo(file:String):Null<FileInfo> {
		return _files.find(f -> f.file == file);
	}

	/** Every indexed file's `FileInfo`, in input order. */
	public function allFiles():Array<FileInfo> {
		return _files.copy();
	}

	/** Files that failed to parse and were excluded from the index. */
	public function skippedFiles():Array<String> {
		return _skipped.copy();
	}

	/**
	 * Files declaring a top-level type named `typeName`. Length 0 / 1 /
	 * many is the ambiguity signal a move-symbol op tests before
	 * proceeding.
	 */
	public function declaringFiles(typeName:String):Array<FileInfo> {
		return _files.filter(f -> f.types.exists(t -> t.name == typeName));
	}

	/**
	 * The import path that names `typeName`, when EXACTLY ONE file
	 * declares it: the file's `module` when the type is the module's
	 * main type, else `module + '.' + typeName` (a sub-type). Null when
	 * zero or more than one file declares it — the path is ambiguous and
	 * a move cannot pick one without more context.
	 */
	public function importPathOf(typeName:String):Null<String> {
		final declarers:Array<FileInfo> = declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final file:FileInfo = declarers[0];
		final type:Null<TypeDeclInfo> = file.types.find(t -> t.name == typeName);
		if (type == null) return null;
		return type.isMain ? file.module : '${file.module}.$typeName';
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
	public function filesImportingModule(modulePath:String):Array<FileInfo> {
		final prefix:String = '$modulePath.';
		return _files.filter(f -> f.imports.exists(imp ->
			imp.kind != ImportKind.Wild
			&& (imp.raw == modulePath || StringTools.startsWith(imp.raw, prefix))));
	}

	/**
	 * Parse every `(file, source)` entry through `plugin.parseFile` and
	 * build the index. A file whose parse throws is recorded in
	 * `skippedFiles()` and EXCLUDED from the index — `build` never
	 * throws. The file basename (the path tail sans `.hx`) drives the
	 * module path and the `isMain` flag for each type, mirroring
	 * `CrossRename`'s parse-each-file pattern.
	 */
	public static function build(files:Array<{file:String, source:String}>, plugin:GrammarPlugin):SymbolIndex {
		final infos:Array<FileInfo> = [];
		final skipped:Array<String> = [];
		for (entry in files) {
			final tree:Null<QueryNode> = try plugin.parseFile(entry.source)
				catch (_:Exception) null;
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
	public static function moduleOf(path:String):String {
		final segments:Array<String> = path.split('.');
		final out:Array<String> = [];
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
	private static function extractFileInfo(file:String, tree:QueryNode):FileInfo {
		final basename:String = baseNameOf(file);
		var pkg:String = '';
		final imports:Array<ImportInfo> = [];
		final types:Array<TypeDeclInfo> = [];

		for (node in tree.children) {
			final nullableName:Null<String> = node.name;
			final nullableSpan:Null<Span> = node.span;
			if (nullableName == null || nullableSpan == null) {
				if (node.kind == 'PackageDecl' && nullableName != null) pkg = nullableName;
				continue;
			}
			// Re-bind to non-nullable locals: Strict null-safety narrows
			// the nullable locals for the guard, but the inferred field
			// type of an anonymous struct literal is taken from the
			// DECLARED type — so the literals must read locals whose
			// declared type is already non-null.
			final name:String = nullableName;
			final span:Span = nullableSpan;
			switch node.kind {
				case 'PackageDecl': pkg = name;
				case 'ImportDecl': imports.push({raw: name, kind: ImportKind.Import, alias: null, span: span});
				case 'ImportAliasDecl': imports.push({raw: name, kind: ImportKind.Alias, alias: name, span: span});
				case 'ImportWildDecl': imports.push({raw: name, kind: ImportKind.Wild, alias: null, span: span});
				case 'UsingDecl': imports.push({raw: name, kind: ImportKind.Using, alias: null, span: span});
				case _ if (TYPE_DECL_KINDS.contains(node.kind)):
					types.push({name: name, kind: node.kind, span: span, isMain: name == basename});
				case _:
			}
		}

		final module:String = pkg == '' ? basename : '$pkg.$basename';
		return {file: file, pkg: pkg, module: module, imports: imports, types: types};
	}

	/** File basename: the path tail after the last `/`, with a `.hx` suffix removed. */
	private static function baseNameOf(file:String):String {
		final slash:Int = file.lastIndexOf('/');
		final tail:String = slash < 0 ? file : file.substr(slash + 1);
		return StringTools.endsWith(tail, '.hx') ? tail.substr(0, tail.length - '.hx'.length) : tail;
	}

	/** Does `segment` begin with an upper-case ASCII letter? */
	private static inline function isUpperInitial(segment:String):Bool {
		final c:Int = StringTools.fastCodeAt(segment, 0);
		return c >= 'A'.code && c <= 'Z'.code;
	}
}
