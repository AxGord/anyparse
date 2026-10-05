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
		for (t in fi.types)
			for (m in t.members)
				if (_enumConstructorKinds.contains(m.kind)) CallGraphTypes.unionInto(_enumConstructors, m.name, [t.name]);
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
