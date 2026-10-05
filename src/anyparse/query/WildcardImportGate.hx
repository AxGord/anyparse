package anyparse.query;

import anyparse.query.ImportOrder.ImportLine;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The simple names one WILDCARD import binds, split by namespace: `types` for a PACKAGE wildcard
 * (`import p.*;` — one per module of `p`), `values` for a FIELD wildcard (`import p.C.*;` — the
 * statics of `C`, its enum constructors / abstract values included).
 */
private typedef WildcardBinding = {
	final types: Array<String>;
	final values: Array<String>;
}

/**
 * Which WILDCARD import lines may sit inside an import RUN as ordinary members — sorted like any
 * other line by `import-order`, and offered as a slot by the insert seat (`ImportOrder.runsIn`).
 *
 * A wildcard used to END every run it touched, so `import tink.unit.Assert.*;` above a sorted
 * block was a fixed point no finding could describe. It may join the run exactly when NO
 * permutation of the run can change what any simple name means, which the compiler's precedence
 * (the table in `docs/decisions.md`) reduces to three pairwise
 * questions. Two namespaces are at stake, and they never interact: in expression position a VALUE
 * outranks a TYPE of the same name in either statement order, and in type position only types
 * count.
 *
 *  - TYPES. A package wildcard binds the MODULE names of its package (no secondary type, no
 *    module-level field, no enum constructor). An explicit import outranks it in either order, so
 *    an explicit import never blocks it; two package wildcards binding one name are resolved LAST
 *    wins, so a shared name is a block.
 *  - VALUES. A field wildcard binds every static its type DECLARES (private ones too, not the
 *    inherited ones), every enum constructor and every abstract value — never the type itself or
 *    a secondary type of its module. Against another field wildcard, an explicit FIELD import
 *    (`import p.D.f;`, `import v.Mod.moduleField;`) and the MODULE-LEVEL fields an explicit module
 *    import brings in (`import v.Mod;`), the LAST statement wins — so a shared name is a block.
 *    The enum constructors and abstract values an explicit TYPE import brings in outrank a field
 *    wildcard in either order and never block.
 *  - Nothing else: a statement outside the run keeps its position relative to every member under
 *    any permutation of the run, so `import.hx`, same-package and module-local types are not
 *    questions this gate has to ask.
 *
 * POSITIVE whitelist — anything the index cannot enumerate keeps the wildcard a run boundary
 * (the pre-gate reading): a package no indexed module belongs to; a field wildcard whose type
 * does not resolve to exactly one declaration, is a `typedef` (it may alias a class whose statics
 * are not listed here), carries a build macro, or has any supertype or interface (an inherited
 * `@:autoBuild` would add statics this index never sees); and, for a field wildcard, any explicit
 * run member whose value names cannot be enumerated — an unindexed module, an unparseable module
 * source, a field import whose owner the index does not list. The residual limit is the index's own:
 * a package split across a root the index does not hold, and a GLOBAL build macro (`--macro
 * addGlobalMetadata`) adding statics no source spells.
 *
 * A wildcard that fails is cut out of the run together with the lines that move with it, which splits the run there. One
 * pass decides every line: a cut only removes neighbours, so it never turns a wildcard that passed into one that fails.
 */
@:nullSafety(Strict)
final class WildcardImportGate {

	/** The suffix every wildcard import's path carries (`p.*`, `p.C.*`) — and no plain import's. */
	private static inline final WILDCARD_SUFFIX: String = '.*';

	/** The declaration kinds whose wildcard binds only the members marked static; every other kind binds every member. */
	private static final CLASS_KINDS: Array<String> = ['ClassDecl', 'AbstractClassDecl', 'FinalDecl', 'ClassForm'];

	/** The declaration kinds whose static set this gate refuses to read — a typedef may alias a class it cannot see. */
	private static final OPAQUE_KINDS: Array<String> = ['TypedefDecl'];

	/** Wildcard path -> what it binds; a stored null is "cannot be enumerated". */
	private final _bindings: Map<String, Null<WildcardBinding>> = [];

	/** Explicit import path -> the value names it binds; a stored null is "cannot be enumerated". */
	private final _explicitValues: Map<String, Null<Array<String>>> = [];

	/** The resolution index, asked for only once a run actually holds a wildcard beside another line. */
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
	 * `run` — directly adjacent plain AND wildcard lines — split into the runs it really is: every
	 * wildcard that may not join is cut out, and a piece left holding wildcards alone stays a run
	 * only when it holds two or more. A run with no wildcard is returned as is, and a lone wildcard
	 * is no run at all — neither ever asks the index.
	 */
	public function split(run: Array<ImportLine>): Array<Array<ImportLine>> {
		if (!run.exists(line -> isWildcard(line.path))) return [run];
		if (run.length == 1) return [];
		final pieces: Array<Array<ImportLine>> = [];
		var current: Array<ImportLine> = [];
		for (line in run) {
			if (!isWildcard(line.path) || joins(line, run)) {
				current.push(line);
				continue;
			}
			if (current.length > 0) pieces.push(current);
			current = [];
		}
		if (current.length > 0) pieces.push(current);
		return pieces.filter(piece -> piece.length > 1 || !isWildcard(piece[0].path));
	}

	/** Whether the wildcard `line` may stay in `piece` — see the class doc's three questions. */
	private function joins(line: ImportLine, piece: Array<ImportLine>): Bool {
		final mine: Null<WildcardBinding> = bindingOf(line.path);
		if (mine == null) return false;
		for (other in piece) if (other != line) {
			if (isWildcard(other.path)) {
				final theirs: Null<WildcardBinding> = bindingOf(other.path);
				if (theirs == null || shares(mine.types, theirs.types) || shares(mine.values, theirs.values)) return false;
				continue;
			}
			if (mine.values.length == 0) continue;
			final values: Null<Array<String>> = explicitValuesOf(other.path);
			if (values == null || shares(mine.values, values)) return false;
		}
		return true;
	}

	/** What the wildcard `path` binds, or null when the index cannot enumerate it (memoised). */
	private function bindingOf(path: String): Null<WildcardBinding> {
		if (_bindings.exists(path)) return _bindings[path];
		final binding: Null<WildcardBinding> = readBinding(path.substring(0, path.length - WILDCARD_SUFFIX.length));
		_bindings[path] = binding;
		return binding;
	}

	/**
	 * What `import <target>.*;` binds: a PACKAGE wildcard when `target`'s last segment is
	 * lower-initial, else a FIELD wildcard over the one type `target` names.
	 */
	private function readBinding(target: String): Null<WildcardBinding> {
		if (!SourceText.isUpperInitial(SourceText.lastSegment(target))) {
			final names: Null<Array<String>> = packages()[target];
			return names == null ? null : { types: names, values: [] };
		}
		final declared: Array<TypeDeclInfo> = typesNamed(target);
		if (declared.length != 1) return null;
		final type: TypeDeclInfo = declared[0];
		final opaque: Bool = OPAQUE_KINDS.contains(type.kind) || type.hasBuild || type.hasAutoBuild || type.supertypes.length > 0
			|| type.interfaces.length > 0;
		if (opaque) return null;
		final statics: Bool = CLASS_KINDS.contains(type.kind);
		return { types: [], values: [for (m in type.members) if (!statics || m.isStatic) m.name] };
	}

	/**
	 * The VALUE names the explicit import `path` binds, or null when they cannot be enumerated:
	 * a module import brings its module-level fields, a secondary-type import nothing, and a field
	 * import its own leaf. A type's own name is a TYPE and never meets a field wildcard's values.
	 */
	private function explicitValuesOf(path: String): Null<Array<String>> {
		if (_explicitValues.exists(path)) return _explicitValues[path];
		final values: Null<Array<String>> = readExplicitValues(path);
		_explicitValues[path] = values;
		return values;
	}

	private function readExplicitValues(path: String): Null<Array<String>> {
		final files: Null<Array<FileInfo>> = modules()[path];
		if (files != null) {
			final out: Array<String> = [];
			for (file in files) {
				final fields: Null<Array<String>> = moduleFieldsOf(file);
				if (fields == null) return null;
				for (name in fields) if (!out.contains(name)) out.push(name);
			}
			return out;
		}
		final leaf: String = SourceText.lastSegment(path);
		final owner: String = SourceText.parentPath(path);
		final secondary: Null<Array<FileInfo>> = modules()[owner];
		if (secondary != null && secondary.exists(f -> f.types.exists(t -> t.name == leaf))) return [];
		final owners: Array<TypeDeclInfo> = typesNamed(owner);
		return owners.length > 0 && owners.foreach(t -> t.members.exists(m -> m.name == leaf)) ? [leaf] : null;
	}

	/**
	 * The module-level FIELD names `file` declares — Haxe 4.2's module statics, which an explicit
	 * import of the module brings in unqualified — read from its retained source, or null when the
	 * source is not retained or does not parse. Every named top-level declaration counts, looking
	 * through nameless wrappers (a `final`, a `#if` region) — minus the types the index lists and
	 * the import-family statements.
	 */
	private function moduleFieldsOf(file: FileInfo): Null<Array<String>> {
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
	 * The gate an insert seat holding only `plugin` can build: over the host's RESOLUTION index when
	 * the run carries one, else null — no index, no proof, and every wildcard stays a boundary.
	 */
	public static function forPlugin(plugin: GrammarPlugin): Null<WildcardImportGate> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		if (host == null || !host.hasAnyResolutionScope()) return null;
		final resolver: SymbolIndexHost = host;
		return new WildcardImportGate(() -> resolver.resolutionIndex(), plugin);
	}

	private static inline function shares(a: Array<String>, b: Array<String>): Bool {
		return a.exists(name -> b.contains(name));
	}

}
