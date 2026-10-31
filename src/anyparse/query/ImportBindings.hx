package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * The simple names ONE import-family line binds, split by the RANK the compiler resolves them at.
 * Two lines' relative order can decide what a name means only when both bind it at the SAME rank:
 * a higher rank wins in either statement order, and inside one rank the LAST statement wins. A null
 * set is "cannot be listed" (`ImportBindings.collision` reads it).
 *
 *  - `types` — the TYPE names an explicit import or a `using` binds: every type of a module, the one
 *    type of a sub-type path. An explicit type outranks a package wildcard's in either order.
 *  - `wildcardTypes` — the module names a PACKAGE wildcard (`import p.*;`) binds.
 *  - `typeValues` — the enum constructors and enum-abstract values of the TYPES a line imports (every
 *    non-private type of a module, a typedef followed to what it aliases). They outrank every
 *    `fieldValues` name in either order.
 *  - `fieldValues` — the module-level fields a module import brings (never a `using`), the leaf of a
 *    field import (`import p.C.f;`, `import p.Col.Red;`), the statics / constructors / values a
 *    FIELD wildcard (`import p.C.*;`) binds.
 */
typedef ImportBinding = {
	final types: Array<String>;
	final wildcardTypes: Array<String>;
	final typeValues: Null<Array<String>>;
	final fieldValues: Null<Array<String>>;
}

/**
 * Why two lines' relative order is load-bearing: the simple `name` both bind at one rank, or — with
 * `unlisted` set — a rank whose names one of them binds and the other line `unlisted` cannot be
 * listed for, so nothing proves it does not bind the same one.
 */
typedef BindingCollision = {
	final name: String;
	final unlisted: Null<String>;
}

/**
 * The one answer to "which simple names does this import line bind", over the resolution index —
 * what `import-order` refuses a reorder by, what `WildcardImportGate` admits a wildcard by, and what
 * `unused-import`, `redundant-import`, `hoist-common-import` and `import-outside-guard` read before
 * they delete or move a line. What the compiler does — the precedence table is in `docs/decisions.md`:
 *
 *  - a module import binds every type of the module, the constructors / enum-abstract values of every
 *    NON-PRIVATE type in it (a secondary enum's too, a typedef's target's too — through `Null<T>`),
 *    and its module-level fields; never the statics of its main class;
 *  - a `using` binds the same minus the module-level fields;
 *  - constructors and abstract values outrank module-level fields, field imports and field wildcards
 *    in either order; inside either tier, and between two types, the LAST statement wins.
 *
 * POSITIVE whitelist. A set the index cannot list is null: an enum or abstract carrying a build macro,
 * a typedef whose target (a nullable wrapper's argument, which the compiler follows through) does not resolve,
 * a module the index never saw. The residual limit —
 * documented, not hidden: a module the index never saw contributes its own last segment as its only
 * TYPE, and two lines whose sets are BOTH unlisted are not read as colliding (`collision`), the
 * pre-index reading; a project unlocks them by declaring the library in `resolutionLibs`.
 */
@:nullSafety(Strict)
final class ImportBindings {

	/** The suffix every wildcard import's path carries (`p.*`, `p.C.*`) — and no plain import's. */
	private static inline final WILDCARD_SUFFIX: String = '.*';

	/** The alias declaration kind — a typedef's static set and constructors are those of what it aliases. */
	private static inline final TYPEDEF_KIND: String = 'TypedefDecl';

	/** The declaration kinds whose wildcard binds only the members marked static; every other kind binds every member. */
	private static final CLASS_KINDS: Array<String> = ['ClassDecl', 'AbstractClassDecl', 'FinalDecl', 'ClassForm'];

	/** Import path -> what the line binds; a stored null is a wildcard that cannot be enumerated. */
	private final _imports: Map<String, Null<ImportBinding>> = [];

	/** The resolution index, asked for only once a question actually needs it. */
	private final _index: () -> Null<SymbolIndex>;

	private final _plugin: GrammarPlugin;

	public function new(index: () -> Null<SymbolIndex>, plugin: GrammarPlugin) {
		_index = index;
		_plugin = plugin;
	}

	/**
	 * What `import <path>;` binds — a wildcard path included — or null for a WILDCARD the index cannot
	 * enumerate (memoised). An explicit import always has an answer: what the index cannot list is a
	 * null SET inside it.
	 */
	public function ofImport(path: String): Null<ImportBinding> {
		if (_imports.exists(path)) return _imports[path];
		final binding: Null<ImportBinding> = isWildcard(path)
			? readWildcard(path.substring(0, path.length - WILDCARD_SUFFIX.length))
			: readExplicit(path);
		_imports[path] = binding;
		return binding;
	}

	/** What `using <path>;` binds: the explicit import's types and type values — a `using` brings no module-level field. */
	public function ofUsing(path: String): ImportBinding {
		final imported: Null<ImportBinding> = ofImport(path);
		return {
			types: imported?.types ?? [SourceText.lastSegment(path)],
			wildcardTypes: [],
			typeValues: imported?.typeValues,
			fieldValues: []
		};
	}

	/** What `import <path> as <alias>;` binds: the alias as a TYPE, and value names nobody measured — unlisted. */
	public function ofAlias(alias: String): ImportBinding {
		return {
			types: [alias],
			wildcardTypes: [],
			typeValues: null,
			fieldValues: null
		};
	}

	/** Whether the index holds a module at `path` that declares at least one type. */
	public function indexesModule(path: String): Bool {
		return filesOf(path).exists(file -> file.types.length > 0);
	}

	/**
	 * The value names the types `import <path>;` brings declare (its `typeValues`), with a module the index never saw and a
	 * typedef whose target it cannot read or resolve read as binding none: null only where the index holds an enum or an
	 * abstract a build macro shapes (directly or through a typedef, a nullable wrapper's argument too), whose constructors no
	 * source lists.
	 */
	public function valuesSeen(path: String): Null<Array<String>> {
		return isWildcard(path) ? [] : readExplicit(path, true).typeValues;
	}

	/**
	 * What the explicit import `path` binds. A module path binds its module; a path one segment longer
	 * than a module binds the secondary type it names, or — when it names a member — that member as a
	 * field value; anything else is a module the index never saw (the residual reading), whose value sets
	 * are unlisted unless `unseenAsNone` reads what the index never saw as binding none (`valuesSeen`).
	 */
	private function readExplicit(path: String, unseenAsNone: Bool = false): ImportBinding {
		final files: Array<FileInfo> = filesOf(path);
		final imported: Array<ResolvedType> = _index()?.refs.names.importedTypes(path) ?? [];
		if (files.length > 0) {
			var typeValues: Null<Array<String>> = [];
			var fieldValues: Null<Array<String>> = [];
			for (file in files) {
				for (t in file.types) if (!t.isPrivate) typeValues = union(typeValues, typeValuesOf(t, file, [], unseenAsNone));
				fieldValues = union(fieldValues, moduleFieldsOf(file));
			}
			final types: Array<String> = [];
			for (r in imported) if (!types.contains(r.type.name)) types.push(r.type.name);
			return {
				types: types,
				wildcardTypes: [],
				typeValues: typeValues,
				fieldValues: fieldValues
			};
		}
		final leaf: String = SourceText.lastSegment(path);
		final owner: String = SourceText.parentPath(path);
		for (r in imported) return {
			types: [leaf],
			wildcardTypes: [],
			typeValues: typeValuesOf(r.type, r.file, [], unseenAsNone),
			fieldValues: []
		};
		final ownerFields: Array<String> = [
			for (file in filesOf(owner)) for (name in moduleFieldsOf(file)) name
		];
		final owners: Array<TypeDeclInfo> = typesNamed(owner);
		final member: Bool = ownerFields.contains(leaf) || owners.length > 0 && owners.foreach(t -> t.members.exists(m -> m.name == leaf));
		return member
			? {
				types: [],
				wildcardTypes: [],
				typeValues: [],
				fieldValues: [leaf]
			}
			: {
				types: [leaf],
				wildcardTypes: [],
				typeValues: unseenAsNone ? [] : null,
				fieldValues: null
			};
	}

	/**
	 * What `import <target>.*;` binds: a PACKAGE wildcard when `target`'s last segment is lower-initial,
	 * else a FIELD wildcard over the one type `target` names — or null when the index cannot enumerate
	 * it: an unindexed package or type, a `typedef` (it may alias a class whose statics are not listed
	 * here), a type carrying a build macro or any supertype or interface (an inherited `@:autoBuild`
	 * would add statics this index never sees).
	 */
	private function readWildcard(target: String): Null<ImportBinding> {
		final binding: Null<TypeNameBinding> = _index()?.refs.names;
		if (binding == null) return null;
		if (TypeNameBinding.splitPath(target) == null) {
			final mains: Null<Array<ResolvedType>> = binding.wildcardTypes(target);
			if (mains == null) return null;
			final names: Array<String> = [];
			for (m in mains) if (!names.contains(m.type.name)) names.push(m.type.name);
			return {
				types: [],
				wildcardTypes: names,
				typeValues: [],
				fieldValues: []
			};
		}
		final declared: Array<TypeDeclInfo> = typesNamed(target);
		if (declared.length != 1) return null;
		final type: TypeDeclInfo = declared[0];
		final opaque: Bool = type.kind == TYPEDEF_KIND
			|| type.hasBuild
			|| type.hasAutoBuild
			|| type.supertypes.length > 0
			|| type.interfaces.length > 0;
		if (opaque) return null;
		final statics: Bool = CLASS_KINDS.contains(type.kind);
		return {
			types: [],
			wildcardTypes: [],
			typeValues: [],
			fieldValues: [for (m in type.members) if (!statics || m.isStatic) m.name]
		};
	}

	/**
	 * The constructors / enum-abstract values importing `type` (declared in `file`) brings in, or null
	 * when they cannot be listed. An enum binds every constructor; an abstract binds its non-static FIELD
	 * members — the values of an `enum abstract`, and of a legacy `@:enum abstract`, which projects as a
	 * plain abstract and so cannot be told apart (a plain abstract's instance properties are the price,
	 * paid in refusals, never in a wrong rewrite); either kind carrying a build macro is unlisted. A
	 * typedef binds what its target binds — an anonymous structure nothing, a nullable wrapper what its
	 * argument binds (the compiler follows `Null<Col>` to `Col`'s constructors) — and is followed through
	 * the index (`aliasValuesOf`). Every other kind binds none.
	 */
	private function typeValuesOf(type: TypeDeclInfo, file: FileInfo, seen: Array<TypeDeclInfo>, unseenAsNone: Bool): Null<Array<String>> {
		final shape: RefShape = _plugin.refShape();
		final abstracts: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final enums: Array<String> = shape.bareConstructorTypeKinds ?? [];
		if (type.kind == TYPEDEF_KIND) return aliasValuesOf(type, file, seen, unseenAsNone);
		if (!abstracts.contains(type.kind) && !enums.contains(type.kind)) return [];
		if (type.hasBuild || type.hasAutoBuild) return null;
		if (!abstracts.contains(type.kind)) return [for (m in type.members) m.name];
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		return [for (m in type.members) if (!m.isStatic && fields.contains(m.kind)) m.name];
	}

	/**
	 * `typeValuesOf` of the typedef `type`: an anonymous structure binds nothing, any other is followed through the index to
	 * what it aliases (`aliasFollowed`, a nullable wrapper's argument included); a target that cannot be read, does not
	 * resolve or re-enters the chain is unlisted — or, under `unseenAsNone`, binds none (the index cannot show it binds any).
	 */
	private function aliasValuesOf(type: TypeDeclInfo, file: FileInfo, seen: Array<TypeDeclInfo>, unseenAsNone: Bool): Null<Array<String>> {
		if (type.isAnonStruct) return [];
		final unlisted: Null<Array<String>> = unseenAsNone ? [] : null;
		final target: Null<String> = aliasFollowed(type);
		if (target == null) return unlisted;
		final next: Null<ResolvedType> = _index()?.refs.resolveTypeRef(target, file, type.span.from);
		return next == null || seen.contains(next.type) ? unlisted : typeValuesOf(next.type, next.file, seen.concat([type]), unseenAsNone);
	}

	/**
	 * The type the typedef `type`'s value names are read through: what it aliases, or — for a nullable wrapper
	 * (`typedef X = Null<Col>`), which the compiler follows to `Col`'s constructors — the wrapper's one argument; null when
	 * neither can be read.
	 */
	private function aliasFollowed(type: TypeDeclInfo): Null<String> {
		final target: Null<String> = type.aliasTargetRaw;
		final written: Null<String> = type.aliasTargetWritten;
		if (target == null || !(_plugin.refShape().nullableWrapperTypeNames ?? []).contains(SourceText.lastSegment(target))) return target;
		final args: Null<Array<String>> = written == null ? null : _plugin.typeSyntax(written)?.argumentTexts();
		return args != null && args.length == 1 ? args[0] : null;
	}

	/** Every declaration `target` names: a module's MAIN type (`p.C`) or a module's secondary type (`p.Mod.C`). */
	private function typesNamed(target: String): Array<TypeDeclInfo> {
		final leaf: String = SourceText.lastSegment(target);
		final out: Array<TypeDeclInfo> = [];
		for (module in [target, SourceText.parentPath(target)])
			for (file in filesOf(module))
				for (t in file.types)
					if (t.name == leaf && !out.contains(t)) out.push(t);
		return out;
	}

	/**
	 * The indexed files of `module`, from the binding layer's module table (`TypeNameBinding`); none without an index.
	 */
	private function filesOf(module: String): Array<FileInfo> {
		return _index()?.refs.names.filesOfModule(module) ?? [];
	}

	/** Whether `path` is a wildcard import's path. */
	public static inline function isWildcard(path: String): Bool {
		return path.endsWith(WILDCARD_SUFFIX);
	}

	/**
	 * Whether `binding` provably binds NO value name at either rank — the one shape a check reasoning
	 * only about TYPE names may move or delete; an unlisted set is not that proof.
	 */
	public static inline function bindsNoValue(binding: Null<ImportBinding>): Bool {
		return binding != null && binding.typeValues?.length == 0 && binding.fieldValues?.length == 0;
	}

	/**
	 * Every simple name `binding` brings into scope except `keep` — the module's other types, the constructors and values
	 * of the types it imports, its module-level fields — or null when a set cannot be listed. What a caller adding the
	 * line must check is not re-pointed in its file.
	 */
	public static function namesBesides(binding: Null<ImportBinding>, keep: String): Null<Array<String>> {
		final values: Null<Array<String>> = binding?.typeValues;
		final fields: Null<Array<String>> = binding?.fieldValues;
		return binding == null || values == null || fields == null
			? null
			: [for (name in binding.types.concat(values).concat(fields)) if (name != keep) name];
	}

	/**
	 * The reader an insert seat holding only `plugin` can build: over the host's RESOLUTION index when
	 * the run carries one, else null — no index, no proof.
	 */
	public static function forPlugin(plugin: GrammarPlugin): Null<ImportBindings> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		if (host == null || !host.hasAnyResolutionScope()) return null;
		final resolver: SymbolIndexHost = host;
		return new ImportBindings(() -> resolver.resolutionIndex(), plugin);
	}

	/**
	 * Why the relative order of the lines binding `a` and `b` decides a simple name, or null when it
	 * provably decides none: a name both bind at one rank, or a rank where one binds a name and the
	 * other's set cannot be listed. Two unlisted sets are the residual (see the class doc), not a
	 * collision. `pathA` / `pathB` name the lines in the answer.
	 */
	public static function collision(a: ImportBinding, pathA: String, b: ImportBinding, pathB: String): Null<BindingCollision> {
		final ranks: Array<{ mine: Null<Array<String>>, theirs: Null<Array<String>> }> = [
			{ mine: a.types, theirs: b.types },
			{ mine: a.wildcardTypes, theirs: b.wildcardTypes },
			{ mine: a.typeValues, theirs: b.typeValues },
			{ mine: a.fieldValues, theirs: b.fieldValues }
		];
		for (rank in ranks) {
			final found: Null<BindingCollision> = rankCollision(rank.mine, pathA, rank.theirs, pathB);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * The module-level FIELD names `file` declares — Haxe 4.2's module statics, which an explicit
	 * import of the module brings in unqualified — each once, a declaration in every `#if` branch
	 * included: the index's own reading of them (`FileInfo.moduleFields`).
	 */
	private static function moduleFieldsOf(file: FileInfo): Array<String> {
		final out: Array<String> = [];
		for (field in file.moduleFields) if (!out.contains(field.name)) out.push(field.name);
		return out;
	}

	/** `collision` at one rank. */
	private static function rankCollision(
		a: Null<Array<String>>, pathA: String, b: Null<Array<String>>, pathB: String
	): Null<BindingCollision> {
		if (a == null && b == null) return null;
		if (a == null) return b != null && b.length > 0 ? { name: b[0], unlisted: pathA } : null;
		if (b == null) return a.length > 0 ? { name: a[0], unlisted: pathB } : null;
		final shared: Null<String> = a.find(name -> b.contains(name));
		return shared == null ? null : { name: shared, unlisted: null };
	}

	/** The union of `a` and `b`, null when either cannot be listed. */
	private static function union(a: Null<Array<String>>, b: Null<Array<String>>): Null<Array<String>> {
		return a == null || b == null ? null : a.concat([for (name in b) if (!a.contains(name)) name]);
	}

}
