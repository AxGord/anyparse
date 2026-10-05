package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;
using StringTools;

/** What one resolution tier says about a name — and, from `TypeNameBinding.tierOf`, what the whole order says. */
enum Tier {

	/** The tier binds the name, to these declarations. */
	Bound(decls: Array<ResolvedType>);

	/** The tier COULD bind the name but what it binds to is not in the index, so no lower tier may answer. */
	Unknown;

	/** The tier provably does not bind the name; the next one is asked. From `tierOf`: no tier does, so only a built-in can. */
	Free;

}

/**
 * The declarations a SIMPLE type name written in a file binds to, asked tier by tier in the order
 * the Haxe compiler resolves it (probed on 4.3.7): the module's own types; the file's explicit
 * imports, aliases by their alias name, the LAST binding one winning; the ambient `import.hx`
 * chain, nearest first; wildcard imports, which bring in module MAIN types only; the file's
 * package and then each parent package, main types only; the toplevel package.
 *
 * A whitelist, not a search: a tier that could bind the name but whose target the index does not
 * hold — an import of an unindexed module (which may carry the name as a sub-type), an alias or an
 * import of an unindexed path, a wildcard over an unindexed package, a `#if`-guarded import that
 * binds it, an ambient chain the index could not bound — answers NULL, and no lower tier is asked.
 * Answering from a lower tier there is exactly how a same-package class shadowed a `Null<…>` alias
 * the compiler actually picked.
 */
@:nullSafety(Strict)
final class TypeNameBinding {

	/** Null when no tier provably answers; otherwise the declarations of the first tier that binds `name`. */
	public static function bind(name: String, fi: FileInfo, index: SymbolIndex): Null<Array<ResolvedType>> {
		return switch tierOf(name, fi, index) {
			case Bound(decls): decls;
			case Unknown, Free: null;
		};
	}

	/**
	 * The whole resolution order's answer: `Bound` by the first tier that binds `name`, `Unknown` when a
	 * tier could bind it to something the index does not hold, `Free` when every tier provably passes —
	 * the one answer that leaves the name to the compiler's own built-ins.
	 */
	public static function tierOf(name: String, fi: FileInfo, index: SymbolIndex): Tier {
		final own: Array<TypeDeclInfo> = fi.types.filter(t -> t.name == name);
		if (own.length > 0) return Bound([for (t in own) { file: fi, type: t }]);
		final tiers: Array<() -> Tier> = [explicitTier.bind(name, fi.imports, index)];
		for (group in fi.ambientImports) tiers.push(explicitTier.bind(name, group.imports, index));
		tiers.push(() -> fi.ambientImportsBounded ? Free : Unknown);
		tiers.push(wildcardTier.bind(name, fi, index));
		tiers.push(packageTier.bind(name, fi.pkg, index));
		for (tier in tiers) switch tier() {
			case Free:
			case answer:
				return answer;
		}
		return Free;
	}

	private static inline function boundOrUnknown(decls: Array<ResolvedType>): Tier {
		return decls.length == 0 ? Unknown : Bound(decls);
	}

	private static inline function lastSegment(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/** The explicit imports of one statement list: the last one binding `name` wins. */
	private static function explicitTier(name: String, imports: Array<ImportInfo>, index: SymbolIndex): Tier {
		var i: Int = imports.length;
		while (i-- > 0) {
			switch importTier(name, imports[i], index) {
				case Free:
				case answer:
					return answer;
			}
		}
		return Free;
	}

	/** What one explicit import says about `name`; a wildcard is left to `wildcardTier`. */
	private static function importTier(name: String, imp: ImportInfo, index: SymbolIndex): Tier {
		if (imp.kind == ImportKind.Wild) return Free;
		if (imp.kind == ImportKind.Alias) {
			final target: Null<String> = imp.aliasTarget;
			return if (imp.alias != name)
				Free
			else if (imp.guarded || target == null)
				Unknown
			else
				boundOrUnknown(index.refs.resolveQualifiedRefAll(target));
		}
		final path: String = imp.raw;
		if (lastSegment(path) == name) return imp.guarded ? Unknown : boundOrUnknown(index.refs.resolveQualifiedRefAll(path));
		final module: Array<FileInfo> = index.allFiles().filter(f -> f.module == path);
		if (module.length == 0) return index.allFiles().exists(f -> f.module == SourceText.parentPath(path)) ? Free : Unknown;
		final sub: Array<ResolvedType> = [
			for (f in module) for (t in f.types) if (t.name == name && !t.isPrivate) { file: f, type: t }
		];
		return if (sub.length == 0)
			Free
		else if (imp.guarded)
			Unknown
		else
			Bound(sub);
	}

	/** Every wildcard import of the file and of its ambient chain, as one tier. */
	private static function wildcardTier(name: String, fi: FileInfo, index: SymbolIndex): Tier {
		final wilds: Array<ImportInfo> = fi.imports.filter(i -> i.kind == ImportKind.Wild);
		for (group in fi.ambientImports) for (i in group.imports) if (i.kind == ImportKind.Wild) wilds.push(i);
		final found: Array<ResolvedType> = [];
		for (w in wilds) {
			final pkg: String = SourceText.parentPath(w.raw);
			final files: Array<FileInfo> = index.allFiles().filter(f -> f.pkg == pkg);
			if (files.length == 0 && !index.allFiles().exists(f -> f.module == pkg)) return Unknown;
			final mains: Array<ResolvedType> = mainTypesNamed(name, files);
			if (mains.length > 0 && w.guarded) return Unknown;
			for (m in mains) found.push(m);
		}
		return found.length == 0 ? Free : Bound(found);
	}

	/**
	 * The file's package, then each parent package, then the toplevel one: the main type of a module
	 * named `name`, or at the toplevel any type of that name. A file the parser skipped that could be
	 * that module makes the tier unreadable.
	 */
	private static function packageTier(name: String, pkg: String, index: SymbolIndex): Tier {
		if (index.skippedFiles().exists(f -> f == '$name.hx' || f.endsWith('/$name.hx'))) return Unknown;
		var p: String = pkg;
		while (p != '') {
			final scope: String = p;
			final mains: Array<ResolvedType> = mainTypesNamed(name, index.allFiles().filter(f -> f.pkg == scope));
			if (mains.length > 0) return Bound(mains);
			p = SourceText.parentPath(p);
		}
		final top: Array<ResolvedType> = [
			for (f in index.allFiles()) if (f.pkg == '') for (t in f.types) if (t.name == name && !t.isPrivate) { file: f, type: t }
		];
		return top.length == 0 ? Free : Bound(top);
	}

	private static function mainTypesNamed(name: String, files: Array<FileInfo>): Array<ResolvedType> {
		return [
			for (f in files) for (t in f.types) if (t.name == name && t.isMain && !t.isPrivate) { file: f, type: t }
		];
	}

}
