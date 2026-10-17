package anyparse.query;

import anyparse.query.CondBranchPath.CondBranchIndex;
import anyparse.query.CondBranchPath.CondFrame;
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

	/** File path -> its `#if` directive marks (`CondBranchPath.scan`), read on the first question about the file. */
	private final _branches: Map<String, CondBranchIndex> = [];

	/** Every indexed file, handed over by the owning `TypeRefIndex`. */
	private final _files: Array<FileInfo>;

	/** The files the index could not parse — each may be the module a package tier asks for. */
	private final _skipped: Array<String>;

	/** The grammar a module outside the index is read with (`StdTypes.moduleTypes`), and the run host when it is one. */
	private final _plugin: GrammarPlugin;

	/** The indexed files' texts, by path — where a use site's `#if` branch is read (`branchPathAt`). */
	private final _sources: Map<String, String>;

	/** The tables `tables` builds on the first question. */
	private var _tables: Null<Tables> = null;

	/**
	 * `splitPath` per import path, null included: `statementAnswer` reads every import of a file once per NAME the
	 * file asks about, and split the same path anew each time (~0.25 s of a TM `lint --all`). Read only here.
	 */
	private final _importPaths: Map<String, Null<ImportPath>> = [];

	/**
	 * Built by the owning `TypeRefIndex` over the same files; `sources` are their texts, read for a use site's `#if` branch.
	 */
	public function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>, plugin: GrammarPlugin) {
		_files = files;
		_skipped = skipped;
		_sources = sources;
		_plugin = plugin;
	}

	/**
	 * Null when no tier provably answers; otherwise the declarations of the first tier that binds `name` — written at offset
	 * `at` of `fi` when the caller knows where (see `tierOf`).
	 */
	public function bind(name: String, fi: FileInfo, ?at: Int): Null<Array<ResolvedType>> {
		return switch tierOf(name, fi, at) {
			case Bound(decls): decls;
			case Unknown, Free: null;
		};
	}

	/**
	 * The whole resolution order's answer for `name` written in `fi` — at offset `at` when the caller knows where: `Bound` by
	 * the first tier that binds it to declarations of the index, `Unknown` when a tier could bind it to something the index
	 * cannot read, `Free` when it binds a declaration outside the index (a built-in, a std or library type) or nothing at all.
	 * The offset decides a `#if`-guarded statement: a use inside the statement's own branch is compiled only by the builds
	 * that hold the statement (`coGuarded`); without one, the other builds are asked too (`bothBuilds`).
	 */
	public function tierOf(name: String, fi: FileInfo, ?at: Int): Tier {
		final own: Array<TypeDeclInfo> = fi.types.filter(t -> t.name == name);
		if (own.length > 0) return Bound([for (t in own) { file: fi, type: t }]);
		return switch explicitFrom(name, fi, orderOf(fi, at), 0, false) {
			case Decls(decls): Bound(decls);
			case Unreadable(_): Unknown;
			case Outside(_), Pass: Free;
		};
	}

	/**
	 * Every type `name`, written in `fi` (at offset `at` when the caller knows where), may be on some build — what a
	 * caller dispatching on each one asks, where `tierOf` answers one or none: `bound`, what the order binds it to wherever
	 * it can read the binding (null where nothing readable binds it); `guarded`, what it binds instead on the builds a
	 * `#if`-guarded statement holds; `unlisted`, what a package wildcard the order cannot list may supply. A binding is a
	 * declaration set of the index or the path of a type outside it (`InIndex`, `OutOfIndex`). The package tier reads the
	 * std core's modules beside the index's, package by package, as the compiler finds either on its class paths.
	 */
	public function bindingsOf(name: String, fi: FileInfo, ?at: Int): NameTargets {
		final out: NameTargets = { bound: null, guarded: [], unlisted: [] };
		final own: Array<TypeDeclInfo> = fi.types.filter(t -> t.name == name);
		if (own.length > 0) {
			out.bound = InIndex([for (t in own) { file: fi, type: t }]);
			return out;
		}
		final order: StatementOrder = orderOf(fi, at);
		for (imp in order.explicit) {
			final answer: Answer = statementAnswer(name, imp);
			// a module the order cannot read may hold the name as a sub-type, which no reading lists: a binding only of the
			// type the statement itself names
			if (answer.match(Pass) || answer.match(Unreadable(_)) && !namesItsType(imp, answer)) continue;
			final binding: Null<NameTarget> = bindingOf(answer);
			if (!imp.guarded || coGuarded(imp, fi, order.use)) {
				out.bound = binding;
				return out;
			}
			if (binding != null) out.guarded.push(binding);
		}
		if (!fi.ambientImportsBounded) return out;
		final std: Answer = stdTypesAnswer(name);
		if (!std.match(Pass)) {
			out.bound = bindingOf(std);
			return out;
		}
		for (w in order.wildcards) {
			final answer: Answer = wildcardAnswer(name, SourceText.parentPath(w.raw));
			final binding: Null<NameTarget> = bindingOf(answer);
			if (binding == null) continue;
			if (answer.match(Unreadable(_)))
				out.unlisted.push(binding)
			else if (w.guarded && !coGuarded(w, fi, order.use))
				out.guarded.push(binding)
			else {
				out.bound = binding;
				return out;
			}
		}
		out.bound = bindingOf(packageAnswer(name, fi.pkg, false, true));
		return out;
	}

	/**
	 * The declarations of the index whose canonical path (`canonicalPath`) is `path`: a module's main type at the module's
	 * path, a sub-type at the module's path and its own name.
	 */
	public function declsAt(path: String): Array<ResolvedType> {
		final last: String = SourceText.lastSegment(path);
		final mains: Array<ResolvedType> = [
			for (f in tables().modules[path] ?? []) for (t in f.types) if (t.isMain && t.name == last) { file: f, type: t }
		];
		if (mains.length > 0 || path.indexOf('.') < 0) return mains;
		return [
			for (f in tables()
				.modules[SourceText.parentPath(path)] ?? []) for (t in f.types) if (!t.isMain && t.name == last) { file: f, type: t }
		];
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

	/** The `#if` regions and branches open at offset `at` of `fi` (`CondBranchPath`), its directives read once per file. */
	public function branchPathAt(fi: FileInfo, at: Int): Array<CondFrame> {
		var index: Null<CondBranchIndex> = _branches[fi.file];
		if (index == null) {
			final source: Null<String> = _sources[fi.file];
			final read: CondBranchIndex = source == null
				? []
				: CondBranchPath.scan(source, _plugin.refShape(), _plugin.lexicalRegions(source));
			_branches[fi.file] = read;
			index = read;
		}
		return CondBranchPath.pathAt(index, at);
	}

	/**
	 * The explicit statements and the package wildcards of `fi` and its ambient chain in the order the compiler asks them,
	 * and the `#if` branch of a use at `at`.
	 */
	private function orderOf(fi: FileInfo, at: Null<Int>): StatementOrder {
		final explicit: Array<ImportInfo> = [];
		final wildcards: Array<ImportInfo> = [];
		for (imports in [fi.imports].concat([for (group in fi.ambientImports) group.imports])) {
			final lastFirst: Array<ImportInfo> = imports.copy();
			lastFirst.reverse();
			for (imp in lastFirst) (imp.kind == ImportKind.Wild ? wildcards : explicit).push(imp);
		}
		return { explicit: explicit, wildcards: wildcards, use: at == null ? null : branchPathAt(fi, at) };
	}

	/**
	 * The answer of the order from explicit statement `at` on: each explicit statement, the LAST of a list first
	 * and the file's own list before the ambient chain's (nearest source first); then the chain's bound, the
	 * `StdTypes` tier and the wildcards. `strict` is set inside a `#if`-guarded statement's other build (`bothBuilds`).
	 */
	private function explicitFrom(name: String, fi: FileInfo, order: StatementOrder, at: Int, strict: Bool): Answer {
		for (i in at ... order.explicit.length) {
			final imp: ImportInfo = order.explicit[i];
			final guarded: Bool = imp.guarded && !coGuarded(imp, fi, order.use);
			switch statementAnswer(name, imp) {
				case Pass:
				case Decls(decls) if (guarded):
					return bothBuilds(decls, explicitFrom(name, fi, order, i + 1, true));
				case answer:
					return guarded ? Unreadable(null) : answer;
			}
		}
		if (!fi.ambientImportsBounded) return Unreadable(null);
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
			final guarded: Bool = w.guarded && !coGuarded(w, fi, order.use);
			switch wildcardAnswer(name, SourceText.parentPath(w.raw)) {
				case Pass:
				case Decls(decls) if (guarded):
					return bothBuilds(decls, wildcardFrom(name, fi, order, i + 1, true));
				case answer:
					return guarded ? Unreadable(null) : answer;
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
		final split: Null<ImportPath> = path == null ? null : importPathOf(path);
		if (split == null) return Unreadable(null);
		if (split.rest.length > 1 || (!aliased && split.rest.length == 1 && split.rest[0] != name)) return Pass;
		final wanted: String = split.rest.length == 1 ? split.rest[0] : aliased ? SourceText.lastSegment(split.module) : name;
		// An alias of a module names its main type, and one whose module declares none names nothing that is known.
		final missing: Answer = aliased && split.rest.length == 0 ? Unreadable(null) : Pass;
		final files: Array<FileInfo> = tables().modules[split.module] ?? [];
		if (files.length > 0) {
			final decls: Array<ResolvedType> = typesIn(files, wanted, false);
			return decls.length > 0 ? Decls(decls) : missing;
		}
		final outside: Null<Array<TypeDeclInfo>> = outsideTypes(split.module, wanted);
		final bound: String = pathIn(split.module, wanted);
		if (outside == null) return Unreadable(bound);
		return outside.exists(t -> t.name == wanted && !t.isPrivate) ? Outside(bound) : missing;
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
		return declared ? Outside(name) : Pass;
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
			case true: declaresMain(outsideTypes('$pkg.$name', name), name, '$pkg.$name') ?? Unreadable('$pkg.$name');
			case null: Unreadable('$pkg.$name');
		};
	}

	/**
	 * The file's package, then each parent package, then the toplevel one: the non-private main type of a
	 * module named `name`. A file the parser skipped that could be that module makes the tier unreadable. A
	 * module outside the index is asked about only in a guarded statement's other build (`strict`), where binding
	 * one is an answer of its own rather than nothing; with `listed`, each package past the index also holds the std core
	 * modules the std listing knows (`StdTypes.declaresModule`) — the toplevel's none — found there before a farther package's.
	 */
	private function packageAnswer(name: String, pkg: String, strict: Bool, listed: Bool = false): Answer {
		if (_skipped.exists(f -> f == '$name.hx' || f.endsWith('/$name.hx'))) return Unreadable(null);
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
			// In a guarded statement's other build a module nothing here can read is unknown, never taken as absent; one the
			// index holds was read above.
			final module: String = scope == '' ? name : '$scope.$name';
			if (listed && scope != '' && StdTypes.declaresModule(scope, name) == true) return Outside(module);
			final outside: Null<Answer> = strict && !tables().modules.exists(module)
				? declaresMain(outsideTypes(module, name), name, module) ?? Unreadable(module)
				: null;
			if (outside != null && !outside.match(Pass)) return outside;
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
	 * Whether the use at the `#if` branch `use` is compiled ONLY by builds that hold the file's own guarded statement `imp`:
	 * the use sits in the statement's branch, or in one of the same spelled condition chain (`CondBranchPath.within`). The
	 * other builds then compile no use of the name, so what it would bind there does not matter. An ambient source's
	 * statement is in another file and guards nothing here.
	 */
	private function coGuarded(imp: ImportInfo, fi: FileInfo, use: Null<Array<CondFrame>>): Bool {
		return use != null && fi.imports.indexOf(imp) >= 0 && CondBranchPath.within(use, branchPathAt(fi, imp.span.from));
	}

	/** Whether the statement `imp` names the type `answer` binds by its own path — the path written, or an alias's target. */
	private static function namesItsType(imp: ImportInfo, answer: Answer): Bool {
		final written: Null<String> = imp.kind == ImportKind.Alias ? imp.aliasTarget : imp.raw;
		return switch answer {
			case Unreadable(path), Outside(path):
				path != null && path == written;
			case _: false;
		};
	}

	/** The path an import of module `module` names its type `name` by: the module's own for its main type. */
	private static inline function pathIn(module: String, name: String): String {
		return name == SourceText.lastSegment(module) ? module : '$module.$name';
	}

	/** What one tier's answer binds a name to: none for `Pass`, nor for an unreadable tier that names no path. */
	private static function bindingOf(answer: Answer): Null<NameTarget> {
		return switch answer {
			case Decls(decls): InIndex(decls);
			case Outside(path): OutOfIndex(path);
			case Unreadable(path): path == null ? null : OutOfIndex(path);
			case Pass: null;
		};
	}

	/**
	 * The path the compiler names a declaration by: a module's main type by the module's path, a sub-type by the module's
	 * path and its own name.
	 */
	public static function canonicalPath(decl: ResolvedType): String {
		return decl.type.isMain ? decl.file.module : '${decl.file.module}.${decl.type.name}';
	}

	/**
	 * Every dotted path that names `decl`, each once: its module's path and its name (`pkg.Mod.Name`), a main type's module
	 * path alone (`pkg.Mod`, which is also its package and its name), and a sub-type's package and its name — its runtime
	 * path (`Type.getClassName`), which no source can write for it, but a declaration of the classes made from a computed
	 * name spells.
	 */
	public static function namingPaths(decl: ResolvedType): Array<String> {
		final name: String = decl.type.name;
		final inModule: String = '${decl.file.module}.$name';
		final inPackage: String = decl.file.pkg == '' ? name : '${decl.file.pkg}.$name';
		return decl.type.isMain ? [decl.file.module, inModule] : [inModule, inPackage];
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
			case _: Unreadable(null);
		};
	}

	/**
	 * `Outside` at `path` when `types`, a module outside the index, declares a non-private main type `name`; `Pass` when
	 * not; null unread.
	 */
	private static function declaresMain(types: Null<Array<TypeDeclInfo>>, name: String, path: String): Null<Answer> {
		return types == null ? null : types.exists(t -> t.name == name && t.isMain && !t.isPrivate) ? Outside(path) : Pass;
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

	/** `splitPath(path)`, memoised for this binding (`_importPaths`). */
	private function importPathOf(path: String): Null<ImportPath> {
		if (_importPaths.exists(path)) return _importPaths[path];
		final split: Null<ImportPath> = splitPath(path);
		_importPaths[path] = split;
		return split;
	}

}

/** An import path as the compiler reads it (`TypeNameBinding.splitPath`): its module, then what follows it — a type, then a field. */
typedef ImportPath = {
	final module: String;
	final rest: Array<String>;
}

/** One type a name may bind to (`TypeNameBinding.bindingsOf`): declarations of the index, or the path of a type outside it. */
enum NameTarget {

	InIndex(decls: Array<ResolvedType>);

	OutOfIndex(path: String);

}

/**
 * Every type a name may bind to on some build (`TypeNameBinding.bindingsOf`): `bound` wherever the order reads it,
 * null where nothing readable binds it; `guarded` on the builds a `#if`-guarded statement holds; `unlisted` where a
 * package wildcard the order cannot list may supply it.
 */
typedef NameTargets = {
	var bound: Null<NameTarget>;
	final guarded: Array<NameTarget>;
	final unlisted: Array<NameTarget>;
}

/**
 * The explicit statements and the package wildcards of a file and its ambient chain, each in the order the
 * compiler asks them: the file's own last to first, then each ambient source nearest first, last to first.
 */
private typedef StatementOrder = {
	final explicit: Array<ImportInfo>;
	final wildcards: Array<ImportInfo>;

	/** The `#if` branch the name is used in, null when the caller gave no offset. */
	final use: Null<Array<CondFrame>>;
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

	/** It binds the name to a declaration the index does not hold — a built-in, a std or library type — at `path`. */
	Outside(path: String);

	/**
	 * It may bind the name to something nothing here can read, so no lower tier may answer: at `path` when the statement
	 * or the package names one.
	 */
	Unreadable(path: Null<String>);

}
