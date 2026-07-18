package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;

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
 * `Refs.walkMulti` resolution is per-name independent — `ScopeFrame.declare`
 * is first-wins PER NAME, and both hit emission and frame priming gate on
 * `out.exists(name)` per name — so priming with extra names never changes
 * what another name resolves to.
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

	public function new() {}

	/**
	 * Every reference / declaration of `name` in `tree`, resolved against
	 * the memoized full-tree index — a copy, safe for the caller to mutate.
	 */
	public function find(name: String, tree: QueryNode, shape: RefShape): Array<RefHit> {
		final hits: Null<Array<RefHit>> = indexFor(tree, shape)[name];
		return hits == null ? [] : hits.copy();
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
