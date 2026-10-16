package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.FileInfo;

/**
 * Whether a bare `case` pattern name may resolve, from one file, to a VALUE the pattern compares
 * against rather than capture — asked of every tier the compiler consults for a pattern identifier
 * (probed on Haxe 4.3.7 `--interp`), and answered "may" wherever a tier cannot be read.
 *
 * The tiers that COMPARE: a `static` final or inline field of the enclosing type, a module-level
 * field of the file (`FileInfo.moduleFields`), a constructor or value of an enum / `enum abstract`
 * of the module, and a value an import brings in — a static, a constructor or value of a type it
 * puts in scope, a module-level field of a module it names whole — the file's own imports and the
 * whole ambient `import.hx` chain alike, as the shared binding reads them
 * (`ValueNameBinding.mayImportValue`). The expected type (the switch subject's) is
 * `CasePatterns.subjectProof`'s question. The tiers that do NOT compare, and are therefore not
 * asked: a local (the capture shadows it), an instance field, a method, a `static var`, a
 * supertype's static, a `using` static, a package wildcard's types, the package and the toplevel
 * (`trace`).
 *
 * The in-file tiers are read OVER-inclusively (every static member counts), since a "may" only
 * ever refuses. An import whose target the index does not hold, and an ambient chain the index
 * could not bound, answer "may": the name is then undecided.
 */
@:nullSafety(Strict)
final class PatternNameScope {

	/** The parsed file the scope answers for. */
	public final root: QueryNode;

	public final shape: RefShape;
	private final _local: Array<String>;
	private final _fi: FileInfo;
	private final _index: SymbolIndex;

	private function new(root: QueryNode, plugin: GrammarPlugin, local: Array<String>, fi: FileInfo, index: SymbolIndex) {
		this.root = root;
		shape = plugin.refShape();
		_local = local;
		_fi = fi;
		_index = index;
	}

	/** The scope of `file` (whose parsed tree is `root`), or null when the index does not hold the file — nothing can then be proven. */
	public static function of(file: String, root: QueryNode, plugin: GrammarPlugin, index: SymbolIndex): Null<PatternNameScope> {
		final fi: Null<FileInfo> = index.fileInfo(file);
		if (fi == null) return null;
		final local: Array<String> = CasePatterns.constantNames([root], plugin.refShape());
		for (name in fi.moduleFields) if (!local.contains(name)) local.push(name);
		return new PatternNameScope(root, plugin, local, fi, index);
	}

	/** Whether `name` may resolve to a value a bare pattern compares against, from this file. */
	public function mayCompare(name: String): Bool {
		return !_fi.ambientImportsBounded || _local.contains(name) || _index.values.mayImportValue(_fi, name);
	}

}
