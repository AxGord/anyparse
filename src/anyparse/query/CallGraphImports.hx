package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * What each file's imports bring into scope by simple name, for a `CallGraph` resolving a bare call or a
 * static extension — the statics an `import` names and the types a `using` adds extensions from — and the
 * enum constructors a bare call may build. Files are keyed by `CallGraphNames.normalizePath`.
 */
@:nullSafety(Strict)
final class CallGraphImports {

	/** Enum constructor name -> the enums declaring one of that name. */
	private final _enumConstructors: Map<String, Array<String>> = [];

	/** File -> the simple names of the types its `using` statements (own and ambient) bring in, nearest first. */
	private final _usings: Map<String, Array<String>> = [];

	/** Type simple name -> member name -> the files whose declarations of the type declare the member. */
	private final _memberFiles: Map<String, Map<String, Array<String>>> = [];

	/** Type simple name -> member name -> each declaration of the member: its file and the type it writes (null for none). */
	private final _memberTypes: Map<String, Map<String, Array<WrittenIn>>> = [];

	/** Type simple name -> the dotted paths that name a declaration of it (`pkg.Module.Name`; a main type's also `pkg.Module`). */
	private final _declaredPaths: Map<String, Array<String>> = [];

	/** File -> the simple names its imports and aliases (own and ambient) bind to a type, and the dotted path each names. */
	private final _typePaths: Map<String, Map<String, String>> = [];

	/** Type simple name -> the paths `pathType` keyed apart from the declarations of that name, as it met them. */
	private final _foreign: Map<String, Array<String>> = [];

	/** File -> the names of the types its own module declares, which its code means before any import's. */
	private final _ownTypes: Map<String, Array<String>> = [];

	/** File -> its package ('' for the toplevel), whose modules and its enclosing packages' its code sees after its imports. */
	private final _packages: Map<String, String> = [];

	/**
	 * File -> the packages its wildcard imports (own and ambient) open, in the order the language searches them — the file's
	 * own last to first, then each ambient group nearest first — each with whether it is `#if`-guarded.
	 */
	private final _wildPackages: Map<String, Array<WildPackage>> = [];

	/** File -> the type names its `#if`-guarded `import p.T;` statements bind, and the path each names: on some builds only. */
	private final _guardedPaths: Map<String, Array<{ name: String, path: String }>> = [];

	private final _enumConstructorKinds: Array<String>;

	/** Whether a type declares a member static — the tables that answer it live with the types. */
	private final _isStatic: (String, String) -> Bool;

	public function new(enumConstructorKinds: Array<String>, isStatic: (String, String) -> Bool) {
		_enumConstructorKinds = enumConstructorKinds;
		_isStatic = isStatic;
	}

	/**
	 * Whether an indexed enum declares a constructor named `name` — which a bare call may build without any
	 * import, since the language resolves a constructor against the expected type.
	 */
	public inline function isEnumConstructor(name: String): Bool {
		return _enumConstructors.exists(name);
	}

	/** The indexed enums declaring a constructor named `name`, by simple name. */
	public inline function enumsDeclaring(name: String): Array<String> {
		return _enumConstructors[name] ?? [];
	}

	/** Whether a `using` of `file` (own or ambient) names a type of simple name `name` — which it brings into scope, as an import does. */
	public inline function usesType(file: String, name: String): Bool {
		return (_usings[CallGraphNames.normalizePath(file)] ?? []).contains(name);
	}

	/**
	 * The files (`normalizePath`d) whose declarations of the type of simple name `typeName` declare `member` itself, not a
	 * supertype's — where the types its record writes are to be read (`CallGraphKeys.keyedIn`).
	 */
	public inline function memberFilesOf(typeName: String, member: String): Array<String> {
		return _memberFiles[typeName]?.get(member) ?? [];
	}

	/**
	 * Each declaration of `member` the declarations of the type of simple name `typeName` hold — one per branch of a
	 * conditional region, one per declaration of the type — with its file and the type it writes, each once.
	 */
	public inline function memberTypesOf(typeName: String, member: String): Array<WrittenIn> {
		return _memberTypes[typeName]?.get(member) ?? [];
	}

	/** The qualified paths the type of simple name `name` is declared under (`recordFile`): by its module, by its package. */
	public inline function declaredPathsOf(name: String): Array<String> {
		return _declaredPaths[name] ?? [];
	}

	/** Fold the declarations and the imports of `fi`, held under `key`. */
	public function recordFile(fi: FileInfo, key: String): Void {
		for (t in fi.types) {
			recordMembers(t, key);
			// a type is named by its module's path and its own name, a main type by its module's path too; and by its package
			// and its name, whatever its module is called — what an import reads when a file does not name its module
			final inModule: String = '${fi.module}.${t.name}';
			final inPackage: String = fi.pkg == '' ? t.name : '${fi.pkg}.${t.name}';
			CallGraphTypes.unionInto(_declaredPaths, t.name, t.isMain ? [fi.module, inModule, inPackage] : [inModule, inPackage]);
		}
		final usings: Array<String> = [];
		final imports: Array<ImportInfo> = [];
		final groups: Array<Array<ImportInfo>> = [fi.imports].concat([for (g in fi.ambientImports) g.imports]);
		for (group in groups) for (imp in group) if (imp.kind == ImportKind.Using) {
			final last: String = imp.raw.substring(imp.raw.lastIndexOf('.') + 1);
			if (!usings.contains(last)) usings.push(last);
		} else {
			imports.push(imp);
		}
		_usings[key] = usings;
		final paths: Map<String, String> = [];
		// the file's own imports first, then each ambient group, nearest first; inside one list the last binding wins
		for (group in groups) {
			final bound: Map<String, String> = [];
			for (imp in group) {
				final named: Null<{ name: String, path: String }> = typeImportOf(imp);
				if (named != null) bound[named.name] = named.path;
			}
			for (name => path in bound) if (!paths.exists(name)) paths[name] = path;
		}
		_typePaths[key] = paths;
		recordSearchOrder(fi, key, groups, imports);
	}

	/** Fold the members of `t`, a declaration of the file keyed `key`: its enum constructors, and where each member is declared. */
	private function recordMembers(t: TypeDeclInfo, key: String): Void {
		final files: Map<String, Array<String>> = _memberFiles[t.name] ?? [];
		final written: Map<String, Array<WrittenIn>> = _memberTypes[t.name] ?? [];
		for (m in t.members) {
			if (_enumConstructorKinds.contains(m.kind)) CallGraphTypes.unionInto(_enumConstructors, m.name, [t.name]);
			CallGraphTypes.unionInto(files, m.name, [key]);
			final each: Array<WrittenIn> = written[m.name] ?? [];
			if (!each.exists(w -> w.file == key && w.written == m.typeSource)) each.push({ file: key, written: m.typeSource });
			written[m.name] = each;
		}
		_memberFiles[t.name] = files;
		_memberTypes[t.name] = written;
	}

	/**
	 * What `wildcardPath` and `alternateTypes` read of `fi`, held under `key`, whose import `groups` are the file's own and
	 * then its ambient ones, nearest first, and whose `imports` are every one of them a `using` is not: the types its module
	 * declares, the packages its wildcards open in search order, the names its guarded imports bind.
	 */
	private function recordSearchOrder(fi: FileInfo, key: String, groups: Array<Array<ImportInfo>>, imports: Array<ImportInfo>): Void {
		_ownTypes[key] = [for (t in fi.types) t.name];
		_packages[key] = fi.pkg;
		final wild: Array<WildPackage> = [];
		for (group in groups) {
			final opened: Array<WildPackage> = [
				for (imp in group) {
					final pkg: String = imp.raw.substring(0, imp.raw.length - 2);
					// `p.T.*` opens the statics of a type, which `importedStatics` reads; `p.*` a package, whose modules it brings in
					if (imp.kind == ImportKind.Wild && !CallGraphNames.isTypeLike(SourceText.lastSegment(pkg)))
						{ pkg: pkg, guarded: imp.guarded };
				}
			];
			opened.reverse();
			for (w in opened) wild.push(w);
		}
		_wildPackages[key] = wild;
		_guardedPaths[key] = [
			for (imp in imports)
				if (imp.kind == ImportKind.Import && imp.guarded && CallGraphNames.isTypeLike(SourceText.lastSegment(imp.raw)))
					{ name: SourceText.lastSegment(imp.raw), path: imp.raw }
		];
	}

	/**
	 * Every type a `using` in `file` brings in that declares a STATIC `member` — the static extensions a
	 * `value.member(…)` there may call when the value's own type declares no such member. All of them: which
	 * one wins depends on the order and on the first argument's type, so a caller that wants every target
	 * a call can run takes the lot.
	 */
	public function staticExtensionsOf(file: String, member: String): Array<String> {
		return [
			for (u in _usings[CallGraphNames.normalizePath(file)] ?? []) if (_isStatic(u, member)) u
		];
	}

	/**
	 * The name the graph keys the type `written` in `file` by (`CallGraph` keys types by simple name): the simple name,
	 * unless the type the file means — a dotted path written out, the path an import or an alias of the file binds the name
	 * to, or the module a wildcard import of a package supplies under it (`wildcardPath`) — is not a declaration of that
	 * simple name the tables hold while one of them bears it. Then the path itself: `sys.thread.Lock` beside a project
	 * `utils.Lock` is another type, and merging the two by name would make a call of the library one run the project's. A
	 * name nothing binds stays as written.
	 */
	public function typeOf(file: String, written: String): String {
		if (written.indexOf('.') >= 0) return pathType(written);
		final path: Null<String> = boundPath(file, written);
		return path == null ? written : pathType(path);
	}

	/**
	 * The type `written` — the path each declaration writes, with the file writing it — names, read where written
	 * (`typeOf`): a library type a project type's simple name bears is keyed apart. `simple` when none is written, or two
	 * declarations key it apart.
	 */
	public function keyedWhereWritten(written: Array<{ path: String, file: String }>, simple: String): String {
		final keyed: Array<String> = [];
		for (w in written) {
			final key: String = typeOf(w.file, w.path);
			if (!keyed.contains(key)) keyed.push(key);
		}
		return keyed.length == 1 ? keyed[0] : simple;
	}

	/**
	 * Whether the type path `path` — as `file` writes it, or as the graph keys it (`typeOf`) — can only name one of `standard`,
	 * the paths a standard type is spelled by: a dotted one among them; a simple name no declaration bears at another path —
	 * one that does makes the simple key mean that type, while the std's own, indexed as a library, sits at a standard path or
	 * its module-qualified twin — which `file` binds to one of them through an import, an alias, a wildcard or its packages,
	 * or leaves unbound while it is one of them itself (a toplevel name). A name an `#if`-guarded import binds elsewhere on
	 * some build is none. A wildcard of a package the tables cannot list is read as `typeOf` reads it: with no declaration
	 * bearing the name, the tables know none it could supply.
	 */
	public function namesStandard(file: String, path: String, standard: Array<String>): Bool {
		if (path.indexOf('.') >= 0) return standard.contains(path);
		final declared: Array<String> = [
			for (d in declaredPathsOf(path)) if (!standard.contains(d) && !standard.contains(SourceText.parentPath(d))) d
		];
		if (declared.length > 0) return false;
		final guarded: Array<{ name: String, path: String }> = _guardedPaths[CallGraphNames.normalizePath(file)] ?? [];
		if (guarded.exists(g -> g.name == path && !standard.contains(g.path))) return false;
		return standard.contains(boundPath(file, path) ?? path);
	}

	/**
	 * The dotted path the simple name `written` means in `file`, when an import, an alias or a wildcard import of a package
	 * binds it there (`typeOf`); null when none does. With `maybe` handed, the paths it may mean on some builds or where
	 * that cannot be told land in it: those an `#if`-guarded import binds it to, and the ones a wildcard may supply it from
	 * (`wildcardPath`). Records nothing: a reader asking after the graph is built keys a path with `pathKey`.
	 */
	public function boundPath(file: String, written: String, ?maybe: Array<String>): Null<String> {
		final key: String = CallGraphNames.normalizePath(file);
		if (maybe != null) for (g in _guardedPaths[key] ?? []) if (g.name == written) maybe.push(g.path);
		return (_typePaths[key] ?? [])[written] ?? wildcardPath(key, written, maybe) ?? packagePath(key, written);
	}

	/**
	 * The other types a value `file` keys as `type` (`typeOf`) may be, which a call on it may run too: a name an `#if`-guarded
	 * import binds to another type on some builds, and a name a wildcard import of a package may supply where the tables
	 * cannot tell whether it does (a guarded wildcard, or a package neither the project nor the std core holds), searched
	 * before the type `typeOf` settled on. Read off the file, not the value: a value of `type` the file did not write
	 * takes them too.
	 */
	public function alternateTypes(file: String, type: String): Array<String> {
		final key: String = CallGraphNames.normalizePath(file);
		final guarded: Array<{ name: String, path: String }> = _guardedPaths[key] ?? [];
		final wild: Array<WildPackage> = _wildPackages[key] ?? [];
		if (guarded.length == 0 && wild.length == 0) return [];
		final name: String = SourceText.lastSegment(type);
		if (typeOf(file, name) != type) return [];
		final paths: Array<String> = [for (g in guarded) if (g.name == name) g.path];
		if (!(_typePaths[key] ?? []).exists(name)) wildcardPath(key, name, paths);
		final out: Array<String> = [];
		for (path in paths) {
			final alternate: String = pathType(path);
			if (alternate != type && !out.contains(alternate)) out.push(alternate);
		}
		return out;
	}

	/**
	 * The `alternateTypes` of `type` as each file of `files` reads it, each once: a value of `type` read off a declaration of
	 * another file is the name that file wrote, which may be another type there.
	 */
	public function alternateTypesIn(files: Array<String>, type: String): Array<String> {
		final out: Array<String> = [];
		for (f in files) for (alternate in alternateTypes(f, type)) if (!out.contains(alternate)) out.push(alternate);
		return out;
	}

	/**
	 * `typeOf` for a dotted path, which needs no file: its last segment unless the path names a type outside the tables
	 * whose simple name a declaration they hold bears. A path starting at a type (`Module.Sub`) is read by its last segment.
	 */
	public function pathType(path: String): String {
		final key: String = pathKey(path);
		if (key == path && path.indexOf('.') >= 0) CallGraphTypes.unionInto(_foreign, SourceText.lastSegment(path), [path]);
		return key;
	}

	/**
	 * The key a written dotted path of a type names, for matching it (`CallGraph.matchIds`): `pathType`'s, without recording
	 * the path as met.
	 */
	public function pathKey(path: String): String {
		final simple: String = SourceText.lastSegment(path);
		final dot: Int = path.indexOf('.');
		if (dot < 0 || CallGraphNames.isTypeLike(path.substring(0, dot))) return simple;
		final declared: Null<Array<String>> = _declaredPaths[simple];
		return declared == null || declared.contains(path) ? simple : path;
	}

	/**
	 * The type keys a pattern `T.*` or `pkg.T.*` names, `written` its part before `.*` (`CallGraph.matchIds`): every type
	 * keyed by the simple name `T`, by it or by a path ending in it; the one declared at `pkg.T` alone (`pathKey`).
	 */
	public function typeKeys(written: String): Array<String> {
		final simple: String = SourceText.lastSegment(written);
		return written == simple ? foreignPaths(simple).concat([simple]) : [pathKey(written)];
	}

	/** The paths of types outside the tables that bear the simple name `simple`, each keyed by its path (`pathType`). */
	public inline function foreignPaths(simple: String): Array<String> {
		return _foreign[simple] ?? [];
	}

	/**
	 * The graph ids a member query names (`CallGraph.resolveTarget`): `T.m` names the member `m` of every type keyed by the
	 * simple name `T` — the one keyed so, and each `pathType` keyed by a path ending in `T`; `pkg.T.m` names the member of
	 * the type declared at that path alone (`pathKey`), never a namesake declared elsewhere.
	 */
	public function memberIds(query: String): Array<String> {
		final simple: String = CallGraphNames.lastSegments(query, 2);
		final dot: Int = simple.indexOf('.');
		final member: String = simple.substring(dot);
		if (query != simple) return [pathKey(query.substring(0, query.length - simple.length + dot)) + member];
		return [simple].concat([for (path in foreignPaths(simple.substring(0, dot))) path + member]);
	}

	/**
	 * The module path a wildcard import of a package supplies under `name` in the file keyed `key` — the first, in the
	 * language's search order, that the project or the std core declares — unless its own module declares the name; null
	 * for none. A wildcard that may supply it where that cannot be told (guarded, or a package neither holds) pushes its
	 * path into `maybe` on the way.
	 */
	private function wildcardPath(key: String, name: String, ?maybe: Array<String>): Null<String> {
		if ((_ownTypes[key] ?? []).contains(name)) return null;
		for (w in _wildPackages[key] ?? []) {
			final path: String = '${w.pkg}.$name';
			final supplied: Null<Bool> = (_declaredPaths[name] ?? []).contains(path) ? true : StdTypes.declaresModule(w.pkg, name);
			if (supplied == true && !w.guarded) return path;
			if (supplied != false) maybe?.push(path);
		}
		return null;
	}

	/**
	 * The module path the package of the file keyed `key` — or a package enclosing it, nearest first — supplies under `name`,
	 * which the language searches after the file's imports: the first one the project declares there, or the std core
	 * declares in a package the core holds (a project file in `sys.thread` sees the std `Lock`); null for none, and in a
	 * package neither holds — a library's, which the tables cannot list. A type its own module declares is one the project
	 * declares there.
	 */
	private function packagePath(key: String, name: String): Null<String> {
		var pkg: String = _packages[key] ?? '';
		while (pkg != '') {
			final path: String = '$pkg.$name';
			if ((_declaredPaths[name] ?? []).contains(path) || StdTypes.declaresModule(pkg, name) == true) return path;
			final dot: Int = pkg.lastIndexOf('.');
			pkg = dot < 0 ? '' : pkg.substring(0, dot);
		}
		return null;
	}

	/**
	 * The type name an import statement binds and the path it binds it to: an alias of a path ending in a type, or an
	 * unguarded `import p.T;` — a guarded one binds the name on some builds only, where the name may mean another type.
	 */
	private static function typeImportOf(imp: ImportInfo): Null<{ name: String, path: String }> {
		final alias: Null<String> = imp.alias;
		final target: Null<String> = imp.aliasTarget;
		return switch imp.kind {
			case Alias if (alias != null && target != null && CallGraphNames.isTypeLike(SourceText.lastSegment(target))):
				{ name: alias, path: target };
			case Import if (!imp.guarded && CallGraphNames.isTypeLike(SourceText.lastSegment(imp.raw))):
				{ name: SourceText.lastSegment(imp.raw), path: imp.raw };
			case _: null;
		};
	}

}

/** A type one declaration writes (null for none), and the file writing it, where its names are read (`CallGraphKeys.keyedIn`). */
typedef WrittenIn = {
	var file: String;
	var written: Null<String>;
}

/** A package a wildcard import opens (`import p.*;`), and whether the import is `#if`-guarded — on some builds only. */
typedef WildPackage = {
	var pkg: String;
	var guarded: Bool;
}
