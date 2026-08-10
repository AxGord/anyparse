package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The static readers over a module's TOP LEVEL: its `package`, the names its import / `using`
 * header binds — including the ones the grammar nests under a `Conditional` rather than leaving
 * at the top level — and the types the module itself declares.
 *
 * Split out of `TypeRefPrinter`, which keeps the DECISION side: given a canonical path and the
 * short name it would like to print, is that name free, already bound, or shadowed. Everything
 * here is a pure function of a parsed tree (or of an indexed `FileInfo`) and holds no printer
 * state, which is why the two conditional-region walks and the alias-target recovery sit on this
 * side of the line rather than in the printer.
 */
@:nullSafety(Strict)
final class ModuleScan {

	/** The import / using declaration kinds a grammar projects at the top level — the anchor set for an insert and for the bound-name scan. */
	private static final IMPORT_DECL_KINDS: Array<String> = [
		'ImportDecl',
		'UsingDecl',
		'ImportWildDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl'
	];

	/** The wildcard import kind — the one bulk form whose binding set depends on the package it names. */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The BULK import kinds — the two statements that bind names they do not spell out (`shadowedByBulkImport`). */
	private static final BULK_IMPORT_KINDS: Array<String> = [WILDCARD_IMPORT_KIND, 'UsingDecl'];

	/** Whether the file carries a `package` declaration whose span the grammar did not record. */
	private static function hasSpanlessPackage(root: QueryNode): Bool {
		for (c in root.children) if (c.kind == 'PackageDecl' && c.span == null) return true;
		return false;
	}

	/**
	 * `pack.Module.SubType` reduced to the `pack.SubType` hybrid a compiler prints for a
	 * secondary type — the MODULE segment dropped when the path has one (a second-to-last
	 * upper-initial segment that is not the type's own name). A main-type path (`pack.Module`)
	 * and a simple name come back unchanged, so a reduction never invents a hybrid where none
	 * exists.
	 */
	private static function dropModuleSegment(path: String): String {
		final parts: Array<String> = path.split('.');
		if (parts.length < 3) return path;
		final module: String = parts[parts.length - 2];
		return !RefactorSupport.isUpperInitial(module) || module == parts[parts.length - 1]
			? path
			: parts.slice(0, parts.length - 2).concat([parts[parts.length - 1]]).join('.');
	}

	/**
	 * The module paths of the file's UNGUARDED, top-level `using <module>;` statements. A `using` IS
	 * an `import` plus static extension, so it brings the module's top-level types into scope on the
	 * same terms — but a `#if`-guarded one does so in one build configuration only, which is why the
	 * guarded set (`guardedImportDecls`) is deliberately not merged in here.
	 */
	private static function usingModulesOf(root: QueryNode): Array<String> {
		return [for (c in root.children) if (c.kind == 'UsingDecl' && c.name != null) (c.name: String)];
	}

	/**
	 * The file's BULK import statements — `ImportWildDecl` and `UsingDecl` — including the ones
	 * LIFTED out of a `#if … #end` region, which the grammar nests under a `Conditional` rather
	 * than leaving at the top level. A guarded bulk import genuinely binds its names under its
	 * own guard, and this predicate only ever refuses a short form, so counting it is the
	 * conservative reading; ignoring it was a FALSE NEGATIVE — the direction that emits a short
	 * name binding a different type in one build configuration.
	 */
	private static function bulkImportDecls(root: QueryNode, guarded: Array<QueryNode>): Array<QueryNode> {
		final out: Array<QueryNode> = [for (c in root.children) if (BULK_IMPORT_KINDS.contains(c.kind)) c];
		for (c in guarded) if (BULK_IMPORT_KINDS.contains(c.kind)) out.push(c);
		return out;
	}

	/**
	 * The file's import-ish declarations LIFTED out of a `#if … #end` region — the ones the grammar
	 * nests under a `Conditional` rather than leaving at the top level, and therefore exactly the ones
	 * `_importMap` and `_aliasTargets` (both top-level scans) cannot see.
	 *
	 * The walk RECURSES. Flattening is a property of a region's BRANCHES, not of nested regions: the
	 * grammar lifts every `#if` / `#elseif` / `#else` branch of ONE directive into that region node's
	 * own children, but a region written INSIDE another (`#if a #if b import … #end #end`) projects as
	 * `Conditional > Conditional > ImportDecl`. A one-level reading of that shape sees no import at
	 * all, which is a FALSE NEGATIVE in the direction that matters — it lets a short name bind a
	 * different type in the build where both guards hold.
	 */
	private static function guardedImportDecls(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectGuardedImports(root, false, out);
		return out;
	}

	/**
	 * Append every import-ish declaration reachable from `node` through conditional regions ONLY —
	 * the walk never enters a type body, so it stays proportional to the file's directive nesting
	 * rather than its size. `guarded` is false at the file's top level and true once the walk has
	 * entered a region, so an UNGUARDED top-level import is skipped (it is already in
	 * `_importMap` / `_aliasTargets`).
	 */
	private static function collectGuardedImports(node: QueryNode, guarded: Bool, out: Array<QueryNode>): Void {
		for (c in node.children) if (c.kind == 'Conditional' || c.kind == 'CondSharedBodyDecl')
			collectGuardedImports(c, true, out);
		else if (guarded && IMPORT_DECL_KINDS.contains(c.kind))
			out.push(c);
	}

	/** Whether the type named `name` in `file` is that module's MAIN type — the only kind a package wildcard binds. */
	private static function isMainTypeIn(file: FileInfo, name: String): Bool {
		final decl: Null<TypeDeclInfo> = file.types.find(t -> t.name == name);
		return decl != null && decl.isMain;
	}

	/** The import path a type named `name` declared in `file` carries: the module itself for the main type, else `module.name`. */
	private static function pathOfTypeIn(file: FileInfo, name: String): String {
		final decl: Null<TypeDeclInfo> = file.types.find(t -> t.name == name);
		return decl != null && decl.isMain ? file.module : '${file.module}.$name';
	}

	/** Whether the file's own top level declares a type named `name` — a same-module type, visible with no import. `final class` wrappers normalised via `RefactorSupport.typeDeclOf`. */
	private static function declaresTypeNamed(root: QueryNode, name: String): Bool {
		for (c in root.children) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(c);
			if (decl != null && decl.name == name) return true;
		}
		return false;
	}

	/**
	 * Every `import <path> as <alias>;` in the file, mapped alias -> target path. The grammar
	 * exposes only the ALIAS in the node's name slot (the documented `ImportInfo` limitation),
	 * so the target is recovered by slicing the statement's own source. A statement that does
	 * not decode maps to `''` — the alias still counts as a bound name through the key.
	 */
	private static function aliasTargetsOf(source: String, root: QueryNode): Map<String, String> {
		final out: Map<String, String> = [];
		for (c in root.children) if (c.kind == 'ImportAliasDecl' || c.kind == 'ImportAliasInDecl') {
			final alias: Null<String> = c.name;
			final span: Null<Span> = c.span;
			if (alias != null && span != null) out[alias] = aliasTargetOf(source.substring(span.from, span.to));
		}
		return out;
	}

	/**
	 * The dotted path of one `import a.b.C as D;` statement text — the identifier run BEFORE the
	 * trailing `as` / `in` keyword, which is where the aliased path always sits — or `''` when it
	 * does not decode. Comments are stripped first: a `/* … *\/` between the keyword and the path
	 * would otherwise be decoded AS the path, and a wrong target silently prints the alias for
	 * the wrong type. `''` still occupies the alias's name, which is what the collision gate
	 * needs.
	 */
	private static function aliasTargetOf(stmt: String): String {
		final bare: String = stripComments(stmt);
		final runs: Array<String> = [];
		final n: Int = bare.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = bare.fastCodeAt(i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = bare.fastCodeAt(i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			runs.push(bare.substring(start, i));
		}
		// `import <path> as <alias>;` -> the run before the `as` / `in` keyword.
		for (r => run in runs) if ((run == 'as' || run == 'in') && r > 0) return runs[r - 1];
		return '';
	}

	/** `text` with every `//` line comment and `/* … *\/` block comment replaced by a space, so a lexical scan cannot read comment content as code. */
	private static function stripComments(text: String): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = text.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			final next: Int = i + 1 < n ? text.fastCodeAt(i + 1) : 0;
			if (c == '/'.code && next == '/'.code) {
				while (i < n && text.fastCodeAt(i) != '\n'.code) i++;
				buf.addChar(' '.code);
				continue;
			}
			if (c == '/'.code && next == '*'.code) {
				i += 2;
				while (i + 1 < n && (text.fastCodeAt(i) != '*'.code || text.fastCodeAt(i + 1) != '/'.code)) i++;
				i = i + 2 < n ? i + 2 : n;
				buf.addChar(' '.code);
				continue;
			}
			buf.addChar(c);
			i++;
		}
		return buf.toString();
	}

	/** The module's main type name — the FIRST named top-level type declaration (the module basename is not available to the printer). */
	private static function mainTypeNameOf(root: QueryNode): Null<String> {
		for (c in root.children) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(c);
			if (decl != null) return decl.name;
		}
		return null;
	}

	/** The file's `package` payload (`''` for the root package, and for a file with no declaration at all). */
	private static function packageOf(root: QueryNode): String {
		for (c in root.children) if (c.kind == 'PackageDecl') return c.name ?? '';
		return '';
	}

}
