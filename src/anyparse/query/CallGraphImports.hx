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
	 * unless the type the file means — a dotted path written out, or the path an import or an alias of the file binds
	 * the name to — is not a declaration of that simple name the tables hold while one of them bears it. Then the path
	 * itself: `sys.thread.Lock` beside a project `utils.Lock` is another type, and merging the two by name would make a
	 * call of the library one run the project's. A name no import binds stays as written.
	 */
	public function typeOf(file: String, written: String): String {
		if (written.indexOf('.') >= 0) return pathType(written);
		final path: Null<String> = (_typePaths[CallGraphNames.normalizePath(file)] ?? [])[written];
		return path == null ? written : pathType(path);
	}

	/**
	 * `typeOf` for a dotted path, which needs no file: its last segment unless the path names a type outside the tables
	 * whose simple name a declaration they hold bears. A path starting at a type (`Module.Sub`) is read by its last segment.
	 */
	public function pathType(path: String): String {
		final simple: String = SourceText.lastSegment(path);
		final dot: Int = path.indexOf('.');
		if (dot < 0 || CallGraphNames.isTypeLike(path.substring(0, dot))) return simple;
		final declared: Null<Array<String>> = _declaredPaths[simple];
		if (declared == null || declared.contains(path)) return simple;
		CallGraphTypes.unionInto(_foreign, simple, [path]);
		return path;
	}

	/** The paths of types outside the tables that bear the simple name `simple`, each keyed by its path (`pathType`). */
	public inline function foreignPaths(simple: String): Array<String> {
		return _foreign[simple] ?? [];
	}

	/**
	 * The graph ids a member query `T.m` or `pkg.T.m` names beside the one of its last two segments: the member `m` of each
	 * type `pathType` keyed by a path ending in `T` — every such type for a query naming `T` alone, the one it names for a
	 * query naming the path.
	 */
	public function keyedIds(query: String): Array<String> {
		final simple: String = CallGraphNames.lastSegments(query, 2);
		final dot: Int = simple.indexOf('.');
		final member: String = simple.substring(dot);
		return dot < 0 ? [] : [
			for (path in foreignPaths(simple.substring(0, dot))) if (query == simple || query == path + member) path + member
		];
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
