package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import haxe.Exception;

using Lambda;
using StringTools;

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
 * The ONE reader of "which simple names does this import line bind", over the resolution index —
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
 * a typedef whose target does not resolve (or is a nullable wrapper the compiler follows through),
 * a module whose retained source does not parse, a module the index never saw. The residual limit —
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

	/** File path -> its module-level field names; a stored null is "source not retained or unparseable". */
	private final _moduleFields: Map<String, Null<Array<String>>> = [];

	/** The resolution index, asked for only once a question actually needs it. */
	private final _index: () -> Null<SymbolIndex>;

	private final _plugin: GrammarPlugin;

	/** Module path -> its indexed files; built on the first question that needs the index. */
	private var _modules: Null<Map<String, Array<FileInfo>>> = null;

	/** Package -> its module names; built from `_modules` on the first package wildcard. */
	private var _packages: Null<Map<String, Array<String>>> = null;

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
		return (modules()[path] ?? []).exists(file -> file.types.length > 0);
	}

	/**
	 * What the explicit import `path` binds. A module path binds its module; a path one segment longer
	 * than a module binds the secondary type it names, or — when it names a member — that member as a
	 * field value; anything else is a module the index never saw (the residual reading).
	 */
	private function readExplicit(path: String): ImportBinding {
		final files: Null<Array<FileInfo>> = modules()[path];
		if (files != null) {
			final types: Array<String> = [];
			var typeValues: Null<Array<String>> = [];
			var fieldValues: Null<Array<String>> = [];
			for (file in files) {
				for (t in file.types) {
					if (!types.contains(t.name)) types.push(t.name);
					if (!t.isPrivate) typeValues = union(typeValues, typeValuesOf(t, file, []));
				}
				fieldValues = union(fieldValues, moduleFieldsOf(file));
			}
			return {
				types: types,
				wildcardTypes: [],
				typeValues: typeValues,
				fieldValues: fieldValues
			};
		}
		final leaf: String = SourceText.lastSegment(path);
		final owner: String = SourceText.parentPath(path);
		for (file in modules()[owner] ?? []) for (t in file.types) if (t.name == leaf) return {
			types: [leaf],
			wildcardTypes: [],
			typeValues: typeValuesOf(t, file, []),
			fieldValues: []
		};
		final ownerFields: Array<String> = [
			for (file in modules()[owner] ?? []) for (name in moduleFieldsOf(file) ?? []) name
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
				typeValues: null,
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
		if (!SourceText.isUpperInitial(SourceText.lastSegment(target))) {
			final names: Null<Array<String>> = packages()[target];
			return names == null ? null : {
				types: [],
				wildcardTypes: names,
				typeValues: [],
				fieldValues: []
			};
		}
		final declared: Array<TypeDeclInfo> = typesNamed(target);
		if (declared.length != 1) return null;
		final type: TypeDeclInfo = declared[0];
		final opaque: Bool = type.kind == TYPEDEF_KIND || type.hasBuild || type.hasAutoBuild || type.supertypes.length > 0
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
	 * typedef binds what its target binds — an anonymous structure nothing — and is followed through the
	 * index; a target that does not resolve, re-enters the chain, or is a nullable wrapper (the compiler
	 * follows `Null<Col>` to `Col`'s constructors) is unlisted. Every other kind binds none.
	 */
	private function typeValuesOf(type: TypeDeclInfo, file: FileInfo, seen: Array<TypeDeclInfo>): Null<Array<String>> {
		final shape: RefShape = _plugin.refShape();
		final abstracts: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final enums: Array<String> = shape.bareConstructorTypeKinds ?? [];
		if (type.kind == TYPEDEF_KIND) {
			if (type.isAnonStruct) return [];
			final target: Null<String> = type.aliasTargetRaw;
			if (target == null || (shape.nullableWrapperTypeNames ?? []).contains(SourceText.lastSegment(target))) return null;
			final next: Null<ResolvedType> = _index()?.refs.resolveTypeRef(target, file);
			return next == null || seen.contains(next.type) ? null : typeValuesOf(next.type, next.file, seen.concat([type]));
		}
		if (!abstracts.contains(type.kind) && !enums.contains(type.kind)) return [];
		if (type.hasBuild || type.hasAutoBuild) return null;
		if (!abstracts.contains(type.kind)) return [for (m in type.members) m.name];
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		return [for (m in type.members) if (!m.isStatic && fields.contains(m.kind)) m.name];
	}

	/**
	 * The module-level FIELD names `file` declares — Haxe 4.2's module statics, which an explicit
	 * import of the module brings in unqualified — read from its retained source, or null when the
	 * source is not retained or does not parse (memoised per file). Every named top-level declaration
	 * counts, looking through nameless wrappers (a `final`, a `#if` region) — minus the types the index
	 * lists and the import-family statements.
	 */
	private function moduleFieldsOf(file: FileInfo): Null<Array<String>> {
		if (_moduleFields.exists(file.file)) return _moduleFields[file.file];
		final fields: Null<Array<String>> = readModuleFields(file);
		_moduleFields[file.file] = fields;
		return fields;
	}

	private function readModuleFields(file: FileInfo): Null<Array<String>> {
		final index: Null<SymbolIndex> = _index();
		final source: Null<String> = index?.sourceOf(file.file);
		if (source == null) return null;
		final tree: Null<QueryNode> = try _plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return null;
		final types: Array<String> = [for (t in file.types) t.name];
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			for (c in node.children) if (
				!ModuleScan.IMPORT_DECL_KINDS.contains(c.kind) && !ModuleScan.PACKAGE_DECL_KINDS.contains(c.kind)
			) {
				final name: Null<String> = c.name;
				if (name == null)
					walk(c);
				else if (SourceText.isIdentifier(name) && !types.contains(name) && !out.contains(name))
					out.push(name);
			}
		}
		walk(tree);
		return out;
	}

	/** Every declaration `target` names: a module's MAIN type (`p.C`) or a module's secondary type (`p.Mod.C`). */
	private function typesNamed(target: String): Array<TypeDeclInfo> {
		final leaf: String = SourceText.lastSegment(target);
		final out: Array<TypeDeclInfo> = [];
		for (module in [target, SourceText.parentPath(target)])
			for (file in modules()[module] ?? [])
				for (t in file.types)
					if (t.name == leaf && !out.contains(t)) out.push(t);
		return out;
	}

	/** Module path -> its indexed files, read once from the index; empty without one. */
	private function modules(): Map<String, Array<FileInfo>> {
		final known: Null<Map<String, Array<FileInfo>>> = _modules;
		if (known != null) return known;
		final built: Map<String, Array<FileInfo>> = [];
		final index: Null<SymbolIndex> = _index();
		if (index != null) for (file in index.allFiles()) {
			final files: Array<FileInfo> = built[file.module] ?? [];
			files.push(file);
			built[file.module] = files;
		}
		_modules = built;
		return built;
	}

	/** Package -> its module names, read with `modules`; empty without an index. */
	private function packages(): Map<String, Array<String>> {
		final known: Null<Map<String, Array<String>>> = _packages;
		if (known != null) return known;
		final built: Map<String, Array<String>> = [];
		for (module => _ in modules()) {
			final dot: Int = module.lastIndexOf('.');
			final pkg: String = dot < 0 ? '' : module.substring(0, dot);
			final names: Array<String> = built[pkg] ?? [];
			names.push(SourceText.lastSegment(module));
			built[pkg] = names;
		}
		_packages = built;
		return built;
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
