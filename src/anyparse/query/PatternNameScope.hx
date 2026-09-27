package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import haxe.Exception;

using Lambda;

/**
 * Whether a bare `case` pattern name may resolve, from one file, to a VALUE the pattern compares
 * against rather than capture — asked of every tier the compiler consults for a pattern identifier
 * (probed on Haxe 4.3.7 `--interp`), and answered "may" wherever a tier cannot be read.
 *
 * The tiers that COMPARE: a `static` final or inline field of the enclosing type, a module-level
 * field of the file, a constructor or value of an enum / `enum abstract` of the module, a static
 * brought in by an explicit, aliased or wildcard (`Type.*`) import, and a constructor or value of a
 * type an import brings in — the file's own imports and the whole ambient `import.hx` chain alike.
 * The expected type (the switch subject's) is `CasePatterns.subjectProof`'s question. The tiers that
 * do NOT compare, and are therefore not asked: a local (the capture shadows it), an instance field,
 * a method, a `static var`, a supertype's static, a `using` static, a package wildcard's types, the
 * package and the toplevel (`trace`).
 *
 * The in-file tiers are read OVER-inclusively (every static member and every module-level name
 * counts), since a "may" only ever refuses. An import whose target the index does not hold, and an
 * ambient chain the index could not bound, answer "may": the name is then undecided.
 */
@:nullSafety(Strict)
final class PatternNameScope {

	/** The last segment of a wildcard import path. */
	private static inline final WILDCARD_SEGMENT: String = '*';

	/** The parsed file the scope answers for. */
	public final root: QueryNode;

	public final shape: RefShape;
	private final _local: Array<String>;
	private final _fi: FileInfo;
	private final _index: SymbolIndex;
	private final _plugin: GrammarPlugin;

	/** The module-level names of every imported module read so far, by module file. */
	private final _moduleNames: Map<String, Null<Array<String>>> = [];

	private function new(root: QueryNode, plugin: GrammarPlugin, local: Array<String>, fi: FileInfo, index: SymbolIndex) {
		this.root = root;
		shape = plugin.refShape();
		_plugin = plugin;
		_local = local;
		_fi = fi;
		_index = index;
	}

	/** The scope of `file` (whose parsed tree is `root`), or null when the index does not hold the file — nothing can then be proven. */
	public static function of(file: String, root: QueryNode, plugin: GrammarPlugin, index: SymbolIndex): Null<PatternNameScope> {
		final shape: RefShape = plugin.refShape();
		final fi: Null<FileInfo> = index.fileInfo(file);
		if (fi == null) return null;
		final local: Array<String> = CasePatterns.constantNames([root], shape);
		for (name in moduleLevelNames(root, shape)) if (!local.contains(name)) local.push(name);
		return new PatternNameScope(root, plugin, local, fi, index);
	}

	/** Whether `name` may resolve to a value a bare pattern compares against, from this file. */
	public function mayCompare(name: String): Bool {
		if (!_fi.ambientImportsBounded || _local.contains(name)) return true;
		if (_fi.imports.exists(imp -> importMayBind(imp, name))) return true;
		return _fi.ambientImports.exists(group -> group.imports.exists(imp -> importMayBind(imp, name)));
	}

	/**
	 * Every name the file declares at MODULE level — a module-level field or function, looked for
	 * among the root's children and one level into a nameless wrapper (a modifier run projects the
	 * declaration as its child). Type and import names come along harmlessly: they never capture.
	 */
	private static function moduleLevelNames(root: QueryNode, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (node in root.children) {
			final name: Null<String> = node.name;
			if (name != null) {
				if (CasePatterns.isCaptureSpelling(name, shape) && !out.contains(name)) out.push(name);
				continue;
			}
			for (child in node.children) {
				final inner: Null<String> = child.name;
				if (inner != null && CasePatterns.isCaptureSpelling(inner, shape) && !out.contains(inner)) out.push(inner);
			}
		}
		return out;
	}

	/** Whether one import statement may bring a value named `name` into the file unqualified. */
	private function importMayBind(imp: ImportInfo, name: String): Bool {
		return switch imp.kind {
			case ImportKind.Using: false;
			case ImportKind.Alias:
				final target: Null<String> = imp.aliasTarget;
				imp.alias == name || (target == null ? true : typeMayCarry(target, name, false));
			case ImportKind.Wild:
				final prefix: String = parentPath(imp.raw);
				lastSegment(imp.raw) == WILDCARD_SEGMENT && SourceText.isUpperInitial(lastSegment(prefix))
					&& typeMayCarry(prefix, name, true);
			case _:
				lastSegment(imp.raw) == name || (
					SourceText.isUpperInitial(lastSegment(imp.raw)) && (typeMayCarry(imp.raw, name, false) || moduleMayCarry(imp.raw, name))
				);
		};
	}

	/**
	 * Whether the type(s) `path` names may carry a value `name` an import brings in unqualified: its
	 * statics for a wildcard (`statics`), otherwise the constructors and values of a closed or
	 * abstract type — together with the sub-types of the module `path` names. A path the index does
	 * not resolve may carry anything.
	 */
	private function typeMayCarry(path: String, name: String, statics: Bool): Bool {
		final types: Array<ResolvedType> = _index.refs.resolveQualifiedRefAll(path);
		for (f in _index.allFiles()) if (f.module == path) for (t in f.types) types.push({ file: f, type: t });
		if (types.length == 0) return true;
		final valueHosts: Array<String> = (shape.bareConstructorTypeKinds ?? []).concat(shape.aliasingDeclKinds ?? []);
		for (resolved in types) {
			final hostsValues: Bool = statics || valueHosts.contains(resolved.type.kind);
			final implicitStatics: Bool = valueHosts.contains(resolved.type.kind);
			if (hostsValues && resolved.type.members.exists(m -> m.name == name && (!statics || m.isStatic || implicitStatics)))
				return true;
		}
		return false;
	}

	/**
	 * Whether the module `path` names declares a module-level field `name`: importing a whole module
	 * (`import pk.Mod;`) brings its module-level fields in unqualified, and a bare pattern compares
	 * against them — a wildcard over the module or its package does not. A module file whose source
	 * the index does not hold, or that does not parse, may declare anything.
	 */
	private function moduleMayCarry(path: String, name: String): Bool {
		for (f in _index.allFiles()) if (f.module == path) {
			final names: Null<Array<String>> = moduleNamesOf(f.file);
			if (names == null || names.contains(name)) return true;
		}
		return false;
	}

	/** The module-level names of `file`, read once; null when its source is unknown or does not parse. */
	private function moduleNamesOf(file: String): Null<Array<String>> {
		if (_moduleNames.exists(file)) return _moduleNames[file];
		final source: Null<String> = _index.sourceOf(file);
		final names: Null<Array<String>> = source == null
			? null
			: try moduleLevelNames(_plugin.parseFile(source), shape) catch (_: Exception) null;
		_moduleNames[file] = names;
		return names;
	}

	private static inline function lastSegment(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	private static inline function parentPath(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot < 0 ? '' : path.substring(0, dot);
	}

}
