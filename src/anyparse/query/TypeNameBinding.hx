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

	/**
	 * The tier provably does not bind the name; the next one is asked. From
	 * `tierOf`: it binds a built-in the index does not hold, or nothing at all.
	 */
	Free;

}

/**
 * THE meaning of a SIMPLE type name written in a file — the one implementation every reader of a bare
 * type name asks, through `TypeRefIndex.names` (`TypeRefIndex.resolveTypeRefAll` answers a simple
 * reference here too). Tier by tier, in the order the Haxe compiler resolves it (each tier probed on
 * 4.3.7, `docs/decisions.md`):
 *
 *  1. the module's own types, a private one included;
 *  2. the file's explicit imports — `import`, `using`, an alias by its alias name — the LAST statement
 *     binding the name winning: a module import binds the module's non-private types, `pkg.Mod.Sub` the
 *     one type, a static-field import none;
 *  3. the ambient `import.hx` chain's explicit imports, nearest source first, the last statement winning
 *     inside each;
 *  4. the types of the std module `StdTypes`, which the compiler imports into every module;
 *  5. the package wildcards — the file's own, then the chain's nearest first, the last statement first
 *     inside each — each binding its package's non-private MAIN types only;
 *  6. the file's package and then each parent package, then the toplevel one: non-private main types.
 *
 * A whitelist, not a search: a tier that could bind the name but whose target the index does not hold
 * — an import of an unindexed module (which may carry the name as a sub-type), an alias or an import of
 * an unindexed path, a wildcard over an unindexed package, a `#if`-guarded statement that binds it, an
 * ambient chain the index could not bound, a skipped file that could be the module — answers `Unknown`,
 * and no lower tier is asked. Answering from a lower tier there is how a same-package class shadowed a
 * `Null<…>` alias the compiler actually picked.
 *
 * The module and package tables built here once are the facts `ImportBindings` lists an import line's
 * names from (`importedTypes`, `wildcardTypes`), so the line ranks and the binding read one table.
 */
@:nullSafety(Strict)
final class TypeNameBinding {

	/** The module the compiler imports into every module ahead of any wildcard, package or toplevel type. */
	public static inline final STD_TYPES_MODULE: String = 'StdTypes';

	/**
	 * Every name `StdTypes` declares on Haxe 4.3 — what its tier binds when neither the index nor the std
	 * listing (`StdTypes.moduleTypes`) can read the std's own `StdTypes.hx`. Such a name binds a built-in,
	 * never a project type the compiler does not pick; `TypeNameBindingTest` pins the list against the std.
	 */
	public static final STD_TYPE_NAMES: Array<String> = [
		'Void',
		'Float',
		'Int',
		'Single',
		'Null',
		'Bool',
		'Dynamic',
		'Iterator',
		'Iterable',
		'KeyValueIterator',
		'KeyValueIterable',
		'ArrayAccess'
	];

	/** Every indexed file, handed over by the owning `TypeRefIndex`. */
	private final _files: Array<FileInfo>;

	/** The files the index could not parse — each may be the module a package tier asks for. */
	private final _skipped: Array<String>;

	/** The grammar a module outside the index is read with (`StdTypes.moduleTypes`), and the run host when it is one. */
	private final _plugin: GrammarPlugin;

	/** The tables `tables` builds on the first question. */
	private var _tables: Null<Tables> = null;

	/** Built by the owning `TypeRefIndex` over the same files. */
	public function new(files: Array<FileInfo>, skipped: Array<String>, plugin: GrammarPlugin) {
		_files = files;
		_skipped = skipped;
		_plugin = plugin;
	}

	/** Null when no tier provably answers; otherwise the declarations of the first tier that binds `name`. */
	public function bind(name: String, fi: FileInfo): Null<Array<ResolvedType>> {
		return switch tierOf(name, fi) {
			case Bound(decls): decls;
			case Unknown, Free: null;
		};
	}

	/**
	 * The whole resolution order's answer for `name` written in `fi`: `Bound` by the first tier that binds it to
	 * declarations of the index, `Unknown` when a tier could bind it to something the index cannot read, `Free`
	 * when it binds a declaration outside the index (a built-in, a std or library type) or nothing at all.
	 */
	public function tierOf(name: String, fi: FileInfo): Tier {
		final own: Array<TypeDeclInfo> = fi.types.filter(t -> t.name == name);
		if (own.length > 0) return Bound([for (t in own) { file: fi, type: t }]);
		final explicit: Array<ImportInfo> = [];
		final wildcards: Array<ImportInfo> = [];
		for (imports in [fi.imports].concat([for (group in fi.ambientImports) group.imports])) {
			final lastFirst: Array<ImportInfo> = imports.copy();
			lastFirst.reverse();
			for (imp in lastFirst) (imp.kind == ImportKind.Wild ? wildcards : explicit).push(imp);
		}
		return switch explicitFrom(name, fi, { explicit: explicit, wildcards: wildcards }, 0, false) {
			case Decls(decls): Bound(decls);
			case Unreadable: Unknown;
			case Outside, Pass: Free;
		};
	}

	/** The indexed files of module `module` (`pkg.Mod`, a root module by its bare name), in index order. */
	public function filesOfModule(module: String): Array<FileInfo> {
		return (tables().modules[module] ?? []).copy();
	}

	/**
	 * The types an explicit `import` or `using` of `path` puts in simple-name scope: every non-private type of
	 * a module, the one type `pkg.Mod.Sub` names, none for a static-field import (`pkg.Mod.field`,
	 * `pkg.Mod.Type.field`). Null when the index does not hold the module, which may carry any sub-type.
	 */
	public function importedTypes(path: String): Null<Array<ResolvedType>> {
		final split: Null<ImportPath> = splitPath(path);
		if (split == null) return null;
		if (split.rest.length > 1) return [];
		final files: Array<FileInfo> = tables().modules[split.module] ?? [];
		if (files.length == 0) return null;
		return typesIn(files, split.rest.length == 0 ? null : split.rest[0], false);
	}

	/**
	 * The types a package wildcard `import pkg.*;` puts in simple-name scope: the non-private MAIN type of each
	 * module of `pkg`, never a sub-type. Null when the index holds no module of `pkg`.
	 */
	public function wildcardTypes(pkg: String): Null<Array<ResolvedType>> {
		final files: Array<FileInfo> = tables().packages[pkg] ?? [];
		return files.length == 0 ? null : typesIn(files, null, true);
	}

	/**
	 * The answer of the order from explicit statement `at` on: each explicit statement, the LAST of a list first
	 * and the file's own list before the ambient chain's (nearest source first); then the chain's bound, the
	 * `StdTypes` tier and the wildcards. `strict` is set inside a `#if`-guarded statement's other build (`bothBuilds`).
	 */
	private function explicitFrom(name: String, fi: FileInfo, order: StatementOrder, at: Int, strict: Bool): Answer {
		for (i in at ... order.explicit.length) {
			final imp: ImportInfo = order.explicit[i];
			final guarded: Bool = imp.guarded;
			switch statementAnswer(name, imp) {
				case Pass:
				case Decls(decls) if (guarded):
					return bothBuilds(decls, explicitFrom(name, fi, order, i + 1, true));
				case answer:
					return guarded ? Unreadable : answer;
			}
		}
		if (!fi.ambientImportsBounded) return Unreadable;
		return switch stdTypesAnswer(name) {
			case Pass: wildcardFrom(name, fi, order, 0, strict);
			case answer: answer;
		};
	}

	/**
	 * The answer of the order from wildcard `at` on: each package wildcard in the order the compiler asks them —
	 * the file's own last to first, then each ambient source nearest first — then the package tiers.
	 */
	private function wildcardFrom(name: String, fi: FileInfo, order: StatementOrder, at: Int, strict: Bool): Answer {
		for (i in at ... order.wildcards.length) {
			final w: ImportInfo = order.wildcards[i];
			switch wildcardAnswer(name, SourceText.parentPath(w.raw)) {
				case Pass:
				case Decls(decls) if (w.guarded):
					return bothBuilds(decls, wildcardFrom(name, fi, order, i + 1, true));
				case answer:
					return w.guarded ? Unreadable : answer;
			}
		}
		return packageAnswer(name, fi.pkg, strict);
	}

	/**
	 * What one explicit statement says about `name`: an alias binds only its alias name, to the type its path
	 * names; an `import` / `using` binds what `importedTypes` lists, and a module outside the index binds what
	 * `outsideTypes` reads of it.
	 */
	private function statementAnswer(name: String, imp: ImportInfo): Answer {
		final aliased: Bool = imp.kind == ImportKind.Alias;
		if (aliased && imp.alias != name) return Pass;
		final path: Null<String> = aliased ? imp.aliasTarget : imp.raw;
		final split: Null<ImportPath> = path == null ? null : splitPath(path);
		if (split == null) return Unreadable;
		if (split.rest.length > 1 || (!aliased && split.rest.length == 1 && split.rest[0] != name)) return Pass;
		final wanted: String = split.rest.length == 1 ? split.rest[0] : aliased ? SourceText.lastSegment(split.module) : name;
		// An alias of a module names its main type, and one whose module declares none names nothing that is known.
		final missing: Answer = aliased && split.rest.length == 0 ? Unreadable : Pass;
		final files: Array<FileInfo> = tables().modules[split.module] ?? [];
		if (files.length > 0) {
			final decls: Array<ResolvedType> = typesIn(files, wanted, false);
			return decls.length > 0 ? Decls(decls) : missing;
		}
		final outside: Null<Array<TypeDeclInfo>> = outsideTypes(split.module, wanted);
		if (outside == null) return Unreadable;
		return outside.exists(t -> t.name == wanted && !t.isPrivate) ? Outside : missing;
	}

	/**
	 * The `StdTypes` tier: its declaration of `name` when the index holds the std's `StdTypes`, `Outside` for a
	 * name it declares that the index does not hold (a built-in), `Pass` for any other name.
	 */
	private function stdTypesAnswer(name: String): Answer {
		final std: Array<FileInfo> = tables().stdTypes;
		if (std.length > 0) {
			final decls: Array<ResolvedType> = typesIn(std, name, false);
			return decls.length > 0 ? Decls(decls) : Pass;
		}
		final outside: Null<Array<TypeDeclInfo>> = StdTypes.moduleTypes(_plugin, STD_TYPES_MODULE);
		final declared: Bool = outside == null ? STD_TYPE_NAMES.contains(name) : outside.exists(t -> t.name == name && !t.isPrivate);
		return declared ? Outside : Pass;
	}

	/**
	 * What the package wildcard over `pkg` says about `name`: the non-private main type of module `pkg.name`. A
	 * field wildcard (`pkg.Mod.*`) imports statics, never a type; a package the index does not hold is read
	 * through `outsideTypes` only for a std core package, whose module list the std listing knows.
	 */
	private function wildcardAnswer(name: String, pkg: String): Answer {
		if (splitPath(pkg) != null) return Pass;
		final mains: Null<Array<ResolvedType>> = wildcardTypes(pkg);
		if (mains != null) {
			final named: Array<ResolvedType> = mains.filter(m -> m.type.name == name);
			return named.length > 0 ? Decls(named) : Pass;
		}
		return switch StdTypes.declaresModule(pkg, name) {
			case false: Pass;
			case true: declaresMain(outsideTypes('$pkg.$name', name), name) ?? Unreadable;
			case null: Unreadable;
		};
	}

	/**
	 * The file's package, then each parent package, then the toplevel one: the non-private main type of a
	 * module named `name`. A file the parser skipped that could be that module makes the tier unreadable. A
	 * module outside the index is asked about only in a guarded statement's other build (`strict`), where binding
	 * one is an answer of its own rather than nothing.
	 */
	private function packageAnswer(name: String, pkg: String, strict: Bool): Answer {
		if (_skipped.exists(f -> f == '$name.hx' || f.endsWith('/$name.hx'))) return Unreadable;
		final packages: Map<String, Array<FileInfo>> = tables().packages;
		final chain: Array<String> = [];
		var p: String = pkg;
		while (p != '') {
			chain.push(p);
			p = SourceText.parentPath(p);
		}
		chain.push('');
		for (scope in chain) {
			final mains: Array<ResolvedType> = typesIn(packages[scope] ?? [], name, true);
			if (mains.length > 0) return Decls(mains);
			final outside: Null<Answer> = strict ? declaresMain(outsideTypes(scope == '' ? name : '$scope.$name', name), name) : null;
			if (outside != null && outside.match(Outside)) return Outside;
		}
		return Pass;
	}

	/**
	 * The types named `name` the module `module`, which the index does not hold, declares — as the run's resolution scope
	 * reads it (`SymbolIndexHost.moduleTypesInScope`), else the std listing (`StdTypes.moduleTypes`); null when neither does.
	 */
	private function outsideTypes(module: String, name: String): Null<Array<TypeDeclInfo>> {
		final host: Null<SymbolIndexHost> = _plugin is SymbolIndexHost ? cast _plugin : null;
		final scoped: Null<Array<TypeDeclInfo>> = host != null && host.hasAnyResolutionScope()
			? host.moduleTypesInScope(module, name)
			: null;
		if (scoped != null) return scoped;
		final std: Null<Array<TypeDeclInfo>> = StdTypes.moduleTypes(_plugin, module);
		return std == null ? null : std.filter(t -> t.name == name);
	}

	/**
	 * The module, package and std `StdTypes` tables over the indexed files, built once.
	 */
	private function tables(): Tables {
		final known: Null<Tables> = _tables;
		if (known != null) return known;
		final built: Tables = { modules: [], packages: [], stdTypes: [] };
		for (f in _files) {
			final files: Array<FileInfo> = built.modules[f.module] ?? [];
			files.push(f);
			built.modules[f.module] = files;
			final siblings: Array<FileInfo> = built.packages[f.pkg] ?? [];
			siblings.push(f);
			built.packages[f.pkg] = siblings;
			if (f.module == STD_TYPES_MODULE && StdResolver.isStdFile(f.file)) built.stdTypes.push(f);
		}
		_tables = built;
		return built;
	}

	/**
	 * `path` split the way the compiler reads an import path: every leading segment that starts lower-case
	 * (after any underscores) is a package, the first that does not is the MODULE — a module name must start
	 * upper-case, the compiler refuses to import any other — and what follows names a type of it and then a
	 * static field. Null when no segment is a module: a package path.
	 */
	public static function splitPath(path: String): Null<ImportPath> {
		final segments: Array<String> = path.split('.');
		for (i in 0...segments.length) if (!isPackageSegment(segments[i])) return {
			module: segments.slice(0, i + 1).join('.'),
			rest: segments.slice(i + 1)
		};
		return null;
	}

	/** Whether `segment` names a package: lower-case after any leading underscores, as the compiler tells one. */
	private static function isPackageSegment(segment: String): Bool {
		var i: Int = 0;
		while (i < segment.length && segment.fastCodeAt(i) == '_'.code) i++;
		if (i == segment.length) return true;
		final c: Int = segment.fastCodeAt(i);
		return c >= 'a'.code && c <= 'z'.code;
	}

	/**
	 * A `#if`-guarded statement binds `decls` in the builds that compile it; `rest` is what the order answers in
	 * the builds that do not. One answer only when the other builds bind the same declarations or nothing at all
	 * — a build in which the name binds nothing does not compile a use of it.
	 */
	private static function bothBuilds(decls: Array<ResolvedType>, rest: Answer): Answer {
		return switch rest {
			case Pass: Decls(decls);
			case Decls(other) if (sameDecls(decls, other)): Decls(decls);
			case _: Unreadable;
		};
	}

	/**
	 * `Outside` when `types`, a module outside the index, declares a non-private main type `name`; `Pass` when not; null unread.
	 */
	private static function declaresMain(types: Null<Array<TypeDeclInfo>>, name: String): Null<Answer> {
		return types == null ? null : types.exists(t -> t.name == name && t.isMain && !t.isPrivate) ? Outside : Pass;
	}

	/** The non-private types `files` declare — named `name` unless it is null, main types only when `mainOnly`. */
	private static function typesIn(files: Array<FileInfo>, name: Null<String>, mainOnly: Bool): Array<ResolvedType> {
		return [
			for (f in files) for (t in f.types) if ((name == null || t.name == name) && (!mainOnly || t.isMain) && !t.isPrivate)
				{ file: f, type: t }
		];
	}

	/** Whether two answers name the same declarations, as files and spans. */
	private static function sameDecls(a: Array<ResolvedType>, b: Array<ResolvedType>): Bool {
		inline function keys(decls: Array<ResolvedType>): Array<String> {
			final out: Array<String> = [for (d in decls) '${d.file.file}#${d.type.span.from}'];
			out.sort(Reflect.compare);
			return out;
		}
		return keys(a).join('|') == keys(b).join('|');
	}

}

/** An import path as the compiler reads it (`TypeNameBinding.splitPath`): its module, then what follows it — a type, then a field. */
typedef ImportPath = {
	final module: String;
	final rest: Array<String>;
}

/**
 * The explicit statements and the package wildcards of a file and its ambient chain, each in the order the
 * compiler asks them: the file's own last to first, then each ambient source nearest first, last to first.
 */
private typedef StatementOrder = {
	final explicit: Array<ImportInfo>;
	final wildcards: Array<ImportInfo>;
}

/** The index's files by module and by package, and the std's own `StdTypes` files among them (`StdResolver.isStdFile`). */
private typedef Tables = {
	final modules: Map<String, Array<FileInfo>>;
	final packages: Map<String, Array<FileInfo>>;
	final stdTypes: Array<FileInfo>;
}

/** What one tier, or the order from one statement on, says about a name inside `TypeNameBinding`. */
private enum Answer {

	/** The tier does not bind the name; the next one is asked. */
	Pass;

	/** It binds the name to these declarations of the index. */
	Decls(decls: Array<ResolvedType>);

	/** It binds the name to a declaration the index does not hold: a built-in, a std or library type. */
	Outside;

	/** It may bind the name to something nothing here can read, so no lower tier may answer. */
	Unreadable;

}
