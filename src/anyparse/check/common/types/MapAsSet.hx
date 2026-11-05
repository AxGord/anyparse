package anyparse.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.loops.MapValueScan;
import anyparse.query.IndexScope;
import anyparse.query.ShapeVocab;
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
 *
 * A set that GROWS is not reported: an array makes every `contains` a linear scan, which is quadratic once the keys are
 * added inside a loop, a local function or a member the map outlives, other than the constructor (a `visited` / `seen`
 * set, a memo) — the hash lookup is the right structure there. A function that also spans the map's own declaration does
 * not count: that map is fresh each call.
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
		final repeating: Array<String> = ShapeVocab.loopKinds(shape).concat(ShapeVocab.nestedFunctionKinds(shape));
		final functions: Array<String> = shape.functionKinds ?? [];
		final seams: Null<ValueSeams> = MapValueScan.seamsOf(shape);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final boolName: Null<String> = shape.nonNullBoolTypeName;
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		if (seams == null || provider == null || boolName == null || mapTypes.length == 0) return [];
		final census: ValueSeams = seams;
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
				final ask: GrowthQuery = {
					name: name,
					declAt: from,
					seams: census,
					repeating: repeating,
					functions: functions,
					constructor: shape.constructorName
				};
				if (growsInRepetition(root, null, -1, null, -1, false, ask)) return;
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

	/**
	 * Whether `node`'s subtree stores a key into the map `ask.name` (`m[k] = true`, `m.set(k, true)`) while a repetition
	 * is running: inside a loop, a nested function or a member the map outlives other than the constructor (`inside`). A
	 * repetition spanning the declaration `ask.declAt` rebuilds the map each turn, so it opens none. `parent` / `grand` are the two
	 * ancestors with the slots they hold their child in.
	 */
	private static function growsInRepetition(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, inside: Bool, ask: GrowthQuery
	): Bool {
		if (node.name == ask.name && inside && storesInto(parent, parentSlot, grand, grandSlot, ask.seams)) return true;
		final span: Null<Span> = node.span;
		final opensMap: Bool = span != null && span.from <= ask.declAt && ask.declAt < span.to;
		final callable: Bool = ask.functions.contains(node.kind) && node.name != ask.constructor;
		final nowInside: Bool = inside || (!opensMap && (ask.repeating.contains(node.kind) || callable));
		for (i in 0...node.children.length) if (growsInRepetition(node.children[i], node, i, parent, parentSlot, nowInside, ask))
			return true;
		return false;
	}

	/** Whether the receiver occurrence under `parent` / `grand` stores a key: an index assignment target or a `set` call. */
	private static function storesInto(
		parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, seams: ValueSeams
	): Bool {
		return parent != null && grand != null && parentSlot == 0 && grandSlot == 0 && (
			parent.kind == seams.indexAccessKind
			&& grand.kind == seams.assignKind
			|| parent.kind == seams.fieldAccessKind
			&& parent.name == MapValueScan.SET_METHOD
			&& grand.kind == seams.callKind
		);
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

/**
 * What `growsInRepetition` asks: the map's name and declaration offset,
 * the census seams, and the kinds that repeat or declare a function.
 */
private typedef GrowthQuery = {
	final name: String;
	final declAt: Int;
	final seams: ValueSeams;
	final repeating: Array<String>;
	final functions: Array<String>;
	final constructor: Null<String>;
};
