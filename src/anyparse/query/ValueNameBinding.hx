package anyparse.query;

import anyparse.query.CondBranchPath;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ModuleField;
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

	/** The type kinds whose every member is a value by its bare name where the type is in scope: an enum's, an abstract's. */
	private final _valueHostKinds: Array<String>;

	public function new(refs: TypeRefIndex, enumConstructorKinds: Array<String>, valueHostKinds: Array<String>) {
		_refs = refs;
		_enumConstructorKinds = enumConstructorKinds;
		_valueHostKinds = valueHostKinds;
	}

	/**
	 * Whether an import of `fi` (its own, then its ambient chain's) may bring a VALUE named `name` into unqualified scope —
	 * what a bare `case` pattern compares against (`PatternNameScope`): a static an explicit import, an alias or a type
	 * wildcard binds (`importedStatics`); a constructor or value of a type an import puts in scope — an enum's, an
	 * abstract's, a module's sub-types' with it; a module-level field of a module a whole-module import names (4.3.7: `import
	 * p.Mod;` brings `Mod`'s module-level `modX` and its sub-type enum's constructors in, and `case modX:` compares). True
	 * where the index cannot list what an import brings, and for an alias or an explicit import spelling `name` itself.
	 */
	public function mayImportValue(fi: FileInfo, name: String): Bool {
		final statics: ImportedStatics = importedStatics(fi, name);
		return statics.unknown || statics.statics.length > 0 || importsOf(fi).exists(imp -> importMayBring(imp, name));
	}

	/**
	 * The path of the first import of `fi` (its own, then its ambient chain's) that may bind the bare call name `name` to a
	 * function the index cannot list — what a gate asks before it trusts that no import routes the call out of sight
	 * (`MacroIndex.unresolvedBinding`): a static-field import or an alias of a static whose owner the index does not hold, a
	 * type wildcard over a type whose statics are not all listed (the type's path), a `using` of a module the index does not
	 * hold or whose types are not all listed (a static extension may answer any call). With `extensionsOnly`, only a `using`
	 * is asked: a call written on a value receiver is routed by none of the others. Null when every import binding the name
	 * is listed, or none binds it.
	 */
	public function unlistedImportOf(fi: FileInfo, name: String, extensionsOnly: Bool = false): Null<String> {
		for (imp in importsOf(fi)) if (!extensionsOnly || imp.kind == ImportKind.Using) {
			final unlistedAt: Null<String> = switch imp.kind {
				case ImportKind.Import if (SourceText.lastSegment(imp.raw) == name):
					final named: Null<ImportedStatic> = staticOf(imp.raw);
					final hidden: Bool = if (named == null)
						TypeNameBinding.splitPath(imp.raw) == null
					else
						unlisted(named.decls);
					hidden ? imp.raw : null;
				case ImportKind.Alias if (imp.alias == name):
					final target: Null<ImportedStatic> = aliasOf(imp)?.target;
					final path: String = imp.aliasTarget ?? imp.raw;
					final hidden: Bool = if (target == null)
						TypeNameBinding.splitPath(path) == null
					else
						unlisted(target.decls);
					hidden ? path : null;
				case ImportKind.Wild:
					final prefix: String = SourceText.parentPath(imp.raw);
					final split: Null<ImportPath> = TypeNameBinding.splitPath(prefix);
					final decls: Array<ResolvedType> = split == null || split.rest.length > 1
						? []
						: typesOf(
							_refs.names.filesOfModule(split.module),
							split.rest.length == 1 ? split.rest[0] : SourceText.lastSegment(split.module)
						);
					split != null && split.rest.length <= 1 && unlisted(decls) ? prefix : null;
				case ImportKind.Using:
					final types: Null<Array<ResolvedType>> = _refs.names.importedTypes(imp.raw);
					types == null || unlisted(types) ? imp.raw : null;
				case _: null;
			};
			if (unlistedAt != null) return unlistedAt;
		}
		return null;
	}

	/**
	 * The module-level declarations of the bare value name `name` a use at offset `at` of `fi` binds, by the `#if` branches
	 * the builds compiling the use take (Haxe 4.3.7, `hx/p1`): the one declaration every such build compiles
	 * (`CondBranchPath.within`), when there is one; else every declaration some such build may compile — none of a branch the
	 * use is an alternative of (`CondBranchPath.comparable`) — and what the imports supply in the builds that compile none of
	 * them. A build compiles at most one: two module-level declarations of a name in one build do not compile. Coverage is not
	 * read — `#if a … #else … #end` declaring the name in both branches still lists the imports — so the answer may hold a
	 * build that does not exist, never miss one that does. Null when the module declares no value of the name.
	 */
	public function moduleValuesAt(fi: FileInfo, name: String, at: Int): Null<ModuleValues> {
		final fields: Array<ModuleField> = fi.moduleFields.filter(f -> f.name == name);
		if (fields.length == 0) return null;
		final use: Array<CondFrame> = _refs.names.branchPathAt(fi, at);
		final certain: Null<ModuleField> = fields.find(f -> CondBranchPath.within(use, branchOf(fi, f)));
		return certain != null
			? { decls: [certain], imported: null }
			: { decls: fields.filter(f -> CondBranchPath.comparable(use, branchOf(fi, f))), imported: importedStatics(fi, name, at) };
	}

	/**
	 * What the imports of `fi` — its own, then its ambient chain's — may supply under the bare name `name`: every static an
	 * explicit import, an alias or a type wildcard binds it to, and whether one may supply it that the index cannot list. None
	 * when every build compiling a use at offset `at` declares the name at module level (`moduleValuesAt`) — with no `at`,
	 * when a declaration of it sits in no `#if` branch: a module-level field is what the name means where it is compiled.
	 */
	public function importedStatics(fi: FileInfo, name: String, ?at: Int): ImportedStatics {
		final out: ImportedStatics = { statics: [], unknown: false };
		// the use's branch is read only for a name the module declares — most are not
		if (fi.moduleFields.exists(f -> f.name == name)) {
			final use: Array<CondFrame> = at == null ? [] : _refs.names.branchPathAt(fi, at);
			if (fi.moduleFields.exists(f -> f.name == name && CondBranchPath.within(use, branchOf(fi, f)))) return out;
		}
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
	 * The types `using <path>` brings, as declarations: the whole module's public types, or the one type a sub-type path
	 * names — 4.3.7 binds an extension declared on ANY type of a used module. Null when the index does not hold the module,
	 * when the path names nothing, and when a type it brings is an alias, whose statics live on a type it does not name.
	 */
	public function usingHosts(path: String): Null<Array<ResolvedType>> {
		final types: Null<Array<ResolvedType>> = _refs.names.importedTypes(path);
		return types == null || types.length == 0 || types.exists(t -> t.type.kind == SymbolIndex.TYPEDEF_DECL_KIND) ? null : types;
	}

	/**
	 * Every type a `using` in scope of `fi` brings — its own statements and the ambient `import.hx` chain's — as declarations
	 * (`usingHosts`), in no particular order; null when one of them cannot be read, so a caller proving that NO static
	 * extension of a name applies is never answered by a module the index does not hold.
	 */
	public function usingDeclarations(fi: FileInfo): Null<Array<ResolvedType>> {
		final out: Array<ResolvedType> = [];
		for (imp in importsOf(fi)) if (imp.kind == ImportKind.Using) {
			final hosts: Null<Array<ResolvedType>> = usingHosts(imp.raw);
			if (hosts == null) return null;
			for (h in hosts) out.push(h);
		}
		return out;
	}

	/**
	 * Whether the one statement `imp` may bring a constructor, a value or a module-level field named `name` into unqualified
	 * scope (`mayImportValue`); a `using` brings none, a package wildcard none, an alias only what the one
	 * type it names carries (4.3.7: `import p.Mod as M;` brings neither `modX` nor a sub-type's constructor).
	 */
	private function importMayBring(imp: ImportInfo, name: String): Bool {
		return switch imp.kind {
			case ImportKind.Using: false;
			case ImportKind.Alias:
				final target: Null<String> = imp.aliasTarget;
				imp.alias == name
					|| if (target == null)
						true
					else
						carriesValue(_refs.names.declsAt(target), name);
			case ImportKind.Wild:
				final prefix: String = SourceText.parentPath(imp.raw);
				TypeNameBinding.splitPath(prefix) != null && carriesValue(_refs.names.declsAt(prefix), name);
			case _:
				final split: Null<ImportPath> = TypeNameBinding.splitPath(imp.raw);
				final types: Null<Array<ResolvedType>> = _refs.names.importedTypes(imp.raw);
				// a static-field import brings its one field, which the last segment spells
				SourceText.lastSegment(imp.raw) == name || split != null && SourceText.isUpperInitial(SourceText.lastSegment(imp.raw))
					&& (types == null || carriesValue(types, name) || split.rest.length == 0
						&& _refs.names.filesOfModule(split.module).exists(f -> f.moduleFields.exists(m -> m.name == name)));
		};
	}

	/** Whether one of `types` — an empty list may be anything — declares `name` as a member its bare name is a value of. */
	private function carriesValue(types: Array<ResolvedType>, name: String): Bool {
		return types.length == 0 || types.exists(t -> _valueHostKinds.contains(t.type.kind) && t.type.members.exists(m -> m.name == name));
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

	/** The `#if` regions and branches the module-level declaration `field` of `fi` sits in. */
	private inline function branchOf(fi: FileInfo, field: ModuleField): Array<CondFrame> {
		return _refs.names.branchPathAt(fi, field.span.from);
	}

}

/** What a bare value name means at module level at one use (`ValueNameBinding.moduleValuesAt`). */
typedef ModuleValues = {
	/** Each module-level declaration of the name a build compiling the use binds it to, in source order. */
	final decls: Array<ModuleField>;

	/** What the imports supply in the builds compiling the use and none of `decls`; null when every such build compiles one. */
	final imported: Null<ImportedStatics>;
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
