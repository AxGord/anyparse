package anyparse.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.loops.MapValueScan;
import anyparse.query.IndexScope;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeSyntax;

/**
 * Flags a map declared with boolean values (`Map<K, Bool>`) that is only ever a SET of its keys: every value it stores is
 * the literal `true` and every use asks membership (`exists`, an index read, `keys`, `remove`). An array of the keys with
 * `contains` says the same with no value to misread. `Severity.Info`, report-only, DEFAULT OFF: the rewrite trades a hash
 * lookup for a linear scan, which is the project's call.
 *
 * Whether the map is a set is `MapValueScan`'s occurrence census under `MapClaim.KeySet`: the one census that already
 * proves what a map can hold, so a local is censused in its file and a non-public member through every file that can
 * reach it. The declared type is read from the written annotation (`TypeInfoProvider.declaredTypeSources`); an
 * unannotated binding and a nullable wrapper are not asked.
 */
@:nullSafety(Strict)
final class MapAsSet extends RuleBase implements DefaultOff implements NoAutofix {

	private static inline final RULE_ID: String = 'map-as-set';

	/** A map type spells its key and its value. */
	private static inline final MAP_ARGUMENTS: Int = 2;

	public function new() {
		super(RULE_ID, 'a Map<K, Bool> used only as a set of keys — an Array<K> with contains() says the same', RuleCategory.Types);
	}

	public function noAutofixReason(): String {
		return 'whether a linear scan of an array may replace the hash lookup is the project\'s call';
	}

	/** Report-only (`noAutofixReason`). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final seams: Null<ValueSeams> = MapValueScan.seamsOf(shape);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final boolName: Null<String> = shape.nonNullBoolTypeName;
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		if (seams == null || provider == null || boolName == null || mapTypes.length == 0) return [];
		// The REPORT index, as `redundant-map-exists` hands the census: it reads the report scope's skipped files as
		// the proof that nothing is hidden, and resolves the wider subtype and grant scope itself.
		var reportIndex: Null<SymbolIndex> = null;
		return RunScan.collect(files, plugin, (entry, root, out) -> {
			final written: Map<Int, String> = provider.declaredTypeSources(entry.source);
			eachDeclaration(root, seams.declKinds, (decl, name, from) -> {
				final key: Null<String> = keyOfSet(written[from], plugin.typeSyntax, mapTypes, boolName);
				final span: Null<Span> = decl.span;
				if (key == null || span == null) return;
				final index: SymbolIndex = reportIndex ?? IndexScope.report(files, plugin);
				reportIndex = index;
				if (!MapValueScan.proven(name, from, entry.source, root, index, plugin, seams, KeySet)) return;
				out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: '\'$name\' is a map whose every value is true, used only as a set of keys — Array<$key'
					+ '> with contains() says the same'
				});
			});
		});
	}

	/** Call `sink` with every declaration of a `declKinds` kind under `node` that carries a name and a span. */
	private static function eachDeclaration(node: QueryNode, declKinds: Array<String>, sink: (QueryNode, String, Int) -> Void): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (declKinds.contains(node.kind) && name != null && span != null) sink(node, name, span.from);
		for (c in node.children) eachDeclaration(c, declKinds, sink);
	}

	/**
	 * The key type's text when `written` is a map type (`mapTypes`) whose value type is the boolean `boolName`, else null —
	 * a nullable wrapper around the map included, which a set of keys would not be written as.
	 */
	private static function keyOfSet(
		written: Null<String>, typeSyntax: TypeSyntaxReader, mapTypes: Array<String>, boolName: String
	): Null<String> {
		final type: Null<TypeSyntax> = written == null ? null : typeSyntax(written);
		return switch type?.shape {
			case Nominal(path, args) if (args.length == MAP_ARGUMENTS && mapTypes.contains(SourceText.lastSegment(path))):
				switch args[1].shape {
					case Nominal(value, []) if (SourceText.lastSegment(value) == boolName): args[0].text;
					case _: null;
				}
			case _: null;
		};
	}

}
