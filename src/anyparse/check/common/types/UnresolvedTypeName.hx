package anyparse.check.common.types;

import anyparse.check.Check.NoAutofix;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeNameBinding;

/**
 * Flags a SIMPLE type name written in a type position that nothing binds: not a type of the file's own module, not an import
 * or alias, not the ambient `import.hx` chain, not `StdTypes`, not a type of the file's package or a parent one, not a std
 * module. Such a file does not compile, so the finding catches a dropped or mistyped import before any compile.
 * `Severity.Warning`, report-only: which module the name should have come from is the author's call.
 *
 * Whether a name binds nothing is `TypeNameBinding.bindsNothing`, which declines wherever the resolution order is not fully
 * known. The rule adds its own declines: a dotted path, a type parameter declared anywhere in the file, a name that does not
 * start with a capital, and macro-reification subtrees (`RefShape.opaqueKinds`).
 */
@:nullSafety(Strict)
final class UnresolvedTypeName extends RuleBase implements NoAutofix {

	private static inline final RULE_ID: String = 'unresolved-type-name';

	public function new() {
		super(RULE_ID, 'a type name that no import, package or std module binds', RuleCategory.Types);
	}

	public function noAutofixReason(): String {
		return 'which module the name belongs to is the author\'s call';
	}

	/** Report-only (`noAutofixReason`). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		if (provider == null) return [];
		final kinds: Array<String> = plugin.typeRefShape().typeRefKinds;
		final opaqueKinds: Array<String> = plugin.refShape().opaqueKinds ?? [];
		final index: SymbolIndex = IndexScope.resolution(files, plugin);
		final names: TypeNameBinding = index.refs.names;
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (info == null) return;
			final written: FileInfo = info;
			final declared: Array<String> = [for (params in provider.typeParamNames(entry.source)) for (p in params) p];
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				final name: Null<String> = node.name;
				final span: Null<Span> = node.span;
				if (
					name != null
					&& span != null
					&& kinds.contains(node.kind)
					&& isTypeName(name)
					&& !declared.contains(name)
					&& names.bindsNothing(name, written, span.from)
				) out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: '\'$name\' is bound by no import, package or std module this run can see'
				});
				for (c in node.children) walk(c);
			}
			walk(tree);
		}, CheckScan.parseTypeRefsOrNull);
	}

	/** A simple name that starts with a capital: the shape every type name has. */
	private static function isTypeName(name: String): Bool {
		final first: String = name.charAt(0);
		return name.indexOf('.') < 0 && first.toUpperCase() == first && first.toLowerCase() != first;
	}

}
