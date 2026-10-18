package anyparse.query;

import anyparse.check.NullFlow.NullFlowVisit;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.TypeResolver.NullSafetyScope;

/**
 * Run-scoped memoization of `Refs.find`, keyed by tree identity.
 *
 * The analysis checks (NullFlow family, NullableSource, AvoidDynamic,
 * PreferFinal, CallSites…) call `Refs.find` hundreds of times per file
 * against the SAME parsed tree — before this cache, every call re-walked
 * the whole tree. `indexFor` primes ONE `Refs.findMulti` walk per tree,
 * seeded with every distinct name found in it; every later `find` for
 * that tree is then a map slice.
 *
 * Per-name results are byte-identical to a solo `Refs.find` call:
 * `Refs.walkMulti` resolution is per-name independent — `ScopeFrame` keeps
 * its bindings PER NAME and resolves each name against its own list, and
 * both hit emission and frame priming gate on `out.exists(name)` per name
 * — so priming with extra names never changes what another name resolves to.
 *
 * `find` returns a COPY of the cached array: the original `Refs.find`
 * hands back a fresh array per call, and a caller mutating its result
 * (e.g. `.pop()`) must not poison the memo for the next caller.
 *
 * Instance state, no statics — create one per lint/fix run and never
 * share across threads, same lifecycle as `CachingGrammarPlugin`'s
 * `_parseCache`.
 */
@:nullSafety(Strict)
final class RefsCache {

	private final _byTree: Map<QueryNode, Map<String, Array<RefHit>>> = [];

	/** Tree -> name -> reference offset -> its binding's offset (`bindingAt`), built per name on its first question. */
	private final _bindings: Map<QueryNode, Map<String, Map<Int, Int>>> = [];

	/** Tree -> `<metaName>\t<disableArg>` -> its `@:nullSafety` scopes (`TypeResolver.collectNullSafetyScopes`). */
	private final _nullSafetyScopes: Map<QueryNode, Map<String, Array<NullSafetyScope>>> = [];

	/** Tree -> the source it was walked over and the recorded visits of its seedless `NullFlow.analyze` walk. */
	private final _nullFlowVisits: Map<QueryNode, { source: String, visits: Array<NullFlowVisit> }> = [];

	public function new() {}

	/** Drop every memo built for one of `trees` — trees the caller's own caches no longer hold, so no query can name them again. */
	public function forget(trees: Array<QueryNode>): Void {
		for (tree in trees) {
			_byTree.remove(tree);
			_bindings.remove(tree);
			_nullSafetyScopes.remove(tree);
			_nullFlowVisits.remove(tree);
		}
	}

	/**
	 * Every reference / declaration of `name` in `tree`, resolved against
	 * the memoized full-tree index — a copy, safe for the caller to mutate.
	 */
	public function find(name: String, tree: QueryNode, shape: RefShape): Array<RefHit> {
		final hits: Null<Array<RefHit>> = indexFor(tree, shape)[name];
		return hits == null ? [] : hits.copy();
	}

	/**
	 * The binding of the reference or declaration of `name` starting at `from` in `tree`: the offset its binding starts at,
	 * -1 for one that binds nothing, null when no hit of `name` starts there. Read off the memoized index (`indexFor`),
	 * one offset table per name, built on its first question.
	 */
	public function bindingAt(name: String, from: Int, tree: QueryNode, shape: RefShape): Null<Int> {
		final byName: Map<String, Map<Int, Int>> = _bindings[tree] ?? [];
		_bindings[tree] = byName;
		final known: Null<Map<Int, Int>> = byName[name];
		if (known != null) return known[from];
		final built: Map<Int, Int> = offsetTable(indexFor(tree, shape)[name] ?? []);
		byName[name] = built;
		return built[from];
	}

	/**
	 * The `@:nullSafety` scopes of `tree` under `key` (the meta name and its disable argument), built by `build` on the
	 * first question and kept for the run like every index here. The array is never handed to a caller that writes it:
	 * `TypeResolver` only iterates it.
	 */
	public function nullSafetyScopes(tree: QueryNode, key: String, build: () -> Array<NullSafetyScope>): Array<NullSafetyScope> {
		final byKey: Map<String, Array<NullSafetyScope>> = _nullSafetyScopes[tree] ?? [];
		_nullSafetyScopes[tree] = byKey;
		final known: Null<Array<NullSafetyScope>> = byKey[key];
		if (known != null) return known;
		final built: Array<NullSafetyScope> = build();
		byKey[key] = built;
		return built;
	}

	/**
	 * The recorded visits of the seedless `NullFlow.analyze` walk over `tree`, built by `record` on the first question
	 * and kept for the run. A tree asked about with a different `source` than it was recorded over is not memoised:
	 * that answer is built and handed back, and the first recording stays.
	 */
	public function nullFlowVisits(tree: QueryNode, source: String, record: () -> Array<NullFlowVisit>): Array<NullFlowVisit> {
		final known: Null<{ source: String, visits: Array<NullFlowVisit> }> = _nullFlowVisits[tree];
		if (known != null) return known.source == source ? known.visits : record();
		final visits: Array<NullFlowVisit> = record();
		_nullFlowVisits[tree] = { source: source, visits: visits };
		return visits;
	}

	/**
	 * The per-name hit index for `tree`, built on first access via one
	 * `Refs.findMulti` primed with every name found in the tree. Keyed by tree
	 * identity ONLY — correct while each tree is queried under a single shape
	 * (one plugin per run); re-keying by shape is needed before any cross-grammar reuse.
	 */
	private function indexFor(tree: QueryNode, shape: RefShape): Map<String, Array<RefHit>> {
		final cached: Null<Map<String, Array<RefHit>>> = _byTree[tree];
		if (cached != null) return cached;
		final names: Array<String> = [];
		collectNames(tree, names);
		final idx: Map<String, Array<RefHit>> = Refs.findMulti(names, tree, shape);
		_byTree[tree] = idx;
		return idx;
	}

	/** Each hit's start -> its binding's start, -1 for a hit that binds nothing (`bindingAt`). */
	public static function offsetTable(hits: Array<RefHit>): Map<Int, Int> {
		final out: Map<Int, Int> = [];
		for (h in hits) out[h.span.from] = h.bindingSpan?.from ?? -1;
		return out;
	}

	/**
	 * Collect every non-null `name` slot in `node`'s subtree, duplicates tolerated —
	 * `Refs.findMulti` dedups. Public so callers (e.g. tests validating cache
	 * equivalence) can enumerate the same name universe the cache primes with.
	 */
	public static function collectNames(node: QueryNode, out: Array<String>): Void {
		final n: Null<String> = node.name;
		if (n != null) out.push(n);
		for (c in node.children) collectNames(c, out);
	}

}
