package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;

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

	/** File -> the `import` statements (own and ambient) that bring names into it, `using` aside. */
	private final _imports: Map<String, Array<ImportInfo>> = [];

	/** File -> the simple names of the types its `using` statements (own and ambient) bring in, nearest first. */
	private final _usings: Map<String, Array<String>> = [];

	/** File -> the statics its `import p.T.member as alias;` statements (own and ambient) bind under another name. */
	private final _fieldAliases: Map<String, Array<FieldAlias>> = [];

	/** Type simple name -> the dotted paths that name a declaration of it (`pkg.Module.Name`; a main type's also `pkg.Module`). */
	private final _declaredPaths: Map<String, Array<String>> = [];

	/** File -> the simple names its imports and aliases (own and ambient) bind to a type, and the dotted path each names. */
	private final _typePaths: Map<String, Map<String, String>> = [];

	/** Type simple name -> the paths `pathType` keyed apart from the declarations of that name, as it met them. */
	private final _foreign: Map<String, Array<String>> = [];

	/** File -> the names of the types its own module declares, which its code means before any import's. */
	private final _ownTypes: Map<String, Array<String>> = [];

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

	/**
	 * Whether the index cannot list a type's statics: not indexed, extern, or under a build macro on its own
	 * chain (`@:build` / `@:autoBuild`), which may add members no declaration shows.
	 */
	private final _unlisted: String -> Bool;

	public function new(enumConstructorKinds: Array<String>, isStatic: (String, String) -> Bool, unlisted: String -> Bool) {
		_enumConstructorKinds = enumConstructorKinds;
		_isStatic = isStatic;
		_unlisted = unlisted;
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

	/** The qualified paths the type of simple name `name` is declared under (`recordFile`): by its module, by its package. */
	public inline function declaredPathsOf(name: String): Array<String> {
		return _declaredPaths[name] ?? [];
	}

	/** Fold the declarations and the imports of `fi`, held under `key`. */
	public function recordFile(fi: FileInfo, key: String): Void {
		for (t in fi.types) {
			for (m in t.members) if (_enumConstructorKinds.contains(m.kind)) CallGraphTypes.unionInto(_enumConstructors, m.name, [t.name]);
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
		_imports[key] = imports;
		final aliases: Array<FieldAlias> = [];
		for (imp in imports) {
			final alias: Null<FieldAlias> = imp.kind == ImportKind.Alias ? fieldAliasOf(imp) : null;
			if (alias != null) aliases.push(alias);
		}
		_fieldAliases[key] = aliases;
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

	/**
	 * What `wildcardPath` and `alternateTypes` read of `fi`, held under `key`, whose import `groups` are the file's own and
	 * then its ambient ones, nearest first, and whose `imports` are every one of them a `using` is not: the types its module
	 * declares, the packages its wildcards open in search order, the names its guarded imports bind.
	 */
	private function recordSearchOrder(fi: FileInfo, key: String, groups: Array<Array<ImportInfo>>, imports: Array<ImportInfo>): Void {
		_ownTypes[key] = [for (t in fi.types) t.name];
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
	 * The statics the imports of `file` bind under a name of their own (`import p.T.member as alias;`) — each with the
	 * type the path names as the member's owner — and every alias whose path does not decode, with no owner and no member:
	 * that one may stand for any static. A plain `import p.T.member;` or a wildcard binds a static under its own name.
	 */
	public inline function fieldAliases(file: String): Array<FieldAlias> {
		return _fieldAliases[CallGraphNames.normalizePath(file)] ?? [];
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
	 * What the imports of `file` may supply under the simple name `name`: the statics an explicit
	 * `import p.T.name;` or `import p.T.f as name;` binds (whether or not the index lists them), those a
	 * wildcard `import p.T.*;` brings in, and `unknown` when a wildcard type's statics are not all listed
	 * (`_unlisted`) — the name may be one of them. A constructor an import names on an indexed enum is none
	 * of these: it builds a value.
	 */
	public function importedStatics(file: String, name: String): ImportedName {
		final out: ImportedName = { statics: [], unknown: false };
		function bind(owner: String, member: String): Void {
			if ((_enumConstructors[member] ?? []).contains(owner)) return;
			if (!out.statics.exists(o -> o.owner == owner && o.member == member)) out.statics.push({ owner: owner, member: member });
		}
		for (imp in _imports[CallGraphNames.normalizePath(file)] ?? []) {
			final path: Null<String> = switch imp.kind {
				case Import: imp.raw;
				case Wild: imp.raw.substring(0, imp.raw.length - 2);
				case _: null;
			};
			if (path == null) continue;
			final segs: Array<String> = path.split('.');
			final last: String = segs[segs.length - 1];
			final before: String = segs.length < 2 ? '' : segs[segs.length - 2];
			switch imp.kind {
				case Wild:
					// `import p.T.*` — `p.*` names a package, whose types bring no statics in
					if (!CallGraphNames.isTypeLike(last)) continue;
					if (_isStatic(last, name))
						bind(last, name)
					else if (_unlisted(last))
						out.unknown = true;
				case Import if (last == name && before != '' && CallGraphNames.isTypeLike(before)):
					bind(before, last);
				case _:
			}
		}
		for (a in fieldAliases(file)) {
			final owner: Null<String> = a.owner;
			final member: Null<String> = a.member;
			if (a.alias == name && owner != null && member != null) bind(owner, member);
		}
		return out;
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
		final key: String = CallGraphNames.normalizePath(file);
		final path: Null<String> = (_typePaths[key] ?? [])[written] ?? wildcardPath(key, written);
		return path == null ? written : pathType(path);
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
	 * The static an alias statement binds — `importedStatics` binds no other: a path whose segment before the last
	 * names a type (`p.T.member`). Null for an alias of a type or a module; an alias whose path did not decode is one with
	 * no owner and no member.
	 */
	private static function fieldAliasOf(imp: ImportInfo): Null<FieldAlias> {
		final alias: Null<String> = imp.alias;
		if (alias == null) return null;
		final path: Null<String> = imp.aliasTarget;
		if (path == null) return { alias: alias, owner: null, member: null };
		final segs: Array<String> = path.split('.');
		if (segs.length < 2 || !CallGraphNames.isTypeLike(segs[segs.length - 2])) return null;
		return { alias: alias, owner: segs[segs.length - 2], member: segs[segs.length - 1] };
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

/** What a file's imports may supply under one simple name: the statics they bind, and whether an unlisted wildcard may supply it too. */
typedef ImportedName = {
	var statics: Array<{ owner: String, member: String }>;
	var unknown: Bool;
}

/**
 * A static an import binds under a name of its own (`import p.T.member as alias;`): `owner` is the type the path names,
 * both null when the path did not decode.
 */
typedef FieldAlias = {
	var alias: String;
	var owner: Null<String>;
	var member: Null<String>;
}

/** A package a wildcard import opens (`import p.*;`), and whether the import is `#if`-guarded — on some builds only. */
typedef WildPackage = {
	var pkg: String;
	var guarded: Bool;
}
