package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.MapValueScan.ValueSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a map lookup spelled as a membership test followed by an index read —
 * `m.exists(k) ? m[k] : d` — which the null-coalescing operator collapses to `m[k] ?? d`,
 * halving the hash lookups. `Severity.Info`, DEFAULT OFF, with an autofix that fires only
 * where a stored null value is PROVEN impossible.
 *
 * ## The null-value gate is real, not theoretical
 *
 * The two forms diverge on exactly one input: a key PRESENT in the map whose stored VALUE is
 * null. The ternary answers that stored `null`; `??` answers the default. So the rewrite is
 * a behaviour change unless no null value can ever be in the map, and that proof —
 * an occurrence census over the whole resolution scope — is `MapValueScan`'s job. Where it
 * fails, the site is still reported (the double lookup is worth a human's attention) but
 * carries no fix; the message says so.
 *
 * ## Why the shape is narrow
 *
 * The receiver must be a BARE IDENTIFIER whose declared type resolves to the grammar's Map
 * abstract. Two reasons, and each is load-bearing: the `??` rewrite relies on a missing key
 * reading as `null`, which is the Map abstract's contract and not a general one; and the
 * census needs a single name to enumerate — a path receiver (`this.m`, `a.b.m`) names an
 * object the census cannot follow. Both `m` and `k` are evaluated TWICE by the ternary and
 * once after the rewrite, so a key whose subtree calls, constructs or assigns is refused:
 * the original is already order-dependent there, and the rule fails closed rather than
 * silently picking one of the two behaviours. The receiver is pure by construction.
 *
 * The two `m` occurrences and the two `k` occurrences must be textually identical
 * (`RefactorSupport.sameSource`), and a comment in either dropped region — `m.exists(k) ?`
 * and the ` : ` before the default — refuses the fix rather than deleting it. A fallback
 * that is itself a bare ternary is parenthesized, since `??` binds tighter than `?:`.
 * Nested matches are flagged outermost-first and not descended into; an inner one is caught
 * on the next `--fix` pass, exactly as `prefer-null-coalescing` does it.
 *
 * ## Sister forms deliberately NOT claimed
 *
 * `m.exists(k) ? m.get(k) : d` and the inverted `!m.exists(k) ? d : m[k]` were measured at
 * ZERO sites across a ~800-file application. The first is `prefer-index-access`'s job one
 * pass earlier (it rewrites `m.get(k)` to `m[k]`, after which this rule matches); the
 * second would add an inversion arm for a shape nothing in the corpus writes.
 *
 * ## Whole-project scope required
 *
 * The census is only sound when it can see every file that references the map — the same
 * contract `prefer-final-field` documents. The check is registered among the `--fix` loop's
 * full-scope ids so later passes keep the whole set.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ternaryKind`, `callKind`, `fieldAccessKind`, `indexAccessKind`, `identKind` and
 * `mapExistsMethods` plus `mapAbstractTypeNames` for the receiver gate (any unset → no-op),
 * and by `MapValueScan.seamsOf` for the proof. All type resolution requires
 * `plugin is TypeInfoProvider`.
 */
@:nullSafety(Strict)
final class RedundantMapExists implements Check implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'redundant-map-exists';

	/** A complete ternary node has children [cond, then, else]. */
	private static inline final TERNARY_CHILD_COUNT: Int = 3;

	/** `m.exists(k)` is a call with [callee, key]. */
	private static inline final EXISTS_CALL_CHILDREN: Int = 2;

	/** `m[k]` is an index access with [receiver, key]. */
	private static inline final INDEX_CHILD_COUNT: Int = 2;

	/** The message for a site whose no-null-value proof cleared — the one that gets a fix. */
	private static inline final FIXABLE_MESSAGE: String = 'this exists-then-index map lookup can be map[key] ?? default';

	/** The message for a site the census could not prove; reported for a human, never fixed. */
	private static inline final UNPROVEN_MESSAGE: String =
		'this exists-then-index map lookup reads like map[key] ?? default, but a stored null value cannot be ruled out';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a map exists-then-index ternary (m.exists(k) ? m[k] : d) replaceable with the null-coalescing lookup (m[k] ?? d)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final c: Cfg = cfg;
		final valueSeams: Null<ValueSeams> = MapValueScan.seamsOf(c.shape);
		// The REPORT index deliberately, not `lazySymbolIndex` (which prefers the resolution
		// one): `MapValueScan` reads its `skippedFiles` as the "nothing is hidden from the
		// scan" proof, and on any project with libraries configured the resolution index's
		// skipped set is permanently non-empty — which silently refused every site. The
		// subtype and access-grant lookups inside the census resolve their own wider scope.
		var reportIndex: Null<SymbolIndex> = null;
		final resolveSymbols: () -> SymbolIndex = () -> {
			final built: SymbolIndex = reportIndex ?? SymbolIndex.build(files, plugin);
			reportIndex = built;
			return built;
		};
		final proven: Map<String, Bool> = [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = c.typed.declaredTypes(entry.source);
			final declaredTypeSources: Map<Int, String> = c.typed.declaredTypeSources(entry.source);
			collect(
				root, entry.source, root, declaredTypes, declaredTypeSources, c, m -> violations.push({
					file: entry.file,
					span: m.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: isProven(m, entry.file, entry.source, root, valueSeams, resolveSymbols(), plugin, proven)
						? FIXABLE_MESSAGE
						: UNPROVEN_MESSAGE
				})
			);
		}
		return violations;
	}

	/**
	 * Rewrite each PROVEN site to `<index read> ?? <default>`. The proof is re-derived here
	 * rather than carried over from `run`: a check's `fix` is handed one file's source and
	 * its own violations, and the census reads the whole resolution scope, so the answer
	 * cannot travel in a `Violation`. An unproven site simply yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final c: Cfg = cfg;
		final valueSeams: Null<ValueSeams> = MapValueScan.seamsOf(c.shape);
		if (valueSeams == null) return [];
		final scope: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		if (scope == null) return [];
		final resolved: SymbolIndex = scope;
		final root: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (root == null) return [];
		final tree: QueryNode = root;
		final declaredTypes: Map<Int, String> = c.typed.declaredTypes(source);
		final declaredTypeSources: Map<Int, String> = c.typed.declaredTypeSources(source);
		final proven: Map<String, Bool> = [];
		final file: String = violations.length > 0 ? violations[0].file : '';
		return RefactorSupport.dropContainedEdits(CheckScan.applyBySpan(plugin, source, violations, [c.ternaryKind], (node, span) -> {
			final m: Null<Match> = match(node, source, tree, declaredTypes, declaredTypeSources, c);
			return m == null || !isProven(m, file, source, tree, valueSeams, resolved, plugin, proven)
				? null
				: { span: span, text: '${m.readSource} ?? ${m.fallbackSource}' };
		}));
	}

	/**
	 * The cached no-null-value verdict for the map `m` binds, false when no proof is
	 * available at all. Keyed on the BINDING, not the name: the census is owner-scoped, so
	 * two same-named maps in different types get their own verdicts.
	 */
	private static function isProven(
		m: Match, file: String, source: String, root: QueryNode, seams: Null<ValueSeams>, index: Null<SymbolIndex>, plugin: GrammarPlugin,
		cache: Map<String, Bool>
	): Bool {
		if (seams == null) return false;
		final key: String = '$file:${m.bindingFrom}';
		final cached: Null<Bool> = cache[key];
		if (cached != null) return cached;
		final verdict: Bool = MapValueScan.proven(m.name, m.bindingFrom, source, root, index, plugin, seams);
		cache[key] = verdict;
		return verdict;
	}

	/**
	 * Walk `node`, invoking `sink` for the OUTERMOST matching ternary on each path — a nested
	 * match inside one would yield an overlapping edit, and is caught on the next `--fix`
	 * pass once the outer rewrite has re-parsed.
	 */
	private static function collect(
		node: QueryNode, source: String, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>, cfg: Cfg,
		sink: Match -> Void
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.ternaryKind) {
			final m: Null<Match> = match(node, source, root, declaredTypes, declaredTypeSources, cfg);
			if (m != null) {
				sink(m);
				return;
			}
		}
		for (c in node.children) collect(c, source, root, declaredTypes, declaredTypeSources, cfg, sink);
	}

	/**
	 * If `ternary` is `m.exists(k) ? m[k] : d` on a bare Map-typed identifier with a pure key
	 * and no comment in either dropped region, return the rewrite's parts; else null.
	 */
	private static function match(
		ternary: QueryNode, source: String, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>,
		cfg: Cfg
	): Null<Match> {
		final shape: Null<Shape> = structuralShape(ternary, source, cfg);
		if (shape == null) return null;
		final recv: QueryNode = shape.recv;
		final read: QueryNode = shape.read;
		final fallback: QueryNode = shape.fallback;
		final name: String = shape.name;
		final bindingFrom: Null<Int> = mapBindingOf(recv, root, declaredTypes, declaredTypeSources, cfg);
		if (bindingFrom == null) return null;
		final ternarySpan: Null<Span> = ternary.span;
		final readSpan: Null<Span> = read.span;
		final fallbackSpan: Null<Span> = fallback.span;
		if (ternarySpan == null || readSpan == null || fallbackSpan == null) return null;
		// The rewrite keeps the index read and the default verbatim and drops everything
		// between them; a comment in either dropped region would be deleted with it.
		if (
			RefactorSupport.textHasCommentMarker(source.substring(ternarySpan.from, readSpan.from))
			|| RefactorSupport.textHasCommentMarker(source.substring(readSpan.to, fallbackSpan.from))
		)
			return null;
		final fallbackSource: String = source.substring(fallbackSpan.from, fallbackSpan.to);
		return {
			span: ternarySpan,
			name: name,
			bindingFrom: bindingFrom,
			readSource: source.substring(readSpan.from, readSpan.to),
			fallbackSource: fallback.kind == cfg.ternaryKind ? '($fallbackSource)' : fallbackSource
		};
	}

	/**
	 * The `m.exists(k) ? m[k] : d` shape of `ternary`, with the two `m` and the two `k`
	 * occurrences proven textually identical and the key proven pure — or null. The TYPE gate and
	 * the comment gate belong to `match`, which layers them on top; this half needs no resolution.
	 */
	private static function structuralShape(ternary: QueryNode, source: String, cfg: Cfg): Null<Shape> {
		if (ternary.children.length != TERNARY_CHILD_COUNT) return null;
		final cond: QueryNode = ternary.children[0];
		final read: QueryNode = ternary.children[1];
		if (cond.kind != cfg.callKind || cond.children.length != EXISTS_CALL_CHILDREN) return null;
		final callee: QueryNode = cond.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldAccessKind || method == null || !cfg.existsMethods.contains(method) || callee.children.length != 1)
			return null;
		final recv: QueryNode = callee.children[0];
		final name: Null<String> = recv.name;
		if (recv.kind != cfg.identKind || name == null) return null;
		if (read.kind != cfg.indexAccessKind || read.children.length != INDEX_CHILD_COUNT) return null;
		final key: QueryNode = cond.children[1];
		if (!RefactorSupport.sameSource(recv, read.children[0], source) || !RefactorSupport.sameSource(key, read.children[1], source))
			return null;
		// `m` and `k` are evaluated TWICE by the ternary and once after the rewrite, so an
		// impure key means the original is already order-dependent; fail closed there.
		for (k in cfg.mutationKinds) if (RefactorSupport.subtreeContainsKind(key, k)) return null;
		return {
			recv: recv,
			read: read,
			fallback: ternary.children[2],
			name: name
		};
	}

	private static function mapBindingOf(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>, cfg: Cfg
	): Null<Int> {
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, root, cfg.shape);
		if (bindingFrom == null) return null;
		final at: Int = bindingFrom;
		final typeName: Null<String> = declaredTypes[at];
		return typeName != null && MapNominal.isMap(typeName, declaredTypeSources[at], cfg.mapTypes, cfg.nullableWrappers) ? at : null;
	}

	/** Resolve the per-grammar seams + type provider, or null when the grammar lacks a needed kind / type info. */
	private static function config(plugin: GrammarPlugin): Null<Cfg> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		if (ternaryKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind == null) return null;
		final existsMethods: Array<String> = shape.mapExistsMethods ?? [];
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		if (existsMethods.length == 0 || mapTypes.length == 0) return null;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		return provider == null ? null : {
			shape: shape,
			typed: provider,
			ternaryKind: ternaryKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			indexAccessKind: indexAccessKind,
			identKind: shape.identKind,
			existsMethods: existsMethods,
			mapTypes: mapTypes,
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			mutationKinds: CheckScan.mutationKinds(shape)
		};
	}

}

/**
 * The structural half of a match — the nodes, before any type or comment gate.
 */
private typedef Shape = {
	final recv: QueryNode;
	final read: QueryNode;
	final fallback: QueryNode;
	final name: String;
}
/**
 * One matched `m.exists(k) ? m[k] : d` site and the verbatim parts its rewrite keeps.
 */
private typedef Match = {
	final span: Span;
	final name: String;
	final bindingFrom: Int;
	final readSource: String;
	final fallbackSource: String;
};

/** Per-run resolved seams + type provider. */
private typedef Cfg = {
	final shape: RefShape;
	final typed: TypeInfoProvider;
	final ternaryKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final indexAccessKind: String;
	final identKind: String;
	final existsMethods: Array<String>;
	final mapTypes: Array<String>;
	final nullableWrappers: Array<String>;
	final opaqueKinds: Array<String>;
	final mutationKinds: Array<String>;
};
