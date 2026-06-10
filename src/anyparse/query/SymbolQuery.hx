package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

/**
 * One row of the `apq symbols` listing: a top-level type declaration
 * resolved to its canonical import path plus its source coordinate.
 * `qualified` is what a consumer would `import` — the module path itself
 * for the module's main type, else `module.TypeName` for a sub-type
 * (the same rule `SymbolIndex.importPathOf` applies). `kind` is the
 * grammar decl-node kind (`ClassDecl` / `InterfaceDecl` / `EnumDecl` /
 * `TypedefDecl` / `AbstractDecl`).
 */
typedef SymbolRow = {
	var qualified: String;
	var name: String;
	var kind: String;
	var file: String;
	var line: Int;
	var col: Int;
}

/**
 * Thin CLI-facing reporting layer over `SymbolIndex` — the cross-file
 * type browser (`apq symbols`) and reverse-import query
 * (`apq importers`). Both are pure: they parse an in-memory
 * `(file, source)` set through the plugin, build the index, and format
 * its answers. No edits, no `EditResult` — they print a report.
 *
 * Keeping this separate from `Cli` keeps the dispatchers thin and lets a
 * SliceTest drive the listing in-memory without touching the filesystem
 * or stdout. `SymbolIndex` does the real work (parse / package / imports
 * / type decls); this layer only resolves coordinates and filters /
 * formats rows.
 */
@:nullSafety(Strict)
final class SymbolQuery {

	/**
	 * Every top-level type declaration across `files`, in input-file
	 * order then source order within each file. When `kindFilter` is
	 * non-null, only decls whose grammar kind equals it are kept
	 * (`ClassDecl` / `InterfaceDecl` / `EnumDecl` / `TypedefDecl` /
	 * `AbstractDecl`). Coordinates are the 1-indexed `line:col` of the
	 * decl span resolved against that file's own source. Unparseable
	 * files are silently excluded (they are in `SymbolIndex.skippedFiles`).
	 */
	public static function symbols(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?kindFilter: String
	): Array<SymbolRow> {
		final sourceOf: Map<String, String> = new Map();
		for (entry in files) sourceOf.set(entry.file, entry.source);

		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final rows: Array<SymbolRow> = [];
		for (info in index.allFiles()) {
			final maybeSrc: Null<String> = sourceOf.get(info.file);
			final src: String = maybeSrc != null ? maybeSrc : '';
			for (type in info.types) {
				if (kindFilter != null && type.kind != kindFilter) continue;
				final pos = type.span.lineCol(src);
				rows.push({
					qualified: type.isMain ? info.module : '${info.module}.${type.name}',
					name: type.name,
					kind: type.kind,
					file: info.file,
					line: pos.line,
					col: pos.col
				});
			}
		}
		return rows;
	}

	/**
	 * The files in `files` that import the module `modulePath` — a
	 * direct `import`/`using` of the module itself or of one of its
	 * sub-types (`SymbolIndex.filesImportingModule`). Returns the file
	 * paths in input order. A wildcard `import pkg.*;` is NOT counted —
	 * see the `filesImportingModule` docstring for why.
	 */
	public static function importers(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, modulePath: String
	): Array<String> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		return [for (info in index.filesImportingModule(modulePath)) info.file];
	}

	/**
	 * The declaration site(s) of the type named `typeName` across `files`,
	 * matching either the simple name or the fully qualified import path —
	 * the focused, single-type counterpart of `symbols`. More than one row
	 * means the name is ambiguous in this scope (two decls of the same type
	 * name); an empty result means it is not declared here. Built on
	 * `symbols`, so the same coordinate and skip-parse rules apply.
	 */
	public static function declares(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeName: String
	): Array<SymbolRow> {
		return symbols(files, plugin).filter(row -> row.name == typeName || row.qualified == typeName);
	}

	/** Render a `SymbolRow` as `qualified<TAB>kind<TAB>file:line:col`. */
	public static function formatSymbolRow(row: SymbolRow): String {
		return '${row.qualified}\t${row.kind}\t${row.file}:${row.line}:${row.col}';
	}

}
