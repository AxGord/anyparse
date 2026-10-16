package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeNameBinding.ImportPath;

using Lambda;

/**
 * THE meaning of a bare VALUE name no local, parameter or member binds, at module level: what the module itself declares
 * there (`FileInfo.moduleFields`), else the statics its imports bring in under the name. Each answer was compiled first on
 * Haxe 4.3.7 (`docs/decisions.md`):
 *
 *  - a module-level field or function of the module is what the name means, before any import's static;
 *  - `import p.T.f;` binds `f`, the static of `T` or the module-level field of module `p.T`; `import p.Mod.Sub.f;` the
 *    static of the sub-type `Sub`; `import p.T.f as a;` binds `a` to it;
 *  - `import p.T.*;` brings in the statics of the TYPE `T` only, never the module-level fields of module `p.T`;
 *  - a path naming a type of the module (`import p.Mod.Sub;`, `import p.T as U;`) binds a type, no static, and one naming
 *    a constructor of an indexed enum builds a value.
 *
 * Owners are read off the index by DECLARATION: the module a path names is split the way the compiler splits it
 * (`TypeNameBinding.splitPath`) and looked up in the binding's module table, so a namesake in another package never lends
 * its statics. A whitelist: a wildcard over a type whose statics the index cannot list — not indexed, `extern`, or under a
 * build macro on it or a supertype — and an alias whose path does not decode answer `unknown`, the name may be one of them.
 */
@:nullSafety(Strict)
final class ValueNameBinding {

	/** The layer the owners' modules and supertypes are read through. */
	private final _refs: TypeRefIndex;

	/** The member kinds an enum constructor projects as: one an import names builds a value, no static. */
	private final _enumConstructorKinds: Array<String>;

	public function new(refs: TypeRefIndex, enumConstructorKinds: Array<String>) {
		_refs = refs;
		_enumConstructorKinds = enumConstructorKinds;
	}

	/**
	 * What the imports of `fi` — its own, then its ambient chain's — may supply under the bare name `name`: every static an
	 * explicit import, an alias or a type wildcard binds it to, and whether one may supply it that the index cannot list. None
	 * when the module itself declares the name at module level.
	 */
	public function importedStatics(fi: FileInfo, name: String): ImportedStatics {
		final out: ImportedStatics = { statics: [], unknown: false };
		if (fi.moduleFields.contains(name)) return out;
		for (imp in importsOf(fi)) switch imp.kind {
			case ImportKind.Import:
				final named: Null<ImportedStatic> = SourceText.lastSegment(imp.raw) == name ? staticOf(imp.raw) : null;
				if (named != null) bind(out, named);
			case ImportKind.Alias if (imp.alias == name):
				final alias: Null<FieldAlias> = aliasOf(imp);
				final target: Null<ImportedStatic> = alias?.target;
				if (target != null)
					bind(out, target)
				else if (alias != null)
					out.unknown = true;
			case ImportKind.Wild:
				wildcard(SourceText.parentPath(imp.raw), name, out);
			case _:
		}
		return out;
	}

	/**
	 * Every alias statement of `fi` (its own, then its ambient chain's) that binds a static under another name
	 * (`import p.T.f as a;`), with the static — or none for one whose path does not decode, which may name any static. An
	 * alias of a type or a module binds none.
	 */
	public function fieldAliases(fi: FileInfo): Array<FieldAlias> {
		final out: Array<FieldAlias> = [];
		for (imp in importsOf(fi)) {
			final alias: Null<FieldAlias> = imp.kind == ImportKind.Alias ? aliasOf(imp) : null;
			if (alias != null) out.push(alias);
		}
		return out;
	}

	/**
	 * The types the `using` statements of `fi` (its own, then its ambient chain's) bring static extensions from, by simple
	 * name, each once: every non-private type of the module `using p.Mod;` names — its sub-types' statics too (4.3.7) — the
	 * one type `using p.Mod.Sub;` names, and the last segment of a module the index does not hold.
	 */
	public function usingTypes(fi: FileInfo): Array<String> {
		final out: Array<String> = [];
		for (imp in importsOf(fi)) if (imp.kind == ImportKind.Using) {
			final types: Null<Array<ResolvedType>> = _refs.names.importedTypes(imp.raw);
			final names: Array<String> = types == null ? [SourceText.lastSegment(imp.raw)] : [for (t in types) t.type.name];
			for (n in names) if (!out.contains(n)) out.push(n);
		}
		return out;
	}

	/**
	 * The static the alias statement `imp` binds (`staticOf`) under its alias name; one with no target when its path does
	 * not decode, null when it names a type or a module.
	 */
	private function aliasOf(imp: ImportInfo): Null<FieldAlias> {
		final alias: Null<String> = imp.alias;
		final target: Null<String> = imp.aliasTarget;
		if (alias == null) return null;
		if (target == null || TypeNameBinding.splitPath(target) == null) return { alias: alias, target: null };
		final named: Null<ImportedStatic> = staticOf(target);
		return named == null ? null : { alias: alias, target: named };
	}

	/**
	 * The static or module-level field the path `path` names: `p.T.f` the field `f` of module `p.T`'s main type or of the
	 * module, `p.Mod.Sub.f` the field of its sub-type `Sub`. Null for a path naming a type or a module, a sub-type of an
	 * indexed module, or a constructor of an indexed enum.
	 */
	private function staticOf(path: String): Null<ImportedStatic> {
		final split: Null<ImportPath> = TypeNameBinding.splitPath(path);
		if (split == null || split.rest.length == 0 || split.rest.length > 2) return null;
		final files: Array<FileInfo> = _refs.names.filesOfModule(split.module);
		final member: String = split.rest[split.rest.length - 1];
		if (split.rest.length == 1 && files.exists(f -> f.types.exists(t -> t.name == member))) return null;
		final owner: String = split.rest.length == 2 ? split.rest[0] : SourceText.lastSegment(split.module);
		final decls: Array<ResolvedType> = typesOf(files, owner);
		if (decls.exists(d -> d.type.members.exists(m -> m.name == member && _enumConstructorKinds.contains(m.kind)))) return null;
		return { owner: owner, decls: decls, member: member };
	}

	/**
	 * The statics a wildcard over `prefix` (`p.T` of `import p.T.*;`, `p.Mod.Sub`) brings in under `name`, into `out`: a
	 * static the type's declarations declare, else `unknown` when its statics are not all listed (`unlisted`). A package
	 * wildcard brings no static, and a module wildcard none of the module's module-level fields.
	 */
	private function wildcard(prefix: String, name: String, out: ImportedStatics): Void {
		final split: Null<ImportPath> = TypeNameBinding.splitPath(prefix);
		if (split == null || split.rest.length > 1) return;
		final owner: String = split.rest.length == 1 ? split.rest[0] : SourceText.lastSegment(split.module);
		final decls: Array<ResolvedType> = typesOf(_refs.names.filesOfModule(split.module), owner);
		if (decls.exists(d -> d.type.members.exists(m -> m.name == name && m.isStatic)))
			bind(out, { owner: owner, decls: decls, member: name })
		else if (unlisted(decls))
			out.unknown = true;
	}

	/**
	 * Whether the statics of the type declared by `decls` are not all listed: the index holds no declaration of it, one is
	 * `extern`, or a build macro on one of them or on a supertype it resolves may add members no declaration shows.
	 */
	private function unlisted(decls: Array<ResolvedType>): Bool {
		return decls.length == 0 || decls.exists(d -> d.type.isExtern || builtAtOrAbove(d, []));
	}

	/** Whether `cur` or a supertype it resolves carries a build macro (`@:build`, `@:autoBuild`); an unresolved link adds none. */
	private function builtAtOrAbove(cur: ResolvedType, seen: Array<String>): Bool {
		if (!_refs.markSeen(cur, seen)) return false;
		if (cur.type.hasBuild || cur.type.hasAutoBuild) return true;
		for (raw in cur.type.supertypesRaw) {
			final up: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file, cur.type.span.from);
			if (up != null && builtAtOrAbove(up, seen)) return true;
		}
		return false;
	}

	/** The import statements of `fi`: its own, then each group of its ambient chain, nearest first. */
	private static function importsOf(fi: FileInfo): Array<ImportInfo> {
		return [
			for (imports in [fi.imports].concat([for (group in fi.ambientImports) group.imports])) for (imp in imports) imp
		];
	}

	/** The non-private types named `name` that `files`, the files of one module, declare. */
	private static function typesOf(files: Array<FileInfo>, name: String): Array<ResolvedType> {
		return [
			for (f in files) for (t in f.types) if (t.name == name && !t.isPrivate) { file: f, type: t }
		];
	}

	/** Add `found` to `out`, once per owner and member. */
	private static function bind(out: ImportedStatics, found: ImportedStatic): Void {
		if (!out.statics.exists(s -> s.owner == found.owner && s.member == found.member)) out.statics.push(found);
	}

}

/** What the imports of a file may supply under one bare value name (`ValueNameBinding.importedStatics`). */
typedef ImportedStatics = {
	/** Each static an import binds the name to. */
	final statics: Array<ImportedStatic>;

	/** Whether an import may supply it that the index cannot list: a wildcard over an unlisted type, an undecoded alias. */
	var unknown: Bool;
}

/**
 * One static an import binds a bare name to: `owner` the type the path names (by simple name; the module's for a
 * module-level field), `decls` the declarations of it the index holds (none outside it, none for a module-level field
 * of a module without a main type), `member` the field.
 */
typedef ImportedStatic = {
	final owner: String;
	final decls: Array<ResolvedType>;
	final member: String;
}

/** An alias statement binding a static under another name (`ValueNameBinding.fieldAliases`): no `target` when its path does not decode. */
typedef FieldAlias = {
	final alias: String;
	final target: Null<ImportedStatic>;
}
